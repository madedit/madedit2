// Printing (File → Print…, ctrl+p).
//
// Options dialog (whole document or selection, line numbers, syntax colors,
// header, wrapping, font size) → PdfPreview page with the OS print dialog /
// save behind its toolbar.
//
// Two ways to make the PDF:
//   • vector text (print_pdf.dart) with system fonts embedded — the editor's
//     family plus a CJK font for the UI locale (print_fonts.dart finds the
//     files; .ttc collections are split, CFF fonts rejected). Small file,
//     selectable text. Used whenever fonts were found that cover every
//     character in the text;
//   • raster (this file, Flutter's text engine at 144 dpi → PNG per page) as
//     the fallback: no embeddable font on this machine, or characters none
//     of the found fonts have (emoji, rare scripts). Big file, but always
//     looks like the editor does.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../l10n/app_localizations.dart';
import '../settings/app_settings.dart';
import '../settings/resizable_dialog.dart';
import '../util/log.dart';
import 'editor_theme.dart';
import 'editor_view.dart';
import 'highlight.dart';
import 'print_fonts.dart';
import 'print_pdf.dart';

export 'print_pdf.dart' show PrintOptions, PrintSource, printMaxBytes;

/// CJK locale keys in preference order for [locale]: ja → J first,
/// zh_CN/zh_SG/zh_Hans → SC first, else TC first.
List<String> printCjkOrder(Locale locale) {
  final lang = locale.languageCode.toLowerCase();
  final region = (locale.countryCode ?? '').toUpperCase();
  final script = (locale.scriptCode ?? '').toLowerCase();
  final String first;
  if (lang == 'ja') {
    first = 'j';
  } else if (lang == 'zh' &&
      (region == 'CN' || region == 'SG' || script == 'hans')) {
    first = 'sc';
  } else {
    first = 'tc';
  }
  return [
    first,
    ...['tc', 'sc', 'j'].where((k) => k != first),
  ];
}

// Font bytes are resolved once per (editor family, locale order) and kept:
// the registry query and reading a 20MB .ttc are the slow parts.
String? _fontsKey;
List<Uint8List>? _fontsBytes;

Future<PrintFonts?> _resolveFonts(Locale locale) async {
  printFontLog ??= (m) => Log.instance.i(m);
  final family = editorMonoFont;
  final order = printCjkOrder(locale);
  final key = '$family|${order.join()}';
  if (_fontsKey != key) {
    _fontsBytes = await resolvePrintFonts(
      editorFamily: family,
      cjkOrder: order,
    );
    _fontsKey = key;
  }
  final bytes = _fontsBytes;
  if (bytes == null) return null;
  try {
    return PrintFonts.fromBytes(bytes);
  } catch (e) {
    Log.instance.w('print: font parse failed, raster fallback ($e)');
    return null;
  }
}

