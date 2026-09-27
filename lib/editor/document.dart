// Document: the asynchronous outer layer of an editable document, wiring the
// purely structural [PieceTree] to the real data sources.
//
//   - buffer 0 (original): the file on disk, read through [LargeFile] windows.
//   - buffer 1 (add): append-only newly typed bytes held in memory.
//
// Splitting an original piece needs "how many newlines are in the left half",
// which requires reading the disk, so this layer computes it asynchronously
// first and then calls the synchronous PieceTree. Edits (insert/delete) return
// a **reverse command** [ReverseEdit]; applying a reverse command returns its
// own reverse → undo/redo are symmetric (see [UndoStack]).
//
// Pure dart:io, no Flutter dependency; testable standalone with `dart run`.

import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';

import 'encoding/codecs.dart';
import 'large_file.dart';
import 'piece_tree.dart';

/// A visible window: start offset, start line (display hint), each line's
/// text with its document byte offset, and each line's byte<->UTF-16 map.
class DocWindow {
  const DocWindow(
    this.startOffset,
    this.startLine,
    this.lines,
    this.offsets,
    this.nextOffset,
    this.atEof, {
    this.maps = const [],
    this.lineNumbers,
  });

  /// Absolute 0-based line number of each entry of [lines] (-1 = unknown)
  /// when the window is not contiguous — code folding skipped lines — so
  /// callers must not assume `startLine + i`. Null = contiguous.
  final List<int>? lineNumbers;

  /// Absolute line of window line [i] (or -1 when unknown).
  int lineNumberAt(int i) {
    final ln = lineNumbers;
    if (ln != null) return i < ln.length ? ln[i] : -1;
    return startLine >= 0 ? startLine + i : -1;
  }

  final int startOffset;
  final int startLine;
  final List<String> lines;
  final List<int> offsets;

  /// Per line: `maps[k][i]` = byte offset (relative to the line's start) of
  /// the character producing UTF-16 code unit `i` of `lines[k]`; one extra
  /// trailing entry holds the line's content byte length (excluding \r\n).
  /// Exact even for malformed bytes — never recompute this by re-encoding.
  final List<Uint32List> maps;

  final int nextOffset; // start of the row after the window (for scrolling)
  final bool atEof;
}

/// Reverse command: applying it undoes one edit. Applying returns "its own
/// reverse" (for redo).
class ReverseEdit {
  ReverseEdit._(
    this._kind,
    this.offset,
    this.length,
    this.pieces, [
    this.parts = const [],
    this.bytes,
  ]);
  factory ReverseEdit._noop() => ReverseEdit._(_EditKind.noop, 0, 0, const []);
  factory ReverseEdit._delete(int offset, int length) =>
      ReverseEdit._(_EditKind.delete, offset, length, const []);
  factory ReverseEdit._insertPieces(int offset, List<PieceRef> pieces) =>
      ReverseEdit._(_EditKind.insertPieces, offset, 0, pieces);

  /// Re-insert raw [bytes] (a materialized [_insertPieces]: no longer tied
  /// to any piece buffer, so it survives the document being reopened after a
  /// save — see [Document.materialize]).
  factory ReverseEdit._insertBytes(int offset, Uint8List bytes) =>
      ReverseEdit._(_EditKind.insertBytes, offset, 0, const [], const [], bytes);

  /// Combine several edits into a single undo step (e.g. overwrite = delete then
  /// insert, whose two reverses must be applied together; column-block edits:
  /// one edit per line).
  ///
  /// [parts] are the edits' reverse commands **in reverse order of application** — the reverse of
  /// the last edit applied comes first, so undoing it puts the offsets the earlier reverses recorded
  /// back where they were.
  factory ReverseEdit.group(List<ReverseEdit> parts) =>
      ReverseEdit._group(parts);

  factory ReverseEdit._group(List<ReverseEdit> parts) {
    final real = parts.where((p) => !p.isNoop).toList();
    if (real.isEmpty) return ReverseEdit._noop();
    if (real.length == 1) return real.first;
    return ReverseEdit._(_EditKind.group, real.first.offset, 0, const [], real);
  }

  final _EditKind _kind;
  final int offset;
  final int length;
  final List<PieceRef> pieces;

  /// Components of a compound reverse (non-empty only for [_EditKind.group]).
  final List<ReverseEdit> parts;

  /// Materialized bytes ([_EditKind.insertBytes] only).
  final Uint8List? bytes;

  bool get isNoop => _kind == _EditKind.noop;
  int get _totalLen => switch (_kind) {
    _EditKind.delete => length,
    _EditKind.group => parts.fold(0, (a, p) => a + p._totalLen),
    _EditKind.insertBytes => bytes!.length,
    _ => pieces.fold(0, (a, p) => a + p.length),
  };

  /// Bytes this entry keeps alive in memory (materialized inserts only;
  /// piece references cost nothing). Used to budget the undo history.
  int get retainedBytes => switch (_kind) {
    _EditKind.insertBytes => bytes!.length,
    _EditKind.group => parts.fold(0, (a, p) => a + p.retainedBytes),
    _ => 0,
  };

  /// Document offset the caret should land on after applying this reverse:
  ///   - delete (undoing an insert) → at the start [offset] after removal;
  ///   - insertPieces (undoing a delete) → at the end of the restored text.
  int get caretAfterApply => switch (_kind) {
    _EditKind.delete => offset,
    // Compound (overwrite): length unchanged, caret stays at the modified position.
    _EditKind.group => offset,
    _ => offset + _totalLen,
  };
}

enum _EditKind { noop, delete, insertPieces, insertBytes, group }

