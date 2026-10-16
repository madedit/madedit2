part of 'editor_view.dart';

// ── Shared text/geometry helpers (used by both render and hit-test so coordinates agree) ──

const double _gutterPad = 6;
const Color _thumb = Color(0x66AAAAAA);
const double _scrollbarMargin = 14; // width reserved for the right-hand scrollbar

/// Layout width for a single-line Paragraph: large enough that every glyph of the line is
/// laid out, so content to the right is still drawn after horizontal scrolling (canvas
/// translation). Bounded because readWindow caps a single line at 1MB.
const double _layoutMaxW = 16777216; // 1 << 24

/// x of a character index within its row (relative to the text origin). Shared by render and
/// caret horizontal scrolling.
/// (Public for test/caret_x_bidi_test.dart.)
double caretXInParagraph(ui.Paragraph p, int charIndex) {
  // The caret before paragraph index i sits on the edge of the glyph before
  // it: an LTR glyph's RIGHT edge, an RTL glyph's LEFT edge (text advances
  // leftward there). The old `getBoxesForRange(0, i).last.right` was the
  // visual right of whichever run came last — wrong inside and after a
  // right-to-left run (Arabic / Hebrew in a line).
  if (charIndex <= 0) {
    final first = p.getBoxesForRange(0, 1);
    if (first.isEmpty) return 0;
    final b = first.first;
    return b.direction == ui.TextDirection.rtl ? b.right : b.left;
  }
  final prev = p.getBoxesForRange(charIndex - 1, charIndex);
  if (prev.isNotEmpty) {
    final b = prev.last;
    return b.direction == ui.TextDirection.rtl ? b.left : b.right;
  }
  // A zero-width glyph (surrogate half, combining mark on its own): fall
  // back to the end of everything before it.
  final boxes = p.getBoxesForRange(0, charIndex);
  return boxes.isEmpty ? 0 : boxes.last.right;
}

/// A laid-out row with tabs expanded to the tab stops (settings → Tab width):
/// the paragraph shows spaces, [map] converts the row's own UTF-16 indices
/// to paragraph indices, and the helpers hide the difference so callers keep
/// working in row indices.
class _LinePara {
  const _LinePara(this.para, this.map, {this.rtl = false});
  final ui.Paragraph para;
  final Int32List map;

  /// Laid out with a right-to-left base direction (first strong character
  /// is RTL, see bidi.dart). Such a row is shown right-aligned: every x the
  /// painter / hit-test computes from this paragraph is offset by
  /// [rtlShift] of the text area's width.
  final bool rtl;

  /// Horizontal offset that right-aligns an RTL row inside a text area
  /// [areaW] wide; 0 for LTR rows, and for RTL rows wider than the area
  /// (those overflow to the right like LTR ones — horizontal scrolling keeps
  /// one origin).
  double rtlShift(double areaW) =>
      rtl && width < areaW ? areaW - width : 0;

  int _d(int charIndex) =>
      map[charIndex < 0
          ? 0
          : (charIndex >= map.length ? map.length - 1 : charIndex)];

  /// x of row char index [charIndex] (relative to the text start).
  double xOf(int charIndex) => caretXInParagraph(para, _d(charIndex));

  /// Glyph boxes covering row chars [a, b).
  List<ui.TextBox> boxes(int a, int b) => para.getBoxesForRange(_d(a), _d(b));

  /// Row char index nearest to x = [dx] (hit test).
  int charAt(double dx) => charForDisplay(
    map,
    para.getPositionForOffset(Offset(dx, para.height / 2)).offset,
  );

  double get width => para.maxIntrinsicWidth;
  double get height => para.height;
}

/// Row shift in document RTL layout: every row's right edge sits on the
/// common right edge max([areaW], [contentW]) (the text area, or the widest
/// visible row's extent when that overflows the view), so line starts line
/// up whatever their length. [contentW] includes the caret padding that
/// _measureContentW adds, which thus lands on the left = the line-end side.
double rtlLayoutShift(double rowWidth, double areaW, double contentW) {
  final right = contentW > areaW ? contentW : areaW;
  final s = right - rowWidth;
  return s > 0 ? s : 0;
}

final RegExp _wordCharRe = RegExp(r'[\p{L}\p{N}_]', unicode: true);

/// First index in sorted [a] whose value is >= [v] (a.length when none).
int _lowerBound(List<int> a, int v) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (a[mid] < v) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Whether the character covering code unit [j] of [s] is a word character
/// (letter / digit / underscore); surrogate halves resolve to their pair.
bool _isWordCharAt(String s, int j) {
  var k = j;
  if ((s.codeUnitAt(k) & 0xFC00) == 0xDC00 && k > 0) k--;
  final pair = (s.codeUnitAt(k) & 0xFC00) == 0xD800 && k + 1 < s.length;
  return _wordCharRe.hasMatch(s.substring(k, k + (pair ? 2 : 1)));
}

/// Display column a soft-wrap slice starts at (0 for a line's first row):
/// tab stops inside the slice depend on the columns its prefix occupies.
int _rowStartColumn(DocWindow? win, WrapRow row, int tabSize) {
  if (row.isFirst || win == null || row.lineIndex >= win.lines.length) return 0;
  final line = win.lines[row.lineIndex];
  final cs = row.charStart > line.length ? line.length : row.charStart;
  return displayColumn(line.substring(0, cs), tabSize);
}

