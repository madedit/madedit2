// Map the byte-range spans produced by the Rust (tree-sitter) backend back to per-line UTF-16
// character spans, which is what the render pipeline (ParagraphBuilder) indexes by.
//
// Kept free of Flutter imports so it stays headless-testable (see tool/rust_highlight_test.dart).

import 'dart:convert';

import '../src/rust/api/highlight.dart' as rust;
import 'highlight.dart';

/// Split byte-range [spans] over the joined text (`lines.join('\n')`) into per-line spans.
///
/// Linear in (lines + spans): the spans come out of tree-sitter-highlight ordered and
/// non-overlapping, so a cursor walks the line table alongside them. (Scanning every line per span
/// instead is O(lines × spans) — fine for a ~50-line window, seconds for a whole file.)
List<List<HlSpan>> mapSpansToLines(
  List<String> lines,
  List<rust.HlSpan> spans,
) {
  final n = lines.length;
  // Start byte of each line within the joined text (+ one past the last line, so line i's content
  // ends at lineStart[i + 1] - 1, i.e. excluding the '\n').
  final lineStart = List<int>.filled(n + 1, 0);
  final ascii = List<bool>.filled(n, false);
  var acc = 0;
  for (var i = 0; i < n; i++) {
    lineStart[i] = acc;
    final line = lines[i];
    var isAscii = true;
    for (var k = 0; k < line.length; k++) {
      if (line.codeUnitAt(k) >= 0x80) {
        isAscii = false;
        break;
      }
    }
    ascii[i] = isAscii;
    acc += (isAscii ? line.length : utf8.encode(line).length) + 1; // + '\n'
  }
  lineStart[n] = acc;

  final byLine = [for (final _ in lines) <HlSpan>[]];
  var i = 0; // line containing the current span's start
  for (final s in spans) {
    while (i > 0 && lineStart[i] > s.start) {
      i--;
    }
    while (i + 1 < n && lineStart[i + 1] <= s.start) {
      i++;
    }
    for (var j = i; j < n; j++) {
      final ls = lineStart[j], le = lineStart[j + 1] - 1;
      if (ls >= s.end) break; // span ended before this line
      final bs = (s.start > ls ? s.start : ls) - ls;
      final be = (s.end < le ? s.end : le) - ls;
      if (be <= bs) continue;
      final cs = _byteToChar(lines[j], bs, ascii[j]);
      final ce = _byteToChar(lines[j], be, ascii[j]);
      if (ce > cs) byLine[j].add(HlSpan(cs, ce, s.style));
    }
  }
  return byLine;
}

// In-line byte offset → UTF-16 code unit index (what ParagraphBuilder indexes by, so an astral
// character such as an emoji counts as 2). [ascii] short-circuits the common case, where the two
// are identical; otherwise walk the code units without allocating.
int _byteToChar(String line, int byteWithin, bool ascii) {
  if (byteWithin <= 0) return 0;
  if (ascii) return byteWithin < line.length ? byteWithin : line.length;
  var b = 0, i = 0;
  final n = line.length;
  while (i < n && b < byteWithin) {
    final u = line.codeUnitAt(i);
    if (u < 0x80) {
      b += 1;
      i += 1;
    } else if (u < 0x800) {
      b += 2;
      i += 1;
    } else if (u >= 0xD800 && u < 0xDC00 && i + 1 < n) {
      b += 4; // surrogate pair = one 4-byte UTF-8 sequence
      i += 2;
    } else {
      b += 3;
      i += 1;
    }
  }
  return i;
}