/// Try to merge two adjacent reverse commands into one (continuous typing /
/// continuous backspace → a single undo). [top] is the stack top (earlier),
/// [next] the newly added one (later). Returns null when they cannot merge.
ReverseEdit? _mergeReverse(ReverseEdit top, ReverseEdit next) {
  if (top._kind == _EditKind.delete && next._kind == _EditKind.delete) {
    // Both reverses of inserts are deletes; typing forward → next directly follows top.
    if (next.offset == top.offset + top.length) {
      return ReverseEdit._delete(top.offset, top.length + next.length);
    }
  } else if (top._kind == _EditKind.insertPieces &&
      next._kind == _EditKind.insertPieces) {
    // Both reverses of deletes are insertPieces; continuous backspace → next directly precedes top.
    if (next.offset + next._totalLen == top.offset) {
      return ReverseEdit._insertPieces(next.offset, [
        ...next.pieces,
        ...top.pieces,
      ]);
    }
    // Continuous Delete (forward delete): every deletion is at the same position;
    // on restore top's text comes first.
    if (next.offset == top.offset) {
      return ReverseEdit._insertPieces(top.offset, [
        ...top.pieces,
        ...next.pieces,
      ]);
    }
  }
  return null;
}

class Document {
  Document._(this._tree, this._orig);

  final PieceTree _tree;
  final LargeFile _orig;
  final List<int> _add = []; // add buffer (append-only)
  bool _edited = false; // whether any edit happened (tree vs index coords)
  bool _origLfExact = false; // initial original piece's lf corrected yet?

  /// Notified on every byte splice — insert (+delta at offset) or delete
  /// (-delta) — including undo/redo, since [apply] funnels through the same
  /// paths. Lets the view shift its own offset-anchored state (bookmarks).
  void Function(int offset, int delta)? onSplice;

  /// Called when an edit has to wait for the line index to be built first
  /// (first edit of a file above the auto-index cap); [done] completes when
  /// the edit can proceed. Lets the view show progress for a wait that can
  /// take seconds on a GB file.
  void Function(Future<void> done)? onIndexWait;

  TextCodec _codec = utf8TextCodec;

  /// How the document's bytes are interpreted as text. Applied only at the
  /// read boundary (decode for display) and write boundary (encode input);
  /// switching it is pure reinterpretation — no bytes change. The caller
  /// reloads its window after changing this.
  ///
  /// Switching to/from a unit-based codec (UTF-16/32) changes what counts as
  /// a newline, so the underlying line index resets (restart it if wanted)
  /// and the original piece's line-feed count is re-derived on demand.
  TextCodec get codec => _codec;

  set codec(TextCodec c) {
    final old = _codec;
    _codec = c;
    final changed =
        c.unitSize != old.unitSize ||
        (c.unitSize > 1 && c.littleEndian != old.littleEndian);
    if (changed) {
      _orig.configureNewlines(unit: c.unitSize, littleEndian: c.littleEndian);
      // Any pre-computed newline count used the old rules; recount lazily
      // before the next edit.
      if (_orig.size > 0) _origLfExact = false;
    }
  }

  // Newline shorthand for the current codec (a newline is one code unit of
  // value 0x0A; \r handling stays at the unit level too).
  int get _u => _codec.unitSize;
  bool get _le => _codec.littleEndian;

  static const int _readStep = 1 << 16; // 64KB

  /// Open a file. Source of the original file's total newline count (which
  /// decides whether the tree's line aggregates are authoritative):
  ///   - [originalLineFeeds] when given;
  ///   - otherwise, when [scanOriginalLineFeeds] is true, scan the whole file
  ///     (exact; for small files / tests);
  ///   - otherwise start with 0 (deferred): the tree's line aggregates are
  ///     **not authoritative**, line numbers come from the underlying index
  ///     instead and are refreshed once indexing completes (GUI large-file
  ///     path, avoiding a full scan on open).
  static Future<Document> open(
    String path, {
    int? originalLineFeeds,
    bool scanOriginalLineFeeds = true,
  }) async {
    final orig = await LargeFile.open(path);
    final size = orig.size;
    final int lf;
    if (size == 0) {
      lf = 0;
    } else if (originalLineFeeds != null) {
      lf = originalLineFeeds;
    } else if (scanOriginalLineFeeds) {
      lf = await orig.newlinesIn(0, size);
    } else {
      lf = 0;
    }
    final tree = size == 0 ? PieceTree.empty() : PieceTree.original(size, lf);
    final doc = Document._(tree, orig);
    // Whether the initial piece's lf is authoritative: empty file, injected
    // count, or a scan are all exact; only the deferred case (scan=false) is not.
    doc._origLfExact =
        size == 0 || originalLineFeeds != null || scanOriginalLineFeeds;
    return doc;
  }

  /// An untitled document: empty, not backed by any file (all content lives
  /// in the add buffer until it is saved somewhere).
  static Future<Document> openEmpty() async {
    final doc = Document._(PieceTree.empty(), await LargeFile.openEmpty());
    doc._origLfExact = true;
    return doc;
  }

  /// The underlying original file (for index/navigation code that still needs
  /// direct access; normally use the proxy methods below).
  LargeFile get original => _orig;

  // ── navigation/index proxies (stage 2: document == original file, delegated
  //    straight to LargeFile; once editing is wired in (stage 4) these switch
  //    to piece-tree document coordinates) ──────
  int get size => _orig.size;
  bool get indexDone => _orig.indexDone;
  double get fractionIndexed => _orig.fractionIndexed;

  /// Line count from the underlying index (an estimate while unindexed; equal
  /// to the document line count until editing is wired in).
  int get indexedLineCount => _orig.lineCount;

  Stream<IndexProgress> get progress => _orig.progress;
  void startIndexing({int? parallelism}) =>
      _orig.startIndexing(parallelism: parallelism);

  // ── navigation (document coordinates, still correct after edits; byte
  //    navigation only scans for newlines and needs no exact lf) ──
  Future<int> alignToLineStart(int offset) => lineStartOf(offset);

