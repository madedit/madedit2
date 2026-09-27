// Soft wrap: split a long logical line into several visual rows at a fixed **character** count
// (settings: font → characters per row). Wrapping by character count rather than by viewport width keeps the
// row a pure function of the text, so the same math serves painting, the caret, hit-testing and
// scrolling — and a 100 MB single-line file stays navigable.
//
// Pure Dart (no Flutter), so it is headless-testable — see tool/soft_wrap_test.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'column_block.dart';
import 'highlight.dart';

/// One visual row produced by wrapping.
class WrapRow {
  const WrapRow({
    required this.text,
    required this.offset,
    required this.lineIndex,
    required this.charStart,
    required this.isFirst,
    required this.isLast,
    this.map,
  });

  /// The row's text (a slice of the logical line).
  final String text;

  /// Document byte offset where this row starts.
  final int offset;

  /// Index of the logical line this row came from (into the window's lines).
  final int lineIndex;

  /// UTF-16 index of [text] within the logical line.
  final int charStart;

  /// Whether this is the logical line's first row (only those get a line number).
  final bool isFirst;

  /// Whether this is the logical line's last row (only there does the newline live).
  final bool isLast;

  /// Row-local byte<->code-unit map from the document's codec: `map[i]` =
  /// byte offset (relative to [offset]) of the character producing code unit
  /// `i` of [text]; one extra trailing entry = the row's byte length. Null
  /// when the caller didn't pass per-line maps (legacy UTF-8 math applies).
  final Uint32List? map;

  /// Byte length of [text] under the document's codec.
  int get contentBytes {
    final m = map;
    return m != null ? m[m.length - 1] : utf8.encode(text).length;
  }

  /// Row-local byte offset of code unit [charIndex] (clamped to the row).
  int byteOfChar(int charIndex) {
    final m = map;
    if (m == null) return byteOffsetOfChar(text, charIndex);
    final i = charIndex < 0
        ? 0
        : (charIndex >= m.length ? m.length - 1 : charIndex);
    return m[i];
  }

  /// First code unit of the character covering row-local [byteWithin]
  /// (`text.length` when at/past the row's content end).
  int charOfByte(int byteWithin) {
    final m = map;
    if (m == null) return _utf8CharOfByte(text, byteWithin);
    if (byteWithin <= 0) return 0;
    final content = m[m.length - 1];
    if (byteWithin >= content) return text.length;
    var lo = 0, hi = text.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (m[mid] <= byteWithin) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    while (ans > 0 && m[ans - 1] == m[ans]) {
      ans--; // back to the character's first code unit (surrogate pairs)
    }
    return ans;
  }
}

// Legacy in-line byte->char for rows without a codec map (UTF-8 assumption).
int _utf8CharOfByte(String line, int byteWithin) {
  if (byteWithin <= 0) return 0;
  var b = 0, ci = 0;
  for (final r in line.runes) {
    if (b >= byteWithin) return ci;
    b += utf8.encode(String.fromCharCode(r)).length;
    ci += r > 0xFFFF ? 2 : 1;
  }
  return ci;
}

/// Where a logical line is cut, as UTF-16 indices: always starts with 0 and ends with the line
/// length. A [columns] of 0 or less (or a short line) yields a single chunk.
///
/// Never cuts between a surrogate pair (that would render as two broken glyphs).
List<int> wrapBoundaries(String line, int columns) {
  if (columns <= 0 || line.length <= columns) return [0, line.length];
  final out = <int>[0];
  var i = 0;
  while (line.length - i > columns) {
    var cut = i + columns;
    final u = line.codeUnitAt(cut - 1);
    if (u >= 0xD800 && u < 0xDC00) cut--; // never cut inside a surrogate pair
    if (cut <= i) cut = i + columns; // degenerate case: force a cut rather than not advancing
    out.add(cut);
    i = cut;
  }
  out.add(line.length);
  return out;
}

/// Byte length of `line[0..charIndex)` (UTF-8), i.e. the byte offset of a wrap point within a line.
int byteOffsetOfChar(String line, int charIndex) =>
    charIndex <= 0 ? 0 : utf8.encode(line.substring(0, charIndex)).length;

/// Expand a window of logical lines into visual rows.
///
/// [offsets] are the lines' document byte offsets (as [DocWindow] provides them). When [columns]
/// is 0 or less, every line becomes exactly one row (wrapping off).
///
/// [maps] (optional, parallel to [lines]) are the per-line byte<->code-unit
/// maps from the document's codec (`DocWindow.maps`); rows then carry exact
/// byte offsets for any encoding instead of assuming UTF-8.
List<WrapRow> wrapWindow(
  List<String> lines,
  List<int> offsets,
  int columns, {
  List<int> Function(String line)? boundariesOf,
  List<Uint32List>? maps,
}) {
  final rows = <WrapRow>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final base = i < offsets.length ? offsets[i] : 0;
    final lineMap = maps != null && i < maps.length ? maps[i] : null;
    if (boundariesOf == null && (columns <= 0 || line.length <= columns)) {
      rows.add(
        WrapRow(
          text: line,
          offset: base,
          lineIndex: i,
          charStart: 0,
          isFirst: true,
          isLast: true,
          map: lineMap,
        ),
      );
      continue;
    }
    final cuts = boundariesOf?.call(line) ?? wrapBoundaries(line, columns);
    for (var k = 0; k + 1 < cuts.length; k++) {
      final a = cuts[k], b = cuts[k + 1];
      Uint32List? rowMap;
      var rowByteStart = 0;
      if (lineMap != null) {
        rowByteStart = lineMap[a];
        rowMap = Uint32List(b - a + 1);
        for (var j = 0; j <= b - a; j++) {
          rowMap[j] = lineMap[a + j] - rowByteStart;
        }
      }
      rows.add(
        WrapRow(
          text: line.substring(a, b),
          offset:
              base +
              (lineMap != null ? rowByteStart : byteOffsetOfChar(line, a)),
          lineIndex: i,
          charStart: a,
          isFirst: k == 0,
          isLast: k + 2 == cuts.length,
          map: rowMap,
        ),
      );
    }
  }
  return rows;
}

