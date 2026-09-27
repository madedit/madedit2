// PDF generation for printing (pure Dart: package:pdf only, no flutter —
// tool/print_pdf_test.dart builds a real PDF headless).
//
// Text is written as vector text with system fonts embedded (subsetted:
// only the glyphs used end up in the file), so the PDF is small, sharp at
// any zoom, and selectable/searchable. Which fonts: print_fonts.dart finds
// the editor's family plus one CJK font per locale on this machine; rows
// are laid out with the fonts' real advance widths (the same per-character
// font choice package:pdf makes: primary first, then the fallbacks in
// order), so wrapping matches what gets painted.
//
// Limits inherited from package:pdf: TrueType (glyf) fonts only, no color
// emoji, no complex-script shaping. print_page.dart falls back to raster
// printing when no font is found or the text has uncovered characters.

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'highlight.dart';
import 'print_layout.dart';

class PrintOptions {
  bool selectionOnly = false;
  bool lineNumbers = true;
  bool syntaxColors = true;
  bool header = true;
  bool wrap = true;
  double fontSize = 9; // points
}

/// What gets printed: the lines, their first (0-based) line number, and
/// optional per-line highlight spans.
class PrintSource {
  const PrintSource({
    required this.title,
    required this.lines,
    required this.firstLine,
    this.spans,
  });
  final String title;
  final List<String> lines;
  final int firstLine;
  final List<List<HlSpan>>? spans;
}

/// The embedded fonts: [primary] (the editor's family) and the CJK
/// [fallback]s, each parsed twice — once for package:pdf, once for metrics.
class PrintFonts {
  PrintFonts._(this.primary, this.fallback, this._parsers);

  final pw.Font primary;
  final List<pw.Font> fallback;
  final List<TtfParser> _parsers; // primary first, same order as fallback

  /// Build from raw TTF bytes, first entry = primary.
  factory PrintFonts.fromBytes(List<Uint8List> ttfs) {
    final data = [for (final b in ttfs) ByteData.sublistView(b)];
    return PrintFonts._(
      pw.Font.ttf(data.first),
      [for (final d in data.skip(1)) pw.Font.ttf(d)],
      [for (final d in data) TtfParser(d)],
    );
  }

  int get count => _parsers.length;

  /// Which font paints [rune] (index into primary+fallback), -1 = none.
  int fontFor(int rune) {
    for (var i = 0; i < _parsers.length; i++) {
      if (_parsers[i].charToGlyphIndexMap.containsKey(rune)) return i;
    }
    return -1;
  }

  bool covers(int rune) => fontFor(rune) >= 0;

  /// Advance width of [rune] in em (of whichever font paints it). Uncovered
  /// characters count as one primary space so the layout stays sane.
  double advanceEm(int rune) {
    final i = fontFor(rune);
    final p = _parsers[i < 0 ? 0 : i];
    final g = p.charToGlyphIndexMap[i < 0 ? 0x20 : rune];
    final m = g == null ? null : p.glyphInfoMap[g];
    return m?.advanceWidth ?? 0.5;
  }

  /// Line height in em from the primary font's ascent/descent, at least 1.3.
  double get lineHeightEm {
    final p = _parsers.first;
    final h = (p.ascent - p.descent) / p.unitsPerEm;
    return h < 1.3 ? 1.3 : h * 1.05;
  }

  /// Code points in [lines] none of the fonts can paint (controls, tab and
  /// newline excluded). Empty = safe to print as vector text.
  Set<int> uncovered(Iterable<String> lines) {
    final seen = <int>{}, missing = <int>{};
    for (final line in lines) {
      for (final r in line.runes) {
        if (r < 0x20 || !seen.add(r)) continue;
        if (!covers(r)) missing.add(r);
      }
    }
    return missing;
  }
}

/// Hard cap so a GB file cannot be printed by accident.
const int printMaxBytes = 8 << 20;
const int printMaxPages = 500;