  Future<int> lineStartForward(int offset, int n) async {
    var pos = offset;
    for (var k = 0; k < n; k++) {
      final ns = await nextLineStart(pos);
      if (ns < 0) return pos; // no more lines
      pos = ns;
    }
    return pos;
  }

  Future<int> lineStartBack(int offset, int n) async {
    var pos = await lineStartOf(offset); // first go to the start of this line
    for (var k = 0; k < n; k++) {
      if (pos == 0) return 0;
      pos = await lineStartOf(pos - 1); // start of the previous line
    }
    return pos;
  }

  /// Start offset of line [line] (0-based). Unedited: via the underlying index
  /// (O(log)); after edits: a document-coordinate scan (rare path). Exact only
  /// with [origLfExact] / an index.
  Future<int> byteOffsetOfLine(int line) async {
    if (line <= 0) return 0;
    if (!_edited) return _orig.byteOffsetOfLine(line);
    return lineStartForward(0, line);
  }

  /// offset → absolute line number (with exact/estimated flag). Unedited: the
  /// underlying index; after edits: the piece-tree.
  Future<LineAt> absoluteLineAt(int offset) async {
    if (_edited) return LineAt(await lineAtOffset(offset), true);
    return _orig.lineAtOffset(offset);
  }

  /// Absolute total line count. Unedited: the underlying index (possibly an
  /// estimate); after edits: the piece-tree.
  int get absoluteLineCount => _edited ? _tree.lineCount : _orig.lineCount;

  /// Whether any edit has happened (decides whether coordinates go through the
  /// tree or the underlying index).
  bool get edited => _edited;

  int get length => _tree.length;
  int get lineCount => _tree.lineCount;
  int get lineFeeds => _tree.lineFeeds;

  /// For tests: verify the internal tree invariants (balance + consistent
  /// aggregates); returns null when fine.
  String? debugValidate() => _tree.validate();

  /// For tests: current number of pieces.
  int get debugPieceCount => _tree.debugPieces().length;

  Future<void> close() => _orig.close();

  /// Release the original file's handle without tearing the document down
  /// (the save path needs the file closed for the atomic replace); [reopen]
  /// restores it when the replace fails so the edits stay saveable.
  Future<void> suspend() => _orig.suspend();
  Future<void> reopen() => _orig.reopen();

  // ── reading ─────────────────────────────────────────────────

  /// Read [rowCount] lines from [startOffset] (mixing original/add).
  Future<DocWindow> readWindow(
    int startOffset,
    int rowCount, {
    int startLine = -1,
  }) async {
    final lines = <String>[];
    final offsets = <int>[];
    final maps = <Uint32List>[];
    void addLine(int offset, List<int> bytes) {
      offsets.add(offset);
      final (text, map) = _decodeLine(bytes);
      lines.add(text);
      maps.add(map);
    }

    if (rowCount <= 0 || startOffset > _tree.length) {
      return DocWindow(
        startOffset,
        startLine,
        lines,
        offsets,
        _tree.length,
        true,
        maps: maps,
      );
    }
    // At EOF (startOffset == length): only an empty document, or one whose
    // previous code unit is \n, has an empty trailing line there (the same
    // last segment split('\n') would give — a place for the caret to sit).
    if (startOffset == _tree.length) {
      var trailing = _tree.length == 0;
      if (!trailing && startOffset >= _u) {
        final pb = await readRangeBytes(startOffset - _u, _u);
        trailing = pb.length == _u && unitValueAt(pb, 0, _u, _le) == 10;
      }
      if (trailing) addLine(startOffset, const []);
      return DocWindow(
        startOffset,
        startLine,
        lines,
        offsets,
        _tree.length,
        true,
        maps: maps,
      );
    }
    final refs = _tree.piecesFrom(startOffset);
    final cur = <int>[];
    var docOffset = startOffset;
    var curLineStart = startOffset;
    var atEof = false;
    // Unit accumulator: a newline is a whole code unit of value 0x0A, built
    // up byte by byte (units can span piece/read boundaries). [startOffset]
    // is a line start, so the window begins unit-aligned.
    final u = _u, le = _le;
    var unitPos = 0, unitVal = 0;

    outer:
    for (final ref in refs) {
      var pos = ref.start;
      final endPos = ref.start + ref.length;
      while (pos < endPos) {
        final want = (endPos - pos) < _readStep ? endPos - pos : _readStep;
        final bytes = await _bufRead(ref.buffer, pos, want);
        if (bytes.isEmpty) break;
        for (var i = 0; i < bytes.length; i++) {
          final b = bytes[i];
          docOffset++;
          if (u == 1) {
            if (b == 10) {
              addLine(curLineStart, cur);
              cur.clear();
              curLineStart = docOffset;
              if (lines.length >= rowCount) break outer;
            } else {
              cur.add(b);
            }
            continue;
          }
          cur.add(b);
          unitVal |= b << (8 * (le ? unitPos : (u - 1 - unitPos)));
          unitPos++;
          if (unitPos == u) {
            if (unitVal == 10) {
              cur.removeRange(cur.length - u, cur.length);
              addLine(curLineStart, cur);
              cur.clear();
              curLineStart = docOffset;
              if (lines.length >= rowCount) {
                unitPos = 0;
                unitVal = 0;
                break outer;
              }
            }
            unitPos = 0;
            unitVal = 0;
          }
        }
        pos += bytes.length;
      }
    }

    if (lines.length < rowCount) {
      // Reached EOF: add split('\n')'s last segment. When the content ends
      // with \n, cur is empty → an empty trailing line (otherwise the screen
      // is one row short and a caret at EOF lands on an undrawn line).
      addLine(curLineStart, cur);
      atEof = true;
    }
    final next = atEof ? _tree.length : curLineStart;
    return DocWindow(
      startOffset,
      startLine,
      lines,
      offsets,
      next,
      atEof,
      maps: maps,
    );
  }

