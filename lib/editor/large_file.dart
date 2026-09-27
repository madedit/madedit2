import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'encoding/text_codec.dart' show unitValueAt;

/// Large-file backend: loads only the parts needed for editing/viewing.
///
/// Navigation uses **byte anchors** (no index needed, zero scanning on open).
/// Line numbers / total line count come from an optional **chunk line-count
/// table** index: the file is cut into fixed-size chunks, each counting its
/// `\n` independently (0x0A is unambiguous in UTF-8, so any split is safe);
/// line counts over byte ranges are additive.
///
///   - Several isolates scan different chunk segments **in parallel** (front
///     segment first, so prefix line numbers become exact as early as possible).
///   - Once the contiguous prefix `[0..K)` is scanned, absolute line numbers for
///     offsets below K are exact; unscanned areas get an **estimate**.
///   - Tiny memory footprint: 1GB / 1MB chunks = about 1024 counters.
///
/// Pure dart:io/isolate, no Flutter dependency; testable standalone with `dart run`.
class LargeFile {
  LargeFile._(this.path);

  final String path;
  late RandomAccessFile _raf;
  bool _rafOpen = false; // false once suspended/closed (see suspend/reopen)
  int _totalBytes = 0;

  // ── chunk line-count table ──
  int _chunkSize = 1 << 20; // 1MB
  int _numChunks = 0;
  late List<int?> _chunkLines; // \n count per chunk (null = not scanned yet)
  late List<int> _cum; // _cum[i] = sum of line counts of chunks[0..i-1] (valid up to _prefixUpto)
  int _prefixUpto = 0; // chunks[0.._prefixUpto-1] are contiguously scanned (the prefix)
  int _scannedChunks = 0;
  int _scannedNewlines = 0;
  int _scannedBytes = 0;
  bool _indexDone = false;
  bool _indexStarted = false;
  int _isolatesDone = 0;

  final StreamController<IndexProgress> _progressCtrl =
      StreamController<IndexProgress>.broadcast();
  Future<void> _ioLock = Future<void>.value(); // serializes file operations
  ReceivePort? _indexPort;

  static const int _readChunk = 1 << 16; // 64KB read granularity
  static const int _maxLineBytes = 1 << 20; // single-line cap (legacy window)

  // ── newline scanning configuration ──
  // A "newline" is one code unit whose value is 0x0A. For 1-byte-unit
  // encodings (UTF-8, single-byte, DBCS — none of whose trail bytes include
  // 0x0A) that is a plain byte scan; for UTF-16/32 the scan steps whole
  // units at unit-aligned file offsets (chunk sizes here are multiples of 4,
  // so units never straddle a scanning boundary).
  int _nlUnit = 1;
  bool _nlLittleEndian = true;

  /// Reconfigure how newlines are found (set from the document's codec).
  /// Changing it invalidates any line index — the chunk counts were counted
  /// under the old rules — so the index resets and can be started again.
  void configureNewlines({required int unit, required bool littleEndian}) {
    final same =
        unit == _nlUnit && (unit == 1 || littleEndian == _nlLittleEndian);
    if (same) return;
    _nlUnit = unit;
    _nlLittleEndian = littleEndian;
    _resetIndex();
  }

  void _resetIndex() {
    _indexPort?.close();
    _indexPort = null;
    _chunkLines = List<int?>.filled(_numChunks, null);
    _cum = List<int>.filled(_numChunks + 1, 0);
    _prefixUpto = 0;
    _scannedChunks = 0;
    _scannedNewlines = 0;
    _scannedBytes = 0;
    _indexDone = false;
    _indexStarted = false;
    _isolatesDone = 0;
    _markEmptyIndexed();
  }

  bool _isNl(List<int> b, int i) =>
      i + _nlUnit <= b.length &&
      unitValueAt(b, i, _nlUnit, _nlLittleEndian) == 10;