/// Raster fallback: pages rendered by Flutter's text engine (so the editor
/// font, system CJK fallback and emoji all come out as on screen) into one
/// PNG per page. [syntax] maps highlight style ids to ARGB colors.
Future<Uint8List> buildPrintPdfRaster(
  PrintSource src,
  PrintOptions o,
  PdfPageFormat format, {
  required String fontFamily,
  required Map<int, int> syntax,
}) async {
  const scale = 2.0; // raster resolution: 144 dpi
  final pageW = format.width * scale;
  final pageH = format.height * scale;
  final left = format.marginLeft * scale;
  final right = format.marginRight * scale;
  final top = format.marginTop * scale;
  final bottom = format.marginBottom * scale;
  final contentW = pageW - left - right;
  final fontPx = o.fontSize * scale;
  final lineH = fontPx * 1.3;
  final gutterChars = o.lineNumbers
      ? (src.firstLine + src.lines.length).toString().length + 1
      : 0;
  final gutterW = gutterChars * fontPx * 0.62;
  final textW = contentW - gutterW;

  ui.Paragraph para(String text, List<HlSpan>? spans, {double? width}) {
    final b = ui.ParagraphBuilder(
      ui.ParagraphStyle(fontFamily: fontFamily, fontSize: fontPx),
    );
    final black = ui.TextStyle(
      color: const Color(0xFF000000),
      fontFamily: fontFamily,
      fontSize: fontPx,
    );
    b.pushStyle(black);
    if (spans == null || spans.isEmpty || !o.syntaxColors) {
      b.addText(text);
    } else {
      var pos = 0;
      for (final s in spans) {
        final a = s.start.clamp(0, text.length),
            e = s.end.clamp(0, text.length);
        if (e <= a) continue;
        if (a > pos) b.addText(text.substring(pos, a));
        final argb = syntax[s.style];
        b.pushStyle(
          ui.TextStyle(
            color: Color(argb ?? 0xFF000000),
            fontFamily: fontFamily,
            fontSize: fontPx,
          ),
        );
        b.addText(text.substring(a, e));
        b.pop();
        pos = e;
      }
      if (pos < text.length) b.addText(text.substring(pos));
    }
    final p = b.build();
    p.layout(ui.ParagraphConstraints(width: width ?? (o.wrap ? textW : 1e7)));
    return p;
  }

  final doc = pw.Document(title: src.title);
  var line = 0;
  var pageNo = 0;
  final total = src.lines.length;
  while (line < total && pageNo < printMaxPages) {
    pageNo++;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, pageW, pageH),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    var y = top;
    if (o.header) {
      final h = para(src.title, null, width: contentW * 0.7);
      canvas.drawParagraph(h, Offset(left, y));
      final n = para('$pageNo', null, width: contentW * 0.25);
      canvas.drawParagraph(n, Offset(pageW - right - n.longestLine, y));
      y += lineH;
      canvas.drawLine(
        Offset(left, y - lineH * 0.15),
        Offset(pageW - right, y - lineH * 0.15),
        Paint()
          ..color = const Color(0xFF888888)
          ..strokeWidth = 1,
      );
      y += lineH * 0.5;
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(left, y, contentW, pageH - bottom - y));
    while (line < total) {
      final text = src.lines[line].replaceAll('\t', '    ');
      final p = para(
        text,
        src.spans != null && line < src.spans!.length ? src.spans![line] : null,
      );
      final h = p.height < lineH ? lineH : p.height;
      if (y + h > pageH - bottom && y > top + lineH) break; // next page
      if (o.lineNumbers) {
        final n = para('${src.firstLine + line + 1}', null, width: gutterW);
        canvas.drawParagraph(
          n,
          Offset(left + gutterW - fontPx * 0.62 - n.longestLine, y),
        );
      }
      canvas.drawParagraph(p, Offset(left + gutterW, y));
      y += h;
      line++;
    }
    canvas.restore();
    final img = await rec.endRecording().toImage(pageW.round(), pageH.round());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (png == null) break;
    final mem = pw.MemoryImage(png.buffer.asUint8List());
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(mem, fit: pw.BoxFit.fill),
      ),
    );
  }
  if (pageNo == 0) {
    doc.addPage(pw.Page(pageFormat: format, build: (_) => pw.SizedBox()));
  }
  return doc.save();
}