  /// Stream the whole document into [sink] (for saving): read piece by piece
  /// (original from disk, add from memory) and write in chunks, never holding
  /// the whole file in memory. The caller is responsible for flushing/closing
  /// [sink].
  Future<void> streamTo(IOSink sink) async {
    for (final ref in _tree.piecesFrom(0)) {
      var pos = ref.start;
      final end = ref.start + ref.length;
      while (pos < end) {
        final want = (end - pos) < _readStep ? end - pos : _readStep;
        final bytes = await _bufRead(ref.buffer, pos, want);
        if (bytes.isEmpty) break;
        sink.add(bytes);
        pos += bytes.length;
      }
    }
  }

  /// Stream the whole document into [sink], re-encoded from [codec] to
  /// [target] ("convert encoding": this is the one operation that really
  /// changes bytes — everything else is reinterpretation). Streams window by
  /// window, so memory stays bounded by line length, not file size.
  ///
  /// Line terminators are preserved per line (LF stays LF, CRLF stays CRLF)
  /// and re-encoded in [target]'s units — unless [newline] is given, which
  /// forces every terminator to that style ("convert line endings"; the last
  /// line's missing terminator stays missing). A leading U+FEFF (BOM) is kept
  /// when [target] can represent it, silently dropped otherwise (Big5 etc.
  /// have no BOM). Returns the number of characters [target] could not
  /// represent (written as literal U+XXXX notation).
  ///
  /// Throws [StateError] when a single line exceeds [maxLineBytes] (the
  /// window reader materializes whole lines).
  Future<int> transcodeTo(
    IOSink sink,
    TextCodec target, {
    int maxLineBytes = 64 << 20,
    String? newline,
  }) async {
    var fallbacks = 0;
    var first = true;
    var pos = 0;
    while (true) {
      final w = await readWindow(pos, 256);
      if (w.lines.isEmpty) break;
      for (var k = 0; k < w.lines.length; k++) {
        var text = w.lines[k];
        final contentBytes = w.maps[k][w.maps[k].length - 1];
        if (contentBytes > maxLineBytes) {
          throw StateError(
            'line at offset ${w.offsets[k]} exceeds '
            '$maxLineBytes bytes',
          );
        }
        if (first) {
          first = false;
          if (text.startsWith('\uFEFF') && !target.canEncode(0xFEFF)) {
            text = text.substring(1); // the target encoding has no BOM
          }
        }
        final next = k + 1 < w.offsets.length ? w.offsets[k + 1] : w.nextOffset;
        final gap = next - w.offsets[k] - contentBytes; // terminator bytes
        var term = gap >= 2 * _u ? '\r\n' : (gap > 0 ? '\n' : '');
        if (newline != null && term.isNotEmpty) term = newline;
        final enc = target.encode('$text$term');
        fallbacks += enc.fallbackCount;
        sink.add(enc.bytes);
      }
      if (w.atEof) break;
      pos = w.nextOffset;
    }
    return fallbacks;
  }

  /// Read the whole document's bytes (for tests/saving; use streaming for large files).
  Future<List<int>> readAllBytes() async {
    final out = <int>[];
    for (final ref in _tree.piecesFrom(0)) {
      var pos = ref.start;
      final end = ref.start + ref.length;
      while (pos < end) {
        final want = (end - pos) < _readStep ? end - pos : _readStep;
        final bytes = await _bufRead(ref.buffer, pos, want);
        if (bytes.isEmpty) break;
        out.addAll(bytes);
        pos += bytes.length;
      }
    }
    return out;
  }

  // ── caret navigation (UTF-8 boundary aware; document coordinates) ─────

  /// Read the raw bytes of [offset, offset+length) (spanning original/add).
  Future<Uint8List> readRangeBytes(int offset, int length) async {
    if (length <= 0 || offset >= _tree.length) return Uint8List(0);
    final end = (offset + length) > _tree.length
        ? _tree.length
        : offset + length;
    var need = end - offset;
    final out = BytesBuilder(copy: false);
    for (final ref in _tree.piecesFrom(offset)) {
      if (need <= 0) break;
      final take = ref.length < need ? ref.length : need;
      var pos = ref.start;
      var rem = take;
      while (rem > 0) {
        final want = rem < _readStep ? rem : _readStep;
        final bytes = await _bufRead(ref.buffer, pos, want);
        if (bytes.isEmpty) break;
        out.add(bytes);
        pos += bytes.length;
        rem -= bytes.length;
      }
      need -= take;
    }
    return out.toBytes();
  }

  /// Text of [offset, offset+length) decoded with [codec] (keeps \r; for
  /// copy / column extraction). When byte<->char positions are needed too,
  /// use [readRangeDecoded] instead — never recompute them by re-encoding.
  Future<String> readRangeString(int offset, int length) async =>
      (await readRangeDecoded(offset, length)).text;

  /// Decode [offset, offset+length) with [codec], including the byte offset
  /// of every UTF-16 code unit (see [DecodedText]).
  Future<DecodedText> readRangeDecoded(int offset, int length) async =>
      codec.decode(await readRangeBytes(offset, length));

  /// Cap for how much line prefix [charLeft] reads to find a DBCS character
  /// boundary; beyond this it decodes only the tail (DBCS resyncs quickly).
  static const int _charLeftScanCap = 1 << 16; // 64KB