  /// Open a file (zero scanning). Call [startIndexing] when line numbers /
  /// the total line count are needed.
  static Future<LargeFile> open(String path, {int chunkSize = 1 << 20}) async {
    final lf = LargeFile._(path);
    lf._raf = await File(path).open();
    lf._rafOpen = true;
    lf._totalBytes = await lf._raf.length();
    lf._chunkSize = chunkSize;
    lf._numChunks = lf._totalBytes == 0
        ? 0
        : (lf._totalBytes + chunkSize - 1) ~/ chunkSize;
    lf._chunkLines = List<int?>.filled(lf._numChunks, null);
    lf._cum = List<int>.filled(lf._numChunks + 1, 0);
    lf._markEmptyIndexed();
    return lf;
  }

  // Zero bytes = zero chunks = nothing to scan: the index is complete from
  // the start, so the UI never offers to build one for an empty/untitled
  // document.
  void _markEmptyIndexed() {
    if (_numChunks != 0) return;
    _indexStarted = true;
    _indexDone = true;
  }

  /// A backing "file" for an untitled document: zero bytes, no file handle.
  /// Every read path bails out on the size checks before touching the
  /// (never-initialized) handle; [close] knows to skip it too.
  static Future<LargeFile> openEmpty() async {
    final lf = LargeFile._('');
    lf._chunkLines = List<int?>.filled(0, null);
    lf._cum = List<int>.filled(1, 0);
    lf._markEmptyIndexed();
    return lf;
  }

  bool get _hasFile => path.isNotEmpty;

  int get size => _totalBytes;
  int get totalBytes => _totalBytes;
  bool get indexDone => _indexDone;
  Stream<IndexProgress> get progress => _progressCtrl.stream;

  /// Build the line index now (if not already running) and wait for it. Used
  /// where an exact newline count of the whole file is needed anyway — the
  /// parallel scan is several times faster than a single-threaded read, and
  /// the chunk table then makes every later range count cheap.
  Future<void> whenIndexed({int? parallelism}) async {
    if (_indexDone) return;
    final done = progress.firstWhere((p) => p.done);
    startIndexing(parallelism: parallelism);
    if (_indexDone) return; // empty file: completed synchronously above
    await done;
  }

  double get fractionIndexed =>
      _totalBytes == 0 ? 1 : _scannedBytes / _totalBytes;

  /// Exact line count (newline count) within the contiguously scanned prefix.
  int get linesInPrefix => _cum[_prefixUpto];
  bool get _fullyScanned => _numChunks == 0 || _scannedChunks == _numChunks;

  /// Current line count: exact once fully scanned, otherwise an estimate.
  int get lineCount {
    if (_totalBytes == 0) return 0;
    if (_fullyScanned) return _cum[_numChunks] + 1;
    if (_scannedNewlines == 0) return 0;
    final avg = _scannedBytes / _scannedNewlines;
    final est =
        _scannedNewlines + ((_totalBytes - _scannedBytes) / avg).round();
    return est + 1;
  }

  // ── start the parallel index ──────────────────────────────
  /// Start the (optional) chunk line-count index. [parallelism] defaults to
  /// core count - 2 (use 1 on an HDD).
  void startIndexing({int? parallelism}) {
    if (_indexStarted) return;
    _indexStarted = true;
    if (_numChunks == 0) {
      _indexDone = true;
      _emitProgress();
      return;
    }
    final p = (parallelism ?? (Platform.numberOfProcessors - 2)).clamp(1, 16);
    final port = ReceivePort();
    _indexPort = port;
    var sinceEmit = 0;
    // Number of isolates actually spawned (fewer than p when a small file has
    // fewer chunks than p). Completion must be judged against this, otherwise
    // we wait forever for "p dones" and the index never finishes. The spawn
    // loop runs synchronously to completion before any message is processed,
    // so the handler always sees the final value of spawned.
    var spawned = 0;
    port.listen((dynamic msg) {
      final m = msg as List;
      if (m.length == 1 && m[0] == 'done') {
        _isolatesDone++;
        if (_isolatesDone >= spawned) {
          _indexDone = true;
          _emitProgress();
          port.close();
        }
        return;
      }
      _applyChunk(m[0] as int, m[1] as int, m[2] as int);
      if (++sinceEmit >= 16) {
        sinceEmit = 0;
        _emitProgress();
      }
    });

    // Contiguous block assignment: isolate 0 takes the front segment so the
    // prefix becomes exact early; the rest work in parallel further along.
    final block = (_numChunks + p - 1) ~/ p;
    for (var i = 0; i < p; i++) {
      final start = i * block;
      if (start >= _numChunks) break;
      final end = ((i + 1) * block).clamp(0, _numChunks);
      Isolate.spawn(
        _scanIsolate,
        _ScanArgs(
          path: path,
          chunkSize: _chunkSize,
          total: _totalBytes,
          startChunk: start,
          endChunk: end,
          sendPort: port.sendPort,
          nlUnit: _nlUnit,
          nlLittleEndian: _nlLittleEndian,
        ),
      );
      spawned++;
    }
  }

