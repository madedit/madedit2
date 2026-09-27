// Print layout (pure Dart, headless-tested in tool/print_layout_test.dart):
// logical lines → print rows. Tabs are expanded to spaces first (the PDF
// font has no tab stops either), highlight spans are remapped through the
// expansion and sliced per row, and long lines are cut where the measured
// width would exceed the page — [advance] gives each code point's width in
// the same units as [maxWidth], and must pick the same font per character
// as the PDF text does (print_pdf.dart's PrintFonts.advance), so a row never
// paints wider than its measure.

import 'highlight.dart';
import 'soft_wrap.dart' show sliceSpans;
import 'tab_expand.dart';

class PrintRow {
  const PrintRow(this.line, this.first, this.text, this.spans);

  /// Index into the source lines.
  final int line;

  /// First row of its line (only these get a line number).
  final bool first;

  /// Display text (tabs already expanded).
  final String text;

  /// Highlight spans in [text]'s UTF-16 indices.
  final List<HlSpan> spans;
}

/// Lay [lines] out as rows no wider than [maxWidth]. With [wrap] false
/// every line is a single row (the printer clips it). [spans] is per line
/// (may be null or shorter than [lines]).
List<PrintRow> layoutPrintRows(
  List<String> lines,
  List<List<HlSpan>>? spans, {
  required int tabSize,
  required double maxWidth,
  required bool wrap,
  required double Function(int rune) advance,
}) {
  final out = <PrintRow>[];
  for (var i = 0; i < lines.length; i++) {
    final ex = expandTabs(lines[i], tabSize);
    final text = ex.display;
    final lineSpans = spans != null && i < spans.length
        ? _remapSpans(spans[i], ex.map, text.length)
        : const <HlSpan>[];
    if (!wrap || text.isEmpty) {
      out.add(PrintRow(i, true, text, lineSpans));
      continue;
    }
    var first = true;
    for (final (a, b) in rowBounds(text, maxWidth, advance)) {
      out.add(
        PrintRow(i, first, text.substring(a, b), sliceSpans(lineSpans, a, b)),
      );
      first = false;
    }
  }
  return out;
}

/// Cut points of [text] into rows no wider than [maxWidth]: (start, end)
/// UTF-16 ranges. A character that would cross the edge moves whole to the
/// next row; surrogate pairs are never split; a row always holds at least
/// one character so a glyph wider than the page still advances.
List<(int, int)> rowBounds(
  String text,
  double maxWidth,
  double Function(int rune) advance,
) {
  final rows = <(int, int)>[];
  var start = 0, i = 0;
  var width = 0.0;
  while (i < text.length) {
    final u = text.codeUnitAt(i);
    final pair = u >= 0xD800 && u < 0xDC00 && i + 1 < text.length;
    final rune = pair
        ? 0x10000 + ((u - 0xD800) << 10) + (text.codeUnitAt(i + 1) - 0xDC00)
        : u;
    final w = advance(rune);
    final len = pair ? 2 : 1;
    if (width + w > maxWidth && i > start) {
      rows.add((start, i));
      start = i;
      width = 0;
    }
    width += w;
    i += len;
  }
  rows.add((start, text.length));
  return rows;
}

// Spans are in the line's original indices; the printed text has tabs
// expanded, so both ends go through the expansion map.
List<HlSpan> _remapSpans(List<HlSpan> spans, List<int> map, int textLen) {
  if (spans.isEmpty) return const [];
  final n = map.length - 1;
  final out = <HlSpan>[];
  for (final s in spans) {
    final a = map[s.start.clamp(0, n)], b = map[s.end.clamp(0, n)];
    if (b > a) out.add(HlSpan(a, b > textLen ? textLen : b, s.style));
  }
  return out;
}