  /// Offset one character to the right of [offset] (stays at EOF). `\r\n`
  /// steps as one unit. [offset] must be a character boundary, which lets
  /// every codec (including DBCS) measure the next character locally.
  // ── character stepping ──────────────────────────────────────
  // charLeft/charRight step by GRAPHEME CLUSTER — what the user perceives as
  // one character: a base letter with its combining marks (Arabic harakat,
  // Hebrew points, accents), an emoji ZWJ sequence or flag pair, CRLF. So
  // Backspace / Delete / ← → never leave half of one behind. The cluster is
  // found by decoding a small window around a CODE POINT boundary (never a
  // raw byte offset: a cut-off first character would decode as U+FFFD and
  // could glue onto the cluster) and falls back to one code point when it
  // cannot be resolved inside the window.
  static const int _graphemeWindow = 64; // bytes read forward
  static const int _graphemeMaxCodePoints = 12; // code points read backward

  Future<int> charRight(int offset) async {
    if (offset >= _tree.length) return _tree.length;
    final cp = await _codePointRight(offset); // always a valid boundary
    final d = codec.decode(await readRangeBytes(offset, _graphemeWindow));
    if (d.text.isEmpty) return cp;
    final g = d.text.characters.first;
    if (g.length >= d.text.length && d.byteLength >= _graphemeWindow) {
      return cp; // the cluster runs past the window: give up on it
    }
    final len = g.length >= d.text.length
        ? d.byteLength
        : d.byteForCodeUnit(g.length);
    final n = offset + len;
    return n > cp && n <= _tree.length ? n : cp;
  }

  Future<int> charLeft(int offset) async {
    if (offset <= 0) return 0;
    final cp = await _codePointLeft(offset);
    var from = cp;
    for (var i = 0; i < _graphemeMaxCodePoints && from > 0; i++) {
      from = await _codePointLeft(from);
    }
    final d = codec.decode(await readRangeBytes(from, offset - from));
    if (d.text.isEmpty) return cp;
    final g = d.text.characters.last;
    if (g.length >= d.text.length && from > 0) return cp; // ran off the window
    final start = from + d.byteForCodeUnit(d.text.length - g.length);
    return start < cp && start >= 0 ? start : cp;
  }

  /// One code point to the right (CRLF as one). The building block of
  /// [charRight]; internal callers that need code points use it directly.
  Future<int> _codePointRight(int offset) async {
    if (offset >= _tree.length) return _tree.length;
    // 8 bytes cover the widest cases: a 4-byte character, or a UTF-32 CRLF.
    final b = await readRangeBytes(offset, 8);
    if (b.isEmpty) return _tree.length;
    final d = codec.decode(b);
    int len;
    if (d.text.length >= 2 &&
        d.text.codeUnitAt(0) == 13 &&
        d.text.codeUnitAt(1) == 10) {
      len = d.byteForCodeUnit(2); // \r\n moves as one step
    } else {
      len = firstCharBytes(d);
    }
    final n = offset + (len > 0 ? len : 1);
    return n > _tree.length ? _tree.length : n;
  }

  /// One code point to the left of [offset] (stays at 0). `\r\n` steps as
  /// one unit. The building block of [charLeft].
  Future<int> _codePointLeft(int offset) async {
    if (offset <= 0) return 0;
    final c = codec;
    if (c.unitSize > 1) {
      // UTF-16/32: decode a small unit-aligned tail; the last character's
      // start is the previous boundary (handles surrogate pairs), and a
      // trailing \r\n steps as one.
      final u = c.unitSize;
      if (offset % u != 0) return offset - offset % u; // resync stray caret
      final from = offset - 4 * u < 0 ? 0 : offset - 4 * u;
      final d = c.decode(await readRangeBytes(from, offset - from));
      if (d.text.isEmpty) return offset - 1;
      if (d.text.length >= 2 &&
          d.text.codeUnitAt(d.text.length - 2) == 13 &&
          d.text.codeUnitAt(d.text.length - 1) == 10) {
        return from + d.byteOffsets[d.text.length - 2];
      }
      return from + d.byteOffsets[d.codeUnitForByte(d.byteLength - 1)];
    }
    // 1-byte-unit codecs: a literal 0D 0A pair is CRLF (0x0D/0x0A never
    // appear inside a multi-byte sequence in the supported families).
    if (offset >= 2) {
      final t = await readRangeBytes(offset - 2, 2);
      if (t.length == 2 && t[0] == 13 && t[1] == 10) return offset - 2;
    }
    if (c is Utf8TextCodec) {
      // Fast path: UTF-8 is self-synchronizing, scan back over trail bytes.
      final from = offset - 4 < 0 ? 0 : offset - 4;
      final b = await readRangeBytes(from, offset - from);
      if (b.isEmpty) return offset - 1;
      var i = b.length - 1;
      while (i > 0 && (b[i] & 0xC0) == 0x80) {
        i--;
      }
      return from + i;
    }
    if (c is SingleByteCodec) return offset - 1;
    // DBCS: boundaries are ambiguous locally (Big5 trails overlap ASCII), so
    // parse forward from the line start and take the last character's start.
    var from = await lineStartOf(offset);
    if (offset - from > _charLeftScanCap) from = offset - _charLeftScanCap;
    final d = codec.decode(await readRangeBytes(from, offset - from));
    if (d.text.isEmpty) return offset - 1;
    return from + d.byteOffsets[d.codeUnitForByte(d.byteLength - 1)];
  }

