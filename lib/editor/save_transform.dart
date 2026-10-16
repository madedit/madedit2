import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'encoding/text_codec.dart' show unitValueAt;

/// Save-time byte transforms (trim trailing whitespace / ensure a final
/// newline), applied while streaming the document out rather than as buffer
/// edits: a GB file trimmed line by line would shatter the piece tree into
/// one piece per line, and the document keeps its exact bytes either way.
///
/// Works on code units so UTF-16/32 files are handled: a newline is an
/// aligned unit with value 10 (the byte 0x0A alone proves nothing there),
/// whitespace is an aligned unit with value 9 or 32. For unitSize == 1
/// (UTF-8, single-byte, DBCS) a byte scan is exact: those encodings never
/// hide 0x09/0x0A/0x20 inside a multi-byte sequence.
///
/// Feed the document's chunks with [push] and call [close] at the end; both
/// return the bytes to write. An empty document stays empty (no newline is
/// added to nothing).
class SaveTransform {
  SaveTransform({
    required this.unitSize,
    required this.littleEndian,
    required this.trimTrailingWhitespace,
    required this.ensureFinalNewline,
    required List<int> newlineBytes,
  }) : _nl = Uint8List.fromList(newlineBytes);

  final int unitSize;
  final bool littleEndian;
  final bool trimTrailingWhitespace;
  final bool ensureFinalNewline;
  final Uint8List _nl;

  final List<int> _buf = <int>[]; // current unterminated line

  /// Consume a chunk, return the bytes that are now safe to write (every
  /// complete line, transformed).
  Uint8List push(List<int> chunk) {
    _buf.addAll(chunk);
    // Consume whole lines with a moving start (removeRange per line would
    // shift the rest of a 1MB chunk once per line).
    var start = 0;
    final out = BytesBuilder();
    var p = _findNewline(start);
    while (p >= 0) {
      final lineEnd = p + unitSize;
      var contentEnd = p;
      // A CR unit right before the LF is part of the terminator, not content.
      if (p > start && _unitAt(p - unitSize) == 13) contentEnd = p - unitSize;
      var cut = contentEnd;
      if (trimTrailingWhitespace) {
        while (cut > start) {
          final v = _unitAt(cut - unitSize);
          if (v != 9 && v != 32) break;
          cut -= unitSize;
        }
      }
      out.add(_buf.sublist(start, cut));
      out.add(_buf.sublist(contentEnd, lineEnd)); // terminator only
      start = lineEnd;
      p = _findNewline(start);
    }
    if (start > 0) _buf.removeRange(0, start);
    return out.toBytes();
  }

  /// Flush the last line (no terminator was found in it).
  Uint8List close() {
    final out = BytesBuilder();
    var end = _buf.length;
    if (trimTrailingWhitespace) {
      while (end >= unitSize) {
        final v = _unitAt(end - unitSize);
        if (v != 9 && v != 32) break;
        end -= unitSize;
      }
    }
    if (end > 0) {
      out.add(_buf.sublist(0, end));
      if (ensureFinalNewline) out.add(_nl);
    }
    // A whitespace-only tail that trimmed to nothing adds nothing: the file
    // either already ends with a newline (something was emitted) or is empty.
    return out.toBytes();
  }

  /// Index of the next aligned newline unit, or -1. Bytes past the last
  /// whole unit stay in the buffer for the next push.
  int _findNewline(int from) {
    if (unitSize == 1) return _buf.indexOf(0x0A, from);
    var i = from;
    final mis = i % unitSize;
    if (mis != 0) i += unitSize - mis;
    while (i + unitSize <= _buf.length) {
      if (unitValueAt(_buf, i, unitSize, littleEndian) == 10) return i;
      i += unitSize;
    }
    return -1;
  }

  int _unitAt(int i) =>
      unitSize == 1
          ? _buf[i]
          : unitValueAt(_buf, i, unitSize, littleEndian);
}

/// Wrap [inner] (a file sink) so everything written through it is
/// transformed first. Returns [inner] untouched when nothing is enabled.
/// Only [add]/[addStream] matter in practice (Document.streamTo adds
/// bytes); the string methods encode with [encoding] first.
IOSink saveTransformSink(
  IOSink inner, {
  required bool trimTrailingWhitespace,
  required bool ensureFinalNewline,
  required int unitSize,
  required bool littleEndian,
  required List<int> newlineBytes,
}) {
  if (!trimTrailingWhitespace && !ensureFinalNewline) return inner;
  return _SaveTransformSink(
    inner,
    SaveTransform(
      unitSize: unitSize,
      littleEndian: littleEndian,
      trimTrailingWhitespace: trimTrailingWhitespace,
      ensureFinalNewline: ensureFinalNewline,
      newlineBytes: newlineBytes,
    ),
  );
}

class _SaveTransformSink implements IOSink {
  _SaveTransformSink(this._inner, this._t);

  final IOSink _inner;
  final SaveTransform _t;
  var _closed = false;

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _inner.add(_t.push(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _inner.add(_t.push(chunk));
    }
  }

  @override
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    var first = true;
    for (final o in objects) {
      if (!first) write(separator);
      write('$o');
      first = false;
    }
  }

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final tail = _t.close();
    if (tail.isNotEmpty) _inner.add(tail);
    await _inner.flush();
    await _inner.close();
  }

  @override
  Future<void> get done => _inner.done;
}