/// Slice a logical line's highlight spans down to one row and shift them to row-local indices.
List<HlSpan> sliceSpans(List<HlSpan>? spans, int charStart, int charEnd) {
  if (spans == null || spans.isEmpty) return const [];
  final out = <HlSpan>[];
  for (final s in spans) {
    if (s.end <= charStart || s.start >= charEnd) continue;
    final a = (s.start < charStart ? charStart : s.start) - charStart;
    final b = (s.end > charEnd ? charEnd : s.end) - charStart;
    if (b > a) out.add(HlSpan(a, b, s.style));
  }
  return out;
}

/// Where the next visual row starts, given [text] read from the current row's start (UTF-16 index
/// into [text]); null = no next row inside [text] (the caller falls back to line navigation).
///
/// Three cases, and getting any of them wrong makes scrolling stick in place:
///   - the row is full but the line continues → the next wrap point;
///   - the row reaches the line end (including an **empty line**) → just past the newline;
///   - no newline in [text] at all (a very long line's tail) → null.
int? nextRowCharOffset(
  String text,
  List<int> Function(String lineRest) boundariesOf,
) {
  if (text.isEmpty) return null;
  final nl = text.indexOf('\n');
  final lineRest = nl >= 0 ? text.substring(0, nl) : text;
  final cuts = boundariesOf(lineRest);
  final wrapAt = cuts.length > 1 ? cuts[1] : lineRest.length;
  if (wrapAt < lineRest.length) return wrapAt;
  if (nl >= 0) return nl + 1;
  return null;
}

/// Where the **last** visual row of [lineContent] starts (empty → 0).
///
/// Scrolling up uses this twice, with the same formula:
///   - still inside the same line → pass the prefix "line start … current row start", which yields
///     the previous row's start;
///   - crossing into the previous line → pass that whole line's content, which yields its last row.
int lastRowCharStart(
  String lineContent,
  List<int> Function(String lineContent) boundariesOf,
) {
  if (lineContent.isEmpty) return 0;
  final cuts = boundariesOf(lineContent);
  return cuts.length >= 2 ? cuts[cuts.length - 2] : 0;
}

/// The wrap point at or before [charIndex] within a line — used when scrolling up into the middle
/// of a wrapped line. Returns 0 when [charIndex] is in the first row.
int wrapStartAtOrBefore(String line, int columns, int charIndex) {
  final cuts = wrapBoundaries(line, columns);
  var start = 0;
  for (final c in cuts) {
    if (c > charIndex) break;
    start = c;
  }
  return start;
}

/// Start of the visual row **preceding** the one that contains [charIndex]; -1 when [charIndex] is
/// already in the first row. This is what scrolling up one row within a wrapped line needs.
int wrapStartBefore(String line, int columns, int charIndex) {
  final cuts = wrapBoundaries(line, columns);
  var curIdx = 0;
  for (var i = 0; i < cuts.length; i++) {
    if (cuts[i] > charIndex) break;
    curIdx = i;
  }
  return curIdx == 0 ? -1 : cuts[curIdx - 1];
}

/// Which row of [cuts] (as returned by [wrapBoundaries] / a measured
/// boundary function) holds UTF-16 index [ci]: the last row starting at or
/// before it — a caret sitting exactly on a cut belongs to the row that cut
/// starts, which is also where the painter draws it.
int rowIndexOfChar(List<int> cuts, int ci) {
  var r = 0;
  for (var k = 1; k + 1 < cuts.length; k++) {
    if (cuts[k] <= ci) r = k;
  }
  return r;
}

/// Caret position (UTF-16 index into [line]) after a vertical move onto row
/// [k] of [line] aiming at display column [goal]: the goal clamped to the
/// row's content. A row that is not the line's last one stops one character
/// short of its cut — the cut itself is the next row's start, so a caret
/// there would render on (and the next move would skip) that row.
int charInRowForColumn(
  String line,
  List<int> cuts,
  int k,
  int goal, {
  int tabSize = 1,
}) {
  final a = cuts[k], b = cuts[k + 1];
  final row = line.substring(a, b);
  var ci = charIndexForColumn(row, goal, tabSize: tabSize);
  final isLast = k + 2 >= cuts.length;
  if (!isLast && ci >= row.length && row.isNotEmpty) {
    ci = row.length - 1;
    final u = row.codeUnitAt(ci);
    // Stay before a surrogate pair rather than inside it.
    if (ci > 0 && u >= 0xDC00 && u < 0xE000) {
      ci--;
    }
  }
  return a + ci;
}