  /// End of the line's CONTENT at [offset] (before the line terminator):
  /// LF line → the \n position; CRLF line → the \r position (the caret never
  /// sits between \r and \n); no newline → EOF. [offset] must be a character
  /// boundary (unit-aligned for UTF-16/32).
  Future<int> lineEndOf(int offset) async {
    final u = _u, le = _le;
    var pos = offset;
    var prev = -1; // previous complete unit's value
    var unitPos = 0, unitVal = 0;
    for (final ref in _tree.piecesFrom(offset)) {
      var p = ref.start;
      var rem = ref.length;
      while (rem > 0) {
        final want = rem < _readStep ? rem : _readStep;
        final bytes = await _bufRead(ref.buffer, p, want);
        if (bytes.isEmpty) break;
        for (var i = 0; i < bytes.length; i++) {
          if (u == 1) {
            if (bytes[i] == 10) return prev == 13 ? pos - 1 : pos;
            prev = bytes[i];
            pos++;
            continue;
          }
          unitVal |= bytes[i] << (8 * (le ? unitPos : (u - 1 - unitPos)));
          unitPos++;
          pos++;
          if (unitPos == u) {
            if (unitVal == 10) {
              // pos is just past the \n unit; back over it (and a \r unit).
              return prev == 13 ? pos - 2 * u : pos - u;
            }
            prev = unitVal;
            unitPos = 0;
            unitVal = 0;
          }
        }
        p += bytes.length;
        rem -= bytes.length;
      }
    }
    return _tree.length;
  }

  /// Start of the next line (just past the nearest newline unit); -1 when
  /// there is none (already on the last line).
  Future<int> nextLineStart(int offset) async {
    final u = _u, le = _le;
    var pos = offset;
    var unitPos = 0, unitVal = 0;
    for (final ref in _tree.piecesFrom(offset)) {
      var p = ref.start;
      var rem = ref.length;
      while (rem > 0) {
        final want = rem < _readStep ? rem : _readStep;
        final bytes = await _bufRead(ref.buffer, p, want);
        if (bytes.isEmpty) break;
        for (var i = 0; i < bytes.length; i++) {
          pos++;
          if (u == 1) {
            if (bytes[i] == 10) return pos;
            continue;
          }
          unitVal |= bytes[i] << (8 * (le ? unitPos : (u - 1 - unitPos)));
          unitPos++;
          if (unitPos == u) {
            if (unitVal == 10) return pos;
            unitPos = 0;
            unitVal = 0;
          }
        }
        p += bytes.length;
        rem -= bytes.length;
      }
    }
    return -1;
  }

  /// Start of the line containing [offset] (document coordinates). Scans
  /// back for the nearest newline unit at unit-aligned positions.
  Future<int> lineStartOf(int offset) async {
    if (offset <= 0) return 0;
    final u = _u, le = _le;
    var hi = offset - offset % u;
    while (hi > 0) {
      var lo = hi - _readStep < 0 ? 0 : hi - _readStep;
      lo -= lo % u;
      final bytes = await readRangeBytes(lo, hi - lo);
      for (var i = ((bytes.length ~/ u) - 1) * u; i >= 0; i -= u) {
        if (unitValueAt(bytes, i, u, le) == 10) return lo + i + u;
      }
      hi = lo;
    }
    return 0;
  }

  /// Line number of the line containing [offset] (0-based, exact).
  Future<int> lineAtOffset(int offset) async {
    if (offset <= 0) return 0;
    if (offset >= _tree.length) return _tree.lineFeeds;
    final loc = _tree.locate(offset);
    if (loc == null) return _tree.lineFeeds;
    final within = await _bufNewlines(loc.buffer, loc.bufStart, loc.within);
    return loc.lfBefore + within;
  }

  // ── editing (returns reverse commands) ─────────────────────

  /// Insert [text] at [offset], encoded with [codec] (characters the codec
  /// cannot represent become literal "U+XXXX" notation). Returns the reverse
  /// command that undoes the insertion. Callers that need the encoded byte
  /// length or the fallback count encode via [codec] themselves and call
  /// [insertBytes].
  Future<ReverseEdit> insert(int offset, String text) =>
      insertBytes(offset, codec.encode(text).bytes);

  /// Insert raw bytes at [offset]. For hex editing: an arbitrary byte (e.g.
  /// 0xFF) must **not** be turned into a String and UTF-8 encoded by [insert],
  /// which would turn it into two bytes.
  Future<ReverseEdit> insertBytes(int offset, List<int> bytes) async {
    if (bytes.isEmpty) return ReverseEdit._noop();
    await _ensureOrigLfExact();
    _edited = true;
    await _ensureBoundary(offset);
    final start = _add.length;
    _add.addAll(bytes);
    int lf;
    if (_u == 1) {
      lf = 0;
      for (final b in bytes) {
        if (b == 10) lf++;
      }
    } else {
      lf = _countNlUnits(bytes, 0, bytes.length);
    }
    _tree.insertPieceAt(offset, 1, start, bytes.length, lf);
    onSplice?.call(offset, bytes.length);
    return ReverseEdit._delete(offset, bytes.length);
  }

  /// Overwrite the same number of bytes starting at [offset] (document length
  /// unchanged; for hex editing).
  ///
  /// Implemented as "delete then insert", but returns a **single** compound
  /// reverse, so undo/redo is one step and never stops in the intermediate
  /// "deleted but not yet re-inserted" state.
  Future<ReverseEdit> overwriteBytes(int offset, List<int> bytes) async {
    if (bytes.isEmpty || offset < 0 || offset >= _tree.length) {
      return ReverseEdit._noop();
    }
    final len = (offset + bytes.length > _tree.length)
        ? _tree.length - offset
        : bytes.length;
    final del = await delete(offset, len);
    final ins = await insertBytes(offset, bytes.sublist(0, len));
    return ReverseEdit._group([ins, del]); // undo: remove the new bytes first, then re-insert the old
  }

  /// Delete [offset, offset+length). Returns the reverse that restores the
  /// deletion (carrying the sequence of removed pieces).
  Future<ReverseEdit> delete(int offset, int length) async {
    if (length <= 0) return ReverseEdit._noop();
    final off = offset < 0
        ? 0
        : (offset > _tree.length ? _tree.length : offset);
    final end = (off + length) > _tree.length ? _tree.length : off + length;
    final len = end - off;
    if (len <= 0) return ReverseEdit._noop();
    await _ensureOrigLfExact();
    _edited = true;
    await _ensureBoundary(off);
    await _ensureBoundary(off + len);
    final removed = _tree.removeRange(off, len);
    onSplice?.call(off, -len);
    return ReverseEdit._insertPieces(off, removed);
  }

