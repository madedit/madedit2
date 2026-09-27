// Bracket matching over a Document (jump to matching bracket + pair highlight).
//
// Plain character-level matching of () [] {} — no syntax awareness (brackets
// inside strings/comments count too, like MadEdit). Scans chunk by chunk in
// document bytes, so it works at any file size; a [maxScanBytes] cap bounds
// the walk (a match further away than that reports "not found"). Byte
// positions always come from the decode map. Chunk edges are re-aligned to
// character boundaries so a cut multi-byte character can never fake a
// bracket byte; a DBCS backward scan can still misdecode briefly after
// landing mid-character (it resyncs at the next ASCII byte) — the accepted
// price of no-index matching.
//
// Pure Dart, no flutter imports (headless-testable: tool/bracket_match_test.dart).

import 'document.dart';

const String bracketOpens = '([{';
const String bracketCloses = ')]}';

const int _chunk = 256 << 10;

/// Byte offset of the bracket matching the one AT [offset]; null when the
/// char there is not a bracket, or no match within [maxScanBytes].
Future<int?> findMatchingBracket(
  Document doc,
  int offset, {
  int maxScanBytes = 4 << 20,
}) async {
  if (offset < 0 || offset >= doc.length) return null;
  final headLen = doc.length - offset < 8 ? doc.length - offset : 8;
  final head = await doc.readRangeDecoded(offset, headLen);
  if (head.text.isEmpty) return null;
  final cu = head.text.codeUnitAt(0);
  final oi = bracketOpens.indexOf(String.fromCharCode(cu));
  if (oi >= 0) {
    return _scanForward(
      doc,
      offset + head.byteForCodeUnit(1),
      bracketOpens.codeUnitAt(oi),
      bracketCloses.codeUnitAt(oi),
      maxScanBytes,
    );
  }
  final ci = bracketCloses.indexOf(String.fromCharCode(cu));
  if (ci >= 0) {
    return _scanBackward(
      doc,
      offset,
      bracketOpens.codeUnitAt(ci),
      bracketCloses.codeUnitAt(ci),
      maxScanBytes,
    );
  }
  return null;
}

Future<int?> _scanForward(
  Document doc,
  int from,
  int open,
  int close,
  int cap,
) async {
  var pos = from;
  var scanned = 0;
  var depth = 1;
  while (pos < doc.length && scanned < cap) {
    final readLen = (doc.length - pos) < _chunk ? doc.length - pos : _chunk;
    final d = await doc.readRangeDecoded(pos, readLen);
    final text = d.text;
    if (text.isEmpty) break;
    final last = pos + readLen >= doc.length;
    // Drop the final (possibly cut) char of a non-final chunk; re-read it.
    final end = last || text.length <= 1 ? text.length : text.length - 1;
    for (var i = 0; i < end; i++) {
      final c = text.codeUnitAt(i);
      if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0) return pos + d.byteForCodeUnit(i);
      }
    }
    if (last) break;
    final next = pos + d.byteForCodeUnit(end);
    scanned += next - pos > 0 ? next - pos : readLen;
    pos = next > pos ? next : pos + readLen;
  }
  return null;
}

Future<int?> _scanBackward(
  Document doc,
  int before,
  int open,
  int close,
  int cap,
) async {
  var pos = before; // exclusive end of the unscanned region
  var scanned = 0;
  var depth = 1;
  while (pos > 0 && scanned < cap) {
    final start = pos - _chunk < 0 ? 0 : pos - _chunk;
    final d = await doc.readRangeDecoded(start, pos - start);
    final text = d.text;
    if (text.isEmpty) break;
    // A chunk starting mid-file may begin with a cut char: skip index 0
    // (it is re-covered when the walk moves past it).
    final first = start > 0 && text.length > 1 ? 1 : 0;
    for (var i = text.length - 1; i >= first; i--) {
      final c = text.codeUnitAt(i);
      if (c == close) {
        depth++;
      } else if (c == open) {
        depth--;
        if (depth == 0) return start + d.byteForCodeUnit(i);
      }
    }
    if (start == 0) break;
    final next = start + d.byteForCodeUnit(first);
    scanned += pos - next > 0 ? pos - next : pos - start;
    pos = next < pos ? next : start;
  }
  return null;
}