/// Options dialog → preview page with the OS print action.
Future<void> showPrintDialog(
  BuildContext context,
  EditorController controller,
) async {
  final l10n = AppLocalizations.of(context);
  if (!controller.hasDoc) return;
  // Start finding the fonts now (Windows: a PowerShell registry query, 1–3 s
  // cold; plus reading a 20MB .ttc) so they are usually ready by the time
  // the user has ticked the options and pressed Preview.
  final locale = Localizations.localeOf(context);
  final warm = _resolveFonts(locale);
  final sel = controller.selection;
  final o = PrintOptions()..selectionOnly = sel != null;
  final fontCtl = TextEditingController(text: '9');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        title: Text(l10n.tr('print_title')),
        content: ResizableDialogBox(
          id: 'print',
          initialWidth: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (sel != null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: o.selectionOnly,
                    onChanged: (v) =>
                        setDlg(() => o.selectionOnly = v ?? false),
                    title: Text(l10n.tr('print_selection_only')),
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: o.lineNumbers,
                  onChanged: (v) => setDlg(() => o.lineNumbers = v ?? true),
                  title: Text(l10n.tr('print_line_numbers')),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: o.syntaxColors,
                  onChanged: (v) => setDlg(() => o.syntaxColors = v ?? true),
                  title: Text(l10n.tr('print_syntax_colors')),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: o.header,
                  onChanged: (v) => setDlg(() => o.header = v ?? true),
                  title: Text(l10n.tr('print_header')),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: o.wrap,
                  onChanged: (v) => setDlg(() => o.wrap = v ?? true),
                  title: Text(l10n.tr('print_wrap')),
                ),
                TextField(
                  controller: fontCtl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.tr('print_font_size'),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.tr('print_preview')),
          ),
        ],
      ),
    ),
  );
  final fs = double.tryParse(fontCtl.text.trim());
  Future<void>.delayed(const Duration(milliseconds: 600), fontCtl.dispose);
  if (ok != true || !context.mounted) return;
  if (fs != null && fs >= 4 && fs <= 40) o.fontSize = fs;

  // Gather the text (capped) and its highlight spans.
  final int start, end;
  if (o.selectionOnly && sel != null) {
    (start, end) = sel;
  } else {
    start = 0;
    end = controller.documentLength;
  }
  if (end - start > printMaxBytes) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.trf('print_too_large', [printMaxBytes >> 20])),
      ),
    );
    return;
  }
  final text = await controller.readDecoded(start, end - start);
  if (text == null || !context.mounted) return;
  final firstLine = await controller.lineOfOffset(start);
  if (!context.mounted) return;
  var lines = text.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  lines = [
    for (final l in lines) l.endsWith('\r') ? l.substring(0, l.length - 1) : l,
  ];
  final spans = o.syntaxColors ? controller.highlightLines(lines) : null;
  final name = controller.name ?? l10n.tr('common_untitled');
  final src = PrintSource(
    title: name,
    lines: lines,
    firstLine: firstLine,
    spans: spans,
  );
  final syntax = AppSettings.instance.light.syntax;
  final tabSize = AppSettings.instance.tabSize;
  final family = editorMonoFont;

  // Vector text if the system fonts cover everything, else raster. Decided
  // once here (not per page-format change) so the preview stays consistent.
  final fontsFuture = warm.then((fonts) {
    if (fonts == null) return null;
    final missing = fonts.uncovered(lines);
    if (missing.isNotEmpty) {
      Log.instance.i(
        'print: ${missing.length} code point(s) not in the embed fonts '
        '(e.g. U+${missing.first.toRadixString(16).toUpperCase()}), '
        'raster fallback',
      );
      return null;
    }
    Log.instance.i('print: vector text, ${fonts.count} font(s) embedded');
    return fonts;
  });

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        appBar: AppBar(title: Text('${l10n.tr('print_title')} — $name')),
        body: PdfPreview(
          build: (format) async {
            final fonts = await fontsFuture;
            if (fonts == null) {
              return buildPrintPdfRaster(
                src,
                o,
                format,
                fontFamily: family,
                syntax: syntax,
              );
            }
            return buildPrintPdf(
              src,
              o,
              format,
              fonts: fonts,
              syntax: syntax,
              tabSize: tabSize,
            );
          },
          pdfFileName: '$name.pdf',
          allowSharing: false,
          canChangePageFormat: true,
          canChangeOrientation: true,
          canDebug: false,
          initialPageFormat: PdfPageFormat.a4,
          previewPageMargin: const EdgeInsets.all(12),
        ),
      ),
    ),
  );
}