  /// Apply a reverse command and return "its own reverse" (for redo). This is
  /// what makes undo/redo symmetric.
  Future<ReverseEdit> apply(ReverseEdit e) async {
    switch (e._kind) {
      case _EditKind.noop:
        return e;
      case _EditKind.delete:
        return delete(e.offset, e.length);
      case _EditKind.insertPieces:
        await _ensureBoundary(e.offset);
        var cursor = e.offset;
        var total = 0;
        for (final p in e.pieces) {
          _tree.insertPieceAt(cursor, p.buffer, p.start, p.length, p.lf);
          cursor += p.length;
          total += p.length;
        }
        onSplice?.call(e.offset, total);
        return ReverseEdit._delete(e.offset, total);
      case _EditKind.insertBytes:
        return insertBytes(e.offset, e.bytes!);
      case _EditKind.group:
        // Apply in order; the resulting reverses must be **reversed** to form
        // this step's redo command.
        final redo = <ReverseEdit>[];
        for (final part in e.parts) {
          redo.add(await apply(part));
        }
        return ReverseEdit._group(redo.reversed.toList());
    }
  }

  /// Copy of [e] that no longer references this document's piece buffers:
  /// every "re-insert these pieces" entry becomes "re-insert these bytes".
  /// Done before a save closes the document, so the undo history stays
  /// usable against the reopened file (whose content is identical, only the
  /// buffers behind it are new). Delete entries are already self-contained.
  Future<ReverseEdit> materialize(ReverseEdit e) async {
    switch (e._kind) {
      case _EditKind.insertPieces:
        final out = BytesBuilder(copy: false);
        for (final p in e.pieces) {
          var pos = p.start, rem = p.length;
          while (rem > 0) {
            final want = rem < _readStep ? rem : _readStep;
            final b = await _bufRead(p.buffer, pos, want);
            out.add(b);
            pos += b.length;
            rem -= b.length;
            if (b.isEmpty) break;
          }
        }
        return ReverseEdit._insertBytes(e.offset, out.takeBytes());
      case _EditKind.group:
        return ReverseEdit._(
          _EditKind.group,
          e.offset,
          0,
          const [],
          [for (final p in e.parts) await materialize(p)],
        );
      case _EditKind.noop:
      case _EditKind.delete:
      case _EditKind.insertBytes:
        return e;
    }
  }

  // ── internal helpers ────────────────────────────────────────

  // Before the first edit, correct the initial original piece's lf to the exact
  // value (the tree is still a single piece at this point). Every piece produced
  // by later splits gets an exact lf from a newlinesIn scan, so it stays exact
  // throughout.
  // Files above the auto-index cap have no index yet; building it here (parallel
  // isolates) is both faster than a single-threaded scan and leaves the chunk
  // table behind, so every later piece split near the edit point counts
  // newlines from the table instead of re-reading up to the edit — the first
  // edit on a GB file went from ~5 s to the index build, later far-away edits
  // from ~5 s to milliseconds.
  Future<void> _ensureOrigLfExact() async {
    if (_origLfExact) return;
    final size = _orig.size;
    if (size > 0 && !_orig.indexDone) {
      final done = _orig.whenIndexed();
      onIndexWait?.call(done);
      await done;
    }
    final lf = size == 0 ? 0 : _orig.lineCount - 1;
    _tree.setSinglePieceLf(lf);
    _origLfExact = true;
  }

  Future<void> _ensureBoundary(int offset) async {
    final loc = _tree.locate(offset);
    if (loc == null || loc.within == 0) return; // EOF or already on a boundary
    final lfLeft = await _bufNewlines(loc.buffer, loc.bufStart, loc.within);
    _tree.splitAt(offset, lfLeft);
  }

  Future<int> _bufNewlines(int buffer, int start, int length) async {
    if (length <= 0) return 0;
    if (buffer == 0) return _orig.newlinesIn(start, start + length);
    if (_u == 1) {
      var n = 0;
      for (var i = start; i < start + length; i++) {
        if (_add[i] == 10) n++;
      }
      return n;
    }
    return _countNlUnits(_add, start, start + length);
  }

  // Count newline UNITS in [from, to) of [b], aligned to [from] (ranges here
  // start at character boundaries, which are unit-aligned).
  int _countNlUnits(List<int> b, int from, int to) {
    final u = _u, le = _le;
    var n = 0;
    for (var i = from; i + u <= to; i += u) {
      if (unitValueAt(b, i, u, le) == 10) n++;
    }
    return n;
  }

  Future<Uint8List> _bufRead(int buffer, int start, int length) async {
    if (length <= 0) return Uint8List(0);
    if (buffer == 0) return _orig.readBytes(start, length);
    return Uint8List.fromList(_add.sublist(start, start + length));
  }

  // Decode one line's content bytes with [codec]: strips a trailing \r
  // unit (CRLF), returns the text plus its byte<->code-unit map (one entry
  // per code unit + a trailing entry with the content byte length).
  (String, Uint32List) _decodeLine(List<int> bytes) {
    var b = bytes;
    if (b.length >= _u && unitValueAt(b, b.length - _u, _u, _le) == 13) {
      b = b.sublist(0, b.length - _u);
    }
    final d = codec.decode(b is Uint8List ? b : Uint8List.fromList(b));
    final map = Uint32List(d.text.length + 1);
    map.setRange(0, d.byteOffsets.length, d.byteOffsets);
    map[d.text.length] = d.byteLength;
    return (d.text, map);
  }
}