  void _applyChunk(int c, int lines, int bytes) {
    if (_chunkLines[c] != null) return;
    _chunkLines[c] = lines;
    _scannedChunks++;
    _scannedNewlines += lines;
    _scannedBytes += bytes;
    while (_prefixUpto < _numChunks && _chunkLines[_prefixUpto] != null) {
      _cum[_prefixUpto + 1] = _cum[_prefixUpto] + _chunkLines[_prefixUpto]!;
      _prefixUpto++;
    }
  }

  void _emitProgress() {
    if (_progressCtrl.isClosed) return;
    _progressCtrl.add(
      IndexProgress(
        lineCount: lineCount,
        indexedBytes: _scannedBytes,
        totalBytes: _totalBytes,
        done: _indexDone,
      ),
    );
  }

  // ── line <-> offset (index: exact within the prefix, otherwise estimated) ──

  /// Read [count] lines of text starting at line [start].
  Future<List<String>> readLines(int start, int count) {
    return _locked(() async {
      final off = await _offsetOfLineUnlocked(start);
      final win = await _readWindowUnlocked(off, count, start);
      return win.lines;
    });
  }

  /// Byte offset of line [line] (exact within the prefix, otherwise estimated
  /// from the average line length).
  Future<int> byteOffsetOfLine(int line) {
    return _locked(() => _offsetOfLineUnlocked(line));
  }

  /// Line number of the line containing [offset] ([LineAt.exact] tells whether
  /// it is exact).
  Future<LineAt> lineAtOffset(int offset) {
    return _locked(() => _lineAtOffsetUnlocked(offset));
  }

