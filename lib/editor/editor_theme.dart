// Shared look of the editor surfaces (text view, hex view): fonts, metrics and colors, all read
// from [AppSettings] so a settings change applies live (these are getters on purpose — every
// build/paint re-reads them).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import '../util/log.dart';
import 'tab_expand.dart';

/// Font size / row height at quick-zoom factor [zoom]. Zoom is per tab (the
/// text and hex views pass their pane's factor); the diff / merge views use
/// the plain getters below, i.e. the font dialog's size.
double editorFontSizeAt(double zoom) => AppSettings.instance.fontSize * zoom;
double editorLineHeightAt(double zoom) =>
    AppSettings.instance.lineHeight * zoom;

double get editorFontSize => editorFontSizeAt(1);
double get editorLineHeight => editorLineHeightAt(1);

Color get editorBg => Color(AppSettings.instance.bgArgb);
Color get editorFg => Color(AppSettings.instance.fgArgb);
Color get editorGutterBg => Color(AppSettings.instance.gutterBgArgb);

/// Interface chrome (menu/status bars, side panels) — NOT the gutter.
Color get editorChromeBg => Color(AppSettings.instance.chromeBgArgb);
Color get editorGutterFg => Color(AppSettings.instance.gutterFgArgb);
Color get editorCaretColor => Color(AppSettings.instance.caretArgb);
Color get editorSelColor => Color(AppSettings.instance.selectionArgb);
Color get editorCurrentLineColor => Color(AppSettings.instance.currentLineArgb);

/// Monospace family: the configured one, else the platform default.
String get editorMonoFont {
  final f = AppSettings.instance.fontFamily.trim();
  if (f.isNotEmpty) return f;
  return Platform.isWindows
      ? 'Consolas'
      : Platform.isMacOS
      ? 'Menlo'
      : 'monospace';
}

/// Layout width for a single-line Paragraph: large enough that the whole line gets laid out, so
/// horizontal scrolling (canvas translation) can still show what is off to the right.
const double editorLayoutMaxW = 16777216; // 1 << 24

/// Build one laid-out, single-line [ui.Paragraph] in the editor font.
///
/// [runs] are (text, color) segments drawn back to back — one run for a plain line, several for
/// syntax colors or the hex view's offset/hex/ascii columns.
ui.Paragraph buildMonoParagraph(
  List<(String, Color)> runs, {
  double maxWidth = editorLayoutMaxW,
  bool singleLine = true,
  double zoom = 1,
}) {
  final fontSize = editorFontSizeAt(zoom);
  final pb = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      fontSize: fontSize,
      fontFamily: editorMonoFont,
      maxLines: singleLine ? 1 : null,
      ellipsis: singleLine ? '' : null,
    ),
  );
  for (final (text, color) in runs) {
    if (text.isEmpty) continue;
    pb.pushStyle(
      ui.TextStyle(
        color: color,
        fontSize: fontSize,
        fontFamily: editorMonoFont,
      ),
    );
    pb.addText(text);
    pb.pop();
  }
  return pb.build()..layout(ui.ParagraphConstraints(width: maxWidth));
}

/// Width of one character in the editor's monospace font (all glyphs are the same width).
double get editorCharWidth => editorCharWidthAt(1);

/// [editorCharWidth] at quick-zoom factor [zoom]. Cached per family/size:
/// tabs at different zoom levels repaint in turn, and a single-slot cache
/// would re-measure on every switch.
double editorCharWidthAt(double zoom) {
  final size = editorFontSizeAt(zoom);
  final key = '$editorMonoFont/$size';
  final hit = _charWidths[key];
  if (hit != null) return hit;
  // First layout in a new family/size: this is where the engine resolves
  // the system font. Logged when slow (a freeze after a font change has
  // been reported; a slow resolve here would explain it).
  final sw = Stopwatch()..start();
  final p = buildMonoParagraph([('0' * 16, editorFg)], zoom: zoom);
  final w = p.maxIntrinsicWidth / 16;
  if (sw.elapsedMilliseconds >= 200) {
    Log.instance.w(
      'slow: first layout of font "$editorMonoFont" $size took '
      '${sw.elapsedMilliseconds} ms',
    );
  }
  if (_charWidths.length > 64) _charWidths.clear(); // font / size churn
  return _charWidths[key] = w;
}

/// Lets the text engine wrap at [width] and returns the wrap points (UTF-16
/// indices; the first and last entries are 0 and the line length).
///
/// Unlike "by character count", this is a **real measurement**: double-width
/// characters (CJK etc.) and word-boundary breaking are all accounted for,
/// so every row truly fits inside the viewport.
List<int> measuredWrapBoundaries(
  String line,
  double width, {
  double zoom = 1,
}) {
  if (width <= 8 || line.isEmpty) return [0, line.length];
  // Lay out the tab-expanded text (that is what gets painted) and map the
  // cut points back to the line's own indices; a cut inside a tab's spaces
  // lands on the tab itself.
  final ex = expandTabs(line, AppSettings.instance.tabSize);
  final shown = ex.display;
  final para = buildMonoParagraph(
    [(shown, editorFg)],
    maxWidth: width,
    singleLine: false,
    zoom: zoom,
  );
  final out = <int>[0];
  var pos = 0;
  while (pos < shown.length) {
    final r = para.getLineBoundary(ui.TextPosition(offset: pos));
    final end = r.end > pos ? r.end : shown.length;
    if (end >= shown.length) break;
    final cut = charForDisplay(ex.map, end);
    if (cut <= out.last) break; // no progress in line indices → stop
    out.add(cut);
    pos = end;
  }
  out.add(line.length);
  return out;
}

final Map<String, double> _charWidths = {};