/// undo/redo stack (reverse-command model, with coalescing).
///
/// Coalescing: continuous typing or continuous backspace merge into one undo
/// entry. On caret jumps / clicks / mode switches the UI should call
/// [breakCoalescing] so the next edit becomes a separate entry.
class UndoStack {
  final List<ReverseEdit> _undo = [];
  final List<ReverseEdit> _redo = [];
  bool _canCoalesce = false; // whether the next push may try to merge with the top

  // Every document state has an id: the id of the newest undo entry (0 for
  // the pristine state). Undo/redo carry ids along with the entries, so the
  // "saved" state can be recognised again after undoing past it and redoing
  // back — the entry objects themselves change on every apply.
  final List<int> _undoIds = [];
  final List<int> _redoIds = [];
  int _nextId = 1;
  int _savedId = 0;

  /// Oldest steps are dropped beyond this many (0 = unlimited).
  int maxSteps = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get length => _undo.length;

  int get _topId => _undoIds.isEmpty ? 0 : _undoIds.last;

  /// The document differs from its last saved state ([markSaved]).
  bool get isDirty => _topId != _savedId;

  /// The current state is what is on disk now. Undoing below it and redoing
  /// back makes [isDirty] false again.
  void markSaved() => _savedId = _topId;

  /// Clear everything (when switching files).
  void clear() {
    _undo.clear();
    _redo.clear();
    _undoIds.clear();
    _redoIds.clear();
    _savedId = 0;
    _canCoalesce = false;
  }

  void _pushEntry(ReverseEdit r) {
    _undo.add(r);
    _undoIds.add(_nextId++);
    _redo.clear();
    _redoIds.clear();
    _trim();
  }

  void _trim() {
    if (maxSteps <= 0) return;
    while (_undo.length > maxSteps) {
      _undo.removeAt(0);
      _undoIds.removeAt(0);
    }
  }

  /// Make every entry independent of [doc]'s buffers (see
  /// [Document.materialize]) — called right before a save closes and
  /// reopens the document. Materialized deletions hold their bytes, so the
  /// history is capped at [maxBytes] of retained data: oldest undo steps go
  /// first, then the redo stack is dropped entirely if still over.
  Future<void> rebase(Document doc, {int maxBytes = 256 << 20}) async {
    for (var i = 0; i < _undo.length; i++) {
      _undo[i] = await doc.materialize(_undo[i]);
    }
    for (var i = 0; i < _redo.length; i++) {
      _redo[i] = await doc.materialize(_redo[i]);
    }
    var total = 0;
    for (final r in _undo) {
      total += r.retainedBytes;
    }
    for (final r in _redo) {
      total += r.retainedBytes;
    }
    while (total > maxBytes && _undo.isNotEmpty) {
      total -= _undo.first.retainedBytes;
      _undo.removeAt(0);
      _undoIds.removeAt(0);
    }
    if (total > maxBytes) {
      _redo.clear();
      _redoIds.clear();
    }
    _canCoalesce = false;
  }

  /// Break coalescing (call after caret moves, clicks, saves, mode switches, etc.).
  void breakCoalescing() => _canCoalesce = false;

  // While non-null, pushes are collected here instead of the stack and
  // become ONE step at endGroup (multi-cursor replays of single-cursor ops).
  List<ReverseEdit>? _group;
  int _groupDepth = 0; // groups nest (macro playback around multi-cursor)

  /// Start collecting pushes into one undo step (see [endGroup]). Nested
  /// calls join the outermost group.
  void beginGroup() {
    if (_groupDepth++ == 0) _group = [];
    _canCoalesce = false;
  }

  /// Close the group opened by [beginGroup]: when the outermost one closes,
  /// the collected reverses become a single step, newest-applied first so
  /// undo replays them in safe order.
  void endGroup() {
    if (_groupDepth == 0) return;
    if (--_groupDepth > 0) return;
    final g = _group;
    _group = null;
    if (g == null || g.isEmpty) return;
    _pushEntry(ReverseEdit.group(g.reversed.toList()));
    _canCoalesce = false;
  }

  /// Record the reverse of one edit (a new edit clears redo).
  /// When [coalesce] is true, try to merge with the top (continuous typing/deleting).
  void push(ReverseEdit reverse, {bool coalesce = false}) {
    if (reverse.isNoop) return;
    final g = _group;
    if (g != null) {
      g.add(reverse);
      return;
    }
    if (coalesce && _canCoalesce && _undo.isNotEmpty) {
      final merged = _mergeReverse(_undo.last, reverse);
      if (merged != null) {
        // A merged step is a new state (the typed text grew).
        _undo[_undo.length - 1] = merged;
        _undoIds[_undoIds.length - 1] = _nextId++;
        _redo.clear();
        _redoIds.clear();
        _canCoalesce = true;
        return;
      }
    }
    _pushEntry(reverse);
    _canCoalesce = coalesce;
  }

  /// Undo one step. Returns the applied reverse (so the UI can read the caret
  /// position after applying), or null when there is nothing to undo.
  Future<ReverseEdit?> undo(Document doc) async {
    if (_undo.isEmpty) return null;
    _canCoalesce = false;
    final r = _undo.removeLast();
    final id = _undoIds.removeLast();
    _redo.add(await doc.apply(r));
    _redoIds.add(id);
    return r;
  }

  /// Redo one step. Returns the applied reverse, or null when there is nothing to redo.
  Future<ReverseEdit?> redo(Document doc) async {
    if (_redo.isEmpty) return null;
    _canCoalesce = false;
    final r = _redo.removeLast();
    final id = _redoIds.removeLast();
    _undo.add(await doc.apply(r));
    _undoIds.add(id);
    return r;
  }
}