/// Render [src] into a PDF of [format]-sized pages. [syntax] maps highlight
/// style ids to ARGB colors (the light theme's, for paper).
Future<Uint8List> buildPrintPdf(
  PrintSource src,
  PrintOptions o,
  PdfPageFormat format, {
  required PrintFonts fonts,
  required Map<int, int> syntax,
  required int tabSize,
}) async {
  final fs = o.fontSize;
  final lineH = fs * fonts.lineHeightEm;
  final digitW = fs * fonts.advanceEm(0x30); // '0'
  final contentW = format.availableWidth;
  final contentH = format.availableHeight;

  // Gutter: widest line number + one digit of gap.
  final digits = o.lineNumbers
      ? (src.firstLine + src.lines.length).toString().length
      : 0;
  final gutterW = o.lineNumbers ? (digits + 1) * digitW : 0.0;
  final textW = contentW - gutterW;

  final headerH = o.header ? lineH * 1.5 : 0.0;
  final rowsPerPage = ((contentH - headerH) / lineH).floor().clamp(1, 1 << 20);

  final rows = layoutPrintRows(
    src.lines,
    o.syntaxColors ? src.spans : null,
    tabSize: tabSize,
    maxWidth: textW,
    wrap: o.wrap,
    advance: (r) => fs * fonts.advanceEm(r),
  );

  pw.TextStyle style([int? argb]) => pw.TextStyle(
    font: fonts.primary,
    fontFallback: fonts.fallback,
    fontSize: fs,
    color: argb == null ? PdfColors.black : PdfColor.fromInt(argb),
  );
  final plain = style();
  final grey = style(0xFF888888);

  pw.Widget rowText(PrintRow r) {
    final text = r.text;
    final children = <pw.TextSpan>[];
    var pos = 0;
    for (final s in r.spans) {
      final a = s.start.clamp(0, text.length), e = s.end.clamp(0, text.length);
      if (e <= a) continue;
      if (a > pos) children.add(pw.TextSpan(text: text.substring(pos, a)));
      final argb = syntax[s.style];
      children.add(
        pw.TextSpan(
          text: text.substring(a, e),
          style: argb == null ? null : style(argb),
        ),
      );
      pos = e;
    }
    if (pos < text.length) {
      children.add(pw.TextSpan(text: text.substring(pos)));
    }
    return pw.RichText(
      text: pw.TextSpan(style: plain, children: children),
      softWrap: false,
      overflow: pw.TextOverflow.clip,
    );
  }

  pw.Widget rowWidget(PrintRow r) => pw.SizedBox(
    height: lineH,
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (o.lineNumbers)
          pw.SizedBox(
            width: gutterW,
            child: pw.Padding(
              padding: pw.EdgeInsets.only(right: digitW),
              child: pw.Text(
                r.first ? '${src.firstLine + r.line + 1}' : '',
                style: grey,
                textAlign: pw.TextAlign.right,
              ),
            ),
          ),
        pw.Expanded(child: pw.ClipRect(child: rowText(r))),
      ],
    ),
  );

  final doc = pw.Document(title: src.title, creator: 'madedit2');
  var pageNo = 0;
  for (var i = 0; i < rows.length && pageNo < printMaxPages; i += rowsPerPage) {
    pageNo++;
    final page = rows.sublist(
      i,
      i + rowsPerPage > rows.length ? rows.length : i + rowsPerPage,
    );
    final n = pageNo; // captured per page
    doc.addPage(
      pw.Page(
        pageFormat: format,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (o.header) ...[
              pw.SizedBox(
                height: lineH,
                child: pw.Row(
                  children: [
                    pw.Expanded(
                      child: pw.Text(
                        src.title,
                        style: plain,
                        maxLines: 1,
                        overflow: pw.TextOverflow.clip,
                      ),
                    ),
                    pw.Text('$n', style: plain),
                  ],
                ),
              ),
              pw.Divider(height: lineH * 0.5, thickness: 0.5, color: PdfColors.grey),
            ],
            for (final r in page) rowWidget(r),
          ],
        ),
      ),
    );
  }
  if (pageNo == 0) {
    // Nothing to print (empty selection): one blank page keeps the preview
    // and the print dialog working.
    doc.addPage(pw.Page(pageFormat: format, build: (_) => pw.SizedBox()));
  }
  return doc.save();
}