  Future<int> _offsetOfLineUnlocked(int line) async {
    if (line <= 0) return 0;
    final known = _cum[_prefixUpto];
    if (line < known) {
      // Binary search for chunk c: _cum[c] <= line
      var lo = 0, hi = _prefixUpto, c = 0;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        if (_cum[mid] <= line) {
          c = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      final lineStart = await _alignToLineStartUnlocked(c * _chunkSize);
      return _lineStartForwardUnlocked(lineStart, line - _cum[c]);
    }
    // Estimate: derive the offset from the average line length, then align to a line start
    final avg = _scannedNewlines > 0 ? _scannedBytes / _scannedNewlines : 64.0;
    var off = (line * avg).round();
    if (off >= _totalBytes) off = _totalBytes > 0 ? _totalBytes - 1 : 0;
    return _alignToLineStartUnlocked(off);
  }

  Future<LineAt> _lineAtOffsetUnlocked(int offset) async {
    if (offset <= 0) return const LineAt(0, true);
    final c = offset ~/ _chunkSize;
    if (c <= _prefixUpto) {
      // The prefix covers chunks[0..c-1] → _cum[c] is exact; count within the chunk from disk now
      final within = await _countNewlinesUnlocked(c * _chunkSize, offset);
      return LineAt(_cum[c] + within, true);
    }
    // Estimate: real counts for scanned chunks, average line length for unscanned ones
    final avg = _scannedNewlines > 0 ? _scannedBytes / _scannedNewlines : 64.0;
    var lines = 0.0;
    for (var i = 0; i < c && i < _numChunks; i++) {
      final cl = _chunkLines[i];
      lines += cl != null ? cl.toDouble() : _chunkSize / avg;
    }
    final cc = _chunkLines[c];
    if (cc != null) {
      lines += await _countNewlinesUnlocked(c * _chunkSize, offset);
    } else {
      lines += (offset - c * _chunkSize) / avg;
    }
    return LineAt(lines.round(), false);
  }

  // Newline units in [from, to). Chunks the index has already counted are
  // taken from the table (any scanned chunk, prefix or not), so with an index
  // a range costs at most two partial-chunk scans instead of its full length —
  // what keeps piece-tree splits on a GB file from re-reading up to the edit
  // point every time. Unscanned stretches are read as before.
  Future<int> _countNewlinesUnlocked(int from, int to) async {
    if (to > _totalBytes) to = _totalBytes;
    if (to <= from) return 0;
    final u = _nlUnit;
    // Only unit-aligned positions can hold a newline unit.
    var pos = from + ((u - from % u) % u);
    var n = 0;
    while (pos < to) {
      final c = pos ~/ _chunkSize;
      final cStart = c * _chunkSize;
      final cEnd = cStart + _chunkSize < _totalBytes
          ? cStart + _chunkSize
          : _totalBytes;
      final counted = c < _numChunks ? _chunkLines[c] : null;
      if (counted != null && pos == cStart && to >= cEnd) {
        n += counted;
        pos = cEnd;
        continue;
      }
      final segEnd = to < cEnd ? to : cEnd;
      n += await _scanNewlinesUnlocked(pos, segEnd);
      pos = segEnd;
    }
    return n;
  }

  // Raw scan of [pos, to) (unit-aligned [pos]).
  Future<int> _scanNewlinesUnlocked(int pos, int to) async {
    final u = _nlUnit;
    var n = 0;
    while (pos < to) {
      final want = (to - pos) < _readChunk ? to - pos : _readChunk;
      await _raf.setPosition(pos);
      final chunk = await _raf.read(want);
      if (chunk.isEmpty) break;
      final full = chunk.length - chunk.length % u;
      if (full == 0) break;
      for (var i = 0; i + u <= full; i += u) {
        if (_isNl(chunk, i)) n++;
      }
      pos += full;
    }
    return n;
  }

  // ── byte-anchor navigation API (no index needed; scans only the required range) ──

  Future<int> alignToLineStart(int byteOffset) =>
      _locked(() => _alignToLineStartUnlocked(byteOffset));
  Future<int> lineStartForward(int startOffset, int n) =>
      _locked(() => _lineStartForwardUnlocked(startOffset, n));
  Future<int> lineStartBack(int startOffset, int n) =>
      _locked(() => _lineStartBackUnlocked(startOffset, n));
  Future<LineWindow> readWindow(
    int startOffset,
    int count, {
    int startLine = -1,
  }) => _locked(() => _readWindowUnlocked(startOffset, count, startLine));

  // ── low-level API for the piece-tree (read raw bytes, count newlines in a range) ──

  /// Read [length] raw bytes starting at [offset] (used by the piece-tree to
  /// read the original buffer). Truncated at EOF; not decoded.
  Future<Uint8List> readBytes(int offset, int length) =>
      _locked(() => _readBytesUnlocked(offset, length));

  Future<Uint8List> _readBytesUnlocked(int offset, int length) async {
    if (length <= 0 || offset < 0 || offset >= _totalBytes) return Uint8List(0);
    final end = (offset + length) > _totalBytes ? _totalBytes : offset + length;
    await _raf.setPosition(offset);
    return _raf.read(end - offset);
  }

  /// Count the `\n` in [from, to) (used to get the LF count of one half when
  /// splitting a piece). Scans directly: always exact, independent of index state.
  Future<int> newlinesIn(int from, int to) => _locked(
    () => _countNewlinesUnlocked(
      from < 0 ? 0 : from,
      to > _totalBytes ? _totalBytes : to,
    ),
  );

  // Deliberately NOT through _locked: close() is the teardown for a document
  // being replaced (open / reload / save-as) and must not wait behind a read
  // that is still in flight — or, in widget tests' fake async zone, one that
  // never completes. suspend()/reopen() do take the lock (the save path runs
  // on the caret queue and wants in-flight reads drained first).
  Future<void> close() async {
    _indexPort?.close();
    await _progressCtrl.close();
    if (_hasFile && _rafOpen) {
      _rafOpen = false;
      await _raf.close();
    }
  }

  /// Close only the file handle, keeping the index and everything else: the
  /// save path must release it before the atomic replace (Windows cannot
  /// replace an open file), and [reopen] brings it back if the replace
  /// fails — otherwise the document would be stuck unreadable with the
  /// user's edits still in memory. A later [close] is still safe.
  Future<void> suspend() => _locked(() async {
    if (_hasFile && _rafOpen) {
      _rafOpen = false;
      await _raf.close();
    }
  });

  /// Undo [suspend]. Only meaningful when the file on disk is unchanged
  /// (the replace did not happen); the chunk index is kept as is.
  Future<void> reopen() => _locked(() async {
    if (!_hasFile || _rafOpen) return;
    _raf = await File(path).open();
    _rafOpen = true;
  });

  Future<T> _locked<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _ioLock = _ioLock.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<int> _alignToLineStartUnlocked(int byteOffset) async {
    if (byteOffset <= 0 || _totalBytes == 0) return 0;
    if (byteOffset > _totalBytes) byteOffset = _totalBytes;
    final u = _nlUnit;
    var hi = byteOffset - byteOffset % u; // snap to a unit boundary
    while (hi > 0) {
      var lo = hi - _readChunk < 0 ? 0 : hi - _readChunk;
      lo -= lo % u;
      await _raf.setPosition(lo);
      final chunk = await _raf.read(hi - lo);
      for (var i = ((chunk.length ~/ u) - 1) * u; i >= 0; i -= u) {
        if (_isNl(chunk, i)) return lo + i + u;
      }
      hi = lo;
    }
    return 0;
  }

  Future<int> _lineStartForwardUnlocked(int startOffset, int n) async {
    if (n <= 0 || _totalBytes == 0) return _totalBytes == 0 ? 0 : startOffset;
    final u = _nlUnit;
    var pos = startOffset; // line starts are unit-aligned
    var skipped = 0;
    var lastLineStart = startOffset;
    await _raf.setPosition(pos);
    while (skipped < n) {
      final chunk = await _raf.read(_readChunk);
      if (chunk.isEmpty) return lastLineStart;
      for (var i = 0; i + u <= chunk.length; i += u) {
        if (_isNl(chunk, i)) {
          skipped++;
          lastLineStart = pos + i + u;
          if (skipped == n) return lastLineStart;
        }
      }
      pos += chunk.length;
    }
    return lastLineStart;
  }

  Future<int> _lineStartBackUnlocked(int startOffset, int n) async {
    if (_totalBytes == 0) return 0;
    if (startOffset <= 0 || n <= 0) return n <= 0 ? startOffset : 0;
    final u = _nlUnit;
    var found = 0;
    // Exclude the newline unit immediately before startOffset (it terminates
    // the line that starts there).
    var hi = startOffset - u;
    hi -= hi % u;
    while (hi > 0) {
      var lo = hi - _readChunk < 0 ? 0 : hi - _readChunk;
      lo -= lo % u;
      await _raf.setPosition(lo);
      final chunk = await _raf.read(hi - lo);
      for (var i = ((chunk.length ~/ u) - 1) * u; i >= 0; i -= u) {
        if (_isNl(chunk, i)) {
          found++;
          if (found == n) return lo + i + u;
        }
      }
      hi = lo;
    }
    return 0;
  }

  Future<LineWindow> _readWindowUnlocked(
    int startOffset,
    int count,
    int startLine,
  ) async {
    final lines = <String>[];
    final offsets = <int>[];
    if (count <= 0 || startOffset >= _totalBytes) {
      return LineWindow(
        startOffset,
        startLine,
        lines,
        offsets,
        _totalBytes,
        true,
      );
    }
    var pos = startOffset;
    var curLineStart = startOffset;
    var atEof = false;
    final carry = BytesBuilder(copy: false);
    await _raf.setPosition(pos);

    while (lines.length < count) {
      final chunk = await _raf.read(_readChunk);
      if (chunk.isEmpty) {
        if (carry.length > 0) {
          offsets.add(curLineStart);
          lines.add(_decode(carry.takeBytes()));
        }
        atEof = true;
        break;
      }
      var lineStart = 0;
      for (var i = 0; i < chunk.length && lines.length < count; i++) {
        if (chunk[i] == 10) {
          offsets.add(curLineStart);
          if (carry.length > 0) {
            carry.add(chunk.sublist(lineStart, i));
            lines.add(_decode(carry.takeBytes()));
          } else {
            lines.add(_decode(Uint8List.sublistView(chunk, lineStart, i)));
          }
          curLineStart = pos + i + 1;
          lineStart = i + 1;
        }
      }
      if (lines.length < count && lineStart < chunk.length) {
        carry.add(chunk.sublist(lineStart, chunk.length));
        if (carry.length > _maxLineBytes) {
          offsets.add(curLineStart);
          lines.add('${_decode(carry.takeBytes())}…');
          await _skipToNextNewline();
          curLineStart = await _raf.position();
        }
      }
      pos += chunk.length;
    }

    final next = atEof ? _totalBytes : curLineStart;
    return LineWindow(startOffset, startLine, lines, offsets, next, atEof);
  }

  Future<void> _skipToNextNewline() async {
    while (true) {
      final chunk = await _raf.read(_readChunk);
      if (chunk.isEmpty) return;
      final idx = chunk.indexOf(10);
      if (idx >= 0) {
        final pos = await _raf.position();
        await _raf.setPosition(pos - (chunk.length - idx - 1));
        return;
      }
    }
  }

  // Legacy UTF-8 decode for [readLines]/_readWindowUnlocked (bench/tests
  // only — the editor reads text through Document.readWindow, which decodes
  // with the document's codec).
  String _decode(List<int> bytes) {
    var b = bytes;
    if (b.isNotEmpty && b.last == 13) b = b.sublist(0, b.length - 1);
    return utf8.decode(b, allowMalformed: true);
  }

  // ── scan isolates (parallel) ───────────────────────────────
  // Chunk sizes are multiples of 4, so unit-aligned scanning stays aligned
  // within every chunk and units never straddle a chunk boundary.
  static void _scanIsolate(_ScanArgs a) {
    final raf = File(a.path).openSync();
    final send = a.sendPort;
    final u = a.nlUnit;
    for (var c = a.startChunk; c < a.endChunk; c++) {
      final pos = c * a.chunkSize;
      final len = (a.total - pos) < a.chunkSize ? a.total - pos : a.chunkSize;
      raf.setPositionSync(pos);
      final bytes = raf.readSync(len);
      var n = 0;
      if (u == 1) {
        for (var i = 0; i < bytes.length; i++) {
          if (bytes[i] == 10) n++;
        }
      } else {
        for (var i = 0; i + u <= bytes.length; i += u) {
          if (unitValueAt(bytes, i, u, a.nlLittleEndian) == 10) n++;
        }
      }
      send.send([c, n, bytes.length]);
    }
    send.send(const ['done']);
    raf.closeSync();
  }
}

/// Line number of the line containing [offset], and whether it is exact.
class LineAt {
  const LineAt(this.line, this.exact);
  final int line;
  final bool exact;
}

/// A window of consecutive lines: text plus the starting byte offset of each line.
class LineWindow {
  const LineWindow(
    this.startOffset,
    this.startLine,
    this.lines,
    this.offsets,
    this.nextOffset,
    this.atEof,
  );

  final int startOffset;
  final int startLine; // -1 = unknown
  final List<String> lines;
  final List<int> offsets;
  final int nextOffset;
  final bool atEof;
}

/// Index progress.
class IndexProgress {
  const IndexProgress({
    required this.lineCount,
    required this.indexedBytes,
    required this.totalBytes,
    required this.done,
  });

  final int lineCount; // estimated or exact
  final int indexedBytes;
  final int totalBytes;
  final bool done;

  double get fraction => totalBytes == 0 ? 1 : indexedBytes / totalBytes;
}

class _ScanArgs {
  const _ScanArgs({
    required this.path,
    required this.chunkSize,
    required this.total,
    required this.startChunk,
    required this.endChunk,
    required this.sendPort,
    required this.nlUnit,
    required this.nlLittleEndian,
  });

  final String path;
  final int chunkSize;
  final int total;
  final int startChunk;
  final int endChunk;
  final SendPort sendPort;
  final int nlUnit;
  final bool nlLittleEndian;
}