/// Gutter (line-number column) width: estimated from the digit count of the largest visible
/// line number. Shared by render and hit-test.
/// [zoom] (and every `...At` helper below) is the pane's quick-zoom factor;
/// the render object and the state wrap these as `_gutterWidthFor` /
/// `_buildLine` / `_buildLineStyled` with their own zoom.
/// Digits are measured in the real font (editorCharWidthAt measures '0'),
/// not estimated: a 0.62em guess clipped the last digit in fonts with wider
/// figures. [_foldColW] is always reserved so the gutter does not change
/// width when fold regions arrive after highlighting.
double _gutterWidthAt(int anchorLine, int linesInWindow, double zoom) {
  final maxNo = anchorLine >= 0 ? anchorLine + linesInWindow + 1 : 0;
  final digits = maxNo > 0 ? maxNo.toString().length : 7;
  return digits.clamp(4, 12) * editorCharWidthAt(zoom) +
      _foldColW +
      _gutterPad * 2;
}

/// Width of the fold-chevron column at the gutter's right edge (the chevron
/// is drawn centred 8px from the edge, ±4px; clicks within 16px toggle).
const double _foldColW = 12;

/// Build one laid-out Paragraph for a row (single line, no wrapping, no ellipsis). Shared by
/// painting and measurement.
_LinePara _buildLineAt(
  double zoom,
  String raw,
  double maxWidth, [
  Color? textColor,
  int startColumn = 0,
  bool? baseRtl,
  int tabSize = 4,
]) {
  final ex = expandTabs(raw, tabSize, startColumn: startColumn);
  final text = ex.display;
  final color = textColor ?? _fg;
  final rtl = baseRtl ?? isRtlText(text);
  final pb =
      ui.ParagraphBuilder(_lineParagraphStyle(rtl, zoom))..pushStyle(
        ui.TextStyle(
          color: color,
          fontSize: editorFontSizeAt(zoom),
          fontFamily: _monoFont,
        ),
      );
  pb.addText(text);
  return _LinePara(
    pb.build()..layout(ui.ParagraphConstraints(width: maxWidth)),
    ex.map,
    rtl: rtl,
  );
}

/// Width of the vertical scrollbar hot zone overlaid on the text area's right
/// edge (mirrors the `width: 16` of that Positioned in build; tests use it to
/// keep their taps out of the zone). The text area itself reserves
/// [_scrollbarMargin] so right-aligned RTL rows stop short of the scrollbar.
const double vScrollbarWidth = 16;

/// One row's paragraph style. The base direction follows the row's first
/// strong character so neutrals (punctuation, brackets, digits) resolve the
/// way an RTL reader expects — except in document RTL layout, where every
/// row is an RTL paragraph (`baseRtl: true`, like Word / Google Docs
/// "right-to-left": an English-led line then shows its English run at the
/// right end); the alignment is the ABSOLUTE left so the
/// glyphs start at x = 0 whatever the direction (right-alignment of RTL rows
/// is a shift applied by the painter, _LinePara.rtlShift — with `start`
/// alignment an RTL paragraph laid out at _layoutMaxW would sit 16M px away).
ui.ParagraphStyle _lineParagraphStyle(bool rtl, double zoom) =>
    ui.ParagraphStyle(
  fontSize: editorFontSizeAt(zoom),
  fontFamily: _monoFont,
  maxLines: 1,
  ellipsis: '',
  textDirection: rtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
  textAlign: ui.TextAlign.left,
);

/// Build one row and apply the syntax-highlight [spans] as colored runs (spans are UTF-16
/// indices within the row, sorted and non-overlapping). null/empty [spans] → all foreground
/// color. Measuring (caret/selection) with this Paragraph is also correct (glyph metrics do
/// not depend on color).
_LinePara _buildLineStyledAt(
  double zoom,
  String raw,
  double maxWidth,
  List<HlSpan>? spans, {
  int startColumn = 0,
  bool? baseRtl,
  int tabSize = 4,
}) {
  final ex = expandTabs(raw, tabSize, startColumn: startColumn);
  final text = ex.display;
  final map = ex.map;
  final rtl = baseRtl ?? isRtlText(text);
  final pb = ui.ParagraphBuilder(_lineParagraphStyle(rtl, zoom));
  void run(int a, int b, int style) {
    if (b <= a) return;
    final argb = AppSettings.instance.hlColor(
      style,
    ); // theme colors, user-editable
    pb.pushStyle(
      ui.TextStyle(
        color: argb != null ? Color(argb) : _fg,
        fontSize: editorFontSizeAt(zoom),
        fontFamily: _monoFont,
      ),
    );
    pb.addText(text.substring(a, b));
    pb.pop();
  }

  if (spans == null || spans.isEmpty) {
    run(0, text.length, Hl.none);
  } else {
    var pos = 0;
    for (final s in spans) {
      // Spans are in raw row indices; the paragraph holds the expanded text.
      final ra = s.start < 0
          ? 0
          : (s.start > raw.length ? raw.length : s.start);
      final rb = s.end < ra ? ra : (s.end > raw.length ? raw.length : s.end);
      final a = map[ra], b = map[rb];
      if (a > pos) run(pos, a, Hl.none);
      run(a, b, s.style);
      pos = b;
    }
    if (pos < text.length) run(pos, text.length, Hl.none);
  }
  return _LinePara(
    pb.build()..layout(ui.ParagraphConstraints(width: maxWidth)),
    ex.map,
    rtl: rtl,
  );
}
