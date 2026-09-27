import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../settings/app_settings.dart';
import '../settings/resizable_dialog.dart';
import '../settings/config_loader.dart';
import '../util/atomic_file.dart';
import '../util/log.dart';
import '../util/mac_files.dart';
import 'column_block.dart';
import 'document.dart';
import 'macro.dart';
import 'multi_cursor.dart';
import 'nav_history.dart';
import 'select_expand.dart';
import 'outline.dart';
import 'word_index.dart';
import 'editor_theme.dart';
import 'encoding/codecs.dart';
import 'encoding/detector.dart';
import 'bidi.dart';
import 'file_explorer.dart' show samePath;
import 'window_splice.dart';
import 'hex_cells.dart';
import 'hex_view.dart';
import 'hl_dirty.dart';
import 'line_ops.dart';
import 'large_file.dart' show IndexProgress;
import 'highlight.dart';
import 'bracket_match.dart';
import 'caret_column.dart';
import 'clipboard_history.dart';
import 'column_editor.dart';
import 'search.dart';
import 'script_transform.dart';
import 'text_stats.dart';
import 'soft_wrap.dart';
import 'tab_expand.dart';
import 'rust_highlight.dart';
import 'user_script.dart';
import 'wasm_grammar.dart';
import '../src/rust/api/script.dart' as rust_script;
import 'keybinding/chord_from_event.dart';
import 'keybinding/commands.dart';
import 'keybinding/key_chord.dart';
import 'keybinding/keymap.dart';
import 'keybinding/resolver.dart';
import 'keybinding/user_keymap.dart';

/// The editor's view mode: plain text / column (rectangular) / hex.
enum ViewMode { text, column, hex }

// Mouse drag granularity, fixed by the press that started the drag.
// `move` = the press landed inside the selection: dragging carries the
// selected text to the drop point (ctrl held at drop = copy).
enum _DragMode { char, word, line, move }

// Pointer kinds the editor's gesture recognizers accept: every kind except
// `trackpad`, which is the kind Flutter gives pan/zoom events (see the
// GestureDetector in build).
const Set<PointerDeviceKind> _pointerDragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

// ── Look & tunables ────────────────────────────────────────
// These read [AppSettings] (settings/settings.json, edited in the settings page) rather than being
// hard-coded, and are getters so a change applies live: every use site re-reads on the next
// build/paint, which _EditorViewState triggers by listening to the settings.
double get _fontSize => AppSettings.instance.zoomedFontSize;
double get _lineHeight => AppSettings.instance.zoomedLineHeight;
Color get _bg => Color(AppSettings.instance.bgArgb);
Color get _gutterBg => Color(AppSettings.instance.gutterBgArgb);
// Search / goto bars and the status bar are chrome, not gutter.
Color get _chromeBg => Color(AppSettings.instance.chromeBgArgb);
Color get _fg => Color(AppSettings.instance.fgArgb);
Color get _gutterFg => Color(AppSettings.instance.gutterFgArgb);
Color get _caretColor => Color(AppSettings.instance.caretArgb);
Color get _selColor => Color(AppSettings.instance.selectionArgb);
Color get _currentLineColor => Color(AppSettings.instance.currentLineArgb);

// Files at or below this size get their line index built on open (line numbers / total lines are
// then exact right away); bigger files (GB scale) stay manual so opening never triggers a full scan.
int get _autoIndexMaxBytes => AppSettings.instance.autoIndexMaxBytes;

// Files at or below this size highlight the WHOLE file at once (correct context — no mis-highlight
// from constructs that start above the visible window) and cache the per-line spans, so scrolling
// just slices the cache. Above it we keep window-parse (can't hold a GB file's syntax tree).
//
// The parse runs on a Rust worker thread (highlightAsync), so this bounds *latency until the colors
// settle*, not a UI freeze; while it runs, the visible window keeps its window-parse colors.
// Measured on a release build with a wasm grammar: ~1.3 s/MB to parse, plus ~25 ms/MB to map the
// spans and ~10 MB of span objects per MB of source — so 4 MB ≈ 5 s and ~40 MB. Whole-file
// highlighting is still non-incremental (every edit re-parses, debounced), which is the reason not
// to raise it much further. 0 = always window-parse.
int get _wholeFileHlMaxBytes => AppSettings.instance.wholeFileHlMaxBytes;

// How long after the last edit to re-parse the whole file.
// Diagnostic: log a UI-thread step that took suspiciously long (the app has
// been seen to freeze after a font change; the last such line before a
// freeze points at the step). Threshold well above a normal frame.
void _slow(String what, Stopwatch sw, {int thresholdMs = 200}) {
  if (sw.elapsedMilliseconds >= thresholdMs) {
    Log.instance.w('slow: $what took ${sw.elapsedMilliseconds} ms');
  }
}

Duration get _wholeFileHlDebounce =>
    Duration(milliseconds: AppSettings.instance.wholeFileHlDebounceMs);

/// Monospace family: the configured one, else the platform default.
String get _monoFont {
  final f = AppSettings.instance.fontFamily.trim();
  if (f.isNotEmpty) return f;
  return Platform.isWindows
      ? 'Consolas'
      : Platform.isMacOS
      ? 'Menlo'
      : 'monospace';
}

// ── Shared text/geometry helpers (used by both render and hit-test so coordinates agree) ──

const double _gutterPad = 10;
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

int get _tabSize => AppSettings.instance.tabSize;

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
    para.getPositionForOffset(Offset(dx, _lineHeight / 2)).offset,
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
int _rowStartColumn(DocWindow? win, WrapRow row) {
  if (row.isFirst || win == null || row.lineIndex >= win.lines.length) return 0;
  final line = win.lines[row.lineIndex];
  final cs = row.charStart > line.length ? line.length : row.charStart;
  return displayColumn(line.substring(0, cs), _tabSize);
}

/// Gutter (line-number column) width: estimated from the digit count of the largest visible
/// line number. Shared by render and hit-test.
double _gutterWidthFor(int anchorLine, int linesInWindow) {
  final maxNo = anchorLine >= 0 ? anchorLine + linesInWindow + 1 : 0;
  final digits = maxNo > 0 ? maxNo.toString().length : 7;
  return digits.clamp(4, 12) * (_fontSize * 0.62) + _gutterPad * 2;
}

/// Build one laid-out Paragraph for a row (single line, no wrapping, no ellipsis). Shared by
/// painting and measurement.
_LinePara _buildLine(
  String raw,
  double maxWidth, [
  Color? textColor,
  int startColumn = 0,
  bool? baseRtl,
]) {
  final ex = expandTabs(raw, _tabSize, startColumn: startColumn);
  final text = ex.display;
  final color = textColor ?? _fg;
  final rtl = baseRtl ?? isRtlText(text);
  final pb =
      ui.ParagraphBuilder(_lineParagraphStyle(rtl))..pushStyle(
        ui.TextStyle(color: color, fontSize: _fontSize, fontFamily: _monoFont),
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
ui.ParagraphStyle _lineParagraphStyle(bool rtl) => ui.ParagraphStyle(
  fontSize: _fontSize,
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
_LinePara _buildLineStyled(
  String raw,
  double maxWidth,
  List<HlSpan>? spans, {
  int startColumn = 0,
  bool? baseRtl,
}) {
  final ex = expandTabs(raw, _tabSize, startColumn: startColumn);
  final text = ex.display;
  final map = ex.map;
  final rtl = baseRtl ?? isRtlText(text);
  final pb = ui.ParagraphBuilder(_lineParagraphStyle(rtl));
  void run(int a, int b, int style) {
    if (b <= a) return;
    final argb = AppSettings.instance.hlColor(
      style,
    ); // theme colors, user-editable
    pb.pushStyle(
      ui.TextStyle(
        color: argb != null ? Color(argb) : _fg,
        fontSize: _fontSize,
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

// byte<->char within a row goes through WrapRow.charOfByte / byteOfChar,
// backed by the per-line maps the document's codec produced at decode time
// (exact for any encoding, including malformed bytes).

/// Self-painted text viewport (LeafRenderObjectWidget). Pure painting: draws the [window]
/// the widget supplies plus caret/selection, and does no IO inside paint (scrolling / loading /
/// caret movement are driven by the outer State).
class TextViewport extends LeafRenderObjectWidget {
  const TextViewport({
    super.key,
    required this.window,
    required this.rows,
    required this.rowSpans,
    required this.anchorLine,
    required this.anchorOffset,
    required this.totalBytes,
    required this.caretOffset,
    required this.caretAtRowEnd,
    required this.smartWord,
    required this.selStart,
    required this.selEnd,
    required this.block,
    required this.caretOn,
    this.caretFocused = true,
    required this.composing,
    required this.spans,
    required this.scrollX,
    required this.contentW,
    this.rtlMode = 1,
    required this.settingsEpoch,
    required this.bookmarks,
    required this.brackets,
    required this.extraCarets,
    required this.extraSels,
    required this.foldable,
    required this.folded,
    required this.dropCaret,
  });

  /// Drop indicator while the selection is being dragged (null = none).
  final int? dropCaret;

  /// Code folding: line-start offsets that have a fold region (gutter
  /// chevron) and those currently collapsed (`⋯` after the header line).
  /// Immutable snapshots, fresh on change.
  final Set<int> foldable;
  final Set<int> folded;

  final DocWindow? window;

  /// Visible "visual rows": soft wrap splits each logical line into several rows (with
  /// wrapping off, one line = one row).
  final List<WrapRow> rows;

  /// Syntax spans per visual row (aligned with [rows], already cut to row coordinates).
  final List<List<HlSpan>> rowSpans;
  final int anchorLine; // line number of the top line, -1 = unknown
  final int anchorOffset; // byte offset of the top line (for the scrollbar)
  final int totalBytes;
  final int caretOffset; // caret's document byte offset; -1 = not shown
  // Caret exactly on a wrap cut belongs to the row before it (End key).
  final bool caretAtRowEnd;

  // The selected whole word, whose other occurrences get backlit; null = none.
  final String? smartWord;
  final int selStart; // selection start (document offset); selStart==selEnd = no selection
  final int selEnd;

  /// Column mode's rectangular selection; non-null replaces the linear [selStart]..[selEnd] one.
  final ColumnBlock? block;
  final bool caretOn; // blink phase (caret drawn only when true)
  /// False while the editor lacks keyboard focus or the window is inactive:
  /// the caret is then drawn steady (no blink) and dimmed, so the position
  /// stays visible but the user can tell typing would not land here.
  final bool caretFocused;
  final String composing; // IME text being composed (drawn at the caret, underlined)
  final List<List<HlSpan>>? spans; // syntax spans per visible line (aligned with window.lines)
  final double scrollX; // horizontal scroll offset (px; text layer shifts left, gutter stays fixed)
  final double contentW; // max content width of the visible lines (for the horizontal scrollbar)

  /// How rows are horizontally aligned (see _EditorViewState._rtlMode):
  /// 0 = every row at the left origin (column mode), 1 = per-row (an RTL row
  /// narrower than the text area is right-aligned inside it), 2 = document
  /// RTL layout (EVERY row right-aligned to the common right edge
  /// max(text area, contentW), so line starts line up and the horizontal
  /// scroll origin is effectively on the right).
  final int rtlMode;
  final int settingsEpoch; // bumped when AppSettings changes → forces a repaint

  /// Bookmarked line-start byte offsets (gutter dots). An IMMUTABLE snapshot:
  /// the view hands over a fresh set on every change so the identical-check
  /// in the setter can detect it.
  final Set<int> bookmarks;

  /// Matched bracket pair to highlight (0 or 2 byte offsets; fresh list on
  /// every change, same identical-check contract as [bookmarks]).
  final List<int> brackets;

  /// Multi-cursor: the extra carets' byte offsets (sorted) and their
  /// selections as flat [start, end, …] pairs. Fresh lists on change.
  final List<int> extraCarets;
  final List<int> extraSels;

  @override
  RenderTextViewport createRenderObject(BuildContext context) =>
      RenderTextViewport(
        window: window,
        rows: rows,
        rowSpans: rowSpans,
        anchorLine: anchorLine,
        anchorOffset: anchorOffset,
        totalBytes: totalBytes,
        caretOffset: caretOffset,
        caretAtRowEnd: caretAtRowEnd,
        smartWord: smartWord,
        selStart: selStart,
        selEnd: selEnd,
        block: block,
        caretOn: caretOn,
        caretFocused: caretFocused,
        composing: composing,
        spans: spans,
        scrollX: scrollX,
        contentW: contentW,
        rtlMode: rtlMode,
        settingsEpoch: settingsEpoch,
        bookmarks: bookmarks,
        brackets: brackets,
        extraCarets: extraCarets,
        extraSels: extraSels,
        foldable: foldable,
        folded: folded,
        dropCaret: dropCaret,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderTextViewport renderObject,
  ) {
    renderObject
      ..window = window
      ..rows = rows
      ..rowSpans = rowSpans
      ..anchorLine = anchorLine
      ..anchorOffset = anchorOffset
      ..totalBytes = totalBytes
      ..caretOffset = caretOffset
      ..caretAtRowEnd = caretAtRowEnd
      ..smartWord = smartWord
      ..selStart = selStart
      ..selEnd = selEnd
      ..block = block
      ..caretOn = caretOn
      ..caretFocused = caretFocused
      ..composing = composing
      ..spans = spans
      ..scrollX = scrollX
      ..contentW = contentW
      ..rtlMode = rtlMode
      ..settingsEpoch = settingsEpoch
      ..bookmarks = bookmarks
      ..brackets = brackets
      ..extraCarets = extraCarets
      ..extraSels = extraSels
      ..foldable = foldable
      ..folded = folded
      ..dropCaret = dropCaret;
  }
}

/// Custom RenderBox that paints only the visible lines: line numbers + text + selection
/// highlight + caret + byte-proportional scrollbar.
class RenderTextViewport extends RenderBox {
  RenderTextViewport({
    required this._window,
    required this._rows,
    required this._rowSpans,
    required this._anchorLine,
    required this._anchorOffset,
    required this._totalBytes,
    required this._caretOffset,
    required this._caretAtRowEnd,
    required this._smartWord,
    required this._selStart,
    required this._selEnd,
    required this._block,
    required this._caretOn,
    required this._caretFocused,
    required this._composing,
    required this._spans,
    required this._scrollX,
    required this._contentW,
    required this._rtlMode,
    required this._settingsEpoch,
    required this._bookmarks,
    required this._brackets,
    required this._extraCarets,
    required this._extraSels,
    required this._foldable,
    required this._folded,
    required this._dropCaret,
  });

  int? _dropCaret;
  set dropCaret(int? v) {
    if (v == _dropCaret) return;
    _dropCaret = v;
    markNeedsPaint();
  }

  // Column mode, a caret column past the end of [line]: the x distance from
  // the character at byte [within] to the block's [caretCol], counted in
  // cells of the (monospace) font — 0 when the column is inside the line.
  double _virtualColumnGap(String line, int within, WrapRow row, int caretCol) {
    final ci = row.charOfByte(within);
    final have = columnForCharIndex(line, ci, tabSize: _tabSize);
    final gap = caretCol - have;
    return gap > 0 ? gap * editorCharWidth : 0;
  }

  Set<int> _foldable;
  set foldable(Set<int> v) {
    if (identical(v, _foldable)) return;
    _foldable = v;
    markNeedsPaint();
  }

  Set<int> _folded;
  set folded(Set<int> v) {
    if (identical(v, _folded)) return;
    _folded = v;
    markNeedsPaint();
  }

  List<int> _extraCarets;
  set extraCarets(List<int> v) {
    if (identical(v, _extraCarets)) return;
    _extraCarets = v;
    markNeedsPaint();
  }

  List<int> _extraSels;
  set extraSels(List<int> v) {
    if (identical(v, _extraSels)) return;
    _extraSels = v;
    markNeedsPaint();
  }

  Set<int> _bookmarks;
  set bookmarks(Set<int> v) {
    if (identical(v, _bookmarks)) return;
    _bookmarks = v;
    markNeedsPaint();
  }

  List<int> _brackets;
  set brackets(List<int> v) {
    if (identical(v, _brackets)) return;
    _brackets = v;
    markNeedsPaint();
  }

  DocWindow? _window;
  set window(DocWindow? v) {
    if (identical(v, _window)) return;
    _window = v;
    markNeedsPaint();
  }

  List<WrapRow> _rows;
  set rows(List<WrapRow> v) {
    if (identical(v, _rows)) return;
    _rows = v;
    markNeedsPaint();
  }

  List<List<HlSpan>> _rowSpans;
  set rowSpans(List<List<HlSpan>> v) {
    if (identical(v, _rowSpans)) return;
    _rowSpans = v;
    markNeedsPaint();
  }

  int _anchorLine;
  set anchorLine(int v) {
    if (v == _anchorLine) return;
    _anchorLine = v;
    markNeedsPaint();
  }

  int _anchorOffset;
  set anchorOffset(int v) {
    if (v == _anchorOffset) return;
    _anchorOffset = v;
    markNeedsPaint();
  }

  int _totalBytes;
  set totalBytes(int v) {
    if (v == _totalBytes) return;
    _totalBytes = v;
    markNeedsPaint();
  }

  int _caretOffset;
  set caretOffset(int v) {
    if (v == _caretOffset) return;
    _caretOffset = v;
    markNeedsPaint();
  }

  bool _caretAtRowEnd;
  set caretAtRowEnd(bool v) {
    if (v == _caretAtRowEnd) return;
    _caretAtRowEnd = v;
    markNeedsPaint();
  }

  String? _smartWord;
  set smartWord(String? v) {
    if (v == _smartWord) return;
    _smartWord = v;
    markNeedsPaint();
  }

  int _selStart;
  set selStart(int v) {
    if (v == _selStart) return;
    _selStart = v;
    markNeedsPaint();
  }

  int _selEnd;
  set selEnd(int v) {
    if (v == _selEnd) return;
    _selEnd = v;
    markNeedsPaint();
  }

  ColumnBlock? _block;
  set block(ColumnBlock? v) {
    if (v == _block) return;
    _block = v;
    markNeedsPaint();
  }

  bool _caretOn;
  set caretOn(bool v) {
    if (v == _caretOn) return;
    _caretOn = v;
    markNeedsPaint();
  }

  bool _caretFocused;
  set caretFocused(bool v) {
    if (v == _caretFocused) return;
    _caretFocused = v;
    markNeedsPaint();
  }

  // Caret paint: full color while focused, dimmed (steady) otherwise.
  Color get _caretPaintColor =>
      _caretFocused ? _caretColor : _caretColor.withValues(alpha: 0.45);

  String _composing;
  set composing(String v) {
    if (v == _composing) return;
    _composing = v;
    markNeedsPaint();
  }

  List<List<HlSpan>>? _spans;
  set spans(List<List<HlSpan>>? v) {
    if (identical(v, _spans)) return;
    _spans = v;
    markNeedsPaint();
  }

  double _scrollX;
  set scrollX(double v) {
    if (v == _scrollX) return;
    _scrollX = v;
    markNeedsPaint();
  }

  double _contentW;
  set contentW(double v) {
    if (v == _contentW) return;
    _contentW = v;
    markNeedsPaint();
  }

  int _rtlMode;
  set rtlMode(int v) {
    if (v == _rtlMode) return;
    _rtlMode = v;
    markNeedsPaint();
  }

  /// Horizontal shift of a row's text origin inside a text area [areaW]
  /// wide — the painter's twin of _EditorViewState._rowShift; both must
  /// agree or clicks miss the drawn glyphs.
  double _rowShiftOf(_LinePara para, double areaW) => switch (_rtlMode) {
    0 => 0,
    2 => rtlLayoutShift(para.width, areaW, _contentW),
    _ => para.rtlShift(areaW),
  };

  // Not painted directly: font/colors/metrics are read from AppSettings at paint time, so this is
  // what tells the render object that those changed.
  int _settingsEpoch;
  set settingsEpoch(int v) {
    if (v == _settingsEpoch) return;
    _settingsEpoch = v;
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  double get _gutterWidth =>
      _gutterWidthFor(_anchorLine, _window?.lines.length ?? 0);

  @override
  void paint(PaintingContext context, Offset offset) {
    // Diagnostic timer around the whole paint (paragraph building happens
    // here, so a font that is slow to resolve shows up as a slow paint).
    final sw = Stopwatch()..start();
    try {
      _paintBody(context, offset);
    } finally {
      _slow('paint text viewport (${_rows.length} rows)', sw);
    }
  }

  void _paintBody(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(offset & size);
    canvas.drawRect(offset & size, Paint()..color = _bg);

    final gw = _gutterWidth;
    canvas.drawRect(
      Rect.fromLTWH(offset.dx, offset.dy, gw, size.height),
      Paint()..color = _gutterBg,
    );

    final win = _window;
    if (win != null) {
      final textX = offset.dx + gw + _gutterPad;
      // Text area width: an RTL row narrower than this is drawn right-aligned
      // (rowX below); in document RTL layout every row is. Column mode
      // (rtlMode 0) keeps every row at the left origin — its rectangle math
      // assumes x grows with the character index.
      // Must equal the state's _textViewW: same subtraction.
      final areaW = _rtlMode == 0
          ? 0.0
          : size.width - gw - _gutterPad - _scrollbarMargin;
      final blk = _block;
      final hasSel = blk == null && _selEnd > _selStart;
      final maxRows = (size.height / _lineHeight).ceil() + 1;
      final rows = _rows.length < maxRows ? _rows.length : maxRows;

      // Text layer (selection / text / caret): horizontal scrolling is done by clipping to
      // the text area and translating the canvas left. The gutter and scrollbars are not in
      // this layer and stay fixed.
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(offset.dx + gw, offset.dy, size.width - gw, size.height),
      );
      canvas.translate(-_scrollX, 0);
      // Current-line highlight: the caret's visual row only. First matching
      // row wins — at a wrap boundary the caret offset satisfies both the end
      // of one row and the start of the next.
      var currentLinePainted = false;
      var lineStart = -1; // start offset of the logical line being painted
      for (var i = 0; i < rows; i++) {
        final y = offset.dy + i * _lineHeight;
        final row = _rows[i];
        final line = row.text;
        final rowStart = row.offset;
        if (row.isFirst) lineStart = rowStart;
        // The next row's start is this row's end (the last row uses the window's end).
        final rowEnd = i + 1 < _rows.length
            ? _rows[i + 1].offset
            : win.nextOffset;
        final contentBytes = row.contentBytes;
        final rowSpans = i < _rowSpans.length ? _rowSpans[i] : null;
        final para = _buildLineStyled(
          line,
          _layoutMaxW,
          rowSpans,
          startColumn: _rowStartColumn(win, row),
          baseRtl: _rtlMode == 2 ? true : null,
        );
        // This row's text origin: textX, plus the right-alignment shift of
        // an RTL row (or of every row in document RTL layout). Everything
        // drawn from the paragraph's x uses rowX.
        final rowX = textX + _rowShiftOf(para, areaW);

        // Current-line backdrop (beneath selection and text): full visible
        // width — the canvas is shifted by -_scrollX, so shift back.
        // A caret exactly on a wrap cut belongs to the row the cut starts
        // (matching _rowIndexOf), so a non-last row owns only cw < content —
        // unless End parked it there (_caretAtRowEnd), when the row before
        // the cut owns it and the row starting at the cut must not.
        final cwHl = _caretOffset - rowStart;
        final ownedByPrev = _caretAtRowEnd && cwHl == 0 && !row.isFirst;
        final caretOnRow =
            _caretOffset >= 0 &&
            cwHl >= 0 &&
            !ownedByPrev &&
            (row.isLast
                ? cwHl <= contentBytes
                : cwHl < contentBytes ||
                      (_caretAtRowEnd && cwHl == contentBytes));
        if (!currentLinePainted && caretOnRow) {
          currentLinePainted = true;
          canvas.drawRect(
            Rect.fromLTWH(
              offset.dx + gw + _scrollX,
              y,
              size.width - gw,
              _lineHeight,
            ),
            Paint()..color = _currentLineColor,
          );
        }

        // Selection highlight (drawn beneath the text)
        void paintSel(int selStart, int selEnd) {
          if (selEnd <= rowStart || selStart >= rowEnd) return;
          final sB = (selStart - rowStart).clamp(0, contentBytes);
          // If the selection crosses the line's newline, the highlight extends to the end of
          // the content (plus a small block showing the newline is selected).
          final selPastEol = row.isLast && selEnd > rowStart + contentBytes;
          final eB = selPastEol
              ? contentBytes
              : (selEnd - rowStart).clamp(0, contentBytes);
          final sc = row.charOfByte(sB);
          final ec = row.charOfByte(eB);
          final paint = Paint()..color = _selColor;
          if (ec > sc) {
            for (final b in para.boxes(sc, ec)) {
              canvas.drawRect(
                Rect.fromLTWH(rowX +b.left, y, b.right - b.left, _lineHeight),
                paint,
              );
            }
          }
          if (selPastEol) {
            // Newline selected: add a small block at the end of the line
            final endX = rowX +para.xOf(row.charOfByte(contentBytes));
            canvas.drawRect(
              Rect.fromLTWH(endX, y, _fontSize * 0.4, _lineHeight),
              paint,
            );
          }
        }

        if (hasSel) paintSel(_selStart, _selEnd);
        // Multi-cursor: the extra cursors' selections, same look.
        for (var k = 0; k + 1 < _extraSels.length; k += 2) {
          paintSel(_extraSels[k], _extraSels[k + 1]);
        }

        // Rectangular (column) selection highlight: each row takes its own slice; a short
        // line is highlighted only up to its end. Column mode never wraps, so row.offset is
        // the start of the logical line.
        if (blk != null) {
          final slice = sliceLine(blk, rowStart, line, map: row.map, tabSize: _tabSize);
          if (slice != null && !slice.isEmpty) {
            final paint = Paint()..color = _selColor;
            for (final box in para.boxes(slice.startChar, slice.endChar)) {
              canvas.drawRect(
                Rect.fromLTWH(
                  rowX +box.left,
                  y,
                  box.right - box.left,
                  _lineHeight,
                ),
                paint,
              );
            }
          }
        }

        // Matching-bracket highlight (beneath the text: fill + thin outline)
        for (final b in _brackets) {
          final rel = b - rowStart;
          if (rel >= 0 && rel < contentBytes) {
            final sc = row.charOfByte(rel);
            for (final box in para.boxes(sc, sc + 1)) {
              final r = Rect.fromLTWH(
                rowX +box.left,
                y,
                box.right - box.left,
                _lineHeight,
              );
              canvas.drawRect(r, Paint()..color = _selColor);
              canvas.drawRect(
                r.deflate(0.5),
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1
                  ..color = _fg,
              );
            }
          }
        }

        // Same-word highlight: the other whole-word occurrences of the
        // selected word (the selection itself already has its own color).
        final sw = _smartWord;
        if (sw != null && sw.isNotEmpty) {
          final paint = Paint()..color = _selColor.withValues(alpha: 0.45);
          var from = 0;
          while (true) {
            final idx = line.indexOf(sw, from);
            if (idx < 0) break;
            final end = idx + sw.length;
            from = end;
            final whole =
                (idx == 0 || !_isWordCharAt(line, idx - 1)) &&
                (end >= line.length || !_isWordCharAt(line, end));
            if (!whole) continue;
            if (rowStart + row.byteOfChar(idx) == _selStart) continue;
            for (final b in para.boxes(idx, end)) {
              canvas.drawRect(
                Rect.fromLTWH(rowX +b.left, y, b.right - b.left, _lineHeight),
                paint,
              );
            }
          }
        }

        // Indent guides: a faint line at each indent level inside the line's
        // leading whitespace (View → Indent guides).
        if (AppSettings.instance.indentGuides && row.isFirst) {
          var i = 0;
          while (i < line.length &&
              (line.codeUnitAt(i) == 0x20 || line.codeUnitAt(i) == 0x09)) {
            i++;
          }
          if (i > 0) {
            final cols = displayColumn(line.substring(0, i), _tabSize);
            final cw = editorCharWidth;
            final paint = Paint()
              ..color = _fg.withValues(alpha: 0.2)
              ..strokeWidth = 1;
            for (var c = 0; c < cols; c += _tabSize) {
              final x = rowX +c * cw + 0.5;
              canvas.drawLine(Offset(x, y), Offset(x, y + _lineHeight), paint);
            }
          }
        }

        // Whitespace marks, three independent toggles (View → Show spaces /
        // tabs / line endings): · for a space, → across a tab, ¶ after a
        // line's content. Only the visible stretch of a row.
        final ws = AppSettings.instance;
        if (ws.showWhitespace) {
          final wsColor = Color(ws.whitespaceArgb);
          final paint = Paint()
            ..color = wsColor
            ..strokeWidth = 1;
          if (ws.showSpaces || ws.showTabs) {
            // Visible stretch in paragraph x (the row may be shifted right;
            // an RTL paragraph maps x to indices in reverse, so order them).
            final sx0 = _scrollX - (rowX - textX);
            final ca = para.charAt(sx0), cb = para.charAt(sx0 + size.width);
            var c0 = (ca < cb ? ca : cb) - 1;
            if (c0 < 0) c0 = 0;
            var c1 = (ca < cb ? cb : ca) + 1;
            if (c1 > line.length) c1 = line.length;
            final cy = y + _lineHeight / 2;
            for (var ci = c0; ci < c1; ci++) {
              final u = line.codeUnitAt(ci);
              final space = u == 0x20 && ws.showSpaces;
              final tab = u == 0x09 && ws.showTabs;
              if (!space && !tab) continue;
              final bx = para.boxes(ci, ci + 1);
              if (bx.isEmpty) continue;
              final l = rowX +bx.first.left, r = rowX +bx.last.right;
              if (space) {
                canvas.drawCircle(Offset((l + r) / 2, cy), 1.2, paint);
              } else if (r - l > 6) {
                final x1 = l + 2, x2 = r - 2;
                canvas.drawLine(Offset(x1, cy), Offset(x2, cy), paint);
                canvas.drawLine(Offset(x2 - 3, cy - 3), Offset(x2, cy), paint);
                canvas.drawLine(Offset(x2 - 3, cy + 3), Offset(x2, cy), paint);
              }
            }
          }
          if (ws.showNewlines &&
              row.isLast &&
              rowEnd > rowStart + contentBytes) {
            final eol = _buildLine('¶', _layoutMaxW, wsColor);
            canvas.drawParagraph(
              eol.para,
              Offset(
                rowX +para.xOf(line.length),
                y + (_lineHeight - eol.height) / 2,
              ),
            );
          }
        }

        // Text
        canvas.drawParagraph(
          para.para,
          Offset(rowX, y + (_lineHeight - para.height) / 2),
        );
        // Collapsed fold: a `⋯` badge after the header's text.
        if (row.isLast && lineStart >= 0 && _folded.contains(lineStart)) {
          // Past the ¶ end-of-line mark when line-end marks are shown.
          final eolGap = AppSettings.instance.showNewlines
              ? editorCharWidth * 1.5
              : 0.0;
          final bx = rowX +para.xOf(line.length) + 6 + eolGap;
          final badge = _buildLine(' ⋯ ', _layoutMaxW, _fg);
          final r = Rect.fromLTWH(bx, y + 2, badge.width + 2, _lineHeight - 4);
          canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(3)),
            Paint()..color = _fg.withValues(alpha: 0.15),
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(3)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = _fg.withValues(alpha: 0.4),
          );
          canvas.drawParagraph(
            badge.para,
            Offset(bx + 1, y + (_lineHeight - badge.height) / 2),
          );
        }

        // Caret (+ IME composition overlay)
        final cw = _caretOffset - rowStart;
        if (caretOnRow) {
          var cx = rowX +para.xOf(row.charOfByte(cw));
          // Column mode: the block's caret column may lie past this line's
          // end (the caret offset itself cannot). Draw it out in virtual
          // space, one cell per missing column, instead of at the line end.
          if (blk != null && rowStart == blk.caretLine) {
            cx += _virtualColumnGap(line, cw, row, blk.caretCol);
          }
          if (_composing.isNotEmpty) {
            // Text being composed is drawn at the caret, underlined (not yet in the document)
            final cp = _buildLine(_composing, _layoutMaxW, _fg);
            canvas.drawParagraph(
              cp.para,
              Offset(cx, y + (_lineHeight - cp.height) / 2),
            );
            final cwid = cp.width;
            canvas.drawRect(
              Rect.fromLTWH(cx, y + _lineHeight - 2, cwid, 1),
              Paint()..color = _fg,
            );
            cx += cwid;
          }
          if (_caretOn) {
            canvas.drawRect(
              Rect.fromLTWH(cx, y + 1, 2, _lineHeight - 2),
              Paint()..color = _caretPaintColor,
            );
          }
        }
        // Drop indicator (selection being dragged): a steady, slightly
        // wider caret at the pointer — no blink, so it never vanishes
        // while the user is aiming.
        final drop = _dropCaret;
        if (drop != null) {
          final rel = drop - rowStart;
          final onRow =
              rel >= 0 &&
              (row.isLast ? rel <= contentBytes : rel < contentBytes);
          if (onRow) {
            final dx = rowX +para.xOf(row.charOfByte(rel));
            canvas.drawRect(
              Rect.fromLTWH(dx - 1, y + 1, 3, _lineHeight - 2),
              Paint()..color = _caretColor.withValues(alpha: 0.7),
            );
          }
        }
        // Multi-cursor: the extra carets on this row (sorted list → the
        // slice that falls inside the row; no wrap-cut affinity for them).
        if (_caretOn && _extraCarets.isNotEmpty) {
          final lo = rowStart, hi = rowStart + contentBytes;
          var k = _lowerBound(_extraCarets, lo);
          for (; k < _extraCarets.length; k++) {
            final rel = _extraCarets[k] - rowStart;
            if (row.isLast ? rel > contentBytes : rel >= contentBytes) break;
            if (_extraCarets[k] > hi) break;
            final cx = rowX +para.xOf(row.charOfByte(rel));
            canvas.drawRect(
              Rect.fromLTWH(cx, y + 1, 2, _lineHeight - 2),
              Paint()..color = _caretPaintColor,
            );
          }
        }
        // Column mode: one caret per line of the block at the caret-side
        // column, like multi-cursor — a zero-width block after typing then
        // looks like the N cursors it acts as. The caret line itself already
        // has the primary caret. On a line shorter than the caret column the
        // caret sits in virtual space past the end (one cell per column).
        if (_caretOn &&
            blk != null &&
            row.isFirst &&
            rowStart != blk.caretLine &&
            rowStart >= blk.topLine &&
            rowStart <= blk.bottomLine) {
          final ci = charIndexForColumn(line, blk.caretCol, tabSize: _tabSize);
          final cx =
              textX +
              para.xOf(ci) +
              _virtualColumnGap(line, row.byteOfChar(ci), row, blk.caretCol);
          canvas.drawRect(
            Rect.fromLTWH(cx, y + 1, 2, _lineHeight - 2),
            Paint()..color = _caretPaintColor,
          );
        }
      }
      canvas.restore(); // end of the text layer's clip/translate

      // Line numbers (fixed column, not horizontally scrolled)
      for (var i = 0; i < rows; i++) {
        final row = _rows[i];
        // Folded windows are not contiguous: the window carries each line's
        // absolute number (lineNumberAt) — never assume anchor + index.
        final lineNo = row.isFirst
            ? (win.lineNumbers != null
                  ? win.lineNumberAt(row.lineIndex)
                  : (_anchorLine >= 0 ? _anchorLine + row.lineIndex : -1))
            : -1;
        _paintRight(
          canvas,
          // Continuation rows of a wrapped line get no number (a · placeholder), so the
          // numbers line up with the real lines.
          lineNo >= 0 ? '${lineNo + 1}' : '·',
          offset.dx + _gutterPad,
          offset.dy + i * _lineHeight,
          gw - _gutterPad * 2 - (_foldable.isEmpty ? 0 : 10),
        );
        // Fold chevron at the gutter's right edge: ▾ open, ▸ collapsed.
        if (row.isFirst && _foldable.contains(row.offset)) {
          final cx = offset.dx + gw - 8;
          final cy = offset.dy + (i + 0.5) * _lineHeight;
          final p = Path();
          if (_folded.contains(row.offset)) {
            p
              ..moveTo(cx - 2, cy - 4)
              ..lineTo(cx + 3, cy)
              ..lineTo(cx - 2, cy + 4);
          } else {
            p
              ..moveTo(cx - 4, cy - 2)
              ..lineTo(cx, cy + 3)
              ..lineTo(cx + 4, cy - 2);
          }
          p.close();
          canvas.drawPath(p, Paint()..color = _gutterFg);
        }
        // Bookmark dot at the gutter's left edge (line-start rows only).
        if (row.isFirst && _bookmarks.contains(row.offset)) {
          canvas.drawCircle(
            Offset(offset.dx + 5, offset.dy + (i + 0.5) * _lineHeight),
            3,
            Paint()..color = _selColor.withValues(alpha: 1),
          );
        }
      }
    }

    _paintScrollbar(canvas, offset);
    _paintHScrollbar(canvas, offset);
    canvas.restore();
  }

  // Paint right-aligned line-number text.
  void _paintRight(
    Canvas canvas,
    String text,
    double x,
    double y,
    double maxWidth,
  ) {
    final p = _buildLine(text, maxWidth.clamp(0.0, 1048576.0), _gutterFg);
    // Right-align: shift by maxWidth - text width
    final tw = p.width;
    canvas.drawParagraph(
      p.para,
      Offset(
        x + (maxWidth - tw).clamp(0.0, maxWidth),
        y + (_lineHeight - p.height) / 2,
      ),
    );
  }

  // Byte-proportional scrollbar (needs no total line count)
  void _paintScrollbar(Canvas canvas, Offset offset) {
    if (_totalBytes <= 0) return;
    const w = 8.0;
    final trackH = size.height;
    if (trackH <= 24.0) return; // viewport smaller than the min thumb

    // Estimate the thumb height from the byte fraction the window roughly covers (min 24px)
    final approxView = (size.height / _lineHeight) * 80; // approximate bytes in the window
    final thumbH = (approxView / _totalBytes * trackH).clamp(24.0, trackH);
    final t = (_anchorOffset / _totalBytes).clamp(0.0, 1.0).toDouble();
    final thumbY = offset.dy + t * (trackH - thumbH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(offset.dx + size.width - w - 2, thumbY, w, thumbH),
        const Radius.circular(4),
      ),
      Paint()..color = _thumb,
    );
  }

  // Bottom horizontal scrollbar (drawn only when the widest visible line exceeds the text area)
  void _paintHScrollbar(Canvas canvas, Offset offset) {
    final gw = _gutterWidth;
    final viewW = size.width - gw - _gutterPad - _scrollbarMargin;
    if (_contentW <= viewW || viewW <= 0) return;
    const h = 8.0;
    final trackX = offset.dx + gw;
    final trackW = size.width - gw - _scrollbarMargin;
    if (trackW <= 24.0) return; // viewport narrower than the min thumb
    final thumbW = (viewW / _contentW * trackW).clamp(24.0, trackW);
    final t = (_scrollX / (_contentW - viewW)).clamp(0.0, 1.0);
    final x = trackX + t * (trackW - thumbW);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, offset.dy + size.height - h - 2, thumbW, h),
        const Radius.circular(4),
      ),
      Paint()..color = _thumb,
    );
  }
}

/// Connects an [EditorView] to the outer shell: the shell drives the current editor through
/// it and listens to its state to update the AppBar.
///
/// With multiple panes (docking) the shell only commands and listens to "the currently
/// active controller" — the menubar / AppBar need not know the editor's internals.
/// One bookmark as the bookmark panel lists it.
class BookmarkInfo {
  const BookmarkInfo(this.offset, this.line, this.exact, this.preview);
  final int offset; // line-start byte offset
  final int line; // 0-based
  final bool exact; // false = estimated (beyond the indexed prefix)
  final String preview;
}

class EditorController extends ChangeNotifier {
  _EditorViewState? _view;

  /// Called when the EditorView gains focus — the shell sets it to "make this pane active".
  VoidCallback? onActivated;

  /// ctrl+n: open a new untitled tab (the layout belongs to the shell).
  VoidCallback? onNewTab;

  /// ctrl+shift+n: open a new window (the shell spawns a --new-window child process).
  VoidCallback? onNewWindow;

  /// ctrl+shift+w: close the window (the shell runs onWindowClose's unsaved-changes flow).
  VoidCallback? onCloseWindow;

  /// ctrl+o: pick a file and open it in a new tab (already open → jump to its tab; shell
  /// handles it).
  VoidCallback? onOpenFile;

  /// ctrl+w: the pane does not own the layout, so the close request is handed to the shell
  /// (including the unsaved-changes confirmation).
  VoidCallback? onCloseRequest;

  /// ctrl+tab / ctrl+shift+tab: cycle tabs, dir=+1 next, -1 previous.
  void Function(int dir)? onTabCycle;

  /// alt+1..9: jump to the n-th tab (1-based, layout order).
  void Function(int n)? onTabSelectN;

  /// ctrl+shift+t: reopen the most recently closed tab (the shell keeps the closed stack).
  VoidCallback? onReopenClosed;

  /// ctrl+shift+p: command palette (the shell owns the menu tree and action dispatch).
  VoidCallback? onCommandPalette;

  /// ctrl+shift+f: find in files (the shell owns the bottom results panel).
  VoidCallback? onFindInFiles;

  /// ctrl+shift+r / ctrl+shift+e: toggle macro recording / play (the shell owns the recorder
  /// and the list).
  VoidCallback? onMacroRecord;
  VoidCallback? onMacroPlay;

  /// ctrl+b: toggle the file explorer sidebar (shell-owned).
  VoidCallback? onToggleExplorer;

  /// ctrl+shift+o: toggle the document outline sidebar (shell-owned).
  VoidCallback? onToggleOutline;

  /// ctrl+k ctrl+s: open the keymap editor (shell-owned).
  VoidCallback? onKeymapEditor;

  /// `macro.run {name}` shortcut: play a saved macro (the shell owns the list).
  void Function(String name)? onRunMacro;

  /// Split-view synchronized scrolling: the user scrolled this pane by [rows] rows /
  /// horizontally to [x] (the shell forwards it to the other visible panes). Forwarded
  /// scrolls do not trigger these two callbacks again.
  void Function(int rows)? onScrollRows;
  void Function(double x)? onScrollX;

  /// Apply a scroll coming from another pane (not re-broadcast).
  void syncScrollRows(int rows) => _view?._applySyncRows(rows);
  void syncScrollX(double x) => _view?._applySyncX(x);

  /// Replay [m] on this pane: [times] runs, or until the end of the file
  /// (stops once a run no longer moves the caret or changes the document).
  /// The whole playback is one undo step; Esc / the busy dialog cancel it.
  void playMacro(Macro m, {int times = 1, bool untilEof = false}) =>
      _view?._playMacro(m, times: times, untilEof: untilEof);

  // Selection queued for a pane whose document is still loading (a
  // find-in-files result opening a new tab); consumed at load end.
  (int, int)? _pendingSelect;

  /// Select [start,end) and scroll it into view — immediately when the
  /// document is ready, otherwise once it finishes loading.
  void selectRange(int start, int end) {
    final v = _view;
    if (v != null && v._doc != null && !v._opening) {
      v._selectRange(start, end);
    } else {
      _pendingSelect = (start, end);
    }
  }

  /// Replace-in-files for a pane that is already open: every match of [re]
  /// in the buffer is replaced as one undo step and the pane stays modified
  /// (nothing is written to disk). Returns the count, or null when the pane
  /// cannot take it right now (hex mode, loading, busy) — the caller then
  /// falls back to rewriting the file on disk.
  Future<int?> replaceAllMatches(
    RegExp re,
    String template, {
    required bool regex,
  }) {
    final v = _view;
    if (v == null) return Future.value(null);
    return v._replaceAllMatches(re, template, regex: regex);
  }

  // Line jump queued for a pane still loading (diff row double-click).
  int? _pendingLine;

  /// Go to a 1-based line — now, or once the document has loaded.
  void gotoLine(int oneBased) {
    final v = _view;
    if (v != null && v._doc != null && !v._opening) {
      v.gotoLine(oneBased);
    } else {
      _pendingLine = oneBased;
    }
  }

  void _attach(_EditorViewState v) => _view = v;
  void _detach(_EditorViewState v) {
    if (identical(_view, v)) _view = null;
  }

  // Called by EditorView at the points where the AppBar/menubar display would change, to
  // tell the shell to rebuild.
  void _bump() => notifyListeners();

  bool get hasView => _view != null;

  // ── Exposed state (safe defaults while not yet attached) ──
  String? get name => _view?._name;
  bool get modified => _view?._modified ?? false;
  bool get saving => _view?._saving ?? false;

  /// Read-only mode (File → Read-only mode; turned on automatically for unwritable files).
  bool get readOnly => _view?._readOnly ?? false;
  void toggleReadOnly() => _view?._toggleReadOnly();

  /// Tail the file (View → Tail file): poll every second, reload and jump to the end on
  /// change.
  bool get tail => _view?._tail ?? false;
  void toggleTail() => _view?._toggleTail();

  /// Document RTL layout (View → Right-to-left layout): rows right-aligned to a common
  /// right edge, horizontal scrolling from the right. Auto-detected on load.
  bool get rtlLayout => _view?._rtlLayout ?? false;
  void toggleRtlLayout() => _view?._toggleRtlLayout();

  /// Soft wrap of this pane: the effective mode ('off'/'columns'/'window'),
  /// the per-tab override (null = follows the global default), and setters.
  String get wrapMode => _view?.wrapSetting ?? AppSettings.instance.softWrapMode;
  String? get wrapOverride => _view?._wrapOverride;
  void setWrapMode(String mode) => _view?._setWrapOverride(mode);
  void toggleWrap() => _view?._toggleWrap();

  /// Horizontal scroll position / range in px (inspection and tests).
  double get scrollX => _view?._scrollX ?? 0;
  double get maxScrollX => _view?._maxScrollX ?? 0;
  bool get opening => _view?._opening ?? false;
  bool get hasDoc => _view?._doc != null;
  bool get indexDone => _view?._doc?.indexDone ?? false;
  bool get indexing => _view?._indexing ?? false;
  double get fractionIndexed => _view?._doc?.fractionIndexed ?? 0;
  String get keymapName => _view?._keymapName ?? 'default';

  /// The current syntax mode: 'auto' / 'plain' / a WASM language name.
  String get syntaxMode => _view?._forcedSyntax ?? 'auto';

  /// The highlighter actually in effect (the Syntax menu shows it next to
  /// "Auto"): a tree-sitter/WASM language name, the pure-Dart lexer's label,
  /// or null when nothing highlights (plain text).
  String? get effectiveSyntax {
    final h = _view?._hl;
    if (h is RustHighlighter) return h.lang;
    if (h is SimpleHighlighter) return h.label.isEmpty ? null : h.label;
    return null;
  }

  // ── Exposed operations (forwarded to the current EditorView; no-op without a view) ──
  void open() => _view?._open();
  // Awaitable so the shell can save-then-close (unsaved-changes prompts).
  Future<void> save() => _view?._save() ?? Future.value();
  Future<void> saveAs() => _view?._saveAs() ?? Future.value();
  void reloadFile() => _view?._reloadFileCommand();
  void undo() => _view?.undo();
  void redo() => _view?.redo();
  void copy() => _view?.copySelection();
  void paste() => _view?.pasteClipboard();
  void cut() => _view?.cutSelection();
  void selectAllText() => _view?.selectAll();
  void openSearch() => _view?.openSearch();
  void openReplace() => _view?.openReplace();
  void findNext() => _view?.findNext();
  void findPrev() => _view?.findPrev();
  void toggleBookmark() => _view?.toggleBookmark();
  void nextBookmark() => _view?.nextBookmark();
  void prevBookmark() => _view?.prevBookmark();
  void clearBookmarks() => _view?.clearBookmarks();
  void promptGotoLine() => _view?._promptGotoLine();
  void startIndexing() => _view?._startIndexing();

  /// File → Build line index: the explanation dialog (with its build
  /// button), or a toast when the index is done / in progress.
  void promptBuildIndex() => _view?._showIndexInfo();

  /// Run a keymap command by name on this pane (menu items whose action is
  /// a plain editor command, e.g. `edit.sortAsc`).
  void runCommand(String name) {
    final v = _view;
    if (v != null) v._registry.dispatch(name, v, null, 1);
  }

  void loadKeymap(String name) => _view?._loadKeymap(name);
  void loadCustomKeymap() => _view?._loadCustomKeymap();

  /// Give this pane's edit area keyboard focus (when switching to this tab / jumping to an
  /// already-open file).
  void focusEditor() => _view?._focus.requestFocus();

  /// Window went to the background / came back (shell's onWindowBlur /
  /// onWindowFocus): the caret is hidden while the window is inactive.
  void setWindowFocused(bool v) => _view?._setWindowFocused(v);

  /// Check whether an external program changed the file; if so, ask the user whether to
  /// reload. The shell calls it on window focus / tab switch / when polling the active pane.
  Future<void> checkExternalChange() =>
      _view?._checkExternalChange() ?? Future<void>.value();

  /// Manually switch the current file's syntax highlighting ('auto' / 'plain' / a WASM
  /// language name).
  void setSyntax(String mode) =>
      _view?._setSyntax(mode == 'auto' ? null : mode);

  /// The current view mode (text / column / hex).
  ViewMode get viewMode => _view?._viewMode ?? ViewMode.text;

  /// Switch the view mode (the menubar's "Mode" menu).
  void setViewMode(ViewMode mode) => _view?._setViewMode(mode);

  /// The active file's encoding (codec name; UTF-8 when nothing is open).
  String get encodingName => _view?._doc?.codec.name ?? 'UTF-8';

  /// Force the active file's encoding (reinterpret bytes; menu action).
  void setEncoding(String name) => _view?._setEncoding(name);

  /// Convert the active file to another encoding and save (rewrites bytes).
  void convertEncoding(String name) => _view?._convertEncoding(name);

  /// Whether the current codec has a BOM at all / whether the file starts
  /// with one (menu checkbox).
  bool get bomPossible => _view?._bomPossible ?? false;
  bool get hasBom => _view?._hasBom ?? false;

  /// Add/remove the BOM as a normal (undoable) edit at offset 0.
  void toggleBom() => _view?._toggleBom();

  /// The active file's newline style ('\n' or '\r\n'; menu checkmark).
  String get newlineStyle => _view?._newline ?? '\n';

  /// Convert the file's line endings: small documents (≤16MB, untitled or
  /// saved) convert in place as one undo step; larger saved files stream +
  /// atomic replace behind a confirm dialog.
  void convertNewline(String style) => _view?._convertNewline(style);

  /// Run a user script (`settings/scripts/<name>.js`) over the document /
  /// the selected lines (Tools menu).
  void runScript(String name) => _view?._runUserScript(name);

  // ── Session persistence (shell reads these when saving the session) ──
  /// Full path of the open file (null = untitled / nothing open).
  String? get path => _view?._path;
  int get caretOffset => _view?._caretOffset ?? 0;
  int get anchorOffset => _view?._anchorOffset ?? 0;

  /// Linear selection [start, end) or null (printing).
  (int, int)? get selection {
    final v = _view;
    if (v == null ||
        (v._selAnchor == null && !v._selAll) ||
        v._selEnd <= v._selStart) {
      return null;
    }
    return (v._selStart, v._selEnd);
  }

  int get documentLength => _view?._doc?.length ?? 0;

  /// Decoded text of [start, start + len) with the pane's codec (printing).
  Future<String?> readDecoded(int start, int len) async {
    final doc = _view?._doc;
    if (doc == null) return null;
    return (await doc.readRangeDecoded(start, len)).text;
  }

  /// 0-based line of [offset] (exact within the indexed prefix).
  Future<int> lineOfOffset(int offset) async {
    final doc = _view?._doc;
    if (doc == null) return 0;
    return (await doc.absoluteLineAt(offset)).line;
  }

  /// Window-parse highlight spans for [lines] with the pane's highlighter.
  List<List<HlSpan>> highlightLines(List<String> lines) =>
      _view?._hl.highlight(lines) ?? const [];

  /// ctrl+p: print (the shell opens the dialog).
  VoidCallback? onPrint;

  /// Shell menu actions bound to keys (file.saveAll, file.quickOpen, …):
  /// the shell points this at its menu dispatcher.
  void Function(String action)? onMenuAction;

  /// Run menu / clipboard history / column editor (all dialogs live in the shell).
  VoidCallback? onRunPrompt;
  void Function(String name)? onRunNamed;
  VoidCallback? onClipboardHistory;
  VoidCallback? onColumnEditor;

  /// Insert [text] at the caret (every cursor), one undo step — clipboard
  /// history paste.
  void insertText(String text) {
    final v = _view;
    if (v == null || text.isEmpty) return;
    v._enqueueCaret(() async {
      v._undo.breakCoalescing();
      await v._forEachCursor((_) => v._doInsert(text));
      v._undo.breakCoalescing();
    });
  }

  /// Column editor (Edit → Column editor…).
  void applyColumnEditor(ColumnEditorSpec spec) =>
      _view?._enqueueCaret(() => _view!._applyColumnEditor(spec));

  /// The selection text, or the word at the caret (external commands'
  /// $(CURRENT_WORD)); '' when neither.
  Future<String> currentWord() async {
    final v = _view;
    if (v == null || v._doc == null) return '';
    final seed = await v._occurrenceSeed();
    return seed?.$3 ?? '';
  }

  /// Most of the caret line handed to an external command's $(CURRENT_LINE).
  static const int _runLineMaxBytes = 4096;

  /// The caret line's text (capped, see [_runLineMaxBytes]) and 1-based
  /// number (external commands).
  Future<(String, int)> currentLine() async {
    final v = _view;
    final doc = v?._doc;
    if (v == null || doc == null) return ('', 0);
    final ls = await doc.lineStartOf(v._caretOffset);
    final le = await doc.lineEndOf(ls);
    // Capped: a minified 2 GB single-line file must not be decoded whole
    // into a String for a $(CURRENT_LINE) (OOM / minutes of freeze).
    final n = (le - ls).clamp(0, _runLineMaxBytes);
    var t = (await doc.readRangeDecoded(ls, n)).text;
    if (t.endsWith('\r')) t = t.substring(0, t.length - 1);
    final la = await doc.absoluteLineAt(ls);
    return (t, la.line + 1);
  }

  /// The encoding to remember: only one the user forced manually (null =
  /// auto-detect again next time).
  String? get manualEncoding =>
      (_view?._encManual ?? false) ? _view?._doc?.codec.name : null;

  /// Editor bookmarks (sorted line-start byte offsets; session persistence).
  List<int> get bookmarks =>
      _view == null ? const [] : (_view!._bookmarks.toList()..sort());

  /// Bumped whenever the bookmark set changes (toggle / clear / edits
  /// shifting offsets / file switch) — the bookmark panel listens.
  final ValueNotifier<int> bookmarksEpoch = ValueNotifier<int>(0);

  /// Bookmarks with line numbers and a line preview (bookmark panel).
  Future<List<BookmarkInfo>> bookmarkDetails() =>
      _view?._bookmarkDetails() ?? Future.value(const []);

  /// Bumped after every edit and document (re)load — the outline panel
  /// rescans (debounced) when it changes.
  final ValueNotifier<int> docEpoch = ValueNotifier<int>(0);

  /// Scan the document's outline with [lang]'s rules; null while loading.
  Future<OutlineResult?> scanOutlineWith(
    OutlineLanguage lang, {
    bool Function()? cancelled,
  }) {
    final v = _view;
    final doc = v?._doc;
    if (v == null || doc == null || v._opening) return Future.value(null);
    return scanOutline(doc, lang, cancelled: cancelled);
  }

  void removeBookmark(int offset) => _view?._removeBookmark(offset);

  /// View → Word count… (statistics dialog; selection-aware).
  void showWordCount() => _view?._showWordCount();

  /// Search → Go to matching bracket (ctrl+m).
  void gotoMatchingBracket() => _view?.matchBracket();

  /// View → Zoom in / out / reset (ctrl+= / ctrl+- / ctrl+0; 0 = reset).
  void zoomFont(int steps) => _view?.zoomFont(steps);
}

/// Editor view for a single file (embeddable in any container; one per pane when there are
/// several).
///
/// Its state is self-contained (Document / caret / scrolling / undo / IME / keybinding /
/// syntax highlighting); operations and state are exposed to the shell through
/// [controller]. Contains **no** Scaffold / AppBar / menubar.
class EditorView extends StatefulWidget {
  const EditorView({
    super.key,
    required this.controller,
    this.initialPath,
    this.initialCaret = 0,
    this.initialAnchor = 0,
    this.initialEncoding,
    this.initialBookmarks = const [],
    this.initialWrap,
    this.startBlank = false,
  });

  final EditorController controller;

  /// File path to load on creation (with multiple panes the shell sets it when opening a
  /// file); null = blank, waiting for a file to be opened.
  final String? initialPath;

  /// Caret / top-anchor offsets to restore (session restore).
  final int initialCaret;
  final int initialAnchor;

  /// Encoding to force on load (a manually chosen one from the saved
  /// session); null = auto-detect.
  final String? initialEncoding;

  /// Bookmarks to restore (line-start byte offsets from the saved session).
  final List<int> initialBookmarks;

  /// Per-tab soft-wrap override to restore ('off' / 'columns' / 'window');
  /// null = follow the global default.
  final String? initialWrap;

  /// With no [initialPath]: true = start with an empty untitled document
  /// (saving asks for a location); false = the legacy "open a file" screen.
  final bool startBlank;

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView>
    implements EditorActions, DeltaTextInputClient {
  Document? _doc;
  DocWindow? _window;

  /// Visible visual rows (after soft-wrap expansion) and each row's spans; recomputed by
  /// build from the window / spans / settings.
  List<WrapRow> _rows = const [];
  List<List<HlSpan>> _rowSpans = const [];
  String _rowsKey = ''; // wrap settings used for the last expansion (mode/columns/view width; recompute on change)
  int _anchorOffset = 0;
  int _anchorLine = 0; // line number of the top line
  bool _anchorLineExact = true; // whether it is exact (a byte jump into unindexed territory → estimate)
  double _viewportH = 1;
  double _viewportW = 1;
  bool _opening = false;

  // ── Horizontal scrolling ──
  // Text-layer shift (px). In document RTL layout the canonical value is
  // _hScrollFromRight instead (distance of the view's right edge from the
  // content's right edge): the setter keeps it in step, and build derives
  // _scrollXv from it whenever the content width changes — so vertical
  // scrolling that brings longer/shorter rows into the window keeps the
  // right edge (line starts) where it was, like an RTL scroll origin.
  double _scrollXv = 0;
  double get _scrollX => _scrollXv;
  set _scrollX(double v) {
    _scrollXv = v;
    final r = _maxScrollX - v;
    _hScrollFromRight = r > 0 ? r : 0;
  }

  double _hScrollFromRight = 0;

  /// Back to the "start" of the content: x = 0, or the right end in document
  /// RTL layout (0 from the right — build turns it into _maxScrollX once the
  /// new window's content width is measured).
  void _resetHScroll() {
    _scrollXv = 0;
    _hScrollFromRight = 0;
  }

  double _contentW = 0; // max content width of the current window's visible lines (measured when the window changes)
  DocWindow? _contentWWin; // the window _contentW was measured for

  /// Document-level right-to-left layout (View → Right-to-left layout): every row is
  /// right-aligned to a common right edge and horizontal scrolling starts
  /// from the right. Auto-detected from the file head on load
  /// (bidi.detectRtlLayout) unless the user toggled it for this path.
  bool _rtlLayout = false;
  bool _rtlLayoutManual = false;

  /// Row alignment handed to the painter (TextViewport.rtlMode): 0 in column
  /// mode (rectangle math needs a left origin), 2 in document RTL layout,
  /// else 1 (per-row right-alignment of RTL rows).
  int get _rtlMode => _columnMode ? 0 : (_rtlLayout ? 2 : 1);
  bool get _rtlLayoutActive => _rtlMode == 2 && !_hexMode;

  /// Paragraph base direction for row paragraphs built by the state (hit
  /// tests, caret x): forced RTL in document RTL layout, else per row
  /// (null = first strong character). Must match the painter's `baseRtl`.
  bool? get _baseRtl => _rtlMode == 2 ? true : null;

  void _toggleRtlLayout() {
    if (_doc == null) return;
    setState(() {
      _rtlLayout = !_rtlLayout;
      _rtlLayoutManual = true;
      _resetHScroll();
    });
    _bump();
  }

  // The head of the file decides the layout direction: first line with a
  // strong character (a few lines, one small window read, like _detectNewline).
  Future<bool> _detectRtlLayout({bool fallback = false}) async {
    final doc = _doc;
    if (doc == null) return fallback;
    final w = await doc.readWindow(0, 8);
    return detectRtlLayout(w.lines, fallback: fallback);
  }

  /// The UI's own direction (MaterialApp's Directionality, i.e. the UI
  /// locale): what a new, still directionless document starts with.
  bool get _uiIsRtl =>
      mounted && Directionality.maybeOf(context) == TextDirection.rtl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The UI language (hence Directionality) changed: a still directionless
    // untitled document follows it. Content with a strong character wins
    // inside _autoRtlUntitled, so a typed-in document is not flipped.
    if (_doc != null && _path == null && !_rtlLayoutManual) {
      _enqueueCaret(_autoRtlUntitled);
    }
  }

  /// An untitled document has no file head to detect from when it opens, so
  /// its layout direction follows what gets typed: re-detected after every
  /// edit (same 8-line read, on the caret queue) until the user toggles it by
  /// hand or the document gets a path (Save As → the file head rule applies
  /// from the next open). While it has no strong character at all it follows
  /// the UI direction — an RTL UI gets RTL new documents, like Notepad/Word.
  Future<void> _autoRtlUntitled() async {
    if (_path != null || _rtlLayoutManual || _hexMode || _doc == null) return;
    final rtl = await _detectRtlLayout(fallback: _uiIsRtl);
    if (rtl == _rtlLayout || !mounted) return;
    setState(() {
      _rtlLayout = rtl;
      _resetHScroll();
    });
    _bump();
  }

  /// Horizontal shift of a row's text origin (the painter's rowX minus
  /// textX); hit-tests and caret x go through it. Must mirror
  /// RenderTextViewport._rowShiftOf.
  double _rowShift(_LinePara para) => switch (_rtlMode) {
    0 => 0,
    2 => rtlLayoutShift(para.width, _textViewW, _contentW),
    _ => para.rtlShift(_textViewW),
  };
  bool _saving = false;
  bool _indexing = false;
  String? _name;
  String? _path; // full path of the open file (for saving)

  // ── External change detection ──
  // Disk stamp (mtime/size) as of our last open/save/reload; a later mismatch
  // means another program touched the file → offer to reload.
  int? _diskMtimeUs;
  int? _diskSize;
  bool _extDialogOpen = false; // re-entry guard for the prompt
  final _jumpCtrl = TextEditingController();
  final _focus = FocusNode();

  // ── Caret / selection (phase 3) ──
  int _caretPos = 0; // caret's document byte offset (use _caretOffset)
  int get _caretOffset => _caretPos;
  // Any move clears the row-end affinity; End re-sets it via _moveCaretTo.
  set _caretOffset(int v) {
    if (v != _caretPos) {
      _caretAtRowEnd = false;
      _selAll = false; // the caret left its place: select-all is over
    }
    _caretPos = v;
  }

  // The caret sits exactly on a soft-wrap cut and belongs to the row *before*
  // it (End on a wrapped row). Without this the cut offset is the next row's
  // start, so End would render at that row's first column.
  bool _caretAtRowEnd = false;

  // Selection anchor (null = no selection); the selection is
  // [min, max](anchor, caret). Assigning it — even null — ends select-all.
  int? _selAnchorRaw;
  int? get _selAnchor => _selAnchorRaw;
  set _selAnchor(int? v) {
    _selAnchorRaw = v;
    _selAll = false;
  }

  // Select-all keeps the caret where it was (the anchor/caret pair cannot
  // express "whole document selected, caret in the middle"), so it is a
  // flag: while set, _selStart/_selEnd cover the document regardless of the
  // anchor. Any caret move or anchor assignment clears it, so every command
  // that consumes or replaces the selection behaves as with a normal one.
  bool _selAll = false;
  int? _goalColumn; // target column kept across up/down moves (rune count)

  // ── Multi-cursor ──
  // Extra cursors beyond the primary (alt+click, ctrl+alt+up/down, select
  // all occurrences). Sorted by caret, never equal to the primary. Per-cursor
  // commands replay the single-cursor code path once per cursor
  // (_forEachCursor); a caret move or edit made outside that loop collapses
  // back to the primary — the offsets would be stale anyway.
  List<Cursor> _extra = const [];
  bool get _multi => _extra.isNotEmpty;
  bool _inMulti = false; // inside _forEachCursor: the funnels must not collapse
  // Painter snapshots, fresh lists on every change (identical-check contract).
  List<int> _extraCaretsView = const [];
  List<int> _extraSelsView = const [];
  bool _caretOn = true; // blink phase
  Timer? _blinkTimer;
  Future<void> _caretOps = Future<void>.value(); // serializes async caret/edit operations to avoid races

  // ── Editing / input (phase 4) ──
  final UndoStack _undo = UndoStack();

  /// Cap on bytes the undo history may hold after a save materializes its
  /// entries (deleted text has to be copied out of the closing document).
  static const int _undoRebaseMaxBytes = 256 << 20;
  bool _modified = false;
  String _newline = '\n'; // this file's newline style (\r\n when \r\n is detected)
  String _composing = ''; // text the IME is composing (shown as an overlay, not yet in the document)
  TextInputConnection? _ime;
  TextEditingValue _imeValue = TextEditingValue.empty;

  // ── Syntax highlighting ──
  Highlighter _hl = const NoHighlighter();
  List<List<HlSpan>>? _spans; // spans per line of the current window (recomputed in build when the window changes)
  DocWindow? _hlWindow; // the window highlighting was last computed for (change detection)
  // Manually chosen syntax: null = auto by extension; 'plain' = no highlighting; otherwise a
  // WASM grammar language name.
  String? _forcedSyntax;

  // Whole-file highlighting (small, fully-indexed files): per-absolute-line spans for the entire
  // file, so the visible window is just sliced out — correct context, and scrolling needs no parse.
  // null = window-parse mode (large files / not yet computed).
  //
  // Kept up to date **incrementally**: every splice widens a dirty byte range (_hlDirtyBytes, fed
  // by Document.onSplice), _reload turns it into a dirty line range (_hlDirty, current numbering),
  // and after a short debounce only those lines go to the backend session (_hlSession), which
  // re-parses incrementally and returns the lines whose spans changed. _fullHl itself always
  // reflects the session's numbering (_hlSyncedLines lines); until a patch lands, dirty lines in
  // the visible window are window-parsed and the rest are sliced from the cache via the dirty
  // range's line delta.
  List<List<HlSpan>>? _fullHl;
  int _fullHlRev =
      0; // bumped when _fullHl or the dirty range changes → window spans recompute
  int _hlFullRevSeen = -1;
  int _fullHlEpoch =
      0; // bumped on syntax/open/encoding changes to discard stale async results
  bool _fullHlComputing = false; // an open()/recompute is in flight
  Timer?
  _fullHlDebounce; // debounce so rapid edits are synced as one batch, not per keystroke
  HlSession? _hlSession;
  final DirtyBytes _hlDirtyBytes = DirtyBytes();
  final DirtyLines _hlDirty = DirtyLines();
  int _hlSyncedLines = 0; // line count _fullHl / the session reflect
  bool _hlSyncing = false; // a session edit() is in flight
  int _editSerial =
      0; // counts splices; lets async steps notice an edit slipped in mid-way

  // Whole-file highlighting applies only to small, fully-indexed files (so absolute line numbers are
  // known and the window can be sliced) that actually have a highlighter.
  bool get _wholeFileHlEligible {
    final d = _doc;
    return d != null &&
        !_hexMode && // hex mode has no syntax coloring; don't waste a whole-file parse
        d.size <= _wholeFileHlMaxBytes &&
        d.indexDone &&
        _hl is! NoHighlighter;
  }

  // Drop the cached whole-file spans and the session (document / highlighter / encoding changed);
  // the next build recomputes from scratch, window-parsing meanwhile. Not for plain edits — those
  // go through _onDocSplice → _noteEditForHl → _syncHl.
  void _invalidateFullHl() {
    _clearFolds(); // the regions belonged to the old tree
    _fullHl = null;
    _fullHlRev++;
    _fullHlEpoch++;
    _hlSession?.close();
    _hlSession = null;
    _hlDirty.clear();
    _hlDirtyBytes.clear();
    _hlSyncing = false;
  }

  // Document splice hook: shift offset-anchored state (bookmarks, folds,
  // navigation history) and record the edit for the incremental highlighter
  // (only while there is a cache to keep in step).
  // Splices since the painted window was read (see window_splice.dart):
  // the painter gets the caret mapped back into the window's coordinates
  // until the next window lands, instead of a caret one past the old line
  // end landing on the next row's start for a frame.
  final List<(int, int)> _windowSplices = [];
  int get _caretForPaint => _windowSplices.isEmpty
      ? _caretOffset
      : offsetBeforeSplices(_caretOffset, _windowSplices);

  void _onDocSplice(int offset, int delta) {
    _editSerial++;
    _windowSplices.add((offset, delta));
    _spliceBookmarks(offset, delta);
    _spliceFolds(offset, delta);
    _nav.shift(offset, delta);
    int sh(int x) => x < offset ? x : (x + delta < offset ? offset : x + delta);
    final le = _lastEditOffset;
    if (le != null) _lastEditOffset = sh(le);
    final sc = _searchScope;
    if (sc != null) _searchScope = (sh(sc.$1), sh(sc.$2));
    final ac = _autoClosedAt;
    if (ac != null) _autoClosedAt = ac < offset ? ac : sh(ac);
    if (_fullHl != null || _fullHlComputing) _hlDirtyBytes.add(offset, delta);
  }

  // Turn the bytes spliced since the last call into a dirty line range (current numbering) and
  // arm a sync. Two line lookups, so it runs on every window reload after an edit.
  Future<void> _noteEditForHl() async {
    final d = _doc;
    if (d == null || _hlDirtyBytes.isEmpty) return;
    if (_fullHl == null && !_fullHlComputing) {
      _hlDirtyBytes.clear();
      return;
    }
    final s = _hlDirtyBytes.start, e = _hlDirtyBytes.end;
    _hlDirtyBytes.clear();
    final serial = _editSerial;
    final a = (await d.absoluteLineAt(s)).line;
    final y = (await d.absoluteLineAt(e)).line + 1;
    if (!mounted || _doc != d) return;
    if (serial != _editSerial) {
      // Another edit slipped in between the lookups: the line numbers above may not match the
      // count below any more, so mark everything (rare; one full re-sync).
      _hlMarkAllDirty();
      return;
    }
    _hlDirty.add(a, y, d.absoluteLineCount);
    _fullHlRev++;
    _maybeScheduleFullHl();
  }

  // The first edit of a file above the auto-index cap builds the line index
  // before it can land (Document.onIndexWait). Small files finish in a blink;
  // for the rest a modal progress dialog says what the wait is, after a short
  // grace period so it does not flash.
  void _onIndexWait(Future<void> done) {
    final doc = _doc;
    if (doc == null || !mounted) return;
    var finished = false;
    done.whenComplete(() => finished = true);
    Timer(const Duration(milliseconds: 300), () {
      if (finished || !mounted || _doc != doc) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _IndexWaitDialog(doc: doc, done: done),
      );
    });
  }

  void _hlMarkAllDirty() {
    final n = _doc?.absoluteLineCount ?? 0;
    _hlDirtyBytes.clear();
    _hlDirty.add(0, n, n);
    _fullHlRev++;
    _maybeScheduleFullHl();
  }

  // Arm the debounced whole-file work when eligible: open a session when there is no cache yet,
  // otherwise sync the pending dirty lines. Rapid edits keep resetting the timer, so while you
  // type the dirty lines stay window-parsed and one incremental sync runs once you pause
  // (settings: wholeFileHighlightDebounceMs).
  void _maybeScheduleFullHl() {
    if (_fullHlComputing || !_wholeFileHlEligible) return;
    if (_fullHl == null) {
      _fullHlDebounce?.cancel();
      _fullHlDebounce = Timer(_wholeFileHlDebounce, _recomputeFullHl);
    } else if (!_hlDirty.isEmpty && !_hlSyncing) {
      _fullHlDebounce?.cancel();
      _fullHlDebounce = Timer(_wholeFileHlDebounce, _syncHl);
    }
  }

  // Read the whole file and highlight it in one pass; cache per-absolute-line spans and, when the
  // backend supports it, keep an incremental session open for the edits that follow.
  Future<void> _recomputeFullHl() async {
    if (_fullHlComputing) return;
    final d = _doc;
    if (d == null || !_wholeFileHlEligible) return;
    _fullHlComputing = true;
    final epoch = _fullHlEpoch;
    final hl = _hl;
    HlSession? session;
    try {
      _hlDirtyBytes.clear();
      _hlDirty.clear();
      final serial = _editSerial;
      final sw = Stopwatch()..start();
      final win = await d.readWindow(0, d.absoluteLineCount, startLine: 0);
      Log.instance.d(
        'hl whole-file: read ${win.lines.length} lines in ${sw.elapsedMilliseconds} ms',
      );
      if (!mounted || epoch != _fullHlEpoch) return;
      if (serial != _editSerial) {
        return; // edited mid-read: the finally block re-arms
      }
      final n = win.lines.length;
      _hlSyncedLines = n;
      _hlDirty.localLines = n;
      // Edits from here on accumulate in _hlDirtyBytes and are synced once the cache exists.
      // Off the UI thread (Rust worker): a multi-MB file takes a while to parse, and the window
      // keeps its window-parse colors until this lands.
      session = hl.createSession();
      var spans = session != null ? await session.open(win.lines) : null;
      if (!mounted || epoch != _fullHlEpoch) return;
      if (spans == null) {
        session?.close();
        session = null;
        spans = await hl.highlightAsync(win.lines);
        if (!mounted || epoch != _fullHlEpoch) return;
      }
      _hlSession = session;
      Log.instance.d(
        'hl whole-file: $n lines, incremental ${session != null ? 'on' : 'off'} '
        '(${hl.description}) — total ${sw.elapsedMilliseconds} ms',
      );
      session = null; // now owned by the state
      setState(() {
        _fullHl = spans;
        _fullHlRev++;
      });
      _scheduleFoldRefresh();
    } finally {
      session?.close();
      _fullHlComputing = false;
      // Edited or invalidated mid-parse: arm the next step (a re-open, or the sync of what was
      // typed meanwhile) instead of waiting for whatever rebuild happens to come next.
      if (mounted) _maybeScheduleFullHl();
    }
  }

  // Lines [a, b) of the document as decoded text; null when the document has fewer lines.
  Future<List<String>?> _readLines(Document d, int a, int b) async {
    if (a >= b) return const [];
    final off = await d.byteOffsetOfLine(a);
    final win = await d.readWindow(off, b - a, startLine: a);
    return win.lines.length == b - a ? win.lines : null;
  }

  // Send the dirty lines to the session and splice the returned spans into _fullHl.
  Future<void> _syncHl() async {
    if (_hlSyncing || _fullHlComputing || _hlDirty.isEmpty) return;
    final d = _doc;
    final full = _fullHl;
    if (d == null || full == null || !_wholeFileHlEligible) return;
    final session = _hlSession;
    if (session == null) {
      // Backend without incremental support: recompute from scratch (the old behaviour).
      _invalidateFullHl();
      _maybeScheduleFullHl();
      return;
    }
    final epoch = _fullHlEpoch;
    final s = _hlDirty.start, e = _hlDirty.end;
    final oldEnd = _hlDirty.oldEnd(_hlSyncedLines);
    final sentLines = _hlDirty.localLines;
    _hlDirty.clear();
    _hlSyncing = true;
    final sw = Stopwatch()..start();
    try {
      final serial = _editSerial;
      final lines = await _readLines(d, s, e);
      if (!mounted || epoch != _fullHlEpoch) return;
      if (lines == null || serial != _editSerial) {
        _hlMarkAllDirty(); // edited mid-read: cannot trust the snapshot
        return;
      }
      final patch = await session.edit(s, oldEnd, lines, (a, b) async {
        // Only a session that cascades past the edit (pure-Dart lexer) reads more; refuse
        // when the document moved on so it reopens instead of mixing states.
        if (serial != _editSerial) return const [];
        return (await _readLines(d, a, b)) ?? const [];
      });
      if (!mounted || epoch != _fullHlEpoch) return;
      if (patch == null) {
        _invalidateFullHl(); // session gone → full re-open
        _maybeScheduleFullHl();
        return;
      }
      // _fullHl is in the synced numbering; the patch is in the sent one. Outside the patched
      // range [x, y) the lines are unchanged, just shifted by this edit's line delta.
      final delta = sentLines - _hlSyncedLines;
      final x = patch.start.clamp(0, full.length);
      final yOld = (patch.end - delta).clamp(x, full.length);
      final next = <List<HlSpan>>[
        ...full.sublist(0, x),
        ...patch.lines,
        ...full.sublist(yOld),
      ];
      _fullHl = next;
      _hlSyncedLines = sentLines;
      _fullHlRev++;
      _scheduleFoldRefresh();
      Log.instance.d(
        'hl sync: lines $s..$e (was ..$oldEnd) → patched '
        '${patch.start}..${patch.end} of $sentLines in ${sw.elapsedMilliseconds} ms',
      );
      if (mounted) setState(() {});
    } catch (e, st) {
      // Not on the caret queue, so the document can be replaced or closed
      // under this read (a save reopens the file; a reload). The new
      // document opens its own session — nothing to patch. Anything else
      // is unexpected: log it and mark everything dirty so the next sync
      // starts over instead of leaving the cache half-updated.
      // (_saving: the handle is suspended for the atomic replace while the
      // Document object stays the same — same situation.)
      if (!identical(_doc, d) || _saving) {
        Log.instance.d('hl sync: document replaced/suspended mid-sync ($e)');
        _hlMarkAllDirty(); // the reopened document re-syncs from scratch anyway
      } else {
        Log.instance.w('hl sync failed: $e\n$st');
        _hlMarkAllDirty();
      }
    } finally {
      if (epoch == _fullHlEpoch) {
        _hlSyncing = false;
        if (mounted && !_hlDirty.isEmpty) _maybeScheduleFullHl();
      }
    }
  }

  // Index into _fullHl (synced numbering) for a line in current numbering, or -1 when the line
  // is inside the pending dirty range.
  int _syncedIndexOf(int line) {
    if (_hlDirty.isEmpty) return line;
    if (line < _hlDirty.start) return line;
    if (line >= _hlDirty.end) {
      return line - (_hlDirty.localLines - _hlSyncedLines);
    }
    return -1;
  }

  // Spans for the current visible window: slice from the whole-file cache when available (and the
  // window's absolute start line is known), window-parsing only the lines whose sync is still
  // pending; otherwise fall back to window-parse for everything.
  List<List<HlSpan>>? _computeWindowSpans() {
    final w = _window;
    if (w == null) return null;
    final full = _fullHl;
    if (full != null && w.startLine >= 0 && _hlDirtyBytes.isEmpty) {
      List<List<HlSpan>>?
      parsed; // window-parse, computed only if a visible line is dirty
      final out = <List<HlSpan>>[];
      for (var i = 0; i < w.lines.length; i++) {
        // Folded windows skip lines: ask the window for the absolute number.
        final abs = w.lineNumberAt(i);
        final k = abs < 0 ? -1 : _syncedIndexOf(abs);
        if (k < 0) {
          parsed ??= _hl.highlight(w.lines);
          out.add(i < parsed.length ? parsed[i] : const <HlSpan>[]);
        } else {
          out.add(k < full.length ? full[k] : const <HlSpan>[]);
        }
      }
      return out;
    }
    return _hl.highlight(w.lines);
  }

  // Pick a highlighter by extension: ① an installed WASM grammar plugin first → ② statically
  // compiled tree-sitter → ③ the pure-Dart lexer (plain-text extensions get no highlighting).
  Highlighter _pickHighlighter(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    // ⓪ The user's own extension → syntax table (Settings → File associations…) wins over
    // every registry: 'plain' or a grammar name; an unknown name (grammar
    // removed since) falls through to the automatic chain.
    final over = AppSettings.instance.syntaxByExt[ext];
    if (over != null) {
      if (over == 'plain') return const NoHighlighter();
      final og = WasmGrammarRegistry.instance.forLang(over);
      if (og != null && nativeBackendAvailable) return RustHighlighter.wasm(og);
    }
    // Without the native library (RustLib.init failed) only the pure-Dart
    // lexer is usable — RustHighlighter would throw on its first call.
    if (nativeBackendAvailable) {
      final g = WasmGrammarRegistry.instance.forExt(ext);
      if (g != null) return RustHighlighter.wasm(g);
      if (ext.isNotEmpty && RustHighlighter.supports(ext)) {
        return RustHighlighter(ext);
      }
    }
    return highlighterForPath(path);
  }

  // Pick the highlighter from the manually chosen syntax, or (when none) automatically.
  Highlighter _resolveHighlighter() {
    final h = _resolveHighlighterUncached();
    // A plugin grammar is read from disk on first use: until then the sync
    // window parse paints plain, so repaint the window once the files are in
    // (the whole-file session awaits the read itself). A later switch makes
    // this callback stale, hence the epoch.
    final g = h is RustHighlighter ? h.grammar : null;
    if (g != null && !g.isLoaded) {
      final epoch = ++_grammarWaitEpoch;
      g.ensureLoaded().then((_) {
        if (!mounted || epoch != _grammarWaitEpoch) return;
        _hlWindow = null;
        setState(() {});
      });
    }
    return h;
  }

  int _grammarWaitEpoch = 0;

  Highlighter _resolveHighlighterUncached() {
    final f = _forcedSyntax;
    if (f == null) return _pickHighlighter(_path ?? '');
    if (f == 'plain') return const NoHighlighter();
    final g = WasmGrammarRegistry.instance.forLang(f);
    if (g != null) return RustHighlighter.wasm(g);
    return _pickHighlighter(_path ?? ''); // language not found → fall back to auto
  }

  // Switch the view mode. Hex rows are a fixed 16 bytes (the anchor must be aligned); in
  // text/column mode the anchor must sit on a line start.
  Future<void> _setViewMode(ViewMode m) async {
    if (_viewMode == m) return;
    setState(() {
      _viewMode = m;
      _colBlock = null; // selection semantics differ (rectangle vs linear) → clear on mode change
      _selAnchor = null;
      if (m == ViewMode.hex) _searchHex = true; // bytes are the unit there
    });
    _bump();
    _syncIme(); // hex mode takes no text input (hex editing not yet supported)
    final doc = _doc;
    if (doc == null) return;
    if (m == ViewMode.hex) {
      _anchorOffset -= _anchorOffset % hexBytesPerRow;
      await _reloadHex();
    } else {
      final ls = await doc.lineStartOf(_anchorOffset);
      final la = await doc.absoluteLineAt(ls);
      _anchorLineExact = la.exact;
      await _setAnchor(ls, la.line);
    }
  }

  // Read the hex view's visible bytes (simpler than text mode: a row is a
  // fixed 16 bytes, no line scanning). Also decodes the text column with the
  // document's codec; a few prefix bytes give context so a multi-byte
  // character straddling the window top still decodes (unit codecs are
  // already aligned — the base is a multiple of 16).
  Future<void> _reloadHex() async {
    final doc = _doc;
    if (doc == null) return;
    final rows = _visibleCount + 1;
    final pre = doc.codec.unitSize == 1
        ? (_anchorOffset < 4 ? _anchorOffset : 4)
        : 0;
    final buf = await doc.readRangeBytes(
      _anchorOffset - pre,
      rows * hexBytesPerRow + pre,
    );
    final skip = pre > buf.length ? buf.length : pre;
    final bytes = Uint8List.sublistView(buf, skip);
    final cells = hexTextCells(doc.codec, buf, skip, bytes.length);
    if (mounted) {
      setState(() {
        _hexBytes = bytes;
        _hexCells = cells;
        _windowSplices.clear(); // the hex window reflects every splice now
      });
    }
  }

  // Content width in hex mode (fixed row width, derived directly from the character count).
  double get _hexContentW {
    final doc = _doc;
    final digits = hexOffsetDigits(doc?.length ?? 0);
    return hexRowChars(digits) * editorCharWidth + 20;
  }

  // Hex-mode scrolling: the anchor moves in 16-byte steps (no line scanning needed).
  Future<void> _hexScrollRows(int rows) async {
    final doc = _doc;
    if (doc == null || rows == 0) return;
    final maxBase = _hexMaxBase(doc.length);
    var next = _anchorOffset + rows * hexBytesPerRow;
    if (next < 0) next = 0;
    if (next > maxBase) next = maxBase;
    if (next == _anchorOffset) return;
    _anchorOffset = next;
    await _reloadHex();
  }

  // Bottom scroll limit (wheel / scrollbar): the top row that puts the last
  // row on the LAST COMPLETE screen row — floor, not ceil, or the wheel
  // stopped with the last row half cut off at the viewport edge.
  int _hexMaxBase(int length) {
    if (length <= 0) return 0;
    final lastRow = (length - 1) ~/ hexBytesPerRow;
    final rowsOnScreen = _fullRowCount;
    final maxRow = lastRow - rowsOnScreen + 1;
    return maxRow <= 0 ? 0 : maxRow * hexBytesPerRow;
  }

  // Hex mode: scroll the caret's row into view.
  Future<void> _ensureCaretVisibleHex() async {
    final doc = _doc;
    if (doc == null) return;
    // COMPLETE rows only (floor), like the text view: _visibleCount rounds
    // the viewport height UP, so with a partial last row the caret parked
    // there counted as visible while its row was cut off at the viewport's
    // bottom edge — right above the status bar, which looked like the bar
    // covering the last line (ctrl+End on a large file).
    final rows = _fullRowCount;
    final caretRow = _caretOffset ~/ hexBytesPerRow;
    final topRow = _anchorOffset ~/ hexBytesPerRow;
    if (caretRow < topRow) {
      _anchorOffset = caretRow * hexBytesPerRow;
      await _reloadHex();
    } else if (caretRow >= topRow + rows) {
      final newTop = caretRow - rows + 1;
      _anchorOffset = newTop * hexBytesPerRow;
      await _reloadHex();
    }
  }

  // Hex-mode caret movement (in bytes; hex has no notion of "line", so it bypasses the
  // keybinding caret.* commands). [keepNibble]: up/down/page moves keep the current high/low
  // nibble (as HxD and other hex editors do); jumps like row start/end return to the high one.
  Future<void> _hexMoveCaret(
    int deltaBytes, {
    required bool select,
    bool keepNibble = false,
  }) async {
    final doc = _doc;
    if (doc == null) return;
    // The caret may sit AFTER the last byte in every mode, like a text
    // editor's: the selection is [anchor, caret), so pinning the caret to the
    // last byte in overwrite mode made that byte unselectable from either
    // side. Typing there appends (see _hexTypeDigit / _hexTypeAscii).
    final maxOff = doc.length;
    var next = _caretOffset + deltaBytes;
    if (next < 0) next = 0;
    if (next > maxOff) next = maxOff;
    setState(() {
      if (select) {
        _selAnchor ??= _caretOffset;
      } else {
        _selAnchor = null;
      }
      _caretOffset = next;
      if (!keepNibble) _hexNibble = 0;
    });
    _restartBlink();
    await _ensureCaretVisibleHex();
  }

  // Left/right in the hex column: the unit is a **nibble** (half a byte).
  // Right: high → low → next byte's high; left is the reverse. The ascii column has no
  // nibbles and goes through _hexMoveCaret.
  Future<void> _hexMoveNibble(int deltaNibbles, {required bool select}) async {
    final doc = _doc;
    if (doc == null || doc.length == 0) return;
    final pos = hexClampNibblePos(
      _caretOffset * 2 + _hexNibble + deltaNibbles,
      doc.length,
      allowEnd: true, // the caret may sit after the last byte (see _hexMoveCaret)
    );
    setState(() {
      if (select) {
        _selAnchor ??= _caretOffset;
      } else {
        _selAnchor = null;
      }
      _caretOffset = pos >> 1;
      _hexNibble = pos & 1;
    });
    _restartBlink();
    await _ensureCaretVisibleHex();
  }

  // ── Hex editing ────────────────────────────────────────────────
  // Overwrite mode: typing rewrites the byte at the caret (the file never grows). Only
  // delete/backspace actually remove bytes. Each overwrite = delete(1) + insertBytes(1), both
  // pushed to the UndoStack, so undo/redo is shared with text mode.

  /// Overwrite the byte at [offset] with [value] (0–255).
  Future<void> _hexOverwrite(int offset, int value) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || offset < 0 || offset >= doc.length) return;
    final rev = await doc.overwriteBytes(offset, [value]);
    _undo.push(rev); // compound reverse edit → one undo step restores the original byte
    _setModified(_undo.isDirty);
    _selAnchor = null;
    await _afterEdit();
  }

  /// Type one hex digit in the hex column.
  ///
  /// Overwrite mode: the high/low nibble each replace their half; after the low nibble the
  /// caret moves to the next byte.
  /// Insert mode: **typing the high nibble inserts a new byte** (low nibble 0 for now), the
  /// caret stays on that new byte's low nibble, and typing the low nibble completes it
  /// (same as HxD).
  Future<void> _hexTypeDigit(int digit) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    final off = _caretOffset;
    // Insert mode, or the caret parked after the last byte (there is nothing
    // to overwrite there, so overwrite mode appends too).
    if ((_hexInsertMode || off >= doc.length) && _hexNibble == 0) {
      await _hexInsertBytes(off, [digit << 4]);
      if (!mounted) return;
      setState(() {
        _caretOffset = off;
        _hexNibble = 1; // stay on the low nibble of the byte just inserted
      });
      return;
    }
    if (doc.length == 0) return;
    final cur = await _hexByteAt(off);
    if (cur == null) return;
    final value = _hexNibble == 0
        ? (digit << 4) | (cur & 0x0F)
        : (cur & 0xF0) | digit;
    await _hexOverwrite(off, value);
    if (!mounted) return;
    // Advance one nibble: after the high nibble stay on the same byte's low nibble; only
    // after the low nibble move to the next byte.
    await _hexMoveNibble(1, select: false);
  }

  /// Type a character in the text column: it is encoded with the document's
  /// codec (so a CJK character in a Big5 file writes its 2 Big5 bytes) and
  /// overwrites (or inserts) that many bytes; the caret moves past them.
  Future<void> _hexTypeAscii(String ch) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    final enc = doc.codec.encode(ch);
    if (enc.bytes.isEmpty) return;
    if (enc.fallbackCount > 0) {
      _toast(_l10n.trf('toast_unencodable_one', [doc.codec.name]));
    }
    if (_hexInsertMode || _caretOffset >= doc.length) {
      // Insert mode, or after the last byte: append.
      await _hexInsertBytes(_caretOffset, enc.bytes);
      if (mounted) await _hexMoveCaret(enc.bytes.length, select: false);
      return;
    }
    if (_caretOffset + enc.bytes.length > doc.length) {
      _toast(_l10n.tr('toast_hex_ovr_end'));
      return;
    }
    final rev = await doc.overwriteBytes(_caretOffset, enc.bytes);
    _undo.push(rev);
    _setModified(_undo.isDirty);
    _selAnchor = null;
    await _afterEdit();
    await _hexMoveCaret(enc.bytes.length, select: false);
  }

  /// Insert bytes at [offset] (insert mode). Consecutive inserts coalesce into one undo step.
  Future<void> _hexInsertBytes(int offset, List<int> bytes) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    final at = offset.clamp(0, doc.length);
    final rev = await doc.insertBytes(at, bytes);
    _undo.push(rev, coalesce: true);
    _setModified(_undo.isDirty);
    _selAnchor = null;
    await _afterEdit();
  }

  /// Delete [length] bytes starting at [offset] (the document shrinks).
  Future<void> _hexDelete(int offset, int length) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || length <= 0 || offset < 0 || offset >= doc.length) {
      return;
    }
    final len = (offset + length > doc.length) ? doc.length - offset : length;
    final rev = await doc.delete(offset, len);
    _undo.push(rev, coalesce: true);
    _setModified(_undo.isDirty);
    setState(() {
      _caretOffset = offset;
      _hexNibble = 0;
      _selAnchor = null;
    });
    await _afterEdit();
  }

  /// Byte value at an offset within the current window (read from the file when outside it).
  Future<int?> _hexByteAt(int offset) async {
    final i = offset - _anchorOffset;
    if (i >= 0 && i < _hexBytes.length) return _hexBytes[i];
    final doc = _doc;
    if (doc == null) return null;
    final b = await doc.readRangeBytes(offset, 1);
    return b.isEmpty ? null : b[0];
  }

  // Log which syntax highlighter this file uses, so the log shows which grammar was loaded
  // (or why nothing is colored).
  void _logSyntax(String why) {
    final name = _path == null
        ? '(no file)'
        : _path!.split(Platform.pathSeparator).last;
    Log.instance.i(
      'syntax [$why] $name → ${_hl.description}'
      '${_forcedSyntax == null ? '' : ' (forced: $_forcedSyntax)'}',
    );
  }

  // Manual syntax switch from the menubar: 'auto' → automatic, 'plain' → no highlighting,
  // anything else = a WASM language name.
  void _setSyntax(String? mode) {
    _forcedSyntax = mode;
    _hl = _resolveHighlighter();
    _logSyntax('switch');
    _hlWindow = null; // force highlight recompute
    _invalidateFullHl(); // new highlighter → recompute whole-file spans
    if (mounted) setState(() {});
    _bump(); // update the menubar checkmark
  }

  // UI strings (toasts / dialogs / status bar) go through l10n; log strings
  // deliberately stay untranslated.
  AppLocalizations get _l10n => AppLocalizations.of(context);

  int get _selStart => _selAll
      ? 0
      : _selAnchor == null
      ? _caretOffset
      : (_selAnchor! < _caretOffset ? _selAnchor! : _caretOffset);
  int get _selEnd => _selAll
      ? (_doc?.length ?? _caretOffset)
      : _selAnchor == null
      ? _caretOffset
      : (_selAnchor! > _caretOffset ? _selAnchor! : _caretOffset);

  // ── keybinding ──
  final CommandRegistry _registry = CommandRegistry.defaults();
  Resolver? _resolver;
  List<KeyBinding> _effectiveBindings = const [];
  String _keymapName = 'default';
  Timer? _chordTimer;
  int _settingsEpoch = 0; // bumped when settings change, to force a repaint

  // ── View mode (text / column / hex) ───────────────────────────
  ViewMode _viewMode = ViewMode.text;
  bool get _hexMode => _viewMode == ViewMode.hex;
  bool get _columnMode => _viewMode == ViewMode.column;

  // Column mode's rectangular selection (null = nothing selected). The caret itself stays at
  // [_caretOffset] like in text mode, so all the existing navigation keeps working; only what a
  // selection *means* changes — hence the linear [_selAnchor] is unused while a block is active.
  ColumnBlock? _colBlock;

  // Visible bytes in hex mode (start = _anchorOffset, aligned to hexBytesPerRow).
  Uint8List _hexBytes = Uint8List(0);
  // Codec-decoded text column, one cell per byte of _hexBytes (hex_cells.dart).
  List<String> _hexCells = const [];

  // ── encoding ──
  // How the current file's encoding was chosen (for the status bar / log):
  // null = default, otherwise the detector's reasoning; _encManual = user
  // forced it from the menu.
  EncodingGuess? _encGuess;
  // Head sample sniffed as binary at the last auto-detection; a freshly
  // opened binary file starts in hex mode (settings editing.autoHexBinary).
  bool _binaryGuess = false;
  String? _autoHexPath; // the path already auto-switched (not on reopen)
  bool _encManual = false;
  int _hexNibble = 0; // which nibble of the byte the caret is on (0=high, 1=low; used when editing)
  HexArea _hexArea = HexArea.hex; // which column takes input (hex types hex digits, ascii types characters; Tab switches)
  bool _hexInsertMode = false; // false=overwrite (default), true=insert; toggled by the Insert key
  final GlobalKey _hexKey = GlobalKey(); // to reach RenderHexViewport for hit-testing

  // Tell the shell (AppBar/menubar) to rebuild — only at points where the display changes.
  void _bump() => widget.controller._bump();

  // Settings were applied (settings page / settings.json): everything visual is read through
  // getters, so a rebuild + repaint is enough — but the render object only repaints when one of its
  // properties changes, hence [_settingsEpoch]. Line height / font size change how many lines fit
  // and how wide the content is, so reload the window; thresholds changed → redo whole-file spans.
  void _onSettingsChanged() {
    if (!mounted) return;
    _undo.maxSteps = AppSettings.instance.undoMaxSteps;
    Log.instance.d(
      'settings changed → pane "$_name" refresh (font ${AppSettings.instance.fontFamily} '
      '${AppSettings.instance.fontSize}/${AppSettings.instance.lineHeight}, wrap $_wrapMode)',
    );
    if (AppSettings.instance.keymap != _keymapName) {
      _loadKeymap(AppSettings.instance.keymap);
    }
    // The extension → syntax table may have changed: files on automatic
    // syntax re-pick their highlighter (manual picks are left alone).
    if (_forcedSyntax == null && _doc != null) {
      _hl = _resolveHighlighter();
      _logSyntax('settings');
    }
    _invalidateFullHl();
    _hlWindow = null; // force window spans to be recomputed too
    setState(() => _settingsEpoch++);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  // Set the modified flag, notifying the shell only on a real change (so the AppBar is not
  // rebuilt on every keystroke).
  void _setModified(bool v) {
    if (_modified == v) return;
    _modified = v;
    _bump();
  }

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
    _loadKeymap(AppSettings.instance.keymap);
    UserKeymap.instance.addListener(_onUserKeymapChanged);
    AppSettings.instance.addListener(_onSettingsChanged);
    _undo.maxSteps = AppSettings.instance.undoMaxSteps;
    _focus.addListener(_onFocusChange);
    final p = widget.initialPath;
    if (p != null) {
      // Defer loading until after the first frame: _loadDocument calls setState and uses
      // context (the IME needs View.of).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadDocument(
            p,
            caret: widget.initialCaret,
            anchorOffset: widget.initialAnchor,
            keepCodec: widget.initialEncoding,
          ).then((_) => Log.instance.mark('document loaded: $_name'));
        }
      });
    } else if (widget.startBlank) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _newDocument();
      });
    }
  }

  void _onFocusChange() {
    if (_focus.hasFocus) widget.controller.onActivated?.call();
    _syncIme();
    // Focus left (search bar, another pane, a dialog…) or came back: the
    // caret is only drawn while this editor owns the keyboard, so repaint
    // and start/stop the blink timer.
    if (mounted) setState(_restartBlink);
  }

  // Whether the OS window is in the foreground (shell forwards
  // onWindowFocus/onWindowBlur). Flutter keeps the FocusNode focused while
  // the window is inactive, so this is tracked separately.
  bool _windowFocused = true;
  void _setWindowFocused(bool v) {
    if (v == _windowFocused) return;
    _windowFocused = v;
    if (mounted) setState(_restartBlink);
  }

  // While this editor lacks keyboard focus or the window is inactive, the
  // caret (main, extra, column-mode and hex) is drawn steady and dimmed
  // instead of blinking (gVim / terminal convention): the position stays
  // visible, yet the user can tell typing would not land here.
  bool get _caretFocused => _focus.hasFocus && _windowFocused;

  // Decide from focus and mode whether to attach the IME:
  //   - non-modal (default/vscode): attach on focus (typing is always possible).
  //   - modal (vim): attach only in insert mode, otherwise the input connection would
  //     swallow normal/visual navigation keys such as hjkl.
  void _syncIme() {
    final modal = _resolver?.defaultMode != null;
    // Hex mode: only the text column takes text (IME included — a CJK
    // character is encoded with the codec and overwrites that many bytes);
    // the hex column types nibbles through _onKeyHex, so no connection there
    // or every keystroke would arrive twice.
    final want =
        _focus.hasFocus &&
        _doc != null &&
        (!_hexMode || _hexArea == HexArea.ascii) &&
        (!modal || _resolver?.mode == 'insert');
    if (want) {
      _attachIme();
    } else {
      _detachIme();
    }
  }

  Future<Map<String, Object?>> _fetchKeymap(String name) async {
    final s = await loadConfigString('keymaps/$name.json');
    return (jsonDecode(s) as Map).cast<String, Object?>();
  }

  // The user overlay (settings/keymaps/user.json) changed → rebuild the
  // resolver on the current preset.
  void _onUserKeymapChanged() {
    if (mounted) _loadKeymap(_keymapName);
  }

  Future<void> _loadKeymap(String name) async {
    final km = await loadKeymapByName(
      name,
      _fetchKeymap,
      isMac: Platform.isMacOS,
    );
    final user = UserKeymap.instance.bindings;
    final eff = user.isEmpty ? km.bindings : mergeBindings(km.bindings, user);
    if (!mounted) return;
    setState(() {
      _keymapName = name;
      _resolver = Resolver(km, eff, ctrlAsMeta: Platform.isMacOS);
      // Context-menu shortcut labels: this platform's bindings only (the
      // resolver keeps the full list and evaluates `when` itself).
      _effectiveBindings = activeOnPlatform(eff, Platform.operatingSystem);
    });
    _bump(); // keymap name changed → the AppBar's keymap label updates
    _syncIme(); // switching preset may change modality → re-decide whether to attach the IME
  }

  Future<void> _loadCustomKeymap() async {
    final picked = await MacFiles.openFile(extensions: ['json']);
    if (picked == null) return;
    final path = picked.path;
    final j = (jsonDecode(await File(path).readAsString()) as Map)
        .cast<String, Object?>();
    // Import: the file's bindings become the user overlay (settings/
    // keymaps/user.json) — every pane reloads through the listener.
    await UserKeymap.instance.replaceAll(
      Keymap.fromJson(j, isMac: Platform.isMacOS).bindings,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l10n.trf('toast_custom_keymap', [_keymapName])),
        ),
      );
    }
  }

  // ── EditorActions: commands drive the editor through these ──
  @override
  void scrollLines(int n) => _scrollByLines(n);
  @override
  void scrollPages(int n) => _scrollByLines(n * _pageRows);
  @override
  void scrollHalfPages(int n) =>
      _scrollByLines(n * (_fullRowCount ~/ 2 > 0 ? _fullRowCount ~/ 2 : 1));

  // One page = the fully visible rows minus one line of overlap for context.
  int get _pageRows => _fullRowCount - 1 > 0 ? _fullRowCount - 1 : 1;
  @override
  void toTop() {
    _anchorLineExact = true;
    _setAnchor(0, 0);
  }

  @override
  void toBottom() => _jumpFraction(1);
  @override
  void gotoLine(int oneBased) => _gotoLine(oneBased);
  @override
  void setMode(String mode) {
    // vim modes: entering visual anchors the selection at the caret; back to normal clears it.
    if (mode == 'visual') _selAnchor = _caretOffset;
    if (mode == 'normal') _selAnchor = null;
    _undo.breakCoalescing(); // mode change → the next edit is its own undo entry
    _resolver?.mode = mode;
    _syncIme(); // in modal keymaps the IME attaches/detaches on entering/leaving insert
    if (mounted) setState(() {});
  }

  // ── Caret commands (EditorActions; async, serialized on _caretOps) ──
  // Caret ops run one at a time on this chain. A failing op must not poison
  // the chain: `.then` on an errored future skips every later callback, so
  // one exception would silently kill all caret commands for the pane's
  // lifetime. Catch, log, move on.
  void _enqueueCaret(Future<void> Function() op) {
    _caretOps = _caretOps.then((_) async {
      if (_doc == null) return;
      try {
        await op();
      } catch (e, st) {
        Log.instance.w('caret op failed: $e\n$st');
      }
    });
  }

  /// Like [_enqueueCaret] but awaitable, for the save-like operations
  /// (save / save as / convert / reload from disk). Running them ON the
  /// queue is what keeps typing during a save correct: every edit is a
  /// queued op, so anything typed while the file streams out simply waits
  /// and lands in the reopened document instead of in the one being
  /// replaced (where it was written to a stale tree, materialized into the
  /// undo history and then dropped by the reopen).
  Future<void> _runQueued(Future<void> Function() op) {
    final done = Completer<void>();
    _caretOps = _caretOps.then((_) async {
      try {
        await op();
      } catch (e, st) {
        Log.instance.w('queued op failed: $e\n$st');
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  /// Arrow keys are VISUAL: on a row laid out right-to-left (document RTL
  /// layout, or a per-row RTL paragraph) the logical previous character is to
  /// the RIGHT, so ←/→ — and the word jumps — swap their logical direction
  /// there, like Word / Google Docs. Approximation: an LTR run embedded in an
  /// RTL row still moves logically (no bidi run analysis). Column and hex
  /// mode keep the logical mapping (the block's edges must not flip).
  int _visualDir(int dir) {
    if (_hexMode || _columnMode) return dir;
    if (_rtlMode == 2) return -dir;
    final at = _windowRowsAtCaret();
    if (at == null) return dir;
    return isRtlText(at.rows[at.index].text) ? -dir : dir;
  }

  @override
  void caretHorizontal(int dir, int count, bool select) => _enqueueCaret(
    () => _forEachCursor(edit: false, (_) async {
      final d = _visualDir(dir);
      var off = _caretOffset;
      for (var i = 0; i < count; i++) {
        off = d < 0 ? await _doc!.charLeft(off) : await _doc!.charRight(off);
      }
      await _moveCaretTo(off, select);
    }),
  );

  @override
  void caretVertical(int dir, int count, bool select) => _enqueueCaret(
    () => _forEachCursor(edit: false, (_) async {
      final doc = _doc!;
      var off = _caretOffset;
      final curStart = await doc.lineStartOf(off);
      // The goal column is in **display width** (wide chars count 2) so the
      // caret keeps its visual x while moving; column mode's block edges use
      // the same coordinate. When wrapping, it is relative to the caret's
      // visual row, not the logical line.
      await _setGoalColumn(off, curStart);
      for (var i = 0; i < count; i++) {
        off = await _verticalOnce(off, dir);
      }
      await _moveCaretTo(off, select, keepGoal: true);
    }),
  );

  // Remember the caret's display column for vertical moves (no-op when one
  // is already held). Relative to the visual row when wrapping.
  Future<void> _setGoalColumn(int off, int curStart) async {
    if (_goalColumn != null) return;
    final doc = _doc!;
    if (_wrapping) {
      final lr = await _lineRows(curStart);
      if (lr != null) {
        final (d, cuts) = lr;
        final ci = d.codeUnitForByte(off - curStart);
        var k = rowIndexOfChar(cuts, ci);
        if (_caretAtRowEnd && k > 0 && cuts[k] == ci) k--;
        _goalColumn = columnForCharIndex(
          d.text.substring(cuts[k], cuts[k + 1]),
          ci - cuts[k],
          tabSize: _tabSize,
        );
        return;
      }
    }
    _goalColumn = columnCount(
      await doc.readRangeString(curStart, off - curStart),
      tabSize: _tabSize,
    );
  }

  @override
  void caretPage(int dir, bool select) => _enqueueCaret(() async {
    final doc = _doc!;
    final n = _pageRows;
    var off = _caretOffset;
    await _setGoalColumn(off, await doc.lineStartOf(off));
    // Scroll the viewport by the same amount so the caret keeps its screen
    // row (like other editors); _ensureCaretVisible corrects the rest near
    // the file's ends.
    final rowBefore = _caretRowInWindow();
    for (var i = 0; i < n; i++) {
      off = await _verticalOnce(off, dir);
    }
    if (rowBefore >= 0) {
      var a = _anchorOffset;
      for (var i = 0; i < n; i++) {
        final s = dir > 0 ? await _nextRowStart(a) : await _prevRowStart(a);
        if (s == a) break;
        a = s;
      }
      await _anchorTo(a);
    }
    await _moveCaretTo(off, select, keepGoal: true);
  });

  @override
  void caretLineEdge(int dir, bool select) => _enqueueCaret(
    () => _forEachCursor(edit: false, (_) async {
      final doc = _doc!;
      final ls = await doc.lineStartOf(_caretOffset);
      if (_wrapping) {
        // Wrapped: Home/End go to the visual row's edges; pressed again at a
        // row edge they go on to the logical line's edge.
        final lr = await _lineRows(ls);
        if (lr != null) {
          final (d, cuts) = lr;
          final ci = d.codeUnitForByte(_caretOffset - ls);
          var k = rowIndexOfChar(cuts, ci);
          if (_caretAtRowEnd && k > 0 && cuts[k] == ci) k--;
          if (dir < 0) {
            if (k == 0) {
              // First row: smart Home (indentation edge ↔ column 0).
              await _moveCaretTo(await _smartHomeTarget(ls), select);
              return;
            }
            final atRowStart = ci == cuts[k] && !_caretAtRowEnd;
            final target = atRowStart ? 0 : cuts[k];
            await _moveCaretTo(ls + d.byteForCodeUnit(target), select);
          } else {
            final isLast = k + 2 >= cuts.length;
            final atRowEnd = ci == cuts[k + 1] && (isLast || _caretAtRowEnd);
            final target = atRowEnd ? d.text.length : cuts[k + 1];
            final onCut = target < d.text.length; // a cut, not the line end
            await _moveCaretTo(
              ls + d.byteForCodeUnit(target),
              select,
              rowEnd: onCut,
            );
          }
          return;
        }
      }
      final off = dir < 0
          ? await _smartHomeTarget(ls)
          : await doc.lineEndOf(_caretOffset);
      await _moveCaretTo(off, select);
    }),
  );

  // Smart Home (VS Code): the first press goes to the first non-blank
  // character of the line, a press there goes to column 0, and from column
  // 0 it comes back to the indentation edge. A blank line has no
  // indentation edge, so Home is plain column 0 there.
  Future<int> _smartHomeTarget(int ls) async {
    final fnb = await _firstNonBlank(ls);
    if (fnb == ls) return ls;
    return _caretOffset == fnb ? ls : fnb;
  }

  // Offset of the first character that is not a space/tab on the line
  // starting at [ls]; [ls] itself when the line is blank or unreadable.
  // Reads at most 4KB of indentation — enough for any sane line.
  Future<int> _firstNonBlank(int ls) async {
    final doc = _doc!;
    var len = 4096;
    if (ls + len > doc.length) len = doc.length - ls;
    if (len <= 0) return ls;
    final d = await doc.readRangeDecoded(ls, len);
    final t = d.text;
    for (var i = 0; i < t.length; i++) {
      final u = t.codeUnitAt(i);
      if (u == 0x0A || u == 0x0D) return ls; // blank line
      if (u != 0x20 && u != 0x09) return ls + d.byteForCodeUnit(i);
    }
    return ls;
  }

  // ── Expand / shrink selection (shift+alt+→ / ←) ──
  // Levels come from select_expand.dart on a 64KB decoded window around the
  // selection, then the whole document. Every expand pushes the previous
  // anchor/caret so shrink can walk back exactly; the stack is only valid
  // while the selection is still the one the last expand produced.
  final List<(int?, int)> _selStack = [];
  (int, int)? _selStackTop;

  @override
  void expandSelection() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || _columnMode) return;
    final s = _selStart, e = _selEnd;
    if (_selStackTop != (s, e)) _selStack.clear();
    const half = 64 << 10;
    final from = s - half < 0 ? 0 : s - half;
    final to = e + half > doc.length ? doc.length : e + half;
    final d = await doc.readRangeDecoded(from, to - from);
    final r = expandedRange(
      d.text,
      d.codeUnitForByte(s - from),
      d.codeUnitForByte(e - from),
    );
    (int, int)? target;
    if (r != null) {
      target = (from + d.byteForCodeUnit(r.$1), from + d.byteForCodeUnit(r.$2));
    } else if (s > 0 || e < doc.length) {
      target = (0, doc.length);
    }
    if (target == null || target == (s, e)) return;
    _selStack.add((_selAnchor, _caretOffset));
    _colBlock = null;
    _selAnchor = target.$1;
    await _moveCaretTo(target.$2, true);
    _selStackTop = (_selStart, _selEnd);
  });

  @override
  void shrinkSelection() => _enqueueCaret(() async {
    if (_doc == null || _selStack.isEmpty) return;
    if (_selStackTop != (_selStart, _selEnd)) {
      _selStack.clear();
      return;
    }
    final (anchor, caret) = _selStack.removeLast();
    _colBlock = null;
    _selAnchor = anchor;
    await _moveCaretTo(caret, anchor != null && anchor != caret);
    _selStackTop = _selStack.isEmpty ? null : (_selStart, _selEnd);
  });

  // ── Auto-close brackets / quotes (settings editing.autoCloseBrackets) ──
  // Typing an opener inserts the pair and parks the caret between; the
  // closer's offset is remembered so typing it steps over instead of
  // doubling, and Backspace right there removes both. A selection gets
  // wrapped. Quotes only pair when not glued to a word (apostrophes).
  int? _autoClosedAt;
  String? _autoClosedChar;

  static const _closers = {
    '(': ')',
    '[': ']',
    '{': '}',
    '"': '"',
    "'": "'",
    '`': '`',
  };

  Future<String?> _charAfter(Document doc, int off) async {
    if (off >= doc.length) return null;
    final r = await doc.charRight(off);
    return (await doc.readRangeDecoded(off, r - off)).text;
  }

  Future<String?> _charBefore(Document doc, int off) async {
    if (off <= 0) return null;
    final l = await doc.charLeft(off);
    return (await doc.readRangeDecoded(l, off - l)).text;
  }

  bool _wordish(String? c) =>
      c != null && c.isNotEmpty && isWordCodeUnit(c.codeUnitAt(0));

  // True when the keystroke was consumed here (pair inserted, selection
  // wrapped, or closer stepped over).
  Future<bool> _autoCloseTyped(Document doc, String ch) async {
    final s = _selStart, e = _selEnd;
    // Step over the closer this feature inserted a moment ago.
    if (e <= s && _autoClosedAt == _caretOffset && _autoClosedChar == ch) {
      _caretOffset += doc.codec.encode(ch).bytes.length;
      _autoClosedAt = null;
      _selAnchor = null;
      _goalColumn = null;
      if (mounted) setState(_restartBlink);
      return true;
    }
    final close = _closers[ch];
    if (close == null) return false;
    final open = doc.codec.encode(ch).bytes;
    if (e > s) {
      // Wrap the selection; it stays selected (inside the pair).
      final closeBytes = doc.codec.encode(close).bytes;
      _undo.breakCoalescing();
      final r1 = await doc.insertBytes(e, closeBytes);
      final r2 = await doc.insertBytes(s, open);
      _undo.push(ReverseEdit.group([r2, r1]));
      _undo.breakCoalescing();
      _colBlock = null;
      _selAnchor = s + open.length;
      _caretOffset = e + open.length;
      _autoClosedAt = null;
      _goalColumn = null;
      _setModified(_undo.isDirty);
      await _afterEdit();
      return true;
    }
    final next = await _charAfter(doc, _caretOffset);
    if (ch == close) {
      // Quote: not inside a word, and not when the same quote follows
      // (the user is closing by hand).
      final prev = await _charBefore(doc, _caretOffset);
      if (_wordish(prev) || _wordish(next) || next == ch) return false;
    } else if (_wordish(next)) {
      return false; // "(" typed right before an identifier: leave it
    }
    final enc = doc.codec.encode(ch + close);
    final rev = await doc.insertBytes(_caretOffset, enc.bytes);
    _undo.push(rev, coalesce: true);
    _caretOffset += open.length;
    _autoClosedAt = _caretOffset;
    _autoClosedChar = close;
    _selAnchor = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
    return true;
  }

  // Backspace between an auto-inserted pair removes both halves.
  Future<bool> _autoCloseBackspace(Document doc) async {
    final close = _autoClosedChar;
    if (close == null || _autoClosedAt != _caretOffset || _multi) return false;
    final prev = await _charBefore(doc, _caretOffset);
    final next = await _charAfter(doc, _caretOffset);
    if (prev == null || next != close || _closers[prev] != close) return false;
    final l = await doc.charLeft(_caretOffset);
    final r = await doc.charRight(_caretOffset);
    final rev = await doc.delete(l, r - l);
    _undo.push(rev, coalesce: true);
    _caretOffset = l;
    _autoClosedAt = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
    return true;
  }

  // shift+alt+i: a cursor at the end of every line the selection touches
  // (the last one becomes the primary). Without a selection it is just End.
  @override
  void cursorsAtLineEnds() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final s = _selStart, e = _selEnd;
    if (e <= s || _colBlock != null) {
      await _moveCaretTo(await doc.lineEndOf(_caretOffset), false);
      return;
    }
    final ends = <int>[];
    var ls = await doc.lineStartOf(s);
    while (ends.length < maxCursors) {
      ends.add(await doc.lineEndOf(ls));
      final ns = await doc.nextLineStart(ls);
      // A selection ending exactly at a line start does not touch that line.
      if (ns < 0 || ns >= e) break;
      ls = ns;
    }
    _colBlock = null;
    _selAnchor = null;
    _undo.breakCoalescing();
    _caretOffset = ends.removeLast();
    _goalColumn = null;
    _extra = [for (final o in ends) Cursor(o)];
    _syncExtraView();
    if (_multi) _toast(_l10n.trf('toast_cursors', [_extra.length + 1]));
    await _ensureCaretVisible();
    if (mounted) setState(_restartBlink);
  });

  @override
  void caretDocEdge(int dir, bool select) => _enqueueCaret(() async {
    final doc = _doc!;
    var target = dir < 0 ? 0 : doc.length;
    // ctrl+end with the tail folded: the end of the last fold's header is
    // the last visible position (EOF itself would sit inside the fold).
    if (dir > 0 && _eofHidden(target) && _hiddenHeaders.isNotEmpty) {
      target = await doc.lineEndOf(_hiddenHeaders.last);
    }
    await _moveCaretTo(target, select);
  });

  @override
  void copySelection() => _enqueueCaret(() async {
    final blk = _colBlock;
    if (_columnMode && blk != null && !blk.isEmpty) {
      final got = await _blockLines(blk);
      if (got == null) {
        _toast(_l10n.trf('toast_sel_too_large_copy', [_blockMaxBytes >> 20]));
        return;
      }
      final (lines, starts, _) = got;
      // Each line contributes its own slice, joined with newlines (pasting elsewhere yields
      // the same rectangle).
      final text = blockSliceTexts(blk, lines, starts, tabSize: _tabSize).join(_newline);
      await _setClipboard(text);
      _toast(_l10n.trf('toast_block_copied', [lines.length]));
      return;
    }
    if (_multi) {
      final text = await _multiSelectionText();
      if (text == null) return;
      await _setClipboard(text);
      _toast(_l10n.trf('toast_cursors_copied', [_extra.length + 1]));
      return;
    }
    final s = _selStart, e = _selEnd;
    if (e <= s) return;
    final text = await _doc!.readRangeString(s, e - s);
    await _setClipboard(text);
    _toast(_l10n.trf('toast_bytes_copied', [e - s]));
  });

  // Every cursor's selection in document order, one per line (the paste
  // side splits it back one line per cursor). null = nothing selected.
  Future<String?> _multiSelectionText() async {
    final doc = _doc!;
    final all = [Cursor(_caretOffset, anchor: _selAnchor), ..._extra]
      ..sort((a, b) => a.caret.compareTo(b.caret));
    if (!all.any((c) => c.hasSelection)) return null;
    final parts = <String>[];
    for (final c in all) {
      parts.add(
        c.hasSelection
            ? await doc.readRangeString(c.selStart, c.selEnd - c.selStart)
            : '',
      );
    }
    return parts.join(_newline);
  }

  @override
  void cutSelection() => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    final blk = _colBlock;
    if (_columnMode && blk != null && !blk.isEmpty) {
      final got = await _blockLines(blk);
      if (got == null) {
        _toast(_l10n.trf('toast_sel_too_large_copy', [_blockMaxBytes >> 20]));
        return;
      }
      final (lines, starts, _) = got;
      final text = blockSliceTexts(blk, lines, starts, tabSize: _tabSize).join(_newline);
      await _setClipboard(text);
      // Clear the block; pushes its own grouped reverse as one undo step.
      await _doBlockEdit('');
      _toast(_l10n.trf('toast_block_cut', [lines.length]));
      return;
    }
    if (_multi) {
      final text = await _multiSelectionText();
      if (text == null) return;
      await _setClipboard(text);
      _undo.breakCoalescing();
      await _forEachCursor((_) async {
        final s = _selStart, e = _selEnd;
        if (e <= s) return;
        _undo.push(await doc.delete(s, e - s));
        _caretOffset = s;
        _selAnchor = null;
        _goalColumn = null;
      });
      _toast(_l10n.trf('toast_cursors_cut', [_extra.length + 1]));
      return;
    }
    final s = _selStart, e = _selEnd;
    if (e <= s) return;
    final text = await doc.readRangeString(s, e - s);
    await _setClipboard(text);
    _undo.breakCoalescing(); // cut is one undo step of its own
    final rev = await doc.delete(s, e - s);
    _undo.push(rev);
    _undo.breakCoalescing();
    _caretOffset = s;
    _selAnchor = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    _toast(_l10n.trf('toast_bytes_cut', [e - s]));
    await _afterEdit();
  });

  @override
  void newTab() => widget.controller.onNewTab?.call();

  @override
  void newWindow() => widget.controller.onNewWindow?.call();

  @override
  void closeWindow() => widget.controller.onCloseWindow?.call();

  @override
  void openFileDialog() => widget.controller.onOpenFile?.call();

  @override
  void gotoLinePrompt() => _promptGotoLine();

  @override
  void closeTab() => widget.controller.onCloseRequest?.call();

  @override
  void nextTab() => widget.controller.onTabCycle?.call(1);

  @override
  void prevTab() => widget.controller.onTabCycle?.call(-1);

  @override
  void gotoTab(int n) => widget.controller.onTabSelectN?.call(n);

  @override
  void reopenClosedTab() => widget.controller.onReopenClosed?.call();

  @override
  void commandPalette() => widget.controller.onCommandPalette?.call();

  // Delete the caret's logical line, trailing newline included; the last
  // line absorbs the PRECEDING newline instead, so no empty line is left.
  @override
  void deleteLine() => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final start = await doc.lineStartOf(_caretOffset);
    final endContent = await doc.lineEndOf(start);
    // The line's OWN terminator, from the document's line navigation — not
    // _newline's length (detected from the file head): in a CRLF file a lone
    // LF line, or the reverse, deleted one byte too many/few and cut into
    // the next line's first character.
    var s = start, e = endContent;
    if (e < doc.length) {
      e = await doc.nextLineStart(start);
    } else if (s > 0) {
      // Last line: absorb the previous line's terminator instead.
      s = await doc.lineEndOf(await doc.lineStartOf(start - 1));
    }
    if (e <= s) return; // empty document
    _undo.breakCoalescing(); // one line deletion = one undo step
    final rev = await doc.delete(s, e - s);
    _undo.push(rev);
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = null;
    _caretOffset = s > doc.length ? doc.length : s;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  });

  // Duplicate the caret's logical line below itself — byte-exact copy (raw
  // bytes, no decode/re-encode round trip). dir picks which copy keeps the
  // caret: +1 the lower (new) one, -1 the upper (offset unchanged — the
  // insertion happens after it). Same text either way.
  @override
  void duplicateLine(int dir) => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || _hexMode || doc.length == 0) return;
    final start = await doc.lineStartOf(_caretOffset);
    final endContent = await doc.lineEndOf(start);
    final nlBytes = doc.codec.encode(_newline).bytes;
    final lineBytes = await doc.readRangeBytes(start, endContent - start);
    // Inserting "newline + line" at the line's content end needs no special
    // case for the newline-less last line.
    final ins = Uint8List(nlBytes.length + lineBytes.length)
      ..setAll(0, nlBytes)
      ..setAll(nlBytes.length, lineBytes);
    _undo.breakCoalescing(); // one duplication = one undo step
    final rev = await doc.insertBytes(endContent, ins);
    _undo.push(rev);
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = null;
    if (dir > 0) {
      _caretOffset = endContent + nlBytes.length + (_caretOffset - start);
    } // dir < 0: the caret offset is before the insertion — already right
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  });

  // Move the caret's logical line up/down by swapping it with its neighbor
  // — byte-exact: [aStart,bEnd) where B directly follows A becomes B+NL+A
  // (same length, so nothing after shifts). The caret rides along.
  @override
  void indentLines(int dir) => _enqueueCaret(() => _indentLines(dir));

  // Edit → Lines: case conversion acts on the selection (the caret's line
  // without one); the line operations act on the lines the selection covers
  // (the whole document without one; join: the caret's line and the next).
  // The affected range is decoded, transformed (line_ops.dart) and spliced
  // back as one undo step; the result stays selected.
  @override
  void transformLines(String op) => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || _hexMode || _columnMode || doc.length == 0) return;
    final hasSel = _selEnd > _selStart;
    int s, e;
    if (caseOps.contains(op)) {
      if (hasSel) {
        s = _selStart;
        e = _selEnd;
      } else {
        s = await doc.lineStartOf(_caretOffset);
        e = await doc.lineEndOf(s);
      }
    } else if (!lineOps.contains(op)) {
      return;
    } else if (hasSel) {
      s = await doc.lineStartOf(_selStart);
      final lastStart = await doc.lineStartOf(_selEnd - 1);
      final ns = await doc.nextLineStart(lastStart);
      e = ns < 0 ? doc.length : ns; // through the trailing newline
    } else if (op == 'joinLines') {
      s = await doc.lineStartOf(_caretOffset);
      final ns = await doc.nextLineStart(s);
      if (ns < 0) return; // last line: nothing to join
      e = await doc.lineEndOf(ns);
    } else {
      s = 0;
      e = doc.length;
    }
    if (e <= s) return;
    if (e - s > _blockMaxBytes) {
      _toast(_l10n.trf('toast_sel_too_large_copy', [_blockMaxBytes >> 20]));
      return;
    }
    final d = await doc.readRangeDecoded(s, e - s);
    final out = caseOps.contains(op)
        ? applyCaseOp(op, d.text)
        : applyLineOp(op, d.text, _newline);
    if (out == null || out == d.text) return;
    final enc = doc.codec.encode(out);
    _undo.breakCoalescing();
    final reverses = <ReverseEdit>[
      await doc.delete(s, e - s),
      await doc.insertBytes(s, enc.bytes),
    ];
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = s;
    _caretOffset = s + enc.bytes.length;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  });

  @override
  void moveLine(int dir) => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || _hexMode || doc.length == 0) return;
    final s1 = await doc.lineStartOf(_caretOffset);
    final e1 = await doc.lineEndOf(s1);
    // Line boundaries come from the document's own navigation, and the
    // terminator between the two lines is re-used byte for byte: assuming
    // every line ends with _newline (detected from the file head) mis-split
    // a lone LF line inside a CRLF file and swapped a byte of the next line.
    int aStart, aEnd, bStart, bEnd;
    if (dir > 0) {
      bStart = await doc.nextLineStart(s1);
      if (bStart <= e1) return; // last line: nothing below
      aStart = s1;
      aEnd = e1;
      bEnd = await doc.lineEndOf(bStart);
    } else {
      if (s1 == 0) return; // first line: nothing above
      bStart = s1;
      bEnd = e1;
      aStart = await doc.lineStartOf(s1 - 1);
      aEnd = await doc.lineEndOf(aStart);
    }
    final nl = await doc.readRangeBytes(aEnd, bStart - aEnd); // a's terminator
    final aBytes = await doc.readRangeBytes(aStart, aEnd - aStart);
    final bBytes = await doc.readRangeBytes(bStart, bEnd - bStart);
    final repl = Uint8List(bBytes.length + nl.length + aBytes.length)
      ..setAll(0, bBytes)
      ..setAll(bBytes.length, nl)
      ..setAll(bBytes.length + nl.length, aBytes);
    final k = _caretOffset - s1; // offset within the caret's line
    _undo.breakCoalescing(); // one swap = one undo step
    final reverses = <ReverseEdit>[
      await doc.delete(aStart, bEnd - aStart),
      await doc.insertBytes(aStart, repl),
    ];
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = null;
    _caretOffset = dir > 0
        ? aStart +
              (bEnd - bStart) +
              nl.length +
              k // the line moved down
        : aStart + k; // the line moved up
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  });

  // ctrl+/: toggle the line-comment prefix on the caret's line. The prefix
  // comes from the lexer config for the file's extension (settings/
  // highlight.json: lineComment, '//' default) — the manual syntax override
  // is ignored (WASM grammars carry no comment info anyway). Uncommenting
  // also swallows one space after the prefix; commenting inserts one.
  @override
  void toggleComment() => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final path = _path ?? '';
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    final prefix = HighlightConfig.instance.forExt(ext).lineComment;
    if (prefix.isEmpty) return;
    final start = await doc.lineStartOf(_caretOffset);
    final endContent = await doc.lineEndOf(start);
    final d = await doc.readRangeDecoded(start, endContent - start);
    final line = d.text;
    var i = 0;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    _undo.breakCoalescing(); // one toggle = one undo step
    if (line.startsWith(prefix, i)) {
      var delLen = prefix.length;
      if (i + delLen < line.length && line[i + delLen] == ' ') delLen++;
      final sByte = start + d.byteForCodeUnit(i);
      final eByte = start + d.byteForCodeUnit(i + delLen);
      final rev = await doc.delete(sByte, eByte - sByte);
      _undo.push(rev);
      if (_caretOffset > sByte) {
        _caretOffset = _caretOffset >= eByte
            ? _caretOffset - (eByte - sByte)
            : sByte;
      }
    } else {
      final insByte = start + d.byteForCodeUnit(i);
      final enc = doc.codec.encode('$prefix ');
      final rev = await doc.insertBytes(insByte, enc.bytes);
      _undo.push(rev);
      if (_caretOffset >= insByte) _caretOffset += enc.bytes.length;
    }
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  });

  // ctrl+shift+/: wrap the selection (or, with none, the caret line's
  // content) in /* */, or unwrap when both markers are already at the
  // edges. Only the range's two edges are decoded, so a huge selection
  // costs nothing. Languages with blockComment=false (py/sh/…) no-op.
  @override
  void toggleBlockComment() => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final path = _path ?? '';
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    if (!HighlightConfig.instance.forExt(ext).blockComment) return;
    int s, e;
    if (_selEnd > _selStart) {
      s = _selStart;
      e = _selEnd;
    } else {
      s = await doc.lineStartOf(_caretOffset);
      e = await doc.lineEndOf(s);
      // Skip the indent so the marker hugs the content.
      final d = await doc.readRangeDecoded(s, e - s);
      var i = 0;
      while (i < d.text.length && (d.text[i] == ' ' || d.text[i] == '\t')) {
        i++;
      }
      s += d.byteForCodeUnit(i);
    }
    if (e < s) return;
    // Peek at both edges (16 bytes cover the marker + a space in any codec).
    final headLen = (e - s) < 16 ? (e - s) : 16;
    final head = await doc.readRangeDecoded(s, headLen);
    final tailStart = (e - 16) > s ? (e - 16) : s;
    final tail = await doc.readRangeDecoded(tailStart, e - tailStart);
    final ht = head.text, tt = tail.text;
    final wrapped = ht.startsWith('/*') && tt.endsWith('*/');
    _undo.breakCoalescing(); // one toggle = one undo step
    final reverses = <ReverseEdit>[];
    if (wrapped) {
      var leadChars = 2;
      if (leadChars < ht.length && ht[leadChars] == ' ') leadChars++;
      var trailChars = 2;
      if (tt.length > trailChars && tt[tt.length - 3] == ' ') trailChars++;
      final leadEnd = s + head.byteForCodeUnit(leadChars);
      final trailStart =
          tailStart + tail.byteForCodeUnit(tt.length - trailChars);
      if (trailStart < leadEnd) return; // markers overlap (e.g. "/*/")
      // Delete the tail first so the lead offsets stay valid.
      reverses.add(await doc.delete(trailStart, e - trailStart));
      reverses.add(await doc.delete(s, leadEnd - s));
      _caretOffset = s;
    } else {
      final open = doc.codec.encode('/* ').bytes;
      final close = doc.codec.encode(' */').bytes;
      // Insert at the high offset first so the low one stays valid.
      reverses.add(await doc.insertBytes(e, close));
      reverses.add(await doc.insertBytes(s, open));
      _caretOffset = s;
    }
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  });

  @override
  // Select all without moving the caret (see _selAll): the whole document is
  // the selection, the caret stays where the user was working, and no
  // scrolling happens.
  void selectAll() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null) return;
    _clearExtra(); // multi-cursor collapses like any other selection command
    if (_completion != null) _closeCompletion();
    _colBlock = null; // linear selection replaces any rectangular block
    _selAnchor = null;
    _selAll = true;
    _undo.breakCoalescing();
    if (mounted) setState(_restartBlink);
    _bump();
  });

  // Select a byte range and reveal it (find-in-files result click).
  void _selectRange(int start, int end) => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final s = start.clamp(0, doc.length);
    final e = end.clamp(s, doc.length);
    _colBlock = null;
    // A collapsed range (outline / bookmark / search-result jumps pass
    // offset, offset) is a caret move, NOT an empty selection: an anchor
    // left equal to the caret turned the next typed character into a
    // one-character selection that the character after it replaced, and a
    // Backspace into "delete selection" of the wrong text — characters
    // silently lost right after such a jump.
    if (e > s) {
      _selAnchor = s;
    } else {
      _selAnchor = null;
    }
    _undo.breakCoalescing();
    await _moveCaretTo(e, e > s);
  });

  @override
  void findInFiles() => widget.controller.onFindInFiles?.call();

  // ── Macros (recorded by the shell's MacroRecorder; this side feeds steps and plays back) ──

  @override
  void macroRecordToggle() => widget.controller.onMacroRecord?.call();

  @override
  void macroPlay() => widget.controller.onMacroPlay?.call();

  @override
  void toggleExplorer() => widget.controller.onToggleExplorer?.call();

  @override
  void toggleOutline() => widget.controller.onToggleOutline?.call();

  @override
  void toggleWordWrap() => _toggleWrap(); // this pane only

  @override
  void openKeymapEditor() => widget.controller.onKeymapEditor?.call();

  @override
  void printDocument() => widget.controller.onPrint?.call();

  @override
  void menuAction(String action) =>
      widget.controller.onMenuAction?.call(action);

  // ── Navigation history (Go Back / Forward / last edit) ──
  // A "jump" = the caret lands somewhere not currently on screen; the
  // position being left is recorded, so Back returns there. Walking the
  // history itself does not record (see _navigating).
  final NavHistory _nav = NavHistory();
  bool _navigating = false;
  int? _lastEditOffset; // where the most recent edit happened

  Future<void> _navTo(int? off) async {
    if (off == null || _doc == null) return;
    _navigating = true;
    try {
      _colBlock = null;
      _selAnchor = null;
      await _moveCaretTo(off, false);
    } finally {
      _navigating = false;
    }
  }

  @override
  void navBack() => _enqueueCaret(() => _navTo(_nav.back(_caretOffset)));

  @override
  void navForward() => _enqueueCaret(() => _navTo(_nav.forward()));

  @override
  void navLastEdit() => _enqueueCaret(() async {
    final off = _lastEditOffset;
    if (off == null || off == _caretOffset) return;
    _recordJumpFrom(_caretOffset);
    await _navTo(off);
  });

  // Record [from] as a history entry unless we are replaying the history.
  void _recordJumpFrom(int from) {
    if (!_navigating) _nav.record(from);
  }

  @override
  void toggleFoldAtCaret() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || !_hasFolds) return;
    final ls = await doc.lineStartOf(_caretOffset);
    final h = _foldHeaderCovering(ls);
    if (h == null) return;
    if (!_folded.remove(h)) _folded.add(h);
    _caretOffset = h;
    _selAnchor = null;
    await _afterFoldChange();
  });

  @override
  void runExternalPrompt() => widget.controller.onRunPrompt?.call();

  @override
  void runExternalNamed(String name) =>
      widget.controller.onRunNamed?.call(name);

  @override
  void clipboardHistory() => widget.controller.onClipboardHistory?.call();

  @override
  void columnEditor() => widget.controller.onColumnEditor?.call();

  // Every copy/cut goes through here so the clipboard history sees it.
  Future<void> _setClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    ClipboardHistory.instance.add(text);
  }

  // Dynamic-menu items bound to keys (keymap editor): args carry the name.
  @override
  void runScriptNamed(String name) => _runUserScript(name);

  @override
  void setSyntaxNamed(String mode) => _setSyntax(mode == 'auto' ? null : mode);

  @override
  void setEncodingNamed(String name) => _setEncoding(name);

  @override
  void runMacroNamed(String name) => widget.controller.onRunMacro?.call(name);

  // Feed the recorder (a no-op unless it is recording). Hex mode's keys are
  // handled outside the keymap with byte semantics, so nothing is recorded
  // there.
  void _recordStep(MacroStep s) {
    if (_hexMode) return;
    MacroRecorder.instance.add(s);
  }

  bool _macroPlaying = false;
  bool _macroCancel = false;

  // Playback runs through the caret queue like everything else: each
  // iteration is an enqueued check (stop conditions) that dispatches the
  // steps — which enqueue their own work — and then enqueues the next
  // check behind them. Grouped into one undo step (nesting with the
  // multi-cursor groups inside).
  void _playMacro(Macro m, {int times = 1, bool untilEof = false}) {
    if (_doc == null || _hexMode || m.steps.isEmpty || _macroPlaying) return;
    _macroPlaying = true;
    _macroCancel = false;
    final done = Completer<void>();
    var runs = 0;
    int? lastCaret, lastLen;
    _enqueueCaret(() async => _undo.beginGroup());
    void finish() => _enqueueCaret(() async {
      _undo.endGroup();
      _undo.breakCoalescing();
      _macroPlaying = false;
      _setModified(_undo.isDirty);
      done.complete();
      if (mounted) setState(() {});
      _toast(_l10n.trf('macro_played', [runs]));
    });
    void iteration() => _enqueueCaret(() async {
      final doc = _doc;
      var stop =
          doc == null ||
          _macroCancel ||
          (!untilEof && runs >= times) ||
          runs >= 1000000;
      if (!stop && untilEof && runs > 0) {
        stop =
            (lastCaret == _caretOffset && lastLen == doc.length) ||
            _caretOffset >= doc.length;
      }
      if (stop) {
        finish();
        return;
      }
      lastCaret = _caretOffset;
      lastLen = doc!.length;
      runs++;
      for (final s in m.steps) {
        _runMacroStep(s);
      }
      iteration();
    });
    iteration();
    _showBusyAfter(
      done.future,
      _l10n.tr('macro_busy_title'),
      _l10n.tr('macro_busy_body'),
      onCancel: () => _macroCancel = true,
    );
  }

  void _runMacroStep(MacroStep s) {
    switch (s) {
      case MacroCommand():
        _registry.dispatch(s.name, this, s.args, s.count);
      case MacroInsert():
        _enqueueCaret(() => _forEachCursor((_) => _doInsert(s.text)));
      case MacroKey():
        switch (s.key) {
          case 'backspace':
            _enqueueCaret(() => _forEachCursor((_) => _doBackspace()));
          case 'delete':
            _enqueueCaret(() => _forEachCursor((_) => _doDeleteForward()));
          case 'tab':
            _enqueueCaret(() => _forEachCursor((_) => _tabKey()));
          case 'shiftTab':
            _enqueueCaret(() => _indentLines(-1));
        }
    }
  }

  // ── Bracket matching (highlight + ctrl+m jump) ────────────────────────

  /// The highlighted pair: [caret-side bracket, its match] byte offsets
  /// (empty = none). Reassigned as a fresh list so the painter's
  /// identical-check sees changes.
  List<int> _bracketPair = const [];
  Timer? _bracketTimer;
  int _bracketEpoch = 0;

  // Debounced: rapid caret movement must not stack up 4MB scans.
  void _scheduleBracketMatch() {
    _bracketTimer?.cancel();
    _bracketTimer = Timer(
      const Duration(milliseconds: 80),
      _computeBracketMatch,
    );
  }

  // Bracket at the caret wins; the char just before the caret is the
  // fallback (the usual "cursor right after a closing bracket" case).
  Future<(int, int)?> _bracketAtCaret() async {
    final doc = _doc;
    if (doc == null || _hexMode) return null;
    final caret = _caretOffset;
    var m = await findMatchingBracket(doc, caret);
    if (m != null) return (caret, m);
    if (caret > 0) {
      final prev = await doc.charLeft(caret);
      m = await findMatchingBracket(doc, prev);
      if (m != null) return (prev, m);
    }
    return null;
  }

  // Timer-driven readers (bracket match, word scan, fold refresh, the status
  // bar's caret position, highlight sync) run OUTSIDE the caret queue, so
  // the document can be replaced (reload) or have its handle suspended (a
  // save's atomic replace) under them; the read then fails with a
  // FileSystemException. That is expected in those moments — the work is
  // dropped and the reopened document redoes it — and only otherwise worth
  // a warning. (Found by edit_undo_fuzz_test's save op: the exception
  // escaped as an unhandled error.)
  Future<void> _offQueue(String what, Future<void> Function() body) async {
    final d = _doc;
    try {
      await body();
    } on FileSystemException catch (e) {
      if (_saving || !identical(_doc, d)) {
        Log.instance.d('$what: document replaced/suspended mid-read ($e)');
      } else {
        Log.instance.w('$what failed: $e');
      }
    }
  }

  Future<void> _computeBracketMatch() =>
      _offQueue('bracket match', _computeBracketMatchNow);

  Future<void> _computeBracketMatchNow() async {
    final epoch = ++_bracketEpoch;
    final pair = await _bracketAtCaret();
    if (!mounted || epoch != _bracketEpoch) return;
    final next = pair == null ? const <int>[] : [pair.$1, pair.$2];
    if (next.length != _bracketPair.length ||
        (next.isNotEmpty &&
            (next[0] != _bracketPair[0] || next[1] != _bracketPair[1]))) {
      setState(() => _bracketPair = next);
    }
  }

  // Quick font zoom: bump the global zoom factor (every pane re-renders via the
  // settings listener) and flash the new percentage. The toast replaces the
  // previous one instead of queueing — a wheel burst would otherwise stack
  // seconds of snackbars.
  @override
  void zoomFont(int steps) {
    AppSettings.instance.zoomFont(steps);
    if (!mounted) return;
    final pct = (AppSettings.instance.fontZoom * 100).round();
    final m = ScaffoldMessenger.of(context);
    m.removeCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(_l10n.trf('toast_zoom', [pct])),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  @override
  void matchBracket() => _enqueueCaret(() async {
    final pair = await _bracketAtCaret();
    if (pair == null) return;
    _colBlock = null;
    _selAnchor = null;
    await _moveCaretTo(pair.$2, false);
  });

  // ── Word count (View menu) ──────────────────────────────────

  // Count the (linear) selection when there is one, the whole document
  // otherwise. The dialog streams the range chunk by chunk with a progress
  // bar (a GB file takes a while) and stops counting when dismissed.
  void _showWordCount() {
    final doc = _doc;
    if (doc == null) return;
    final s = _selStart, e = _selEnd;
    final hasSel = _colBlock == null && e > s && !_hexMode;
    showDialog<void>(
      context: context,
      builder: (_) => _WordCountDialog(
        doc: doc,
        start: hasSel ? s : 0,
        end: hasSel ? e : doc.length,
        selection: hasSel,
      ),
    );
  }

  // ── Context menu ─────────────────────────────────────────────
  // A fixed set of common editor commands (dispatched through the command
  // registry, so they behave exactly like their keys) with the live shortcut
  // labels from the effective keymap. A right-click outside the selection
  // first moves the caret there (like every other editor); inside it keeps
  // the selection so cut/copy apply to it.
  String _shortcutLabelFor(String command) {
    final pick = labelBindingFor(
      _effectiveBindings,
      command,
      mode: _resolver?.mode,
    );
    return pick == null ? '' : chordsLabel(pick.chords);
  }

  Future<void> _showContextMenu(Offset local, Offset global) async {
    final doc = _doc;
    if (doc == null) return;
    _closeCompletion();
    if (!_hexMode) {
      // Outside the selection → caret goes there.
      final off = _offsetAt(local);
      if (off != null &&
          !(_selEnd > _selStart && off >= _selStart && off < _selEnd)) {
        await _moveCaretTo(off, false);
      }
    }
    if (!mounted) return;
    final l10n = _l10n;
    final hasSel = _selEnd > _selStart;
    final ro = _readOnly;
    PopupMenuItem<String> item(
      String labelKey,
      String command, {
      bool enabled = true,
      IconData? icon,
    }) => PopupMenuItem<String>(
      value: command,
      enabled: enabled,
      height: AppSettings.instance.menuRowHeight,
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: icon == null ? null : Icon(icon, size: 16),
          ),
          Expanded(child: Text(l10n.tr(labelKey))),
          const SizedBox(width: 24),
          Text(
            _shortcutLabelFor(command),
            style: TextStyle(
              fontSize: 11.5,
              color: Theme.of(context).disabledColor,
            ),
          ),
        ],
      ),
    );
    final items = <PopupMenuEntry<String>>[
      item(
        'item_undo',
        'edit.undo',
        enabled: !ro && _undo.canUndo,
        icon: Icons.undo,
      ),
      item(
        'item_redo',
        'edit.redo',
        enabled: !ro && _undo.canRedo,
        icon: Icons.redo,
      ),
      const PopupMenuDivider(),
      item(
        'item_cut',
        'edit.cut',
        enabled: !ro && hasSel,
        icon: Icons.content_cut,
      ),
      item('item_copy', 'edit.copy', enabled: hasSel, icon: Icons.content_copy),
      item(
        'item_paste',
        'edit.paste',
        enabled: !ro && !_hexMode,
        icon: Icons.content_paste,
      ),
      item('ctx_delete', 'ctx.delete', enabled: !ro && hasSel),
      const PopupMenuDivider(),
      item('item_select_all', 'edit.selectAll'),
      if (!_hexMode) ...[
        const PopupMenuDivider(),
        item('item_find', 'search.find', icon: Icons.search),
        item(
          'item_replace',
          'search.replace',
          enabled: !ro,
          icon: Icons.find_replace,
        ),
        item('item_goto_line', 'search.gotoLine'),
        const PopupMenuDivider(),
        item(
          'item_bookmark_toggle',
          'bookmark.toggle',
          icon: Icons.bookmark_add_outlined,
        ),
        item('item_toggle_comment', 'edit.toggleComment', enabled: !ro),
        item('item_upper', 'edit.upper', enabled: !ro),
        item('item_lower', 'edit.lower', enabled: !ro),
        if (_hasFolds) ...[
          const PopupMenuDivider(),
          item('item_fold', 'fold.fold'),
          item('item_unfold', 'fold.unfold'),
        ],
      ],
    ];
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        global.dx,
        global.dy,
        global.dx,
        global.dy,
      ),
      items: items,
    );
    if (!mounted || choice == null) return;
    _focus.requestFocus();
    if (choice == 'ctx.delete') {
      _enqueueCaret(() => _forEachCursor((_) => _doDeleteForward()));
      return;
    }
    _registry.dispatch(choice, this, null, 1);
    _recordStep(MacroCommand(choice));
  }

  // ── Autocomplete / word completion ───────────────────────────────────
  // Candidates = the document's own words (word_index.dart, rescanned with a
  // debounce after edits/loads, first 8MB) + the language's keywords. The
  // popup opens as you type once the word prefix reaches the configured
  // length (or on ctrl+space), follows further typing / backspace, and
  // Enter / Tab accept; any caret move or click closes it.
  Set<String> _words = const {};
  Timer? _wordScanTimer;
  int _wordScanSerial = 0;
  _CompletionState? _completion;

  void _scheduleWordScan() {
    if (!AppSettings.instance.autoComplete && _completion == null) return;
    _wordScanTimer?.cancel();
    _wordScanTimer = Timer(const Duration(milliseconds: 1200), _scanWords);
  }

  Future<void> _scanWords() => _offQueue('word scan', _scanWordsNow);

  Future<void> _scanWordsNow() async {
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final serial = ++_wordScanSerial;
    final words = await scanDocumentWords(
      doc,
      cancelled: () => serial != _wordScanSerial,
    );
    if (!mounted || serial != _wordScanSerial) return;
    _words = words;
  }

  Set<String> get _languageKeywords {
    final p = _path;
    if (p == null) return const {};
    final dot = p.lastIndexOf('.');
    final ext = dot >= 0 ? p.substring(dot + 1).toLowerCase() : '';
    return HighlightConfig.instance.forExt(ext).keywords;
  }

  // The identifier prefix before the caret (null when the line is too long
  // to read cheaply or the caret is not right after a word).
  Future<String?> _wordPrefixAtCaret() async {
    final doc = _doc;
    if (doc == null) return null;
    final ls = await doc.lineStartOf(_caretOffset);
    final len = _caretOffset - ls;
    if (len <= 0 || len > 4096) return len <= 0 ? '' : null;
    final d = await doc.readRangeDecoded(ls, len);
    return wordPrefixBefore(d.text, d.text.length);
  }

  // After a keystroke landed: open / refresh / close the popup.
  Future<void> _completionAfterTyping(String typed) async {
    final s = AppSettings.instance;
    if (_hexMode || _readOnly || _composing.isNotEmpty || _multi) {
      _closeCompletion();
      return;
    }
    final open = _completion != null;
    if (!open) {
      if (!s.autoComplete) return;
      // Only a typed word character opens it (not paste, Enter, space…).
      if (typed.length != 1 || !isWordCodeUnit(typed.codeUnitAt(0))) return;
    }
    final prefix = await _wordPrefixAtCaret();
    if (prefix == null || prefix.isEmpty) {
      _closeCompletion();
      return;
    }
    if (!open && prefix.length < s.autoCompleteMinChars) return;
    if (_words.isEmpty && _wordScanTimer == null) {
      await _scanWords(); // first use on this document
    }
    _showCompletion(prefix, manual: false);
  }

  void _showCompletion(String prefix, {required bool manual}) {
    final items = completionsFor(
      _words,
      prefix,
      keywords: _languageKeywords,
      max: 12,
    );
    if (items.isEmpty) {
      _closeCompletion();
      if (manual) _toast(_l10n.tr('toast_no_completion'));
      return;
    }
    final pos = _caretScreenPos();
    if (pos == null) {
      _closeCompletion();
      return;
    }
    final prev = _completion;
    setState(() {
      _completion = _CompletionState(
        prefix: prefix,
        items: items,
        selected: prev != null && prev.selected < items.length
            ? prev.selected
            : 0,
        anchor: pos,
      );
    });
  }

  void _closeCompletion() {
    if (_completion == null) return;
    if (mounted) setState(() => _completion = null);
  }

  void _acceptCompletion([int? index]) {
    final c = _completion;
    if (c == null) return;
    final i = index ?? c.selected;
    if (i < 0 || i >= c.items.length) return;
    final word = c.items[i].word;
    final prefix = c.prefix;
    _closeCompletion();
    // Replace the typed prefix (case may differ) with the whole word.
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null) return;
      final tail = word.startsWith(prefix)
          ? word.substring(prefix.length)
          : null;
      if (tail != null) {
        await _forEachCursor((_) => _doInsert(tail));
      } else {
        await _forEachCursor((_) async {
          final ls = await doc.lineStartOf(_caretOffset);
          final len = _caretOffset - ls;
          final d = await doc.readRangeDecoded(ls, len);
          final p = wordPrefixBefore(d.text, d.text.length);
          final pStart = ls + d.byteForCodeUnit(d.text.length - p.length);
          _selAnchor = pStart;
          await _doInsert(word); // replaces the selection
        });
      }
    });
  }

  // Pixel position just below the caret (viewport coordinates).
  Offset? _caretScreenPos() {
    final win = _window;
    if (win == null) return null;
    // From _window, not _rows: this runs right after an edit, before the
    // frame that rebuilds _rows (see _windowRowsAtCaret).
    final at = _windowRowsAtCaret();
    if (at == null) return null;
    final row = at.index;
    final r = at.rows[row];
    final within = (_caretOffset - r.offset).clamp(0, r.contentBytes);
    final para = _buildLine(
      r.text,
      _layoutMaxW,
      null,
      _rowStartColumn(win, r),
      _baseRtl,
    );
    final gw = _gutterWidthFor(_anchorLine, win.lines.length);
    _ensureContentW(); // the row shift in RTL layout depends on it
    return Offset(
      gw +
          _gutterPad +
          _rowShift(para) +
          para.xOf(r.charOfByte(within)) -
          _scrollX,
      (row + 1) * _lineHeight,
    );
  }

  // Keys the popup owns while open. True = consumed.
  bool _completionKey(KeyEvent e) {
    final c = _completion;
    if (c == null) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      _closeCompletion();
      return true;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.tab) {
      _acceptCompletion();
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final n = c.items.length;
      final d = k == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() => c.selected = (c.selected + d + n) % n);
      return true;
    }
    if (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.pageUp) {
      final n = c.items.length;
      final d = k == LogicalKeyboardKey.pageDown ? 6 : -6;
      setState(() => c.selected = (c.selected + d).clamp(0, n - 1));
      return true;
    }
    // Anything else that moves the caret (Home/End/←/→) closes it; typing
    // keeps it open and re-filters through _completionAfterTyping.
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.home ||
        k == LogicalKeyboardKey.end) {
      _closeCompletion();
    }
    return false;
  }

  @override
  void triggerCompletion() => _enqueueCaret(() async {
    if (_doc == null || _hexMode || _readOnly) return;
    final prefix = await _wordPrefixAtCaret();
    if (prefix == null || prefix.isEmpty) return;
    if (_words.isEmpty) await _scanWords();
    _showCompletion(prefix, manual: true);
  });

  Widget _completionPopup() {
    final c = _completion!;
    const w = 260.0;
    const rowH = 24.0;
    final h = c.items.length * rowH + 4;
    var left = c.anchor.dx;
    if (left + w > _viewportW) left = (_viewportW - w).clamp(0.0, left);
    var top = c.anchor.dy;
    if (top + h > _viewportH && c.anchor.dy - _lineHeight - h >= 0) {
      top = c.anchor.dy - _lineHeight - h; // not enough room below: above
    }
    final theme = Theme.of(context);
    return Positioned(
      left: left,
      top: top,
      width: w,
      height: h,
      child: Material(
        key: const ValueKey('completion-popup'),
        elevation: 6,
        borderRadius: BorderRadius.circular(4),
        color: theme.colorScheme.surfaceContainerHigh,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 2),
          itemExtent: rowH,
          itemCount: c.items.length,
          itemBuilder: (_, i) {
            final it = c.items[i];
            final sel = i == c.selected;
            return InkWell(
              onTap: () => _acceptCompletion(i),
              child: Container(
                color: sel
                    ? theme.colorScheme.primary.withValues(alpha: 0.25)
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(
                      it.keyword ? Icons.key : Icons.text_fields,
                      size: 14,
                      color: theme.disabledColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: RichText(
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: TextStyle(
                            fontFamily: editorMonoFont,
                            fontSize: 13,
                            color: theme.colorScheme.onSurface,
                          ),
                          children: [
                            TextSpan(
                              text: it.word.substring(0, c.prefix.length),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextSpan(text: it.word.substring(c.prefix.length)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Code folding (tree-sitter syntax tree) ────────────────────────
  // Fold regions come from the whole-file highlight session's tree
  // (RustHighlighter sessions only, so files ≤ wholeFileHlMaxMB with a
  // tree-sitter grammar). Kept as BYTE offsets so edits shift them like
  // bookmarks: header line start → [hiddenStart, hiddenEnd) = start of the
  // first hidden line .. start of the first visible line after. Rebuilt
  // (debounced) after every highlight sync; collapsed headers survive
  // rebuilds when a region still starts there. Hidden lines are skipped at
  // the window level (_readVisibleWindow) and by row/line navigation.
  Map<int, (int, int)> _foldRanges = {};
  final Set<int> _folded = {};
  List<(int, int)> _hidden = const []; // merged, sorted
  List<int> _hiddenHeaders = const []; // header of each merged range
  Set<int> _foldableView = const {};
  Set<int> _foldedView = const {};
  Timer? _foldTimer;
  int _foldSerial = 0;

  bool get _hasFolds => _foldRanges.isNotEmpty;

  void _clearFolds() {
    _foldTimer?.cancel();
    _foldSerial++;
    if (_foldRanges.isEmpty && _folded.isEmpty) return;
    final hadHidden = _hidden.isNotEmpty;
    _foldRanges = {};
    _folded.clear();
    _recomputeHidden();
    // Hidden lines are skipped when the window is READ, so the painted
    // window still lacks them until it is re-read: switching syntax away
    // from the grammar that owned a collapsed region left its lines
    // invisible with no chevron left to open them.
    if (hadHidden && _doc != null) unawaited(_reload());
  }

  void _scheduleFoldRefresh() {
    _foldTimer?.cancel();
    _foldTimer = Timer(const Duration(milliseconds: 400), _refreshFolds);
  }

  Future<void> _refreshFolds() => _offQueue('fold refresh', _refreshFoldsNow);

  Future<void> _refreshFoldsNow() async {
    final session = _hlSession;
    final doc = _doc;
    if (session == null || doc == null || _hexMode) {
      _clearFolds();
      return;
    }
    final serial = ++_foldSerial;
    final editSerial = _editSerial;
    final rows = await session.folds();
    if (!mounted || serial != _foldSerial) return;
    if (rows == null) {
      _clearFolds();
      return;
    }
    // Rows → byte offsets in one pass over the line starts.
    final need = <int>{};
    for (final f in rows) {
      need
        ..add(f.startRow)
        ..add(f.startRow + 1)
        ..add(f.endRow + 1);
    }
    final offsets = await _lineStartOffsets(doc, need);
    if (!mounted || serial != _foldSerial) return;
    if (editSerial != _editSerial) {
      _scheduleFoldRefresh(); // edited mid-pass: the next sync redoes it
      return;
    }
    final next = <int, (int, int)>{};
    for (final f in rows) {
      final h = offsets[f.startRow];
      final s = offsets[f.startRow + 1];
      final e = offsets[f.endRow + 1] ?? doc.length;
      if (h == null || s == null || s <= h || e <= s) continue;
      next.putIfAbsent(h, () => (s, e));
    }
    _foldRanges = next;
    final before = _folded.length;
    _folded.removeWhere((h) => !next.containsKey(h));
    _recomputeHidden();
    // A collapsed region that no longer exists (new grammar, edits) was
    // hidden at read time: re-read the window so its lines come back.
    if (_folded.length != before) unawaited(_reload());
    if (mounted) setState(() {});
  }

  // Byte offset of each requested line start (missing when past the end).
  Future<Map<int, int>> _lineStartOffsets(Document doc, Set<int> rows) async {
    final out = <int, int>{};
    if (rows.isEmpty) return out;
    final wanted = rows.toList()..sort();
    var wi = 0;
    var pos = 0, line = 0;
    const chunk = 4096;
    while (wi < wanted.length) {
      final w = await doc.readWindow(pos, chunk, startLine: line);
      if (w.lines.isEmpty) break;
      final end = line + w.lines.length;
      while (wi < wanted.length && wanted[wi] < end) {
        final r = wanted[wi];
        if (r >= line) out[r] = w.offsets[r - line];
        wi++;
      }
      if (w.atEof) {
        // One past the last line = end of document.
        while (wi < wanted.length) {
          if (wanted[wi] == end) out[wanted[wi]] = doc.length;
          wi++;
        }
        break;
      }
      pos = w.nextOffset;
      line = end;
    }
    return out;
  }

  // Merge the collapsed regions into sorted, non-overlapping hidden ranges.
  void _recomputeHidden() {
    final parts = <(int, int, int)>[
      for (final h in _folded)
        if (_foldRanges[h] case final r?) (r.$1, r.$2, h),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    final heads = <int>[];
    for (final p in parts) {
      if (merged.isNotEmpty && p.$1 <= merged.last.$2) {
        final last = merged.last;
        if (p.$2 > last.$2) merged[merged.length - 1] = (last.$1, p.$2);
      } else {
        merged.add((p.$1, p.$2));
        heads.add(p.$3);
      }
    }
    _hidden = merged;
    _hiddenHeaders = heads;
    _foldableView = Set.unmodifiable(_foldRanges.keys.toSet());
    _foldedView = Set.unmodifiable(_folded);
  }

  /// The hidden range containing [offset], or null.
  (int, int)? _hiddenRangeContaining(int offset) {
    final h = _hidden;
    if (h.isEmpty) return null;
    var lo = 0, hi = h.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (h[mid].$2 <= offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < h.length && h[lo].$1 <= offset && offset < h[lo].$2) return h[lo];
    return null;
  }

  // The last fold swallowed the document tail (its hidden range reaches
  // EOF): [offset] == length then has no visible row to sit on, so caret
  // moves must stop on that fold's header instead of stepping past it.
  bool _eofHidden(int offset) {
    final doc = _doc;
    return doc != null &&
        offset >= doc.length &&
        _hidden.isNotEmpty &&
        _hidden.last.$2 >= doc.length;
  }

  // A line start that is hidden → the first visible line start after it
  // (dir > 0) or the fold header (dir < 0).
  Future<int> _skipHiddenLine(int lineStart, int dir) async {
    final h = _hiddenRangeContaining(lineStart);
    if (h == null) return lineStart;
    if (dir > 0) return h.$2;
    final doc = _doc!;
    return h.$1 == 0 ? 0 : doc.lineStartOf(h.$1 - 1);
  }

  // Document.onSplice: shift the fold table with every edit (like bookmarks);
  // the next highlight sync rebuilds it from the tree anyway.
  void _spliceFolds(int offset, int delta) {
    if (_foldRanges.isEmpty || delta == 0) return;
    int mv(int x) {
      if (x < offset) return x;
      if (delta > 0) return x + delta;
      final end = offset - delta;
      return x >= end ? x + delta : offset;
    }

    final next = <int, (int, int)>{};
    for (final e in _foldRanges.entries) {
      final h = mv(e.key), s = mv(e.value.$1), en = mv(e.value.$2);
      if (s > h && en > s) next.putIfAbsent(h, () => (s, en));
    }
    final folded = _folded.map(mv).where(next.containsKey).toSet();
    _foldRanges = next;
    _folded
      ..clear()
      ..addAll(folded);
    _recomputeHidden();
  }

  // The window the viewport shows: consecutive lines with collapsed regions
  // left out. Each line carries its absolute number (the window is no
  // longer contiguous); nextOffset is where the last shown line ends.
  Future<DocWindow> _readVisibleWindow(
    Document doc,
    int offset,
    int count,
    int line,
  ) async {
    if (_hidden.isEmpty) return doc.readWindow(offset, count, startLine: line);
    var pos = offset;
    var ln = line;
    final start = _hiddenRangeContaining(pos);
    if (start != null) {
      pos = start.$2;
      ln = ln >= 0 ? (await doc.absoluteLineAt(pos)).line : -1;
    }
    final lines = <String>[];
    final offsets = <int>[];
    final maps = <Uint32List>[];
    final nums = <int>[];
    var nextOffset = pos;
    var atEof = false;
    while (lines.length < count) {
      final w = await doc.readWindow(pos, count - lines.length, startLine: ln);
      if (w.lines.isEmpty) {
        atEof = w.atEof;
        if (lines.isEmpty) nextOffset = w.nextOffset;
        break;
      }
      var skipTo = -1;
      for (var i = 0; i < w.lines.length; i++) {
        final o = w.offsets[i];
        final h = _hiddenRangeContaining(o);
        if (h != null) {
          skipTo = h.$2;
          nextOffset = o; // the previous line ended where the hidden one starts
          break;
        }
        lines.add(w.lines[i]);
        offsets.add(o);
        maps.add(w.maps[i]);
        nums.add(ln >= 0 ? ln + i : -1);
      }
      if (skipTo < 0) {
        nextOffset = w.nextOffset;
        atEof = w.atEof;
        if (w.atEof) break;
        pos = w.nextOffset;
        ln = ln >= 0 ? ln + w.lines.length : -1;
      } else {
        if (skipTo >= doc.length) {
          atEof = true;
          break;
        }
        pos = skipTo;
        ln = ln >= 0 ? (await doc.absoluteLineAt(pos)).line : -1;
      }
    }
    return DocWindow(
      offset,
      line,
      lines,
      offsets,
      nextOffset,
      atEof,
      maps: maps,
      lineNumbers: nums,
    );
  }

  // Innermost fold region whose header or hidden lines cover [lineStart].
  int? _foldHeaderCovering(int lineStart) {
    if (_foldRanges.containsKey(lineStart)) return lineStart;
    int? best;
    for (final e in _foldRanges.entries) {
      if (e.key < lineStart && lineStart < e.value.$2) {
        if (best == null || e.key > best) best = e.key;
      }
    }
    return best;
  }

  // [scrollToCaret] is off for gutter clicks and fold-all / unfold-all: the
  // user is looking at the rows being folded, and a caret parked elsewhere
  // must not yank the view away (the caret may end up off screen; the next
  // caret move brings it back into view as usual).
  Future<void> _afterFoldChange({bool scrollToCaret = true}) async {
    _recomputeHidden();
    _undo.breakCoalescing();
    await _reload();
    if (scrollToCaret) await _ensureCaretVisible();
    if (mounted) setState(_restartBlink);
  }

  Future<void> _unfoldCovering(int lineStart) async {
    var changed = false;
    for (final h in _folded.toList()) {
      final r = _foldRanges[h];
      // A fold reaching EOF also covers the (rowless) EOF position itself.
      if (r != null &&
          r.$1 <= lineStart &&
          (lineStart < r.$2 || (lineStart == r.$2 && _eofHidden(r.$2)))) {
        _folded.remove(h);
        changed = true;
      }
    }
    if (changed) {
      _recomputeHidden();
      await _reload();
      if (mounted) setState(() {});
    }
  }

  void _toggleFold(int header) => _enqueueCaret(() async {
    if (!_foldRanges.containsKey(header)) return;
    if (!_folded.remove(header)) _folded.add(header);
    // A gutter click acts like a click on that row: the caret moves to the
    // header (so it is never inside the hidden lines, and the view stays put
    // instead of scrolling to wherever the caret was).
    _caretOffset = header;
    _selAnchor = null;
    _goalColumn = null;
    if (_multi) _clearExtra(); // a jump collapses the extra cursors
    if (_completion != null) _closeCompletion();
    await _afterFoldChange(scrollToCaret: false);
  });

  // Gutter chevron click → toggle that row's fold. True when handled.
  bool _foldGutterTap(Offset local) {
    final win = _window;
    if (win == null || _foldRanges.isEmpty || _rows.isEmpty) return false;
    final gw = _gutterWidthFor(_anchorLine, win.lines.length);
    if (local.dx < gw - 16 || local.dx >= gw) return false;
    final row = (local.dy / _lineHeight).floor();
    if (row < 0 || row >= _rows.length) return false;
    final r = _rows[row];
    if (!r.isFirst || !_foldRanges.containsKey(r.offset)) return false;
    _toggleFold(r.offset);
    return true;
  }

  @override
  void foldAtCaret() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || !_hasFolds) return;
    final ls = await doc.lineStartOf(_caretOffset);
    final h = _foldHeaderCovering(ls);
    if (h == null || _folded.contains(h)) return;
    _folded.add(h);
    _caretOffset = h;
    _selAnchor = null;
    if (_multi) _clearExtra();
    if (_completion != null) _closeCompletion();
    await _afterFoldChange();
  });

  @override
  void unfoldAtCaret() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || _folded.isEmpty) return;
    final ls = await doc.lineStartOf(_caretOffset);
    if (!_folded.remove(ls)) {
      // Not on a header: open the innermost collapsed region around here.
      int? best;
      for (final h in _folded) {
        final r = _foldRanges[h];
        if (r != null && h < ls && ls < r.$2 && (best == null || h > best)) {
          best = h;
        }
      }
      if (best == null) return;
      _folded.remove(best);
    }
    await _afterFoldChange();
  });

  @override
  void foldAll() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || !_hasFolds) return;
    _folded.addAll(_foldRanges.keys);
    _recomputeHidden();
    // Caret inside a region → the outermost header covering it.
    final ls = await doc.lineStartOf(_caretOffset);
    final h = _hiddenRangeContaining(ls);
    if (h != null) {
      final i = _hidden.indexOf(h);
      _caretOffset = _hiddenHeaders[i];
      _selAnchor = null;
    }
    await _afterFoldChange(scrollToCaret: false);
  });

  @override
  void unfoldAll() => _enqueueCaret(() async {
    if (_folded.isEmpty) return;
    _folded.clear();
    await _afterFoldChange(scrollToCaret: false);
  });

  // ── Bookmarks (line-start byte offsets) ──────────────────────────────

  final Set<int> _bookmarks = {};
  Set<int> _bookmarksView = const {}; // immutable snapshot for the painter
  String? _bookmarksPath; // which file the set belongs to
  bool _initialBookmarksUsed = false; // widget.initialBookmarks consumed once

  void _bookmarksChanged() {
    _bookmarksView = Set.unmodifiable(_bookmarks);
    if (mounted) setState(() {});
    widget.controller.bookmarksEpoch.value++; // bookmark panel refresh
  }

  void _removeBookmark(int offset) {
    if (_bookmarks.remove(offset)) _bookmarksChanged();
  }

  // Line number + preview for every bookmark (bookmark panel). Line
  // numbers are exact within the indexed prefix, estimated beyond it.
  Future<List<BookmarkInfo>> _bookmarkDetails() async {
    final doc = _doc;
    if (doc == null) return const [];
    final sorted = _bookmarks.where((b) => b <= doc.length).toList()..sort();
    final out = <BookmarkInfo>[];
    for (final off in sorted) {
      final la = await doc.absoluteLineAt(off);
      var len = doc.length - off;
      if (len > 512) len = 512;
      var text = len > 0 ? (await doc.readRangeDecoded(off, len)).text : '';
      final nl = text.indexOf('\n');
      if (nl >= 0) text = text.substring(0, nl);
      if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
      text = text.trim();
      if (text.length > 160) text = text.substring(0, 160);
      out.add(BookmarkInfo(off, la.line, la.exact, text));
    }
    return out;
  }

  // Document.onSplice: shift bookmark offsets with every edit (undo/redo
  // included — apply() funnels through the same document paths). Bookmarks
  // inside a deleted range collapse onto its start.
  void _spliceBookmarks(int offset, int delta) {
    if (_bookmarks.isEmpty || delta == 0) return;
    var changed = false;
    final moved = <int>{};
    for (final b in _bookmarks) {
      var nb = b;
      if (b >= offset) {
        if (delta > 0) {
          nb = b + delta;
        } else {
          final end = offset - delta; // deleted range = [offset, end)
          nb = b >= end ? b + delta : offset;
        }
      }
      changed = changed || nb != b;
      moved.add(nb);
    }
    if (!changed && moved.length == _bookmarks.length) return;
    _bookmarks
      ..clear()
      ..addAll(moved);
    _bookmarksChanged();
  }

  @override
  void toggleBookmark() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final ls = await doc.lineStartOf(_caretOffset);
    if (!_bookmarks.remove(ls)) _bookmarks.add(ls);
    _bookmarksChanged();
  });

  @override
  void nextBookmark() => _jumpBookmark(1);

  @override
  void prevBookmark() => _jumpBookmark(-1);

  @override
  void clearBookmarks() {
    if (_bookmarks.isEmpty) return;
    _bookmarks.clear();
    _bookmarksChanged();
  }

  // Jump to the nearest bookmark after/before the caret's line, wrapping
  // around at either end.
  void _jumpBookmark(int dir) => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || _bookmarks.isEmpty) return;
    final sorted = _bookmarks.where((b) => b <= doc.length).toList()..sort();
    if (sorted.isEmpty) return;
    final cur = await doc.lineStartOf(_caretOffset);
    final target = dir > 0
        ? sorted.firstWhere((b) => b > cur, orElse: () => sorted.first)
        : sorted.lastWhere((b) => b < cur, orElse: () => sorted.last);
    _colBlock = null;
    _selAnchor = null;
    _undo.breakCoalescing();
    await _moveCaretTo(target, false);
  });

  // ── Search bar ─────────────────────────────────────────────

  bool _searchOpen = false;
  bool _replaceOpen = false; // the second (replace) row of the bar
  bool _searchRegex = false;
  bool _searchCase = false;
  bool _searchWord = false; // whole word (alt+w)
  // Find in selection (alt+l): the selection at the moment the toggle went
  // on becomes the scope; matches outside it are ignored, wrap-around and
  // replace-all stay inside it. Edits shift it along (see _onDocSplice).
  bool _searchInSel = false;
  (int, int)? _searchScope;
  // Hex mode: query is a byte sequence (`FF 00 A1`, `??` = any byte) rather
  // than decoded text. Only consulted while in hex mode; defaults on when
  // entering it.
  bool _searchHex = false;
  bool get _byteSearch => _hexMode && _searchHex;
  bool _searching = false; // one chunked scan at a time
  final TextEditingController _searchCtl = TextEditingController();
  final TextEditingController _replaceCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _replaceFocus = FocusNode();

  @override
  void openSearch() {
    if (_doc == null) return;
    setState(() {
      _searchOpen = true;
      _gotoOpen = false;
    });
    _searchFocus.requestFocus();
    _prefillSearchFromSelection();
  }

  @override
  void openReplace() {
    if (_doc == null) return;
    if (_hexMode) {
      openSearch(); // byte view edits bytes, not decoded text: search only
      return;
    }
    setState(() {
      _searchOpen = true;
      _replaceOpen = true;
      _gotoOpen = false;
    });
    _searchFocus.requestFocus();
    _prefillSearchFromSelection();
  }

  void _prefillSearchFromSelection() {
    _enqueueCaret(() async {
      // Prefill from the selection; regex queries are never overwritten
      // (the selection is literal text, not a pattern).
      final doc = _doc;
      final s = _selStart, e = _selEnd;
      if (doc != null && e > s && e - s <= _searchSeedMax) {
        if (_byteSearch) {
          _searchCtl.text = formatHexBytes(await doc.readRangeBytes(s, e - s));
        } else if (!_searchRegex) {
          _searchCtl.text = await doc.readRangeString(s, e - s);
        }
      }
      // Select the query so typing replaces it.
      _searchCtl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchCtl.text.length,
      );
    });
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _replaceOpen = false;
    });
    _focus.requestFocus();
  }

  // Find in selection on: the current (non-empty) selection becomes the
  // scope — with nothing selected the existing scope is kept, else nothing
  // to scope to and the toggle stays off. Off: scope forgotten.
  void _toggleSearchInSel() {
    if (_searchInSel) {
      setState(() {
        _searchInSel = false;
        _searchScope = null;
      });
      return;
    }
    final s = _selStart, e = _selEnd;
    if (e > s && _colBlock == null) {
      setState(() {
        _searchInSel = true;
        _searchScope = (s, e);
      });
    } else if (_searchScope != null) {
      setState(() => _searchInSel = true);
    }
  }

  RegExp? _compileSearch() {
    final p = _searchCtl.text;
    if (p.isEmpty) return null;
    try {
      return compileQuery(
        p,
        regex: _searchRegex,
        caseSensitive: _searchCase,
        wholeWord: _searchWord,
      );
    } on FormatException {
      _toast(_l10n.tr('toast_bad_regex'));
      return null;
    }
  }

  // Hex-mode byte query → pattern (null + toast when malformed or empty).
  List<int?>? _compileBytePattern() {
    try {
      final pat = parseHexPattern(_searchCtl.text);
      return pat.isEmpty ? null : pat;
    } on FormatException {
      _toast(_l10n.tr('toast_bad_hex'));
      return null;
    }
  }

  @override
  void findNext() => _find(forward: true);

  @override
  void findPrev() => _find(forward: false);

  // Replace the current hit (selection re-verified against the pattern —
  // the buffer may have changed since it was found), then jump to the next.
  // A selection that is not a match just jumps, like F3.
  void _replaceCurrent() {
    if (_blockedReadOnly()) return;
    if (_searching) return;
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null || _hexMode) return;
      final re = _compileSearch();
      if (re == null) return;
      final s = _selStart, e = _selEnd;
      if (e <= s) return;
      final m = await searchForward(doc, re, s);
      if (m == null || m.start != s || m.end != e) return;
      final text = expandReplacement(
        _replaceCtl.text,
        m.groups,
        regex: _searchRegex,
      );
      final enc = doc.codec.encode(text);
      final reverses = <ReverseEdit>[
        await doc.delete(m.start, m.end - m.start),
        if (enc.bytes.isNotEmpty) await doc.insertBytes(m.start, enc.bytes),
      ];
      _undo.push(ReverseEdit.group(reverses.reversed.toList()));
      _undo.breakCoalescing();
      if (enc.fallbackCount > 0) {
        _toast(
          _l10n.trf('toast_unencodable_many', [
            enc.fallbackCount,
            doc.codec.name,
          ]),
        );
      }
      _caretOffset = m.start + enc.bytes.length;
      _selAnchor = null;
      _lastMatchStart = _lastMatchEnd = null;
      _setModified(_undo.isDirty);
      await _afterEdit();
    });
    _find(forward: true); // queued after the replace above
  }

  // Replace every match in the document, all of it one undo step. Walks
  // forward re-searching after each splice, so offsets never go stale.
  void _replaceAll() {
    if (_blockedReadOnly()) return;
    if (_searching) return;
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null || _hexMode) return;
      final re = _compileSearch();
      if (re == null) return;
      _searching = true;
      if (mounted) setState(() {});
      try {
        final scope = _searchInSel ? _searchScope : null;
        final (count, fallbacks) = await _replaceAllWith(
          doc,
          re,
          _replaceCtl.text,
          regex: _searchRegex,
          from: scope?.$1 ?? 0,
          to: scope?.$2,
        );
        if (count == 0) {
          _toast(_l10n.tr('toast_not_found'));
          return;
        }
        if (fallbacks > 0) {
          _toast(
            _l10n.trf('toast_unencodable_many', [fallbacks, doc.codec.name]),
          );
        }
        _toast(_l10n.trf('toast_replaced', [count]));
      } finally {
        _searching = false;
        if (mounted) setState(() {});
      }
    });
  }

  // Core of replace-all, shared with replace-in-files for panes that are
  // open: returns (replacements, unencodable chars); when anything was
  // replaced it is pushed as ONE undo step and the view is refreshed. Must
  // run inside the caret queue.
  Future<(int, int)> _replaceAllWith(
    Document doc,
    RegExp re,
    String template, {
    required bool regex,
    int from = 0,
    int? to, // find-in-selection: only matches ending here or before
  }) async {
    final reverses = <ReverseEdit>[];
    var pos = from, count = 0, fallbacks = 0;
    var limit = to;
    while (true) {
      final m = await searchForward(doc, re, pos);
      if (m == null || (limit != null && m.end > limit)) break;
      final text = expandReplacement(template, m.groups, regex: regex);
      final enc = doc.codec.encode(text);
      fallbacks += enc.fallbackCount;
      reverses.add(await doc.delete(m.start, m.end - m.start));
      if (enc.bytes.isNotEmpty) {
        reverses.add(await doc.insertBytes(m.start, enc.bytes));
      }
      pos = m.start + enc.bytes.length;
      if (limit != null) limit += enc.bytes.length - (m.end - m.start);
      count++;
    }
    if (count == 0) return (0, 0);
    // Reverses run newest-first on undo, so offsets stay valid.
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = null;
    _lastMatchStart = _lastMatchEnd = null;
    if (_caretOffset > doc.length) _caretOffset = doc.length;
    _setModified(_undo.isDirty);
    await _afterEdit();
    return (count, fallbacks);
  }

  // Replace-in-files entry for an open pane: edits the buffer (one undo
  // step, left modified — the user saves). null = this pane can't take it
  // (hex mode, still loading, busy), so the caller rewrites the disk file.
  Future<int?> _replaceAllMatches(
    RegExp re,
    String template, {
    required bool regex,
  }) {
    if (_readOnly) return Future.value(0); // read-only pane: nothing replaced
    final c = Completer<int?>();
    if (_searching || _hexMode || _doc == null || _opening) {
      c.complete(null);
      return c.future;
    }
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null || _hexMode) {
        c.complete(null);
        return;
      }
      _searching = true;
      if (mounted) setState(() {});
      try {
        final (count, _) = await _replaceAllWith(
          doc,
          re,
          template,
          regex: regex,
        );
        c.complete(count);
      } catch (e, st) {
        c.completeError(e, st);
      } finally {
        _searching = false;
        if (mounted) setState(() {});
      }
    });
    return c.future;
  }

  // ── User scripts (Tools menu) ──────────────────────────────

  bool _scripting = false;

  // Run user script [name] over the whole document, or over the lines
  // covered by the (linear) selection when there is one. All spliced lines
  // are one undo step. Hex mode is byte-oriented → scripts don't apply.
  // Show a modal "busy" dialog if [done] takes longer than a blink (long
  // script runs); it closes itself when [done] completes.
  void _showBusyAfter(
    Future<void> done,
    String title,
    String body, {
    VoidCallback? onCancel,
  }) {
    var finished = false;
    done.whenComplete(() => finished = true);
    Timer(const Duration(milliseconds: 300), () {
      if (finished || !mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _BusyDialog(
          title: title,
          body: body,
          done: done,
          onCancel: onCancel,
        ),
      );
    });
  }

  // Whole-text script contract: the selection (or the whole file) goes to
  // the script in ONE call — bounded by settings.scriptWholeFileMaxMB, since
  // the text is held several times over (Dart string, engine copy, result) —
  // and the result replaces it as one undo step, staying selected.
  Future<void> _runTextScript(Document doc, int id, int s, int e) async {
    final capMB = AppSettings.instance.scriptWholeFileMaxMB;
    if (e - s > capMB << 20) {
      final rangeMB = (e - s + (1 << 20) - 1) >> 20;
      _toast(_l10n.trf('toast_script_too_large', [rangeMB, capMB]));
      return;
    }
    final d = await doc.readRangeDecoded(s, e - s);
    final out = await rust_script.scriptSessionTransformText(
      id: id,
      text: d.text,
    );
    final err = out.error;
    if (err != null) {
      _toast(_l10n.trf('toast_script_error', [err]));
      return;
    }
    final text = out.text;
    if (text == null || text == d.text) {
      _toast(_l10n.tr('toast_script_no_change'));
      return;
    }
    final enc = doc.codec.encode(
      text.replaceAll('\r\n', '\n').replaceAll('\n', _newline),
    );
    _undo.breakCoalescing();
    final reverses = <ReverseEdit>[
      if (e > s) await doc.delete(s, e - s),
      await doc.insertBytes(s, enc.bytes),
    ];
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();
    _colBlock = null;
    _selAnchor = s;
    _caretOffset = s + enc.bytes.length;
    _goalColumn = null;
    _lastMatchStart = _lastMatchEnd = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
    if (enc.fallbackCount > 0) {
      _toast(
        _l10n.trf('toast_unencodable_many', [
          enc.fallbackCount,
          doc.codec.name,
        ]),
      );
    }
    _toast(_l10n.trf('toast_script_text_done', [text.length]));
  }

  void _runUserScript(String name) {
    if (_blockedReadOnly()) return;
    if (_scripting) return;
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null || _hexMode || _scripting) return;
      final regErr = UserScriptRegistry.instance.errorFor(name);
      if (regErr != null) {
        _toast(_l10n.trf('toast_script_error', [regErr]));
        return;
      }
      _scripting = true;
      final done = Completer<void>();
      _showBusyAfter(
        done.future,
        _l10n.tr('script_wait_title'),
        _l10n.trf('script_wait_body', [name]),
      );
      int? sessionId;
      try {
        // One engine instance per run: the script's globals persist across
        // chunks, and its begin/end hooks bracket the run.
        final engine = UserScriptRegistry.instance.engineFor(name);
        final open = await rust_script.scriptSessionOpen(
          engine: engine == ScriptEngine.lua ? 'lua' : 'js',
          name: name,
        );
        final openErr = open.error;
        if (openErr != null) {
          _toast(_l10n.trf('toast_script_error', [openErr]));
          return;
        }
        sessionId = open.id;
        final s = _selStart, e = _selEnd;
        final hasSel = _colBlock == null && e > s;
        if (open.hasText) {
          await _runTextScript(
            doc,
            open.id,
            hasSel ? s : 0,
            hasSel ? e : doc.length,
          );
          return;
        }
        var start = 0;
        int? end;
        if (hasSel) {
          start = await doc.lineStartOf(s);
          // e-1: a selection ending exactly at a line start must not pull in
          // the following line. -1 = selection reaches the last line.
          final next = await doc.nextLineStart(e - 1);
          end = next < 0 ? null : next;
        }
        _undo.breakCoalescing();
        final res = await applyLineTransform(
          doc,
          (lines, firstLineNo) async {
            final out = await rust_script.scriptSessionTransformLines(
              id: open.id,
              lines: lines,
              firstLineNo: firstLineNo,
            );
            final err = out.error;
            if (err != null) throw _ScriptRunError(err);
            return [
              for (var i = 0; i < out.lines.length; i++)
                out.deleted[i] ? null : out.lines[i],
            ];
          },
          start: start,
          end: end,
          newline: _newline,
        );
        // Even a failed run keeps its already-applied batches undoable.
        if (res.reverses.isNotEmpty) {
          _undo.push(ReverseEdit.group(res.reverses.reversed.toList()));
          _undo.breakCoalescing();
          _colBlock = null;
          _selAnchor = null;
          _lastMatchStart = _lastMatchEnd = null;
          if (_caretOffset > doc.length) _caretOffset = doc.length;
          _setModified(_undo.isDirty);
          await _afterEdit();
        }
        final resErr = res.error;
        if (resErr != null) {
          _toast(_l10n.trf('toast_script_error', [resErr]));
          return;
        }
        if (res.fallbackCount > 0) {
          _toast(
            _l10n.trf('toast_unencodable_many', [
              res.fallbackCount,
              doc.codec.name,
            ]),
          );
        }
        _toast(
          res.changedLines == 0
              ? _l10n.tr('toast_script_no_change')
              : res.skippedLong > 0
              ? _l10n.trf('toast_script_done_skipped', [
                  res.changedLines,
                  res.skippedLong,
                ])
              : _l10n.trf('toast_script_done', [res.changedLines]),
        );
      } finally {
        if (sessionId != null) rust_script.scriptSessionClose(id: sessionId);
        done.complete();
        _scripting = false;
        if (mounted) setState(() {});
      }
    });
  }

  // F3/shift+F3 work from a closed bar too, and a selection the USER made
  // (≠ the previous hit — hits become selections, so "selection always
  // wins" would break query cycling) replaces the query. Regex queries are
  // never overwritten by seeding. The bar is shown for feedback without
  // stealing focus, so F3 keeps cycling from the editor.
  static const int _searchSeedMax = searchOverlap;
  int? _lastMatchStart, _lastMatchEnd;

  void _find({required bool forward}) {
    if (_searching) return;
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null) return;
      final s = _selStart, e = _selEnd;
      final isOwnHit = s == _lastMatchStart && e == _lastMatchEnd;
      final bytes = _byteSearch;
      if (e > s && !isOwnHit && e - s <= _searchSeedMax) {
        if (bytes) {
          _searchCtl.text = formatHexBytes(await doc.readRangeBytes(s, e - s));
        } else if (!_searchRegex) {
          _searchCtl.text = await doc.readRangeString(s, e - s);
        }
      }
      // Byte pattern (hex mode) or text regex — one of the two is compiled.
      List<int?>? pat;
      RegExp? re;
      if (bytes) {
        pat = _compileBytePattern();
        if (pat == null) return;
      } else {
        re = _compileSearch();
        if (re == null) return;
      }
      if (!_searchOpen && mounted) setState(() => _searchOpen = true);
      _searching = true;
      if (mounted) setState(() {});
      try {
        // Find-in-selection clamps the start point and rejects hits that
        // leave the scope; wrap-around restarts at the scope's edges.
        final scope = _searchInSel ? _searchScope : null;
        Future<SearchMatch?> fwd(int from) async {
          if (scope != null && from < scope.$1) from = scope.$1;
          final m = pat != null
              ? await searchBytesForward(doc, pat, from)
              : await searchForward(doc, re!, from);
          return m != null && scope != null && m.end > scope.$2 ? null : m;
        }

        Future<SearchMatch?> bwd(int before) async {
          if (scope != null && before > scope.$2) before = scope.$2;
          final m = pat != null
              ? await searchBytesBackward(doc, pat, before)
              : await searchBackward(doc, re!, before);
          return m != null && scope != null && m.start < scope.$1 ? null : m;
        }

        SearchMatch? m;
        var wrapped = false; // the hit came from restarting at the far edge
        if (forward) {
          // Continue after the current hit (= the selection), wrap once.
          final from = _selEnd > _selStart ? _selEnd : _caretOffset;
          final lo = scope?.$1 ?? 0;
          m = await fwd(from);
          if (m == null && from > lo) {
            m = await fwd(lo);
            wrapped = m != null;
          }
        } else {
          final before = _selEnd > _selStart ? _selStart : _caretOffset;
          final hi = scope?.$2 ?? doc.length;
          m = await bwd(before);
          if (m == null && before < hi) {
            m = await bwd(hi);
            wrapped = m != null;
          }
        }
        if (m == null) {
          _toast(_l10n.tr('toast_not_found'));
          return;
        }
        // Tell the user the search passed the end (or start) and continued
        // from the other edge — otherwise cycling silently jumps back to
        // the first hit and looks like a new one.
        if (wrapped) {
          _toast(
            _l10n.tr(
              forward ? 'toast_search_wrapped_end' : 'toast_search_wrapped_start',
            ),
          );
        }
        _colBlock = null;
        _selAnchor = m.start;
        _lastMatchStart = m.start;
        _lastMatchEnd = m.end;
        await _moveCaretTo(m.end, true);
      } finally {
        _searching = false;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void pasteClipboard() => _enqueueCaret(() async {
    // Hex mode edits bytes a key at a time; pasting text there would insert
    // encoded text at a byte offset, which is never what OVR users expect.
    if (_doc == null || _hexMode) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) return;
    // A paste is one undo step of its own: never merged with the typing
    // before it, and the typing after it starts a fresh coalescing run.
    _undo.breakCoalescing();
    // Multi-cursor: one clipboard line per cursor when the counts match
    // (a multi-cursor copy round-trips), else the whole text everywhere.
    final lines = splitForCursors(text, _extra.length + 1);
    await _forEachCursor((i) => _doInsert(lines == null ? text : lines[i]));
    _undo.breakCoalescing();
  });

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 900)),
    );
  }

  // ── Column mode: coordinates and content of the rectangular selection ─────────────

  // Document offset → (offset of the line start, column within the line). The column unit is
  // **display width** (a wide character counts 2 columns), consistent with _goalColumn, so
  // the rectangle's left/right edges stay in the same column and line up on vertical moves.
  Future<(int, int)> _lineColOf(int off) async {
    final doc = _doc!;
    final ls = await doc.lineStartOf(off);
    if (off <= ls) return (ls, 0);
    final text = await doc.readRangeString(ls, off - ls);
    return (ls, columnCount(text, tabSize: _tabSize));
  }

  // The lines the rectangular selection covers (text + line-start offsets). The whole range
  // is read at once and then sliced, hence a size cap; beyond it null is returned (the caller
  // tells the user) rather than pulling hundreds of MB into memory for one operation.
  static const int _blockMaxBytes = 16 << 20;

  Future<(List<String>, List<int>, List<Uint32List>)?> _blockLines(
    ColumnBlock b,
  ) async {
    final doc = _doc!;
    final end = await doc.lineEndOf(b.bottomLine);
    final len = end - b.topLine;
    if (len < 0 || len > _blockMaxBytes) return null;
    final d = await doc.readRangeDecoded(b.topLine, len);
    final text = d.text;
    final lines = <String>[];
    final starts = <int>[];
    final maps = <Uint32List>[];
    var pos = 0;
    while (true) {
      final nl = text.indexOf('\n', pos);
      var contentEnd = nl < 0 ? text.length : nl;
      if (contentEnd > pos && text.codeUnitAt(contentEnd - 1) == 13) {
        contentEnd--; // CRLF: \r is not content
      }
      lines.add(text.substring(pos, contentEnd));
      final lineByteStart = d.byteForCodeUnit(pos);
      starts.add(b.topLine + lineByteStart);
      // Per-line byte<->code-unit map (DocWindow.maps layout), sliced from
      // the decoded range so block edits stay byte-exact for any codec.
      final m = Uint32List(contentEnd - pos + 1);
      for (var j = 0; j <= contentEnd - pos; j++) {
        m[j] = d.byteForCodeUnit(pos + j) - lineByteStart;
      }
      maps.add(m);
      if (nl < 0) break;
      pos = nl + 1;
    }
    return (lines, starts, maps);
  }

  // Move one line up/down, keeping the _goalColumn target column.
  // A logical line's decoded content (no newline) plus its wrap cuts; null
  // when the line is too long to read whole (caller falls back to logical
  // lines).
  Future<(DecodedText, List<int>)?> _lineRows(int ls) async {
    final doc = _doc!;
    final le = await doc.lineEndOf(ls);
    if (le - ls > _wrapBackScanCap) return null;
    final d = await doc.readRangeDecoded(ls, le - ls);
    return (d, _boundariesOf(d.text));
  }

  // One vertical step by **visual row** when wrapping: the caret moves to the
  // neighbouring row of the same line, or the first/last row of the next/
  // previous line. Null = fall back to logical-line movement (oversized line).
  Future<int?> _verticalOnceWrapped(int off, int dir) async {
    final doc = _doc!;
    final ls = await doc.lineStartOf(off);
    final cur = await _lineRows(ls);
    if (cur == null) return null;
    final (d, cuts) = cur;
    final ci = d.codeUnitForByte(off - ls);
    var k = rowIndexOfChar(cuts, ci);
    // End's row-end affinity only applies to the real caret, not to an
    // intermediate step of a multi-row move.
    if (_caretAtRowEnd && off == _caretOffset && k > 0 && cuts[k] == ci) k--;
    final goal = _goalColumn ?? 0;
    if (dir > 0) {
      if (k + 2 < cuts.length) {
        return ls +
            d.byteForCodeUnit(charInRowForColumn(d.text, cuts, k + 1, goal, tabSize: _tabSize));
      }
      var ns = await doc.nextLineStart(off);
      if (ns < 0) return off; // last line
      ns = await _skipHiddenLine(ns, 1);
      if (_eofHidden(ns)) return off; // tail folded away
      final nx = await _lineRows(ns);
      if (nx == null) return null;
      return ns +
          nx.$1.byteForCodeUnit(charInRowForColumn(nx.$1.text, nx.$2, 0, goal, tabSize: _tabSize));
    }
    if (k > 0) {
      return ls +
          d.byteForCodeUnit(charInRowForColumn(d.text, cuts, k - 1, goal, tabSize: _tabSize));
    }
    if (ls == 0) return off; // first line
    final ps = await _skipHiddenLine(await doc.lineStartOf(ls - 1), -1);
    final pv = await _lineRows(ps);
    if (pv == null) return null;
    final lastRow = pv.$2.length - 2;
    return ps +
        pv.$1.byteForCodeUnit(
          charInRowForColumn(pv.$1.text, pv.$2, lastRow, goal, tabSize: _tabSize),
        );
  }

  Future<int> _verticalOnce(int off, int dir) async {
    final doc = _doc!;
    if (_wrapping) {
      final r = await _verticalOnceWrapped(off, dir);
      if (r != null) return r;
    }
    final curStart = await doc.lineStartOf(off);
    int targetStart;
    if (dir < 0) {
      if (curStart == 0) return off; // already on the first line
      targetStart = await doc.lineStartOf(curStart - 1); // previous line's start
    } else {
      final ns = await doc.nextLineStart(off); // next line's start (after the \n)
      if (ns < 0) return off; // already on the last line
      targetStart = ns;
    }
    targetStart = await _skipHiddenLine(targetStart, dir);
    if (dir > 0 && _eofHidden(targetStart)) return off; // tail folded away
    if (targetStart >= doc.length && dir > 0 && curStart >= doc.length) {
      return off;
    }
    final targetEnd = await doc.lineEndOf(targetStart);
    final d = await doc.readRangeDecoded(targetStart, targetEnd - targetStart);
    // A target column inside a wide character snaps left (caret before that character); a
    // line shorter than the target column stops at its end.
    return targetStart +
        d.byteForCodeUnit(charIndexForColumn(d.text, _goalColumn ?? 0, tabSize: _tabSize));
  }

  // Apply a caret move: update selection/caret, ensure visibility, repaint and restart the
  // blink.
  Future<void> _moveCaretTo(
    int offset,
    bool select, {
    bool keepGoal = false,
    bool rowEnd = false, // caret on a wrap cut belongs to the row before it
    int? virtualCol, // column mode: a click past the line end (see below)
  }) async {
    if (_multi && !_inMulti) _clearExtra(); // any outside move collapses
    if (_completion != null && !_inMulti) _closeCompletion();
    _autoClosedAt = null; // the caret left the auto-inserted pair
    final clamped = offset < 0
        ? 0
        : (offset > (_doc?.length ?? 0) ? _doc!.length : offset);
    // Navigation history: leaving the visible area counts as a jump (goto
    // line, search hit, bookmark, bracket, scrollbar click…); arrow keys and
    // clicks inside the window do not.
    if (!_inMulti && clamped != _caretOffset && !_isOffsetOnScreen(clamped)) {
      _recordJumpFrom(_caretOffset);
    }
    if (_columnMode) {
      // Rectangular selection: the anchor corner stays put, the caret corner follows the new
      // position.
      if (select) {
        if (_colBlock == null) {
          final (l0, c0) = await _lineColOf(_caretOffset);
          _colBlock = ColumnBlock.at(l0, c0);
        }
        final (line, col) = await _lineColOf(clamped);
        // Moving up/down across a short line clamps the caret to its end; the rectangle must
        // remember the **virtual column** (_goalColumn), otherwise dragging a block downward
        // past a short line shrinks the whole rectangle's right edge.
        final goal = virtualCol != null && virtualCol > col
            ? virtualCol
            : (keepGoal && _goalColumn != null && _goalColumn! > col
                  ? _goalColumn!
                  : col);
        _colBlock = _colBlock!.withCaret(line, goal);
      } else if (virtualCol != null) {
        // A plain click past the line end: a zero-width block parked on the
        // virtual column, so typing pads the line out to it (_doBlockEdit).
        final (line, col) = await _lineColOf(clamped);
        _colBlock = virtualCol > col ? ColumnBlock.at(line, virtualCol) : null;
      } else {
        _colBlock = null;
      }
      _selAnchor = null;
    } else if (select) {
      _selAnchor ??= _caretOffset;
    } else {
      _selAnchor = null;
    }
    _caretOffset = clamped;
    // A collapsed selection is no selection: an anchor equal to the caret
    // would turn the next edit's caret advance into a real selection.
    if (_selAnchor == _caretOffset) _selAnchor = null;
    _caretAtRowEnd = rowEnd;
    if (!keepGoal) _goalColumn = null;
    _undo.breakCoalescing(); // caret moved → the next edit is its own undo entry
    await _ensureCaretVisible();
    _scheduleBracketMatch();
    if (mounted) setState(_restartBlink);
  }

  // Rows that fit the viewport in full. The window reads a couple more
  // (_visibleCount + 1) so a row cut off at the bottom still paints, but a
  // caret parked on one of those is invisible — "visible" here means fully.
  int get _fullRowCount {
    final n = (_viewportH / _lineHeight).floor();
    return n > 0 ? n : 1;
  }

  // Visual row of the caret in the current window, or -1 when the window does
  // not contain it. Expanded from _window the same way the painter does — not
  // from _rows, which is only rebuilt at build time while this runs between
  // setState and the next frame.
  int _caretRowInWindow() => _windowRowsAtCaret()?.index ?? -1;

  // The current window expanded into visual rows plus the row holding the
  // caret; null when the window does not contain the caret. Callers that run
  // between an edit's _reload() and the next frame must use this rather than
  // _rows (stale: the completion popup once landed at the start of the row
  // after the caret's, because the caret had just moved past the old row end).
  ({List<WrapRow> rows, int index})? _windowRowsAtCaret() {
    final win = _window;
    if (win == null || win.offsets.isEmpty) return null;
    final c = _caretOffset;
    if (c < win.offsets.first) return null;
    if (c >= win.nextOffset && !win.atEof) return null;
    final rows = wrapWindow(
      win.lines,
      win.offsets,
      _wrapColumns,
      boundariesOf: _wrapMeasure,
      maps: win.maps,
    );
    for (var i = rows.length - 1; i >= 0; i--) {
      if (c >= rows[i].offset) {
        final prevOwns =
            _caretAtRowEnd && c == rows[i].offset && !rows[i].isFirst && i > 0;
        return (rows: rows, index: prevOwns ? i - 1 : i);
      }
    }
    return null;
  }

  Future<void> _anchorTo(int offset) async {
    final doc = _doc;
    if (doc == null || offset == _anchorOffset) return;
    final la = await doc.absoluteLineAt(offset);
    _anchorLineExact = la.exact;
    await _setAnchor(offset, la.line);
  }

  // Start of the visual row holding the caret (the line start when not
  // wrapping). Same prefix approximation as _prevRowStart.
  Future<int> _caretRowStart(int cls) async {
    final doc = _doc!;
    if (!_wrapping || _caretOffset <= cls) return cls;
    if (_caretOffset - cls > _wrapBackScanCap) return cls;
    final d = await doc.readRangeDecoded(cls, _caretOffset - cls);
    return cls + d.byteForCodeUnit(lastRowCharStart(d.text, _boundariesOf));
  }

  // Scroll so the caret row is fully visible (vertical + horizontal).
  Future<void> _ensureCaretVisible() async {
    if (_inMulti) return; // once for the primary when the replay is done
    if (_hexMode) return _ensureCaretVisibleHex();
    final doc = _doc;
    if (doc == null) return;
    final cls = await doc.lineStartOf(_caretOffset);
    // The caret landed inside a collapsed region (search, goto line, undo):
    // open the folds covering it first.
    if (_hiddenRangeContaining(cls) != null || _eofHidden(cls)) {
      await _unfoldCovering(cls);
    }
    final full = _fullRowCount;
    var row = _caretRowInWindow();
    if (row < 0) {
      int newAnchor;
      if (cls <= _anchorOffset) {
        newAnchor = cls; // scrolling up: caret line to the top
      } else {
        // Scrolling down: caret row becomes the last full row, so the anchor
        // is (full - 1) visual rows above it.
        newAnchor = await _caretRowStart(cls);
        if (_wrapping) {
          for (var i = 0; i < full - 1; i++) {
            final p = await _prevRowStart(newAnchor);
            if (p == newAnchor) break;
            newAnchor = p;
          }
        } else {
          newAnchor = await doc.lineStartBack(newAnchor, full - 1);
        }
      }
      await _anchorTo(newAnchor);
      row = _caretRowInWindow();
    }
    if (row >= full) {
      // In the window but on a row that is cut off (or entirely below) the
      // viewport: step the anchor forward so the caret row is the last full
      // one. Also corrects the wrap-boundary approximation above.
      var a = _anchorOffset;
      for (var i = 0; i < row - full + 1; i++) {
        final n = await _nextRowStart(a);
        if (n == a) break;
        a = n;
      }
      await _anchorTo(a);
    }
    _ensureCaretVisibleX(cls);
  }

  // If the caret is outside the horizontal view, adjust _scrollX to show it (with a margin on
  // each side). Measurement uses the current window's line text (vertical scrolling has
  // already guaranteed the caret line is in the window).
  void _ensureCaretVisibleX(int caretLineStart) {
    // The caret's VISUAL row (wrapping), expanded from _window rather than
    // _rows: this runs right after an edit or a jump, before the frame that
    // rebuilds _rows, and the stale rows clamped the caret to the old line
    // length (a long paste at a line end did not scroll) or missed the
    // offset entirely (goto line:column did nothing horizontally).
    final at = _windowRowsAtCaret();
    if (at == null) return;
    final r = at.rows[at.index];
    final line = r.text;
    caretLineStart = r.offset;
    final contentBytes = r.contentBytes;
    final within = (_caretOffset - caretLineStart).clamp(0, contentBytes);
    final para = _buildLine(
      line,
      _layoutMaxW,
      null,
      _rowStartColumn(_window, r),
      _baseRtl,
    );
    // Measure the (possibly new) window first: in document RTL layout the
    // row shift — hence x and the scroll range — depend on its content width,
    // and build has not seen this window yet.
    _ensureContentW();
    var x =
        _rowShift(para) +
        para.xOf(r.charOfByte(within));
    if (_composing.isNotEmpty) {
      // The composition overlay is drawn right of the caret → keep it visible too
      x += _buildLine(_composing, _layoutMaxW).width;
    }
    const margin = 24.0;
    final viewW = _textViewW;
    var target = _scrollX;
    if (x < _scrollX + margin) {
      target = x - margin;
    } else if (x > _scrollX + viewW - margin) {
      target = x - viewW + margin;
    }
    _scrollX = target < 0 ? 0.0 : target; // build clamps the upper bound with the new window's content width
  }

  // ── Blink ──
  void _restartBlink() {
    _caretOn = true;
    _blinkTimer?.cancel();
    // Unfocused editor / inactive window: leave the caret steadily on
    // (drawn dimmed) instead of blinking — background panes would otherwise
    // repaint every 530ms.
    if (!_caretFocused) return;
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (!mounted) return;
      setState(() => _caretOn = !_caretOn);
    });
  }

  // ── Mouse hit-test: pixels → document offset, setting caret/selection ──
  // Double-click detection is done by hand in onTapDown: registering
  // onDoubleTap on the GestureDetector would make the tap recognizer wait
  // out the double-tap window and caret placement would lag every click.
  DateTime? _lastTapTime;
  Offset? _lastTapPos;

  int _tapCount = 0;

  // Drag granularity, decided by the press that started it: a double-click
  // then drag extends by whole words, a triple-click then drag by whole
  // lines, and the range the click selected (_dragBase) is always kept.
  _DragMode _dragMode = _DragMode.char;
  (int, int)? _dragBase;

  // The tap recognizer fires onTapDown at its 100ms deadline; a drag that
  // wins the arena before that skips onTapDown entirely, so onPanStart
  // must run the press logic itself, and at the raw press position
  // (_pressPos): by the time the drag is recognised the pointer has moved,
  // which would break the multi-click distance check. Listener.onPointerDown
  // records both.
  bool _pressHandled = false;
  Offset _pressPos = Offset.zero;
  // Was alt held when the press started (alt+click = add a cursor)?
  bool _pressAlt = false;

  // Shared by onTapDown and onPanStart: click counting, alt+click cursor,
  // double/triple-click selection, plain caret placement.
  void _onPress(Offset local) {
    _pressHandled = true;
    _dragMode = _DragMode.char;
    _dragBase = null;
    // Alt is read once, here: a drag keeps doing what the press started,
    // whatever the modifier state does later (and whether or not this
    // machine reports it at all — see Mods).
    _pressAlt = Mods.alt;
    if (!_hexMode && _foldGutterTap(local)) return; // chevron: toggled a fold
    final shift = Mods.shift;
    var taps = _tapCountAt(local);
    if (shift) {
      // shift = continue the current selection, whatever came before it: a
      // shift-click right after a double-click must extend that selection,
      // not count as a third click (line) nor start a move-drag.
      _tapCount = taps = 1;
    }
    if (Mods.alt && !_hexMode) {
      _addCursorAt(local); // alt+click: add (or remove) a cursor
    } else if (taps == 3 && !_hexMode) {
      _dragMode = _DragMode.line;
      _selectLineAt(local);
    } else if (taps == 2 && !_hexMode) {
      _dragMode = _DragMode.word;
      _selectWordAt(local);
    } else {
      if (!shift && _pressInsideSelection(local)) {
        // Don't collapse the selection yet: a drag from here moves the
        // text (onPanUpdate/onPanEnd); a plain click places the caret on
        // release (onTapUp) instead of on press.
        _dragMode = _DragMode.move;
        _dragBase = (_selStart, _selEnd);
        return;
      }
      _placeCaretAt(local, select: shift);
    }
  }

  // Text mode, single linear selection, pointer over it ([start, end)).
  bool _pressInsideSelection(Offset local) {
    if (!AppSettings.instance.dragAndDrop) return false;
    if (_hexMode || _multi || _colBlock != null) return false;
    final s = _selStart, e = _selEnd;
    if (e <= s) return false;
    final off = _offsetAt(local);
    return off != null && off >= s && off < e;
  }

  // Drop indicator while dragging the selection (document offset under the
  // pointer, null when not dragging); painted as a second caret.
  int? _dropOffset;

  void _moveDragHover(Offset local) {
    final off = _offsetAt(local);
    if (off == _dropOffset) return;
    setState(() => _dropOffset = off);
  }

  void _moveDragCancel() {
    if (_dropOffset != null) setState(() => _dropOffset = null);
    _dragMode = _DragMode.char;
    _dragBase = null;
  }

  // Drop the dragged selection: cut it out and re-insert it at the drop
  // point (one undo step), or duplicate it there when [copy]. Dropping
  // onto the selection itself is a no-op.
  void _moveDragDrop({required bool copy}) {
    final base = _dragBase;
    final drop = _dropOffset;
    _moveDragCancel();
    if (base == null || drop == null) return;
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null || _hexMode) return;
      final (s, e) = base;
      // The selection may have changed under us (async ops): re-validate.
      if (_selStart != s || _selEnd != e || e <= s) return;
      if (drop >= s && drop <= e) return;
      if (_blockedReadOnly()) return;
      final len = e - s;
      if (len > _blockMaxBytes) {
        _toast(_l10n.trf('toast_sel_too_large_copy', [_blockMaxBytes >> 20]));
        return;
      }
      final bytes = await doc.readRangeBytes(s, len);
      _undo.breakCoalescing();
      final reverses = <ReverseEdit>[];
      var at = drop;
      if (!copy) {
        reverses.add(await doc.delete(s, len));
        if (drop > e) at = drop - len; // text after the cut shifted left
      }
      reverses.add(await doc.insertBytes(at, bytes));
      _undo.push(ReverseEdit.group(reverses.reversed.toList()));
      _undo.breakCoalescing();
      _colBlock = null;
      _selAnchor = at;
      _caretOffset = at + len;
      _goalColumn = null;
      _setModified(_undo.isDirty);
      await _afterEdit();
    });
  }

  // Drag after a double/triple-click: the unit under the pointer (word or
  // line) is unioned with the base range; the caret sits on the pointer
  // side so keyboard shift+arrows continue from there.
  Future<void> _extendDragTo(Offset local) async {
    // _selectLineAt sets the base after an await: an update arriving before
    // it must not collapse the selection — just wait for the next one.
    if (_dragBase == null) return;
    final (int, int)? unit = switch (_dragMode) {
      _DragMode.word => _wordRangeAt(local),
      _DragMode.line => await _lineRangeAt(local),
      _DragMode.char || _DragMode.move => null,
    };
    if (unit == null) {
      final off = _offsetAt(local);
      if (off == null) return;
      return _extendDragRange((off, off));
    }
    return _extendDragRange(unit);
  }

  Future<void> _extendDragRange((int, int) unit) async {
    final (bs, be) = _dragBase!;
    final (us, ue) = unit;
    _colBlock = null;
    if (us < bs) {
      _selAnchor = be;
      await _moveCaretTo(us, true);
    } else {
      _selAnchor = bs;
      await _moveCaretTo(ue > be ? ue : be, true);
    }
  }

  // 1 = single, 2 = double (word), 3 = triple (line); a fourth starts over.
  int _tapCountAt(Offset local) {
    final now = DateTime.now();
    final last = _lastTapTime;
    final chained =
        last != null &&
        now.difference(last) < const Duration(milliseconds: 400) &&
        _lastTapPos != null &&
        (_lastTapPos! - local).distance < 6;
    _tapCount = chained && _tapCount < 3 ? _tapCount + 1 : 1;
    _lastTapTime = now;
    _lastTapPos = local;
    return _tapCount;
  }

  // Triple-click: select the whole logical line under the pointer, newline
  // included (so a following delete/cut takes the line out).
  Future<void> _selectLineAt(Offset local) async {
    final r = await _lineRangeAt(local);
    if (r == null) return;
    final (ls, e) = r;
    _dragBase = r;
    _selAnchor = ls;
    _caretOffset = e;
    _goalColumn = null;
    _undo.breakCoalescing();
    await _ensureCaretVisible();
    _scheduleBracketMatch();
    if (mounted) setState(_restartBlink);
  }

  // Same-word highlight ("smart highlighting"): when the selection is one
  // whole word, every other occurrence of it in the window is backlit. The
  // painter gets the word (null = nothing to highlight); it is recomputed
  // per build, which is cheap (a substring of one row).
  String? _smartWord;

  String? _computeSmartWord() {
    if (_hexMode || _columnMode) return null;
    final s = _selStart, e = _selEnd;
    if (e <= s || e - s > 256) return null;
    final ri = _rowIndexOf(s);
    if (ri < 0) return null;
    final row = _rows[ri];
    if (e > row.offset + row.contentBytes) return null; // spans rows
    final text = row.text;
    final a = row.charOfByte(s - row.offset),
        b = row.charOfByte(e - row.offset);
    if (b <= a) return null;
    for (var i = a; i < b; i++) {
      if (_charClassAt(text, i) != 0) return null; // not a plain word
    }
    // Whole word only: not glued to more word characters on either side.
    if (a > 0 && _charClassAt(text, a - 1) == 0) return null;
    if (b < text.length && _charClassAt(text, b) == 0) return null;
    return text.substring(a, b);
  }

  // Double-click: select the run under the pointer — letters/digits/_ make a
  // word; whitespace and punctuation each select their own contiguous run.
  // Runs are found within the visual row (a word split by soft wrap selects
  // only the clicked half — accepted simplification).
  static final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

  // Class of the code point covering code unit [j] of [s]: 0 = word char
  // (letters/digits/_), 1 = whitespace, 2 = other. Both halves of a
  // surrogate pair report the same class, so runs never split a pair.
  static int _charClassAt(String s, int j) {
    if ((s.codeUnitAt(j) & 0xFC00) == 0xDC00) j--; // align to the lead
    final pair = (s.codeUnitAt(j) & 0xFC00) == 0xD800 && j + 1 < s.length;
    final ch = s.substring(j, j + (pair ? 2 : 1));
    if (_wordChar.hasMatch(ch)) return 0;
    if (ch.trim().isEmpty) return 1;
    return 2;
  }

  // alt+left/right: word-wise movement. Forward skips whitespace then runs
  // to the END of the next same-class run; backward mirrors to a run START.
  // Both work on a decoded window around the caret — a word jump is local,
  // and newlines count as whitespace so it crosses lines.
  static const int _wordJumpWindow = 4096;

  Future<int> _wordRightOf(Document doc, int off) async {
    var len = doc.length - off;
    if (len > _wordJumpWindow) len = _wordJumpWindow;
    if (len <= 0) return off;
    final d = await doc.readRangeDecoded(off, len);
    final t = d.text;
    if (t.isEmpty) return off;
    var i = 0;
    while (i < t.length && _charClassAt(t, i) == 1) {
      i++;
    }
    if (i < t.length) {
      final c = _charClassAt(t, i);
      while (i < t.length && _charClassAt(t, i) == c) {
        i++;
      }
    }
    return off + d.byteForCodeUnit(i);
  }

  Future<int> _wordLeftOf(Document doc, int off) async {
    if (off <= 0) return 0;
    var start = off - _wordJumpWindow;
    if (start < 0) start = 0;
    final d = await doc.readRangeDecoded(start, off - start);
    final t = d.text;
    if (t.isEmpty) return off;
    var i = t.length;
    while (i > 0 && _charClassAt(t, i - 1) == 1) {
      i--;
    }
    if (i > 0) {
      final c = _charClassAt(t, i - 1);
      while (i > 0 && _charClassAt(t, i - 1) == c) {
        i--;
      }
    }
    return start + d.byteForCodeUnit(i);
  }

  @override
  void caretWord(int dir, int count, bool select) => _enqueueCaret(
    () => _forEachCursor(edit: false, (_) async {
      final doc = _doc;
      if (doc == null || _hexMode) return;
      final d = _visualDir(dir); // visual on RTL rows, see _visualDir
      var target = _caretOffset;
      final steps = count < 1 ? 1 : count;
      for (var i = 0; i < steps; i++) {
        target = d < 0
            ? await _wordLeftOf(doc, target)
            : await _wordRightOf(doc, target);
      }
      await _moveCaretTo(target, select);
    }),
  );

  /// Delete to the previous (-1) / next (+1) word boundary — Ctrl+Backspace
  /// and Ctrl+Delete on Windows/Linux, ⌥⌫ / ⌥⌦ on macOS.
  ///
  /// Reuses the same boundaries as [caretWord], so "how far is a word" is one
  /// definition shared by jumping and deleting. A selection is deleted instead
  /// (that is what every editor does), which also keeps the multi-cursor case
  /// simple: each cursor deletes its own run.
  @override
  void deleteWord(int dir, int count) => _enqueueCaret(
    () => _forEachCursor((_) async {
      if (_blockedReadOnly()) return;
      final doc = _doc;
      if (doc == null || _hexMode) return;
      _colBlock = null;
      if (_selEnd > _selStart) {
        _undo.push(await doc.delete(_selStart, _selEnd - _selStart));
        _undo.breakCoalescing();
        _caretOffset = _selStart;
        _selAnchor = null;
      } else {
        var target = _caretOffset;
        final steps = count < 1 ? 1 : count;
        for (var i = 0; i < steps; i++) {
          target = dir < 0
              ? await _wordLeftOf(doc, target)
              : await _wordRightOf(doc, target);
        }
        final from = target < _caretOffset ? target : _caretOffset;
        final to = target < _caretOffset ? _caretOffset : target;
        if (to <= from) return;
        _undo.push(await doc.delete(from, to - from));
        _undo.breakCoalescing();
        _caretOffset = from;
        _selAnchor = null;
      }
      _goalColumn = null;
      _setModified(_undo.isDirty);
      await _afterEdit();
    }),
  );

  /// Select the whole logical line the caret is on (VS Code's Ctrl+L), the
  /// newline included so a following press extends line by line.
  @override
  void selectLine() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode) return;
    // Extend from wherever the selection already ends, so repeated presses
    // swallow one more line each time.
    final from = _selEnd > _selStart ? _selStart : _caretOffset;
    final cur = _selEnd > _selStart ? _selEnd : _caretOffset;
    final start = await doc.lineStartOf(from);
    var end = await doc.nextLineStart(cur);
    if (end == cur && cur < doc.length) end = doc.length;
    _selAnchor = start;
    await _moveCaretTo(end, true);
  });

  /// shift+enter: a bare newline, no auto-indent — what Enter does with the
  /// setting off. Same funnel as typed text (multi-cursor, undo coalescing,
  /// the read-only guard inside _doInsert). Handled as a key command, so the
  /// IME never sees the Enter and cannot add its own newline.
  @override
  void insertNewlinePlain() => _enqueueCaret(
    () => _forEachCursor((_) => _doInsert('\n', autoIndent: false)),
  );

  /// Open a blank line below (+1) / above (-1) the caret's line and go to it —
  /// VS Code's Ctrl+Enter / Ctrl+Shift+Enter. Works from anywhere in the line,
  /// which is the point: no need to go to the end first.
  @override
  void insertLine(int dir) => _enqueueCaret(
    () => _forEachCursor((_) async {
      if (_blockedReadOnly()) return;
      final doc = _doc;
      if (doc == null || _hexMode) return;
      _colBlock = null;
      final lineStart = await doc.lineStartOf(_caretOffset);
      final at = dir < 0 ? lineStart : await doc.nextLineStart(_caretOffset);
      // Keep the caller's indentation, like pressing Enter does.
      final head = await doc.readRangeDecoded(
        lineStart,
        (_caretOffset - lineStart).clamp(0, 4096),
      );
      final indent = RegExp(r'^[ \t]*').firstMatch(head.text)?.group(0) ?? '';
      // Appending past a last line with no terminator needs the newline first;
      // everywhere else the blank line goes in ahead of the following line.
      final atEof = dir > 0 && at == doc.length && !await _endsWithNewline(doc);
      final ins = atEof ? '$_newline$indent' : '$indent$_newline';
      _undo.breakCoalescing();
      _undo.push(await doc.insert(at, ins));
      _undo.breakCoalescing();
      // Indent and newline are ASCII, so UTF-16 length == byte length here.
      _caretOffset = atEof ? at + ins.length : at + indent.length;
      _selAnchor = null;
      _goalColumn = null;
      _setModified(_undo.isDirty);
      await _afterEdit();
    }),
  );

  /// Whether the document's last byte is a line terminator.
  Future<bool> _endsWithNewline(Document doc) async {
    if (doc.length == 0) return false;
    final b = await doc.readRangeBytes(doc.length - 1, 1);
    return b.isNotEmpty && (b.last == 0x0a || b.last == 0x0d);
  }

  // Byte range [line start, next line start) of the logical line under the
  // pointer (newline included; the last line runs to EOF).
  Future<(int, int)?> _lineRangeAt(Offset local) async {
    final doc = _doc;
    if (doc == null || _rows.isEmpty) return null;
    final row = (local.dy / _lineHeight).floor().clamp(0, _rows.length - 1);
    final ls = await doc.lineStartOf(_rows[row].offset);
    final ns = await doc.nextLineStart(ls);
    return (ls, ns < 0 ? doc.length : ns);
  }

  Future<void> _selectWordAt(Offset local) async {
    final r = _wordRangeAt(local);
    if (r == null) return;
    _dragBase = r;
    _colBlock = null;
    _selAnchor = r.$1;
    await _moveCaretTo(r.$2, true);
  }

  // Byte range of the word (run of same-class characters) under the pointer
  // within its visual row; null on an empty row or nothing shown.
  (int, int)? _wordRangeAt(Offset local) {
    final win = _window;
    final doc = _doc;
    if (_hexMode || win == null || doc == null || _rows.isEmpty) return null;
    final gw = _gutterWidthFor(_anchorLine, win.lines.length);
    final row = (local.dy / _lineHeight).floor().clamp(0, _rows.length - 1);
    final line = _rows[row].text;
    if (line.isEmpty) return null;
    final rowStart = _rows[row].offset;
    final para = _buildLine(
      line,
      _layoutMaxW,
      null,
      _rowStartColumn(_window, _rows[row]),
      _baseRtl,
    );
    final dx = (local.dx - gw - _gutterPad + _scrollX - _rowShift(para)).clamp(
      0.0,
      double.infinity,
    );
    var i = para.charAt(dx);
    if (i >= line.length) i = line.length - 1;
    if (i < 0) i = 0;

    int classOf(int j) => _charClassAt(line, j);

    final cls = classOf(i);
    var start = i, end = i + 1;
    while (start > 0 && classOf(start - 1) == cls) {
      start--;
    }
    while (end < line.length && classOf(end) == cls) {
      end++;
    }
    return (
      rowStart + _rows[row].byteOfChar(start),
      rowStart + _rows[row].byteOfChar(end),
    );
  }

  Future<void> _placeCaretAt(Offset local, {required bool select}) async {
    if (_hexMode) {
      final ro = _hexKey.currentContext?.findRenderObject();
      if (ro is! RenderHexViewport) return;
      // A click/drag past the last byte lands after it (see _hexMoveCaret).
      final hit = ro.hitTest2(local, allowEnd: true);
      if (hit == null) return;
      setState(() {
        if (select) {
          _selAnchor ??= _caretOffset;
        } else {
          _selAnchor = null;
        }
        _caretOffset = hit.offset;
        _hexArea = hit.area == HexArea.ascii ? HexArea.ascii : HexArea.hex;
        _hexNibble = hit.area == HexArea.hex ? hit.nibble : 0;
      });
      _syncIme(); // the text column has an IME connection, the hex column not
      _restartBlink();
      // A click on the half row cut off at the bottom scrolls it fully into
      // view, as _moveCaretTo does for the text view.
      await _ensureCaretVisibleHex();
      return;
    }
    final off = _offsetAt(local);
    if (off == null) return;
    // Column mode: a click past a line's end lands on a virtual column.
    final vcol = _columnMode ? _virtualColumnAt(local) : null;
    await _moveCaretTo(off, select, virtualCol: vcol);
    if (vcol != null) _goalColumn = vcol; // up/down keep the virtual column
  }

  // Column mode hit-test past the end of a row: the display column the
  // pointer is on, counting the empty space after the text in cells of the
  // monospace font. Null when the pointer is over (or before) the text.
  int? _virtualColumnAt(Offset local) {
    final win = _window;
    if (win == null || _rows.isEmpty) return null;
    final gw = _gutterWidthFor(_anchorLine, win.lines.length);
    final row = (local.dy / _lineHeight).floor().clamp(0, _rows.length - 1);
    final line = _rows[row].text;
    final dx = local.dx - gw - _gutterPad + _scrollX;
    final para = _buildLine(
      line,
      _layoutMaxW,
      null,
      _rowStartColumn(_window, _rows[row]),
      _baseRtl,
    );
    final extra = (dx - para.width) / editorCharWidth;
    if (extra < 0.5) return null;
    return columnCount(line, tabSize: _tabSize) + extra.round();
  }

  // Pixel → document byte offset in text mode (null when nothing is shown).
  int? _offsetAt(Offset local) {
    final win = _window;
    final doc = _doc;
    if (win == null || doc == null || _rows.isEmpty) return null;
    final gw = _gutterWidthFor(_anchorLine, win.lines.length);
    // The vertical hit is a "visual row" (a wrapped logical line may span several).
    final row = (local.dy / _lineHeight).floor().clamp(0, _rows.length - 1);
    final line = _rows[row].text;
    final rowStart = _rows[row].offset;
    final para = _buildLine(
      line,
      _layoutMaxW,
      null,
      _rowStartColumn(_window, _rows[row]),
      _baseRtl,
    );
    // Add back the horizontal scroll offset (screen x → x within the row); a right-aligned
    // row also subtracts its shift
    final dx = (local.dx - gw - _gutterPad + _scrollX - _rowShift(para)).clamp(
      0.0,
      double.infinity,
    );
    final charIndex = para.charAt(dx).clamp(0, line.length);
    // UTF-16 index -> byte within the row, via the codec's decode map.
    return rowStart + _rows[row].byteOfChar(charIndex);
  }

  // ── Multi-cursor ─────────────────────────────────────────────

  void _syncExtraView() {
    _extraCaretsView = [for (final c in _extra) c.caret];
    _extraSelsView = selectionPairs(_extra);
  }

  void _clearExtra() {
    if (!_multi) return;
    _extra = const [];
    _syncExtraView();
  }

  // Replay [op] — ordinary single-cursor code acting on the primary
  // caret/anchor — once per cursor, highest offset first so one cursor's
  // splices never move a cursor still to run; cursors already done shift by
  // each later net byte delta (multi_cursor.dart). Every reverse pushed on
  // the way becomes ONE undo step; view refresh happens once at the end.
  // [op] gets the cursor's index in document order (paste distribution).
  Future<void> _forEachCursor(
    Future<void> Function(int docOrderIndex) op, {
    bool edit = true,
  }) async {
    if (!_multi) return op(0);
    final doc = _doc;
    if (doc == null) return;
    final primary = Cursor(
      _caretOffset,
      anchor: _selAnchor,
      goal: _goalColumn,
      rowEnd: _caretAtRowEnd,
    );
    final all = [primary, ..._extra];
    final order = editOrder(all);
    final done = <Cursor>[];
    _inMulti = true;
    if (edit) _undo.beginGroup();
    try {
      for (var k = 0; k < order.length; k++) {
        final c = order[k];
        _caretOffset = c.caret;
        _caretAtRowEnd = c.rowEnd;
        _selAnchor = c.anchor;
        _goalColumn = c.goal;
        _colBlock = null;
        final before = doc.length;
        await op(order.length - 1 - k);
        c.caret = _caretOffset;
        c.anchor = _selAnchor;
        c.goal = _goalColumn;
        c.rowEnd = _caretAtRowEnd;
        shiftProcessed(done, doc.length - before);
        done.add(c);
      }
    } finally {
      _inMulti = false;
      if (edit) _undo.endGroup();
    }
    _caretOffset = primary.caret;
    _caretAtRowEnd = primary.rowEnd;
    _selAnchor = primary.anchor;
    _goalColumn = primary.goal;
    _extra = mergeExtras(all, primary);
    _syncExtraView();
    if (edit) {
      _undo.breakCoalescing();
      _setModified(_undo.isDirty);
      await _afterEdit(keepCursors: true);
    } else {
      _undo.breakCoalescing();
      await _ensureCaretVisible();
      _scheduleBracketMatch();
      if (mounted) setState(_restartBlink);
    }
  }

  // alt+click: toggle a cursor at the clicked spot.
  void _addCursorAt(Offset local) {
    final off = _offsetAt(local);
    if (off == null) return;
    if (_extra.length + 1 >= maxCursors && !_extra.any((c) => c.caret == off)) {
      return;
    }
    _colBlock = null;
    _undo.breakCoalescing();
    setState(() {
      _extra = toggleCursor(_extra, _caretOffset, off);
      _syncExtraView();
      _restartBlink();
    });
  }

  @override
  void clearCursors() {
    if (!_multi) return;
    setState(_clearExtra);
  }

  // ctrl+alt+up/down: a new cursor one visual row above the topmost / below
  // the bottommost cursor, keeping its display column.
  @override
  void addCursorVertical(int dir) => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || _extra.length + 1 >= maxCursors) return;
    final all = [Cursor(_caretOffset, goal: _goalColumn), ..._extra];
    final edge = dir < 0
        ? all.reduce((a, b) => a.caret <= b.caret ? a : b)
        : all.reduce((a, b) => a.caret >= b.caret ? a : b);
    // _verticalOnce reads the goal column from the primary's slot.
    final savedGoal = _goalColumn;
    _goalColumn = edge.goal;
    if (_goalColumn == null) {
      final ls = await doc.lineStartOf(edge.caret);
      _goalColumn = columnCount(await doc.readRangeString(ls, edge.caret - ls), tabSize: _tabSize);
    }
    final goal = _goalColumn;
    final off = await _verticalOnce(edge.caret, dir);
    _goalColumn = savedGoal;
    if (off == edge.caret) return; // at the document's edge already
    if (off == _caretOffset || _extra.any((c) => c.caret == off)) return;
    _colBlock = null;
    _undo.breakCoalescing();
    final next = [..._extra, Cursor(off, goal: goal)]
      ..sort((a, b) => a.caret.compareTo(b.caret));
    _extra = next;
    _syncExtraView();
    if (mounted) setState(_restartBlink);
  });

  // The text an "occurrence" command looks for: the primary selection, or
  // the word at the caret (which then gets selected). null = nothing usable.
  Future<(int, int, String)?> _occurrenceSeed() async {
    final doc = _doc!;
    if (_selEnd > _selStart) {
      if (_selEnd - _selStart > 4096) return null;
      return (
        _selStart,
        _selEnd,
        await doc.readRangeString(_selStart, _selEnd - _selStart),
      );
    }
    // Word around the caret from a small decoded window.
    const half = 2048;
    final from = _caretOffset - half < 0 ? 0 : _caretOffset - half;
    var len = _caretOffset + half - from;
    if (from + len > doc.length) len = doc.length - from;
    if (len <= 0) return null;
    final d = await doc.readRangeDecoded(from, len);
    final t = d.text;
    final ci = d.codeUnitForByte(_caretOffset - from);
    var a = ci, b = ci;
    while (a > 0 && _isWordCharAt(t, a - 1)) {
      a--;
    }
    while (b < t.length && _isWordCharAt(t, b)) {
      b++;
    }
    if (b <= a) return null;
    return (
      from + d.byteForCodeUnit(a),
      from + d.byteForCodeUnit(b),
      t.substring(a, b),
    );
  }

  // ctrl+shift+l: a selecting cursor on every occurrence of the selection
  // (or the caret's word). Literal, case-sensitive, capped at maxCursors.
  @override
  void selectAllOccurrences() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode) return;
    final seed = await _occurrenceSeed();
    if (seed == null) return;
    final (ps, pe, text) = seed;
    final re = compileQuery(text, regex: false, caseSensitive: true);
    final found = <Cursor>[];
    var pos = 0;
    while (found.length < maxCursors) {
      final m = await searchForward(doc, re, pos);
      if (m == null) break;
      if (m.start != ps) found.add(Cursor(m.end, anchor: m.start));
      pos = m.end;
    }
    _colBlock = null;
    _selAnchor = ps;
    _caretOffset = pe;
    _extra = found; // ascending already (forward scan)
    _syncExtraView();
    _undo.breakCoalescing();
    _toast(_l10n.trf('toast_cursors', [found.length + 1]));
    await _ensureCaretVisible();
    if (mounted) setState(_restartBlink);
  });

  // ctrl+alt+d: add a selecting cursor on the next occurrence after the
  // last cursor (wrapping); it becomes the primary so the view follows it.
  @override
  void addNextOccurrence() => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || _hexMode || _extra.length + 1 >= maxCursors) return;
    final seed = await _occurrenceSeed();
    if (seed == null) return;
    final (ps, pe, text) = seed;
    final re = compileQuery(text, regex: false, caseSensitive: true);
    final all = [Cursor(pe, anchor: ps), ..._extra];
    final taken = {for (final c in all) c.selStart};
    var from = all.map((c) => c.selEnd).reduce((a, b) => a > b ? a : b);
    SearchMatch? hit;
    for (var wrapped = false; ; wrapped = true) {
      final m = await searchForward(doc, re, from);
      if (m != null && !taken.contains(m.start)) {
        hit = m;
        break;
      }
      if (m == null) {
        if (wrapped) break;
        from = 0;
        continue;
      }
      from = m.end;
    }
    _colBlock = null;
    _undo.breakCoalescing();
    if (hit == null) {
      // Nothing new: still make sure the seed word itself is selected.
      _selAnchor = ps;
      _caretOffset = pe;
    } else {
      _extra = all..sort((a, b) => a.caret.compareTo(b.caret));
      _selAnchor = hit.start;
      _caretOffset = hit.end;
    }
    _syncExtraView();
    await _ensureCaretVisible();
    if (mounted) setState(_restartBlink);
  });

  // ── Column-mode block editing ─────────────────────────────────────

  // Replace the rectangular selection with [insert] ('' = pure delete): one edit per line,
  // applied **bottom-up** (so every edit's offsets are still those of the original document),
  // with the reverse edits grouped into **one undo step**.
  //
  // The block does not vanish after the edit; it collapses to a "zero-width block at the new
  // left edge" — so typing several characters in a row puts each of them into every line
  // (which is the point of column editing), instead of the first character going into all
  // lines and the rest into one. Returns false = nothing to do (the caller falls back to the
  // single-caret path).
  // Column editor: a different text per line of [blk] (a number sequence or
  // one text), padded with spaces on lines shorter than the block's left
  // edge so every insertion lands in the same column. One undo step; the
  // block collapses to its left edge.
  Future<bool> _doBlockEditPerLine(
    ColumnBlock blk,
    ColumnEditorSpec spec,
  ) async {
    final doc = _doc;
    if (doc == null) return false;
    final got = await _blockLines(blk);
    if (got == null) {
      _toast(_l10n.trf('toast_sel_too_large_edit', [_blockMaxBytes >> 20]));
      return true;
    }
    final (lines, starts, maps) = got;
    final texts = columnTexts(spec, lines.length);
    final perLine = <String>[];
    final perBytes = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final full = padForColumn(lines[i], blk.leftCol, tabSize: _tabSize) + texts[i];
      perLine.add(full);
      perBytes.add(doc.codec.encode(full).bytes.length);
    }
    final edits = blockEdits(
      blk,
      lines,
      starts,
      maps: maps,
      tabSize: _tabSize,
      insertPerLine: perLine,
      insertBytesPerLine: perBytes,
    );
    if (edits.isEmpty) return false;
    final reverses = <ReverseEdit>[];
    for (final e in edits) {
      if (e.end > e.start) {
        reverses.add(await doc.delete(e.start, e.end - e.start));
      }
      if (e.text.isNotEmpty) {
        reverses.add(await doc.insert(e.start, e.text));
      }
    }
    // Reverses in reverse order (see _doBlockEdit).
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();
    final top = shiftedLineStart(edits, blk.topLine);
    final bottom = shiftedLineStart(edits, blk.bottomLine);
    final caretLine = blk.caretLine == blk.topLine ? top : bottom;
    _colBlock = _columnMode
        ? ColumnBlock(
            anchorLine: blk.anchorLine == blk.topLine ? top : bottom,
            anchorCol: blk.leftCol,
            caretLine: caretLine,
            caretCol: blk.leftCol,
          )
        : null;
    final ci = starts.indexOf(blk.caretLine);
    final padded = padForColumn(ci >= 0 ? lines[ci] : '', blk.leftCol, tabSize: _tabSize);
    _caretOffset =
        caretLine +
        doc.codec
            .encode(
              padded.substring(0, charIndexForColumn(padded, blk.leftCol, tabSize: _tabSize)),
            )
            .bytes
            .length;
    _selAnchor = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
    return true;
  }

  // Edit → Column editor…: the block is the column-mode selection, or (in text
  // mode) the lines the selection covers at the caret's column.
  Future<void> _applyColumnEditor(ColumnEditorSpec spec) async {
    final doc = _doc;
    if (doc == null || _hexMode || _blockedReadOnly()) return;
    ColumnBlock? blk = _columnMode ? _colBlock : null;
    if (blk == null) {
      final (ls, col) = await _lineColOf(_caretOffset);
      var top = ls, bottom = ls;
      if (_selEnd > _selStart) {
        top = await doc.lineStartOf(_selStart);
        bottom = await doc.lineStartOf(_selEnd - 1);
      }
      blk = ColumnBlock(
        anchorLine: top,
        anchorCol: col,
        caretLine: bottom,
        caretCol: col,
      );
    }
    _undo.breakCoalescing();
    await _doBlockEditPerLine(blk, spec);
  }

  Future<bool> _doBlockEdit(String insert) async {
    final doc = _doc;
    final blk = _colBlock;
    if (doc == null || blk == null) return false;
    final got = await _blockLines(blk);
    if (got == null) {
      _toast(_l10n.trf('toast_sel_too_large_edit', [_blockMaxBytes >> 20]));
      return true; // handled (don't fall through to the single-caret path, which would edit one line only)
    }
    final (lines, starts, maps) = got;
    final insertBytes = doc.codec.encode(insert).bytes.length;
    // Lines shorter than the block's left edge get spaces up to it first, so
    // the typed text lands on the same column everywhere (the virtual
    // columns become real ones). A pure delete never pads.
    List<String>? perLine;
    List<int>? perBytes;
    if (insert.isNotEmpty) {
      perLine = [
        for (final l in lines)
          padForColumn(l, blk.leftCol, tabSize: _tabSize) + insert,
      ];
      perBytes = [for (final t in perLine) doc.codec.encode(t).bytes.length];
    }
    final edits = blockEdits(
      blk,
      lines,
      starts,
      insert: insert,
      maps: maps,
      insertBytes: insertBytes,
      insertPerLine: perLine,
      insertBytesPerLine: perBytes,
      tabSize: _tabSize,
    );
    if (edits.isEmpty) return false;

    final reverses = <ReverseEdit>[];
    for (final e in edits) {
      if (e.end > e.start) {
        reverses.add(await doc.delete(e.start, e.end - e.start));
      }
      if (e.text.isNotEmpty) {
        reverses.add(await doc.insert(e.start, e.text));
      }
    }
    // The reverse edits must be ordered **in reverse** (the last applied edit first), so undo
    // never uses an offset that has been shifted.
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();

    // New left edge (the inserted text counts as columns) + each line's post-edit start →
    // collapse to a zero-width block, caret staying on its original line.
    final newLeft = blk.leftCol + columnCount(insert, tabSize: _tabSize);
    final top = shiftedLineStart(edits, blk.topLine);
    final bottom = shiftedLineStart(edits, blk.bottomLine);
    final caretLine = blk.caretLine == blk.topLine ? top : bottom;
    _colBlock = ColumnBlock(
      anchorLine: blk.anchorLine == blk.topLine ? top : bottom,
      anchorCol: newLeft,
      caretLine: caretLine,
      caretCol: newLeft,
    );
    final ci = starts.indexOf(blk.caretLine);
    final caretText = ci >= 0 ? lines[ci] : '';
    _caretOffset =
        caretLine +
        byteOffsetOfColumn(
          // The line's content after the edit: the slice replaced by insert (only up to the
          // left edge + the inserted part is needed), including the padding a short line got
          // up to the left edge.
          caretText.substring(0, charIndexForColumn(caretText, blk.leftCol, tabSize: _tabSize)) +
              (insert.isEmpty ? '' : padForColumn(caretText, blk.leftCol, tabSize: _tabSize)) +
              insert,
          newLeft,
          byteLen: (s) => doc.codec.encode(s).bytes.length,
          tabSize: _tabSize,
        );
    _selAnchor = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
    return true;
  }

  // Column-mode delete: a rectangle with width is deleted; a zero-width multi-line one is
  // first widened by one column to the left (backspace) / right (delete) and then deleted,
  // i.e. "delete one character on every line at once".
  Future<bool> _doBlockDelete(int dir) async {
    final b = _colBlock;
    if (b == null) return false;
    if (!b.hasWidth) {
      if (!b.multiLine) return false; // single-point selection → ordinary delete
      final l = dir < 0 ? b.leftCol - 1 : b.leftCol;
      if (l < 0) return true; // already at the line start, nothing to delete
      _colBlock = ColumnBlock(
        anchorLine: b.anchorLine,
        anchorCol: l,
        caretLine: b.caretLine,
        caretCol: l + 1,
      );
    }
    return _doBlockEdit('');
  }

  // ── Editing (phase 4): insert/delete go through Document + UndoStack, in document coordinates ──

  // Insert text (replacing the selection). Consecutive inserts coalesce into one undo entry.
  // [autoIndent] false = a bare newline even when the setting is on
  // (shift+enter, edit.newlinePlain).
  Future<void> _doInsert(String rawText, {bool autoIndent = true}) async {
    final doc = _doc;
    if (doc == null || rawText.isEmpty) return;
    if (_blockedReadOnly()) return;
    // Newline normalization: unify any \r\n / \n into this file's newline style (so Enter
    // never inserts the wrong kind).
    var text = rawText.replaceAll('\r\n', '\n').replaceAll('\n', _newline);
    // Auto-indent: a typed Enter (just the newline) carries the current
    // line's leading whitespace — up to the caret, so pressing Enter inside
    // the indentation does not duplicate what moves down with the caret.
    if (text == _newline &&
        autoIndent &&
        AppSettings.instance.autoIndent &&
        !_columnMode) {
      final at = _selEnd > _selStart ? _selStart : _caretOffset;
      text += await _leadingWhitespaceBefore(doc, at);
    }
    // Auto-close brackets/quotes for a single typed character.
    if (text.length == 1 &&
        !_columnMode &&
        !_hexMode &&
        AppSettings.instance.autoCloseBrackets &&
        (_closers.containsKey(text) || _closers.containsValue(text))) {
      if (await _autoCloseTyped(doc, text)) return;
    }
    // Column mode: typing goes into every line of the rectangle (except a paste containing
    // newlines — that is not a rectangular operation).
    if (_columnMode && _colBlock != null && !text.contains('\n')) {
      if (await _doBlockEdit(text)) return;
    }
    _colBlock = null; // single-caret path → this edit shifts the old block's line starts, so it cannot stay
    if (_selEnd > _selStart) {
      final rev = await doc.delete(_selStart, _selEnd - _selStart);
      _undo.push(rev);
      _undo.breakCoalescing();
      _caretOffset = _selStart;
      _selAnchor = null;
    }
    // Encode with the document's codec; characters it cannot represent are
    // written as literal U+XXXX notation (tell the user when that happens).
    final enc = doc.codec.encode(text);
    final rev = await doc.insertBytes(_caretOffset, enc.bytes);
    if (enc.fallbackCount > 0) {
      _toast(
        _l10n.trf('toast_unencodable_many', [
          enc.fallbackCount,
          doc.codec.name,
        ]),
      );
    }
    _undo.push(rev, coalesce: true);
    _caretOffset += enc.bytes.length;
    _selAnchor = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  }

  // Leading spaces/tabs of the line containing [at], counted only up to [at].
  Future<String> _leadingWhitespaceBefore(Document doc, int at) async {
    final ls = await doc.lineStartOf(at);
    final len = at - ls;
    if (len <= 0) return '';
    final d = await doc.readRangeDecoded(ls, len < 4096 ? len : 4096);
    final t = d.text;
    var i = 0;
    while (i < t.length &&
        (t.codeUnitAt(i) == 0x20 || t.codeUnitAt(i) == 0x09)) {
      i++;
    }
    return t.substring(0, i);
  }

  // Tab key: with a selection spanning lines it indents them; otherwise it
  // inserts a tab character, or (settings → Tab key inserts spaces) the spaces that
  // reach the next tab stop from the caret's display column.
  Future<void> _tabKey() async {
    final doc = _doc;
    if (doc == null) return;
    if (_selEnd > _selStart && !_columnMode) {
      final a = await doc.lineStartOf(_selStart);
      final b = await doc.lineStartOf(_selEnd - 1);
      if (b > a) return _indentLines(1);
    }
    if (!AppSettings.instance.insertSpaces) return _doInsert('\t');
    final at = _selEnd > _selStart ? _selStart : _caretOffset;
    final ls = await doc.lineStartOf(at);
    final len = at - ls;
    final d = await doc.readRangeDecoded(ls, len < 65536 ? len : 65536);
    final col = displayColumn(d.text, _tabSize);
    return _doInsert(' ' * (_tabSize - col % _tabSize));
  }

  // Indent (dir > 0) or outdent (dir < 0) every line touched by the
  // selection (the caret's line without one) — one undo step. The selection
  // afterwards spans the same lines from their first start.
  Future<void> _indentLines(int dir) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null || _hexMode || _columnMode) return;
    final s = _selEnd > _selStart ? _selStart : _caretOffset;
    final e = _selEnd > _selStart ? _selEnd : _caretOffset;
    final first = await doc.lineStartOf(s);
    final last = await doc.lineStartOf(e > s ? e - 1 : e);
    if (last - first > _blockMaxBytes) {
      _toast(_l10n.trf('toast_sel_too_large_copy', [_blockMaxBytes >> 20]));
      return;
    }
    final starts = <int>[first];
    var pos = first;
    while (pos < last) {
      final ns = await doc.nextLineStart(pos);
      if (ns < 0 || ns > last) break;
      starts.add(ns);
      pos = ns;
    }
    final unit = doc.codec
        .encode(AppSettings.instance.insertSpaces ? ' ' * _tabSize : '\t')
        .bytes;
    final reverses = <ReverseEdit>[];
    var delta = 0; // bytes added (removed when negative) in total
    // Bottom-up, so earlier offsets stay valid.
    for (final start in starts.reversed) {
      if (dir > 0) {
        reverses.add(await doc.insertBytes(start, unit));
        delta += unit.length;
        continue;
      }
      // Outdent: one tab, or up to tabSize leading spaces.
      final le = await doc.lineEndOf(start);
      final look = le - start;
      if (look <= 0) continue;
      final d = await doc.readRangeDecoded(start, look < 64 ? look : 64);
      final t = d.text;
      var n = 0;
      if (t.startsWith('\t')) {
        n = 1;
      } else {
        while (n < t.length && n < _tabSize && t.codeUnitAt(n) == 0x20) {
          n++;
        }
      }
      if (n == 0) continue;
      final bytes = d.byteForCodeUnit(n);
      reverses.add(await doc.delete(start, bytes));
      delta -= bytes;
    }
    if (reverses.isEmpty) return;
    _undo.breakCoalescing();
    _undo.push(ReverseEdit.group(reverses.reversed.toList()));
    _undo.breakCoalescing();
    _colBlock = null;
    if (e > s) {
      _selAnchor = first;
      final ne = e + delta;
      _caretOffset = ne < first ? first : ne;
    } else {
      final nc = _caretOffset + (dir > 0 ? unit.length : delta);
      _caretOffset = nc < first ? first : nc;
      _selAnchor = null;
    }
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  }

  // Backspace: delete the selection if any, else one character left of the caret.
  Future<void> _doBackspace() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    if (_columnMode && await _doBlockDelete(-1)) return;
    _colBlock = null;
    if (_selEnd > _selStart) {
      final rev = await doc.delete(_selStart, _selEnd - _selStart);
      _undo.push(rev);
      _undo.breakCoalescing();
      _caretOffset = _selStart;
      _selAnchor = null;
    } else {
      if (_caretOffset == 0) return;
      if (AppSettings.instance.autoCloseBrackets &&
          await _autoCloseBackspace(doc)) {
        return;
      }
      final prev = await doc.charLeft(_caretOffset);
      final rev = await doc.delete(prev, _caretOffset - prev);
      _undo.push(rev, coalesce: true);
      _caretOffset = prev;
      _selAnchor = null; // a stale collapsed anchor must not become a selection
    }
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  }

  // Forward delete: delete the selection if any, else one character right of the caret.
  Future<void> _doDeleteForward() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    if (_columnMode && await _doBlockDelete(1)) return;
    _colBlock = null;
    if (_selEnd > _selStart) {
      final rev = await doc.delete(_selStart, _selEnd - _selStart);
      _undo.push(rev);
      _caretOffset = _selStart;
      _selAnchor = null;
    } else {
      if (_caretOffset >= doc.length) return;
      final next = await doc.charRight(_caretOffset);
      final rev = await doc.delete(_caretOffset, next - _caretOffset);
      _undo.push(rev, coalesce: true);
      _selAnchor = null; // see _doBackspace
    }
    // (No breakCoalescing here: consecutive Deletes coalesce like Backspaces
    // — _mergeReverse joins deletions made at the same offset.)
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  }

  // After an edit: re-read the window, ensure the caret is visible, repaint.
  // Inside a multi-cursor replay this is deferred to the loop's end; an edit
  // made outside the loop collapses the extra cursors (stale offsets).
  Future<void> _afterEdit({bool keepCursors = false}) async {
    if (_inMulti) return;
    if (_multi && !keepCursors) _clearExtra();
    _lastEditOffset = _caretOffset; // ctrl+k ctrl+q target
    _caretPosCache = null; // line numbers / columns may have shifted
    widget.controller.docEpoch.value++; // outline panel rescans (debounced)
    _scheduleWordScan();
    await _autoRtlUntitled();
    // The whole-file highlight cache is not dropped here: the splice hook recorded the edit and
    // _reload turns it into dirty lines that get synced incrementally.
    await _reload();
    await _ensureCaretVisible();
    await _refreshBom(); // an edit at offset 0 (incl. undo) may add/remove it
    _scheduleBracketMatch();
    if (mounted) setState(_restartBlink);
  }

  @override
  void undo() => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final applied = await _undo.undo(_doc!);
    if (applied == null) return;
    _caretOffset = applied.caretAfterApply; // caret returns to the edit site
    _selAnchor = null;
    _colBlock = null; // line starts may have shifted after undo/redo; the old rectangle cannot stay
    _goalColumn = null;
    _setModified(_undo.isDirty); // undone back to the saved state = clean
    await _afterEdit();
  });

  @override
  void redo() => _enqueueCaret(() async {
    if (_blockedReadOnly()) return;
    final applied = await _undo.redo(_doc!);
    if (applied == null) return;
    _caretOffset = applied.caretAfterApply;
    _selAnchor = null;
    _colBlock = null;
    _goalColumn = null;
    _setModified(_undo.isDirty);
    await _afterEdit();
  });

  // ── IME / TextInput (DeltaTextInputClient) ──────────────────
  // Character input (including CJK composition) goes through TextInput; control keys
  // (backspace/delete/arrows/undo) go through _onKey.

  void _attachIme() {
    if (_doc == null || !mounted) return;
    if (_ime != null && _ime!.attached) return;
    _ime = TextInput.attach(
      this,
      TextInputConfiguration(
        // Multi-window Flutter needs the owning FlutterView, or attach fails with "view ID is null".
        viewId: View.of(context).viewId,
        inputType: TextInputType.multiline,
        enableDeltaModel: true,
        inputAction: TextInputAction.newline,
      ),
    );
    _imeValue = TextEditingValue.empty;
    _imeCommitted = 0;
    _ime!.setEditingState(_imeValue);
    _ime!.show();
  }

  void _detachIme() {
    _ime?.close();
    _ime = null;
    if (_composing.isNotEmpty && mounted) setState(() => _composing = '');
  }

  void _resetImeBaseline() {
    _imeValue = TextEditingValue.empty;
    _imeCommitted = 0;
    _ime?.setEditingState(_imeValue);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _imeValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) => _imeValue = value;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    var v = _imeValue;
    for (final d in deltas) {
      if (d.oldText != v.text) {
        // Computed against text we have just cleared: after a commit the
        // platform emits several updates in a row (GTK/ibus: preedit
        // changed, commit, preedit end) before it sees our
        // setEditingState(empty), and a non-text update *carries* that old
        // text as the new value. Everything in it was inserted already, so
        // adopt it as the committed baseline instead of inserting it again
        // (bug: one 烏 from libchewing became three).
        Log.instance.d(
          'ime: resync baseline "${v.text}" → "${d.oldText}" (${d.runtimeType})',
        );
        v = TextEditingValue(
          text: d.oldText,
          selection: TextSelection.collapsed(offset: d.oldText.length),
        );
        _imeCommitted = d.oldText.length;
      }
      v = d.apply(v);
    }
    _imeValue = v;
    final composing = v.composing;
    Log.instance.d(
      'ime: ${deltas.map((d) => d.runtimeType).join('+')} '
      'text="${v.text}" composing ${composing.start}..${composing.end}',
    );
    final inComposition = composing.isValid && composing.end <= v.text.length;
    if (inComposition && !composing.isCollapsed) {
      // Composing: shown as an overlay, not yet written to the document
      setState(() => _composing = composing.textInside(v.text));
      return;
    }
    // Composition over (range invalid), or a *collapsed* composing range.
    // The Windows engine sends the latter twice per composition and both
    // times the text must NOT be treated as final: at compose-begin (text
    // still empty) and at compose-commit, when the IME may keep composing
    // (Microsoft Bopomofo commits 咪 and goes on with the next syllable).
    // Resetting the platform's editing state at either point ends the
    // composition in the engine's model, after which every phonetic symbol
    // arrives as plain text (bug: ㄇㄧ landed in the document instead of 咪).
    // So: insert whatever is new beyond what was already inserted, and only
    // wipe the baseline once the range is gone.
    if (v.text.length < _imeCommitted) _imeCommitted = 0; // edited behind us
    final committed = v.text.substring(_imeCommitted);
    _composing = '';
    if (committed.isNotEmpty) {
      _imeCommitted = v.text.length;
      if (_hexMode) {
        // Text column of hex mode: encode with the codec, overwrite/insert
        // those bytes (no line semantics, no completion, no macro).
        final text = committed.replaceAll('\n', '').replaceAll('\r', '');
        if (text.isNotEmpty) _enqueueCaret(() => _hexTypeAscii(text));
      } else {
        _enqueueCaret(() async {
          await _forEachCursor((_) => _doInsert(committed));
          await _completionAfterTyping(committed);
        });
        _recordStep(MacroInsert(committed));
      }
    }
    if (!composing.isValid) {
      _resetImeBaseline(); // clear the baseline; the next input starts fresh
    }
    if (mounted) setState(() {});
  }

  /// Characters of [_imeValue].text already inserted into the document (a
  /// commit that arrived while the composing range was still present).
  int _imeCommitted = 0;

  @override
  void performAction(TextInputAction action) {
    // The newline is already handled by the IME's \n delta (updateEditingValueWithDeltas);
    // inserting here as well would make Enter insert twice.
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
  @override
  void connectionClosed() => _ime = null;
  @override
  void insertTextPlaceholder(Size size) {}
  @override
  void removeTextPlaceholder() {}
  @override
  void showToolbar() {}
  // macOS routes the standard editing key equivalents through NSTextInputContext
  // while a text input connection is open: AppKit turns ⌘X / ⌥← / … into
  // `NSStandardKeyBindingResponding` selectors and hands them to the text input
  // client, so the raw key event never reaches `_onKey` and the keymap never
  // sees the chord (bug: on macOS ⌘X/⌘C/⌘V/⌘A and every ⌥ chord did nothing).
  // Map the selector back to the chord macOS used and run it through the same
  // resolver, so a user's keymap override still decides what actually happens.
  // Selectors we don't map are logged, not swallowed silently.
  static const Map<String, String> _macSelectorChords = {
    'cut:': 'ctrl+x',
    'copy:': 'ctrl+c',
    'paste:': 'ctrl+v',
    'selectAll:': 'ctrl+a',
    'undo:': 'ctrl+z',
    'redo:': 'ctrl+shift+z',
    // shift+return: AppKit's selector when the text input interprets it
    // before us; the keymap binding (edit.newlinePlain) decides.
    'insertLineBreak:': 'shift+enter',
    // ⌥ + arrows: word / paragraph motion.
    'moveWordLeft:': 'alt+left',
    'moveWordRight:': 'alt+right',
    'moveWordLeftAndModifySelection:': 'alt+shift+left',
    'moveWordRightAndModifySelection:': 'alt+shift+right',
    'moveToBeginningOfParagraph:': 'alt+up',
    'moveToEndOfParagraph:': 'alt+down',
    'moveToBeginningOfParagraphAndModifySelection:': 'alt+shift+up',
    'moveToEndOfParagraphAndModifySelection:': 'alt+shift+down',
    // ⌘ + arrows: line / document ends.
    'moveToLeftEndOfLine:': 'ctrl+left',
    'moveToRightEndOfLine:': 'ctrl+right',
    'moveToBeginningOfDocument:': 'ctrl+up',
    'moveToEndOfDocument:': 'ctrl+down',
    'moveToLeftEndOfLineAndModifySelection:': 'ctrl+shift+left',
    'moveToRightEndOfLineAndModifySelection:': 'ctrl+shift+right',
    'moveToBeginningOfDocumentAndModifySelection:': 'ctrl+shift+up',
    'moveToEndOfDocumentAndModifySelection:': 'ctrl+shift+down',
    // ⌥⌫ / ⌥⌦: delete a word.
    'deleteWordBackward:': 'alt+backspace',
    'deleteWordForward:': 'alt+delete',
    // PageUp / PageDown / Home / End on an extended keyboard: AppKit sends
    // these as selectors too (plain PgUp is `scrollPageUp:`, ⌥PgUp is
    // `pageUp:`). They map to the bare keys so the keymap decides — Home/End
    // are line start/end here (VS Code on macOS), not the NSTextView
    // "scroll to document end" default.
    'scrollPageUp:': 'pageup',
    'scrollPageDown:': 'pagedown',
    'pageUp:': 'pageup',
    'pageDown:': 'pagedown',
    'pageUpAndModifySelection:': 'shift+pageup',
    'pageDownAndModifySelection:': 'shift+pagedown',
    'scrollToBeginningOfDocument:': 'home',
    'scrollToEndOfDocument:': 'end',
  };

  @override
  void performSelector(String selectorName) {
    final spec = _macSelectorChords[selectorName];
    if (spec == null) {
      Log.instance.d('performSelector unmapped: $selectorName');
      return;
    }
    final chord = parseChord(spec, isMac: Platform.isMacOS);
    // If `_onKey` just handled this very chord, the engine delivered both paths
    // (it does not on macOS today, but a future engine might) — don't run twice.
    final now = DateTime.now();
    if (_lastFiredChord == chord.canonical &&
        now.difference(_lastFiredAt).inMilliseconds < 250) {
      return;
    }
    final r = _resolver;
    if (r == null) return;
    final res = r.input(chord, _keyContext);
    if (res.kind != ResolveKind.fired) return;
    Log.instance.d('performSelector $selectorName → $chord → ${res.command}');
    _registry.dispatch(res.command!, this, res.args, res.count);
    _recordStep(MacroCommand(res.command!, args: res.args, count: res.count));
    setState(() {});
  }

  // Last chord `_onKey` fired, for the duplicate guard in [performSelector].
  String? _lastFiredChord;
  DateTime _lastFiredAt = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}
  @override
  void insertContent(KeyboardInsertedContent content) {}
  @override
  bool onFocusReceived() => false;

  // ── Horizontal scrolling: measure / clamp / apply ──

  // Visible width of the text area (minus gutter, padding and the right-hand scrollbar).
  double get _textViewW {
    final gw = _gutterWidthFor(_anchorLine, _window?.lines.length ?? 0);
    final w = _viewportW - gw - _gutterPad - _scrollbarMargin;
    return w > 16 ? w : 16;
  }

  double get _maxScrollX {
    final m = _contentW - _textViewW;
    return m > 0 ? m : 0;
  }

  // Max content width of the visible lines (readWindow caps a line at 1MB → measurement is
  // bounded). A caret's width is left after the line end.
  double _measureContentW(DocWindow win) {
    var w = 0.0;
    for (final line in win.lines) {
      if (line.isEmpty) continue;
      // In monospace the width upper bound ≈ character count × fontSize (a full-width CJK
      // glyph ≈ 1em); lines clearly shorter than the current max skip measurement.
      if (line.length * _fontSize < w) continue;
      final mw = _buildLine(line, _layoutMaxW).width;
      if (mw > w) w = mw;
    }
    return w == 0 ? 0 : w + _fontSize;
  }

  /// _contentW for the current window, measured at most once per window
  /// (build, and whoever needs it before build: caret-visibility after an
  /// edit, the completion popup position).
  void _ensureContentW() {
    if (_hexMode) {
      _contentW = _hexContentW; // hex rows have a fixed width, no measuring needed
      return;
    }
    final w = _window;
    if (identical(_contentWWin, w)) return;
    _contentWWin = w;
    final sw = Stopwatch()..start();
    _contentW = w == null ? 0 : _measureContentW(w);
    _slow('measure content width (${w?.lines.length} lines)', sw);
  }

  void _scrollXBy(double px) {
    final v = (_scrollX + px).clamp(0.0, _maxScrollX);
    if (v != _scrollX) {
      setState(() => _scrollX = v);
      _broadcastScrollX();
    }
  }

  // Click/drag on the bottom horizontal scrollbar: the track starts at the gutter's right
  // edge (matching the painter).
  void _hScrollTo(double localX) {
    final m = _maxScrollX;
    if (m <= 0) return;
    final gw = _gutterWidthFor(_anchorLine, _window?.lines.length ?? 0);
    final trackW = _viewportW - gw - _scrollbarMargin;
    if (trackW <= 0) return;
    final f = ((localX - gw) / trackW).clamp(0.0, 1.0);
    setState(() => _scrollX = f * m);
    _broadcastScrollX();
  }

  // Scroll coalescing: wheel/drag pixels accumulate into whole lines; multiple events are
  // applied serially through a queue to avoid races
  double _wheelAccum = 0;
  int _pendingDelta = 0;
  bool _draining = false;

  int get _visibleCount => (_viewportH / _lineHeight).ceil() + 1;

  Future<void> _open() async {
    if (_opening) return;
    final picked = await MacFiles.openFile();
    if (picked == null) return;
    await _loadDocument(picked.path);
  }

  // Load a path as the current document (shared by open and reopen-after-save).
  // [caret]/[anchorOffset] restore the position after a save-reopen (the content is the same
  // before and after saving, so the offsets are unchanged).
  Future<void> _loadDocument(
    String path, {
    int caret = 0,
    int anchorOffset = 0,
    String? keepCodec, // reopen after save: keep a manually chosen encoding
    bool keepUndo = false, // reopen after save: history was rebased, keep it
  }) async {
    setState(() => _opening = true);
    _bump();
    try {
      await _doc?.close(); // the save flow may have closed it already → tolerate a double close
    } catch (_) {}
    // A file the OS won't let us write opens read-only (the user can still
    // turn that off and Save As elsewhere); a manual read-only stays.
    // Read-only follows the file: a different path resets the automatic
    // (or manual) flag first — a read-only file opened earlier in this pane
    // used to leave every later writable file read-only too. Same path
    // (save reopen, reload) keeps a manual choice.
    if (path != _path) _readOnly = false;
    if (!await _isWritable(path)) _readOnly = true;
    // Same for the layout direction: a manual toggle sticks to its path.
    if (path != _path) _rtlLayoutManual = false;
    final file = await Document.open(path, scanOriginalLineFeeds: false);
    await _recordDiskStamp(path);
    final kept = keepCodec == null ? null : textCodecByName(keepCodec);
    if (kept != null) {
      file.codec = kept;
      _encManual = true;
      _encGuess = null;
    } else {
      await _detectEncoding(file);
    }
    file.progress.listen((p) {
      if (!mounted) return;
      // The document may start the index itself (first edit of a big file);
      // show the same progress as a manual/automatic build.
      if (!p.done) _indexing = true;
      setState(() {});
      _bump();
      // Once the index is done, replace an estimated top line number with the exact one
      if (p.done && !_anchorLineExact) {
        file.absoluteLineAt(_anchorOffset).then((la) async {
          if (mounted && la.exact) {
            setState(() {
              _anchorLine = la.line;
              _anchorLineExact = true;
            });
            // The window's per-row line numbers came from the estimate:
            // re-read so whole-file highlight spans (keyed by line) line up.
            if (la.line != _window?.startLine) await _reload();
          }
        });
      }
    });
    // Small files index automatically on open: exact line numbers / total lines right away,
    // no need to press "Build line index", and no oddity of "scrolled through the whole file
    // yet still shown as unindexed". Large files stay manual/deferred.
    final autoIndex = file.size <= _autoIndexMaxBytes;
    // Bookmarks stay across save-reopen/reload of the SAME file (offsets
    // unchanged there); a different file starts clean — seeded from the
    // session snapshot (clamped; consumed once) when this pane restores one.
    if (_bookmarksPath != path) {
      _bookmarks.clear();
      _bookmarksPath = path;
      if (path == widget.initialPath && !_initialBookmarksUsed) {
        _initialBookmarksUsed = true;
        _bookmarks.addAll(
          widget.initialBookmarks.where((b) => b >= 0 && b <= file.length),
        );
      }
    }
    // The file may have been rewritten externally (between sessions, or via
    // the reload prompt): saved offsets can drift off line starts, and a
    // non-line-start bookmark neither paints its gutter dot nor jumps to a
    // clean position. Re-align each to its line's start; being POSITION
    // anchors, they may still point at a neighboring line after big external
    // edits — the price of not doing content anchoring.
    if (_bookmarks.isNotEmpty) {
      final aligned = <int>{};
      for (final b in _bookmarks) {
        aligned.add(await file.lineStartOf(b > file.length ? file.length : b));
      }
      _bookmarks
        ..clear()
        ..addAll(aligned);
    }
    _bookmarksView = Set.unmodifiable(_bookmarks);
    file.onSplice = _onDocSplice;
    file.onIndexWait = _onIndexWait;
    // The grammar list is scanned alongside the first frame; a session file
    // can get here first, and would otherwise miss its plugin syntax.
    await WasmGrammarRegistry.instance.ready;
    // The pane can be closed while the file was opening (session restore
    // with many tabs, an untitled pane replaced by an open): setState on an
    // unmounted State throws and the freshly opened handle leaked, which on
    // Windows kept the file locked until the process exited.
    if (!mounted) {
      await file.close();
      return;
    }
    setState(() {
      _doc = file;
      _path = path;
      _anchorOffset = anchorOffset;
      _anchorLine = 0;
      _anchorLineExact = true;
      _name = path.split(Platform.pathSeparator).last;
      _opening = false;
      _indexing = autoIndex;
      _caretOffset = caret;
      _selAnchor = null;
      _goalColumn = null;
      _modified = false;
      _composing = '';
      _resetHScroll();
    });
    _bump();
    if (keepUndo) {
      // Same bytes, new buffers: the stack was materialized before the
      // close (see _save), so it still applies. This state is "saved".
      _undo.markSaved();
    } else {
      _undo.clear();
    }
    _forcedSyntax = null; // a new file goes back to automatic detection
    _hl = _resolveHighlighter(); // WASM plugin → static tree-sitter → pure Dart
    _logSyntax('open');
    _hlWindow = null; // force recompute
    _invalidateFullHl(); // new document → discard previous file's whole-file spans
    if (autoIndex) file.startIndexing();
    await _reload();
    await _refreshBom();
    await _detectNewline(); // infer the newline style from the file's first line (one small window read)
    if (!_rtlLayoutManual) {
      final rtl = await _detectRtlLayout();
      if (rtl != _rtlLayout && mounted) setState(() => _rtlLayout = rtl);
    }
    // Restore the top line number (reopen after save, when anchorOffset != 0)
    if (anchorOffset > 0) {
      final la = await file.absoluteLineAt(anchorOffset);
      if (mounted) {
        setState(() {
          _anchorLine = la.line;
          _anchorLineExact = la.exact;
        });
        // The first _reload above read the window as if it started at line
        // 0; its line numbers drive the whole-file highlight lookup, so the
        // restored view was painted with line-0 colours (session restore at
        // a scrolled position). Re-read with the real top line.
        await _reload();
      }
    }
    // A binary file (NULs / control bytes in the head) is far more useful in
    // hex mode; only on the first open of that path, so a manual switch back
    // to text survives save-reopen / reload.
    if (_binaryGuess &&
        keepCodec == null &&
        AppSettings.instance.autoHexBinary &&
        _autoHexPath != path) {
      _autoHexPath = path;
      await _setViewMode(ViewMode.hex);
    }
    _restartBlink();
    _resetImeBaseline();
    // The load is complete: notify the shell once more — the earlier _bump
    // ran BEFORE _detectNewline/_refreshBom, so without this the menubar
    // (newline checkmark, BOM) keeps pre-load values until some other event
    // rebuilds it (the "restored file shows LF until you switch tabs" bug).
    _bump();
    // A selection queued while the document was loading (find-in-files
    // result opening a fresh tab).
    final pending = widget.controller._pendingSelect;
    if (pending != null) {
      widget.controller._pendingSelect = null;
      _selectRange(pending.$1, pending.$2);
    }
    final pendingLine = widget.controller._pendingLine;
    if (pendingLine != null) {
      widget.controller._pendingLine = null;
      gotoLine(pendingLine);
    }
    widget.controller.docEpoch.value++; // outline panel: new content
    _scheduleWordScan();
    _focus.requestFocus();
  }

  // Remember the file's on-disk mtime/size (called whenever WE read or wrote
  // it); _checkExternalChange compares against this.
  Future<void> _recordDiskStamp(String path) async {
    try {
      final st = await File(path).stat();
      _diskMtimeUs = st.modified.microsecondsSinceEpoch;
      _diskSize = st.size;
    } catch (_) {
      _diskMtimeUs = null;
      _diskSize = null;
    }
  }

  // ── Read-only mode ──────────────────────────────────────────────
  // A UI guard, not a lock: every edit entry point asks _blockedReadOnly()
  // first. Set automatically when the file isn't writable, by the user via
  // File → Read-only mode, and while tail mode is on.
  bool _readOnly = false;

  bool _blockedReadOnly() {
    if (!_readOnly) return false;
    _toast(_l10n.tr('toast_read_only'));
    return true;
  }

  void _toggleReadOnly() {
    if (_doc == null) return;
    if (_tail && _readOnly) {
      _toast(_l10n.tr('toast_tail_read_only'));
      return;
    }
    setState(() => _readOnly = !_readOnly);
    _undo.breakCoalescing();
    _bump();
  }

  // Whether the OS lets us write [path] (Windows read-only attribute maps
  // to the mode's write bits too).
  Future<bool> _isWritable(String path) async {
    try {
      final st = await File(path).stat();
      return (st.mode & 0x80) != 0;
    } catch (_) {
      return true;
    }
  }

  // ── Tail the file (tail -f) ──────────────────────────────────
  // Poll the file once a second; when it changed, reload and jump to the
  // end. The pane is read-only meanwhile (edits would be lost on reload)
  // and the external-change prompt is suppressed.
  bool _tail = false;
  Timer? _tailTimer;
  bool _tailBusy = false;
  bool _tailReadOnlyBefore = false;

  void _toggleTail() {
    if (_tail) {
      _tailTimer?.cancel();
      _tailTimer = null;
      setState(() {
        _tail = false;
        _readOnly = _tailReadOnlyBefore;
      });
      _bump();
      return;
    }
    if (_path == null || _doc == null || _hexMode) return;
    if (_modified) {
      _toast(_l10n.tr('toast_tail_unsaved'));
      return;
    }
    _tailReadOnlyBefore = _readOnly;
    setState(() {
      _tail = true;
      _readOnly = true;
    });
    _tailTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tailTick());
    _enqueueCaret(_jumpToEnd);
    _toast(_l10n.tr('toast_tail_on'));
    _bump();
  }

  Future<void> _tailTick() async {
    if (!_tail || _tailBusy || _opening || _saving || !mounted) return;
    final path = _path;
    if (path == null) return;
    final FileStat st;
    try {
      st = await File(path).stat();
    } catch (_) {
      return;
    }
    if (st.type == FileSystemEntityType.notFound) return;
    if (st.modified.microsecondsSinceEpoch == _diskMtimeUs &&
        st.size == _diskSize) {
      return;
    }
    _tailBusy = true;
    try {
      await _reloadFromDisk();
      await _jumpToEnd();
    } finally {
      _tailBusy = false;
    }
  }

  Future<void> _jumpToEnd() async {
    final doc = _doc;
    if (doc == null) return;
    _selAnchor = null;
    _colBlock = null;
    _caretOffset = doc.length;
    await _ensureCaretVisible();
    if (mounted) setState(_restartBlink);
  }

  // ── Backup of the original on save ───────────────────────────────────────────
  // Copies the file about to be overwritten: `<file>.bak` beside it, or
  // `<backupDir>/<name>.<timestamp>.bak` when a folder is configured.
  Future<void> _backupOriginal(String path) async {
    final s = AppSettings.instance;
    if (!s.backupOnSave) return;
    final src = File(path);
    if (!await src.exists()) return;
    try {
      final String dest;
      final dir = s.backupDir.trim();
      if (dir.isEmpty) {
        dest = '$path.bak';
      } else {
        await Directory(dir).create(recursive: true);
        final name = path.split(Platform.pathSeparator).last;
        final t = DateTime.now();
        String two(int v) => v.toString().padLeft(2, '0');
        final ts =
            '${t.year}${two(t.month)}${two(t.day)}-'
            '${two(t.hour)}${two(t.minute)}${two(t.second)}';
        dest = '$dir${Platform.pathSeparator}$name.$ts.bak';
      }
      await src.copy(dest);
    } catch (e) {
      Log.instance.w('backup failed: $path ($e)');
      _toast(_l10n.trf('toast_backup_failed', [e.toString()]));
    }
  }

  // Did another program modify the file on disk? Compare the stamp; on a
  // mismatch ask the user whether to reload (shell calls this on window
  // focus / tab activation / a slow poll of the active pane).
  Future<void> _checkExternalChange() async {
    final path = _path;
    if (path == null || _doc == null || _opening || _saving || _extDialogOpen) {
      return;
    }
    if (_tail) return; // tail mode reloads on its own
    if (_diskMtimeUs == null && _diskSize == null) return; // stamp unknown
    final FileStat st;
    try {
      st = await File(path).stat();
    } catch (_) {
      return;
    }
    // Missing can be transient (another editor's atomic delete+rename replace);
    // the next check sees the new file's stamp.
    if (st.type == FileSystemEntityType.notFound) return;
    final mtime = st.modified.microsecondsSinceEpoch;
    if (mtime == _diskMtimeUs && st.size == _diskSize) return;
    // Adopt the seen stamp BEFORE prompting: "ignore" means don't ask again
    // until the file changes again.
    _diskMtimeUs = mtime;
    _diskSize = st.size;
    if (!mounted) return;
    _extDialogOpen = true;
    _bump();
    try {
      final reload = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_l10n.tr('ext_change_title')),
          content: Text(
            _l10n.trf('ext_change_body', [_name ?? path]) +
                (_modified ? _l10n.tr('ext_change_unsaved') : ''),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(_l10n.tr('common_ignore')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(_l10n.tr('common_reload')),
            ),
          ],
        ),
      );
      if (reload == true && mounted) await _reloadFromDisk();
    } finally {
      _extDialogOpen = false;
    }
  }

  // Reopen the current file from disk, keeping a manually chosen encoding and
  // (clamped) caret/scroll position. Discards unsaved edits by design — the
  // prompt above warned about that.
  // On the caret queue like the saves: a reload replaces the document, so
  // edits typed meanwhile must wait for it rather than hit the old one.
  Future<void> _reloadFromDisk() => _runQueued(_reloadFromDiskNow);

  Future<void> _reloadFromDiskNow() async {
    final path = _path;
    if (path == null) return;
    final keep = _encManual ? _doc?.codec.name : null;
    // The file shrunk? Clamp the restored offsets to the new size (the anchor
    // falls back to the top — an arbitrary mid-file offset may no longer be a
    // line start anyway).
    var caret = _caretOffset;
    var anchor = _anchorOffset;
    try {
      final size = await File(path).length();
      if (caret > size) caret = size;
      if (anchor > size) anchor = 0;
    } catch (_) {
      caret = 0;
      anchor = 0;
    }
    await _loadDocument(
      path,
      caret: caret,
      anchorOffset: anchor,
      keepCodec: keep,
    );
  }

  // Blank untitled document (startup default). All content lives in the add
  // buffer; "save" asks for a location and the document becomes file-backed.
  Future<void> _newDocument() async {
    try {
      await _doc?.close();
    } catch (_) {}
    final file = await Document.openEmpty();
    _encManual = false;
    _encGuess = null;
    _readOnly = false;
    _diskMtimeUs = null;
    _diskSize = null;
    _bookmarks.clear();
    _bookmarksPath = null;
    _bookmarksView = const {};
    file.onSplice = _onDocSplice;
    file.onIndexWait = _onIndexWait;
    if (!mounted) return;
    setState(() {
      _doc = file;
      _path = null;
      _anchorOffset = 0;
      _anchorLine = 0;
      _anchorLineExact = true;
      _name = AppLocalizations.t('common_untitled');
      _opening = false;
      _indexing = false;
      _caretOffset = 0;
      _selAnchor = null;
      _goalColumn = null;
      _modified = false;
      _composing = '';
      _resetHScroll();
      _rtlLayout = false;
      _rtlLayoutManual = false;
    });
    _bump();
    // A new document has no content to detect from: start with the UI's
    // direction (RTL locale → RTL layout); typing re-detects as usual.
    await _autoRtlUntitled();
    _undo.clear();
    _forcedSyntax = null;
    _hl = const NoHighlighter();
    _logSyntax('new');
    _hlWindow = null;
    _invalidateFullHl();
    _newline = '\n';
    await _reload();
    await _refreshBom();
    _restartBlink();
    _resetImeBaseline();
    _focus.requestFocus();
  }

  // Untitled document: ask where to save, stream the content there, then
  // reopen from disk (the document becomes file-backed).
  Future<void> _saveAs() async {
    final doc = _doc;
    if (doc == null || _saving) return;
    final picked = await MacFiles.saveFile(
      dialogTitle: _l10n.tr('save_as_title'),
      // Propose the current name for file-backed documents.
      fileName: _path == null ? _l10n.tr('untitled_filename') : _name,
    );
    if (picked == null) return;
    final loc = picked.path;
    // Saving over the file being edited IS a plain save: the document's
    // original pieces still read from that very file, so writing it directly
    // would truncate our own source (it showed up as the file shrinking to
    // whatever lived in the add buffer). Same-path goes through _save's
    // temp-file + atomic-replace flow.
    final cur = _path;
    if (cur != null && samePath(loc, cur)) return _save();
    return _runQueued(() => _saveAsWrite(doc, loc));
  }

  Future<void> _saveAsWrite(Document doc, String loc) async {
    if (!identical(_doc, doc) || _saving) return; // replaced meanwhile
    setState(() => _saving = true);
    _bump();
    var suspended = false;
    try {
      if (await File(loc).exists()) {
        // Existing target (on Windows/Linux the picker has already created
        // it): temp file beside it + atomic replace, like _save, so a failure
        // mid-write leaves the old contents intact. The sandboxed macOS panel
        // grants only the file itself, so the temp goes to the container.
        final sep = Platform.pathSeparator;
        final dir = MacFiles.isActive
            ? Directory.systemTemp.path
            : File(loc).parent.path;
        final tmp = '$dir$sep.${File(loc).uri.pathSegments.last}.tmp~';
        try {
          final sink = File(tmp).openWrite();
          await doc.streamTo(sink);
          await sink.flush();
          await sink.close();
          await _replaceFile(tmp, loc);
        } catch (_) {
          try {
            if (await File(tmp).exists()) await File(tmp).delete();
          } catch (_) {}
          rethrow;
        }
      } else {
        final sink = File(loc).openWrite();
        await doc.streamTo(sink);
        await sink.flush();
        await sink.close();
      }
      final caret = _caretOffset, anchor = _anchorOffset;
      final keep = _encManual ? doc.codec.name : null;
      await doc.suspend();
      suspended = true;
      await _loadDocument(
        loc,
        caret: caret,
        anchorOffset: anchor,
        keepCodec: keep,
      );
      if (mounted) {
        setState(() => _saving = false);
        _bump();
        _toast(_l10n.tr('toast_saved'));
      }
    } catch (e) {
      if (suspended) await _reopenAfterFailedReplace(doc);
      if (mounted) {
        setState(() => _saving = false);
        _bump();
        _toast(_l10n.trf('toast_save_failed', [e]));
      }
    }
  }

  // Detect the file's encoding from a sample of its head (size from the
  // settings) and set the document's codec. Runs before auto-indexing, so a
  // UTF-16/32 file's line index counts newline UNITS from the start.
  Future<void> _detectEncoding(Document file) async {
    _encManual = false;
    _encGuess = null;
    final sample = await file.original.readBytes(
      0,
      AppSettings.instance.encodingSampleBytes,
    );
    final g = detectEncoding(sample);
    _binaryGuess = looksBinary(sample);
    _encGuess = g;
    final codec = textCodecByName(g.codecName);
    if (codec == null) {
      Log.instance.w(
        'encoding: detected ${g.codecName} but no codec registered',
      );
      return;
    }
    file.codec = codec;
    Log.instance.i(
      'encoding: $_name -> ${codec.name} '
      '(${g.confident ? g.reason : 'fallback: ${g.reason}'})',
    );
  }

  // Force an encoding from the menu: pure reinterpretation (no bytes change).
  // Switching to/from UTF-16/32 changes what a newline is, so the line index
  // resets (Document handles that) — realign the anchor/caret to the new
  // line structure, restart auto-indexing, and redraw.
  // Queued (see _toggleBom): reinterpreting moves the caret/anchor.
  Future<void> _setEncoding(String name) =>
      _runQueued(() => _setEncodingNow(name));

  Future<void> _setEncodingNow(String name) async {
    final doc = _doc;
    final codec = textCodecByName(name);
    if (doc == null || codec == null) return;
    if (identical(doc.codec, codec)) return;
    doc.codec = codec;
    _encManual = true;
    Log.instance.i('encoding: $_name -> ${codec.name} (manual)');
    // Realign to the new unit / line structure.
    _caretOffset -= _caretOffset % codec.unitSize;
    _selAnchor = null;
    _colBlock = null;
    if (!_hexMode) {
      _anchorOffset = await doc.lineStartOf(_anchorOffset);
      final la = await doc.absoluteLineAt(_anchorOffset);
      _anchorLine = _anchorOffset == 0 ? 0 : la.line;
      _anchorLineExact = _anchorOffset == 0 || la.exact;
    }
    if (!doc.indexDone && doc.size <= _autoIndexMaxBytes) {
      doc.startIndexing();
      _indexing = true;
    }
    _invalidateFullHl();
    _hlWindow = null;
    _bump();
    await _reload();
    await _refreshBom(); // different codec = different BOM byte pattern
    if (mounted) setState(() {});
  }

  // Convert the document to another encoding and save ("Convert encoding": the one
  // operation that really rewrites bytes). Streams via Document.transcodeTo
  // into a temp file, atomically replaces the original, then reopens with
  // the target codec. Unsaved edits are included; undo history is cleared
  // by the reopen — the confirm dialog says so.
  Future<void> _convertEncoding(String name) async {
    final doc = _doc;
    final path = _path;
    final target = textCodecByName(name);
    if (doc == null || path == null || target == null || _saving) return;
    if (identical(doc.codec, target)) return;
    final from = doc.codec.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_l10n.tr('convert_title')),
        content: Text(_l10n.trf('convert_body', [_name, from, target.name])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(_l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(_l10n.tr('convert_do')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Write phase on the caret queue (see _runQueued): edits typed meanwhile
    // wait for the reopen instead of landing in the document being replaced.
    return _runQueued(() => _convertEncodingWrite(doc, path, target, from));
  }

  Future<void> _convertEncodingWrite(
    Document doc,
    String path,
    TextCodec target,
    String from,
  ) async {
    if (!identical(_doc, doc) || _saving) return; // replaced meanwhile
    setState(() => _saving = true);
    _bump();
    final sep = Platform.pathSeparator;
    final tmp = '${File(path).parent.path}$sep.${_name ?? 'file'}.tmp~';
    var suspended = false;
    try {
      final sink = File(tmp).openWrite();
      final fallbacks = await doc.transcodeTo(sink, target);
      await sink.flush();
      await sink.close();
      await doc.suspend();
      suspended = true;
      await _backupOriginal(path);
      await _replaceFile(tmp, path);
      await _loadDocument(path, keepCodec: target.name);
      Log.instance.i(
        'encoding: $_name converted $from -> ${target.name} '
        '($fallbacks fallbacks)',
      );
      if (mounted) {
        setState(() => _saving = false);
        _bump();
        _toast(
          fallbacks > 0
              ? _l10n.trf('toast_converted_fallback', [target.name, fallbacks])
              : _l10n.trf('toast_converted', [target.name]),
        );
      }
    } catch (e) {
      try {
        if (await File(tmp).exists()) await File(tmp).delete();
      } catch (_) {}
      if (suspended) await _reopenAfterFailedReplace(doc);
      if (mounted) {
        setState(() => _saving = false);
        _bump();
        _toast(_l10n.trf('toast_convert_failed', [e]));
      }
    }
  }

  // Newline style conversion (CRLF↔LF): same convert-&-save flow as _convertEncoding —
  // a GB file has millions of newlines, so an in-buffer edit would shatter
  // the piece tree into per-line pieces; streaming through transcodeTo with
  // the newline override + atomic replace scales, and the reload re-detects
  // the (now converted) style.
  Future<void> _convertNewline(String style) async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    final path = _path;
    if (doc == null || _saving) return;
    if (style == _newline) return;
    final label = style == '\r\n' ? 'CRLF' : 'LF';
    if (doc.length <= _newlineInBufferMax) {
      // Small documents (untitled or saved) convert in place: undoable, no
      // confirm dialog, and no forced save — the ● appears like any edit.
      _convertNewlineInBuffer(style, label);
      return;
    }
    if (path == null) {
      // Huge untitled: no disk file to stream through — needs a save first.
      _toast(_l10n.tr('toast_newline_too_large'));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_l10n.tr('newline_convert_title')),
        content: Text(_l10n.trf('newline_convert_body', [_name, label])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(_l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(_l10n.tr('convert_do')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    return _runQueued(() => _convertNewlineWrite(doc, path, style, label));
  }

  Future<void> _convertNewlineWrite(
    Document doc,
    String path,
    String style,
    String label,
  ) async {
    if (!identical(_doc, doc) || _saving) return; // replaced meanwhile
    setState(() => _saving = true);
    _bump();
    final sep = Platform.pathSeparator;
    final tmp = '${File(path).parent.path}$sep.${_name ?? 'file'}.tmp~';
    var suspended = false;
    try {
      final sink = File(tmp).openWrite();
      await doc.transcodeTo(sink, doc.codec, newline: style);
      await sink.flush();
      await sink.close();
      await doc.suspend();
      suspended = true;
      await _backupOriginal(path);
      await _replaceFile(tmp, path);
      // Keep the encoding only when the user chose it manually; otherwise
      // let the reload re-detect (same bytes character-wise, same result).
      await _loadDocument(path, keepCodec: _encManual ? doc.codec.name : null);
      Log.instance.i('newline: $_name converted to $label');
      if (mounted) {
        setState(() => _saving = false);
        _bump();
        _toast(_l10n.trf('toast_converted', [label]));
      }
    } catch (e) {
      try {
        if (await File(tmp).exists()) await File(tmp).delete();
      } catch (_) {}
      if (suspended) await _reopenAfterFailedReplace(doc);
      if (mounted) {
        setState(() => _saving = false);
        _bump();
        _toast(_l10n.trf('toast_convert_failed', [e]));
      }
    }
  }

  // Documents up to this size convert newlines in place; larger ones go
  // through the streaming convert-&-save path — per-line edits on a GB file
  // (millions of them) would shatter the piece tree and balloon the undo.
  static const int _newlineInBufferMax = 16 << 20;

  // In-place newline conversion (small documents, untitled or saved):
  // rewrite every terminator that differs, highest offset first, one undo
  // step. Nothing is written to disk — it is a normal pending edit.
  void _convertNewlineInBuffer(String style, String label) {
    _enqueueCaret(() async {
      final doc = _doc;
      if (doc == null) return;
      if (doc.length > _newlineInBufferMax) {
        _toast(_l10n.tr('toast_newline_too_large')); // safety net
        return;
      }
      final term = doc.codec.encode(style).bytes;
      // Collect the terminators that differ (byte ranges, unit-aware via the
      // document's line navigation).
      final edits = <(int, int)>[];
      var pos = 0;
      while (true) {
        final e = await doc.lineEndOf(pos);
        final n = await doc.nextLineStart(e);
        if (n < 0) break; // last line (no terminator)
        final len = n - e;
        final cur = await doc.readRangeBytes(e, len);
        var same = cur.length == term.length;
        for (var i = 0; same && i < term.length; i++) {
          if (cur[i] != term[i]) same = false;
        }
        if (!same) edits.add((e, len));
        pos = n;
      }
      _newline = style; // future Enter presses follow the new style
      _bump(); // menu checkmark
      if (edits.isEmpty) return;
      _undo.breakCoalescing();
      final reverses = <ReverseEdit>[];
      // Highest offset first so earlier offsets stay valid.
      for (final (off, len) in edits.reversed) {
        reverses.add(await doc.delete(off, len));
        reverses.add(await doc.insertBytes(off, term));
      }
      _undo.push(ReverseEdit.group(reverses.reversed.toList()));
      _undo.breakCoalescing();
      _colBlock = null;
      _selAnchor = null;
      if (_caretOffset > doc.length) _caretOffset = doc.length;
      _setModified(_undo.isDirty);
      _toast(_l10n.trf('toast_newline_changed', [label]));
      await _afterEdit();
    });
  }

  // ── BOM ──
  // Whether the document currently starts with the codec's BOM bytes
  // (recomputed after loads/edits — cheap: reads at most 4 bytes).
  bool _hasBom = false;

  bool get _bomPossible => _doc?.codec.canEncode(0xFEFF) ?? false;

  Future<void> _refreshBom() async {
    final doc = _doc;
    var has = false;
    if (doc != null && doc.codec.canEncode(0xFEFF)) {
      final bom = doc.codec.encode('\uFEFF').bytes;
      final head = await doc.readRangeBytes(0, bom.length);
      has = head.length == bom.length;
      for (var i = 0; has && i < bom.length; i++) {
        if (head[i] != bom[i]) has = false;
      }
    }
    if (has != _hasBom) {
      _hasBom = has;
      _bump(); // menu checkmark
    }
  }

  // Toggle the BOM as a NORMAL edit (insert/delete U+FEFF at offset 0), so
  // it is undoable and saved through the regular save path.
  // Queued: it edits the document and moves the caret, so it must not run
  // between a queued edit's await and its use of _caretOffset.
  Future<void> _toggleBom() => _runQueued(_toggleBomNow);

  Future<void> _toggleBomNow() async {
    if (_blockedReadOnly()) return;
    final doc = _doc;
    if (doc == null) return;
    if (!doc.codec.canEncode(0xFEFF)) {
      _toast(_l10n.trf('toast_no_bom', [doc.codec.name]));
      return;
    }
    final bom = doc.codec.encode('\uFEFF').bytes;
    final ReverseEdit rev;
    if (_hasBom) {
      rev = await doc.delete(0, bom.length);
      if (_caretOffset >= bom.length) _caretOffset -= bom.length;
    } else {
      rev = await doc.insertBytes(0, bom);
      if (_caretOffset > 0) _caretOffset += bom.length;
    }
    _undo.push(rev);
    _undo.breakCoalescing();
    _setModified(_undo.isDirty);
    if (_anchorOffset > 0) {
      _anchorOffset = await doc.lineStartOf(
        _hasBom ? _anchorOffset - bom.length : _anchorOffset + bom.length,
      );
    }
    await _afterEdit();
    _bump();
  }

  // Save: stream the pieces → temp file in the same directory → close the original → atomic
  // replace → reopen (restoring caret/anchor). An untitled document (no path) goes to Save As.
  Future<void> _save() {
    if (_doc == null || _saving) return Future.value();
    if (_path == null) return _saveAs();
    return _runQueued(_saveQueued);
  }

  Future<void> _saveQueued() async {
    final doc = _doc;
    final path = _path;
    if (doc == null || path == null || _saving) return;
    setState(() => _saving = true);
    _bump();
    // Under the macOS sandbox the grant covers the file, not its directory, so the temp file
    // cannot be a sibling — it goes to the app container and _replaceFile swaps it in natively.
    final sep = Platform.pathSeparator;
    final dir = MacFiles.isActive
        ? Directory.systemTemp.path
        : File(path).parent.path;
    final tmp = '$dir$sep.${_name ?? 'file'}.tmp~';
    var suspended = false;
    try {
      // 1. Stream out to the temp file
      final sink = File(tmp).openWrite();
      await doc.streamTo(sink);
      await sink.flush();
      await sink.close();
      // 2. Remember the position (same content before and after → offsets unchanged); a
      //    manually chosen encoding is kept too
      final caret = _caretOffset, anchor = _anchorOffset;
      final keepCodec = _encManual ? doc.codec.name : null;
      // Undo entries reference this doc's buffers; copy the bytes out now so
      // the history survives the reopen (edits before the save stay undoable).
      await _undo.rebase(doc, maxBytes: _undoRebaseMaxBytes);
      // 3. Close the original's handle (Windows cannot overwrite otherwise), then replace
      //    atomically. _doc still points at the closed doc: during this gap only fields
      //    (size etc.) are read, no IO, so the view does not flicker.
      await doc.suspend();
      suspended = true;
      await _backupOriginal(path);
      await _replaceFile(tmp, path);
      // 4. Reopen the saved file, restoring the position
      await _loadDocument(
        path,
        caret: caret,
        anchorOffset: anchor,
        keepCodec: keepCodec,
        keepUndo: true,
      );
      if (mounted) {
        setState(() => _saving = false);
        _bump();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_l10n.tr('toast_saved')),
            duration: const Duration(milliseconds: 900),
          ),
        );
      }
    } catch (e) {
      try {
        if (await File(tmp).exists()) await File(tmp).delete();
      } catch (_) {}
      // The replace failed after the handle was released (another program
      // holding the file, disk full…): get the handle back so the document
      // stays readable and the edits saveable — without this every later
      // save hit the closed handle and the work was stuck in memory.
      if (suspended) await _reopenAfterFailedReplace(doc);
      if (mounted) {
        setState(() => _saving = false);
        _bump();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_l10n.trf('toast_save_failed', [e]))),
        );
      }
    }
  }

  Future<void> _reopenAfterFailedReplace(Document doc) async {
    try {
      await doc.reopen();
    } catch (e) {
      Log.instance.w('reopen after failed replace: $e');
    }
  }

  // Replace [dest] with [tmp]. macOS goes through FileManager.replaceItemAt — the only swap the
  // sandbox allows onto a user-granted path (and it carries the original's permissions over).
  // POSIX otherwise renames straight over; Windows (where an existing dest makes rename fail)
  // falls back to "dest -> backup, tmp -> dest, drop backup", restoring the backup on failure.
  Future<void> _replaceFile(String tmp, String dest) async {
    if (MacFiles.isActive) {
      await MacFiles.replaceItem(tmp, dest);
      return;
    }
    await atomicReplaceFile(tmp, dest);
  }

  @override
  void save() => _save();

  @override
  void saveAs() => _saveAs();

  @override
  void reloadFile() => _reloadFileCommand();

  // File → Reload File: reopen the current file from disk. Unsaved edits are
  // discarded, so a modified tab asks first; untitled tabs have nothing to
  // reload and tail mode already reloads on its own.
  Future<void> _reloadFileCommand() async {
    final path = _path;
    if (path == null || _saving || _tail || _opening) return;
    if (_modified) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_l10n.tr('item_reload')),
          content: Text(_l10n.trf('reload_confirm_body', [_name ?? path])),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(_l10n.tr('common_cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(_l10n.tr('common_reload')),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _reloadFromDisk();
  }

  // Infer the newline style from the FIRST line's terminator, read from the
  // document head with its own tiny window. Deliberately not the view window:
  // a session-restored anchor can sit on the last line, whose 1-line window
  // made the old version fall back to LF on a CRLF file. Terminator size =
  // nextOffset - line start - content bytes (content excludes \r), compared
  // per codec unit; a lone unterminated line (or empty file) defaults to LF.
  Future<void> _detectNewline() async {
    final doc = _doc;
    var style = '\n';
    if (doc != null) {
      final w = await doc.readWindow(0, 1);
      if (w.lines.isNotEmpty) {
        final content0 = w.maps.isNotEmpty
            ? w.maps[0][w.maps[0].length - 1]
            : utf8.encode(w.lines[0]).length;
        final gap = w.nextOffset - w.offsets[0] - content0;
        if (gap >= 2 * doc.codec.unitSize) style = '\r\n';
      }
    }
    _newline = style;
  }

  // Soft wrap is per pane: [_wrapOverride] set from the View menu / alt+z /
  // the toolbar applies to this tab only; null follows the global default
  // (AppSettings.softWrapMode, set in the font dialog). Persisted with the
  // session (SessionFile.wrap).
  late String? _wrapOverride = widget.initialWrap;

  /// The wrap style the toggle returns to ("on" restores columns/window,
  /// whichever was in use, so alt+z never silently changes the style).
  String _wrapBeforeOff = 'window';

  /// Effective wrap setting of this pane regardless of view mode.
  String get wrapSetting =>
      _wrapOverride ?? AppSettings.instance.softWrapMode;

  void _setWrapOverride(String mode) {
    if (!AppSettings.softWrapModeChoices.contains(mode)) return;
    if (mode != 'off') _wrapBeforeOff = mode;
    if (mode == wrapSetting && _wrapOverride != null) return;
    setState(() => _wrapOverride = mode);
    _hlWindow = null; // rows / window spans are keyed on the wrap mode
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
    _bump();
  }

  void _toggleWrap() {
    final cur = wrapSetting;
    if (cur != 'off') _wrapBeforeOff = cur;
    _setWrapOverride(cur == 'off' ? _wrapBeforeOff : 'off');
  }

  // Wrap mode: only text mode wraps. Hex has its own fixed row width; in column mode a wrap
  // would make a "column" no longer map to the same position in the logical line (the
  // rectangular selection would deform), so it never wraps.
  String get _wrapMode => _viewMode == ViewMode.text ? wrapSetting : 'off';

  // Characters per row in "columns" mode; 0 in the other modes (= no column-based wrap).
  int get _wrapColumns =>
      _wrapMode == 'columns' ? AppSettings.instance.softWrapColumns : 0;

  // "Window width" mode: wrap points are measured for real (so CJK wide characters also stay
  // within the view).
  List<int> Function(String)? get _wrapMeasure {
    if (_wrapMode != 'window') return null;
    final w = _textViewW;
    return (line) => measuredWrapBoundaries(line, w);
  }

  // Whether wrapping is in effect (decides whether scrolling works in visual rows).
  bool get _wrapping => _wrapMode == 'window' || _wrapColumns > 0;

  // Wrap cut points of a piece of text under the current wrap settings.
  List<int> _boundariesOf(String text) =>
      _wrapMeasure?.call(text) ?? wrapBoundaries(text, _wrapColumns);

  // Expand the visible window into visual rows (cutting each line's spans to row
  // coordinates as well).
  void _rebuildRows() {
    final win = _window;
    if (win == null) {
      _rows = const [];
      _rowSpans = const [];
      return;
    }
    final cols = _wrapColumns;
    _rowsKey =
        '$_wrapMode/$cols/${_wrapMode == 'window' ? _textViewW.round() : 0}';
    _rows = wrapWindow(
      win.lines,
      win.offsets,
      cols,
      boundariesOf: _wrapMeasure,
      maps: win.maps,
    );
    _rowSpans = [
      for (final r in _rows)
        sliceSpans(
          (_spans != null && r.lineIndex < _spans!.length)
              ? _spans![r.lineIndex]
              : null,
          r.charStart,
          r.charStart + r.text.length,
        ),
    ];
  }

  // Which visual row a document offset falls on (-1 = not in the visible range).
  int _rowIndexOf(int offset) {
    for (var i = _rows.length - 1; i >= 0; i--) {
      if (offset >= _rows[i].offset) {
        // End parked the caret on this row's cut → it belongs to the row
        // before (see _caretAtRowEnd).
        final prevOwns =
            _caretAtRowEnd &&
            offset == _caretOffset &&
            offset == _rows[i].offset &&
            !_rows[i].isFirst &&
            i > 0;
        return prevOwns ? i - 1 : i;
      }
    }
    return -1;
  }

  // Re-read the visible window from the current anchor
  Future<void> _reload() async {
    final file = _doc;
    if (file == null) return;
    await _noteEditForHl(); // edits since the last reload → dirty lines for the highlighter
    if (_hexMode) {
      await _reloadHex();
      return;
    }
    final sw = Stopwatch()..start();
    final win = await _readVisibleWindow(
      file,
      _anchorOffset,
      _visibleCount + 1,
      _anchorLine,
    );
    _slow('reload window (${_visibleCount + 1} rows)', sw);
    if (mounted) {
      setState(() {
        _window = win;
        _windowSplices.clear(); // the window now reflects every splice
      });
    }
  }

  Future<void> _setAnchor(int offset, int line) async {
    final file = _doc;
    if (file == null) return;
    final win = await _readVisibleWindow(file, offset, _visibleCount + 1, line);
    if (!mounted) return;
    setState(() {
      _anchorOffset = offset;
      _anchorLine = line;
      _window = win;
      _windowSplices.clear();
    });
  }

  // ── Trackpad pan/zoom (macOS) ──
  // A two-finger pan scrolls, a pinch zooms the font. `scale` is cumulative
  // from the gesture's start, so a step is taken each time it grows past
  // _pinchStep against the scale the last step was taken at.
  static const double _pinchStep = 1.12;
  double _pinchScale = 1.0;

  void _panZoomStart() {
    _pinchScale = 1.0;
    _wheelAccum = 0;
  }

  void _panZoomUpdate(PointerPanZoomUpdateEvent e) {
    final s = e.scale;
    if (s > 0) {
      while (s / _pinchScale >= _pinchStep) {
        _pinchScale *= _pinchStep;
        zoomFont(1);
      }
      while (_pinchScale / s >= _pinchStep) {
        _pinchScale /= _pinchStep;
        zoomFont(-1);
      }
    }
    // The content follows the fingers, the opposite sign of a scroll delta.
    final d = e.localPanDelta;
    if (d.dx != 0) _scrollXBy(-d.dx);
    if (d.dy != 0) _accumScroll(-d.dy);
  }

  // Accumulate pixel scrolling → whole lines
  void _accumScroll(double px) {
    _wheelAccum += px;
    final n = _wheelAccum ~/ _lineHeight;
    if (n != 0) {
      _wheelAccum -= n * _lineHeight;
      _scrollByLines(n);
    }
  }

  void _scrollByLines(int n) {
    if (n == 0) return;
    // Split-pane synchronized scrolling: tell the shell (which forwards to
    // the other visible panes) unless this scroll IS such a forward.
    if (!_syncApplying) widget.controller.onScrollRows?.call(n);
    if (_hexMode) {
      _hexScrollRows(n); // hex: a row = a fixed 16 bytes, no need for the line-scan queue
      return;
    }
    _pendingDelta += n;
    _drain();
  }

  // True while applying a scroll forwarded from another pane (no rebroadcast).
  bool _syncApplying = false;

  void _applySyncRows(int n) {
    _syncApplying = true;
    try {
      _scrollByLines(n);
    } finally {
      _syncApplying = false;
    }
  }

  void _applySyncX(double x) {
    final v = x.clamp(0.0, _maxScrollX);
    if (v != _scrollX) setState(() => _scrollX = v);
  }

  void _broadcastScrollX() {
    if (!_syncApplying) widget.controller.onScrollX?.call(_scrollX);
  }

  // Start (byte offset) of the "next/previous visual row" when wrapping. The anchor may rest
  // on a wrap point in the middle of a line — that is what makes a file with a 100MB line
  // scrollable at all (otherwise the whole line is a single scroll unit).
  //
  // Scrolling back needs the line's prefix, so it reads from the line start to the current
  // position; for an overlong line (beyond [_wrapBackScanCap]) it falls back to the line
  // start instead of reading tens of MB to scroll one row.
  static const int _wrapBackScanCap = 4 << 20; // 4MB

  // Roughly how many characters fit on a row in window-width mode (only used to decide how
  // many bytes to read).
  int get _windowColumnsGuess {
    final w = _textViewW;
    final cw = editorCharWidth;
    final n = cw > 0 ? (w / cw).floor() : 80;
    return n < 8 ? 8 : n;
  }

  Future<int> _nextRowStart(int offset) async {
    final r = await _nextRowStartRaw(offset);
    // Folded: a hidden line is skipped over as a whole.
    final h = _hiddenRangeContaining(r);
    if (h == null) return r;
    return _eofHidden(h.$2) ? offset : h.$2;
  }

  Future<int> _nextRowStartRaw(int offset) async {
    final doc = _doc!;
    if (!_wrapping) return doc.lineStartForward(offset, 1);
    final cols = _wrapColumns > 0 ? _wrapColumns : _windowColumnsGuess;
    // A character is at most 4 bytes; read enough to cover a row + newline.
    final d = await doc.readRangeDecoded(offset, cols * 4 + 8);
    if (d.text.isEmpty) return offset;
    final next = nextRowCharOffset(d.text, _boundariesOf);
    if (next == null) {
      return doc.lineStartForward(offset, 1); // no next row in range
    }
    return offset + d.byteForCodeUnit(next);
  }

  Future<int> _prevRowStart(int offset) async {
    final p = await _prevRowStartRaw(offset);
    // Folded: land on the fold header's last row instead of a hidden line.
    final h = _hiddenRangeContaining(p);
    return h == null ? p : _prevRowStartRaw(h.$1);
  }

  Future<int> _prevRowStartRaw(int offset) async {
    final doc = _doc!;
    if (!_wrapping) return doc.lineStartBack(offset, 1);
    final ls = await doc.lineStartOf(offset);
    if (offset > ls) {
      // Within the same line: back one wrap point.
      if (offset - ls > _wrapBackScanCap) return ls;
      // The prefix's last row start IS the previous row's start.
      final d = await doc.readRangeDecoded(ls, offset - ls);
      final prev = lastRowCharStart(d.text, _boundariesOf);
      return ls + d.byteForCodeUnit(prev);
    }
    // Already at a line start: jump to the previous line's LAST row.
    final prevLs = await doc.lineStartBack(offset, 1);
    if (prevLs == offset) return offset; // at BOF
    if (offset - prevLs > _wrapBackScanCap) return prevLs;
    final d = await doc.readRangeDecoded(prevLs, offset - prevLs);
    // Strip the trailing newline before computing wrap points (indices into
    // the stripped text still map straight into the decoded range).
    var t = d.text;
    while (t.isNotEmpty && (t.endsWith('\n') || t.endsWith('\r'))) {
      t = t.substring(0, t.length - 1);
    }
    return prevLs + d.byteForCodeUnit(lastRowCharStart(t, _boundariesOf));
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      await _drainLoop();
    } catch (e) {
      // Reading a document whose handle is suspended for a save/reload, or
      // that was closed meanwhile. Without the finally the flag stayed set
      // and the pane never scrolled again.
      Log.instance.w('scroll drain aborted: $e');
      _pendingDelta = 0;
    } finally {
      _draining = false;
    }
  }

  Future<void> _drainLoop() async {
    final file = _doc;
    while (_pendingDelta != 0 && file != null && identical(_doc, file)) {
      final n = _pendingDelta;
      _pendingDelta = 0;
      // Move n "visual rows" at once (= lines when not wrapping).
      var newOffset = _anchorOffset;
      for (var k = 0; k < n.abs(); k++) {
        final step = n > 0
            ? await _nextRowStart(newOffset)
            : await _prevRowStart(newOffset);
        if (step == newOffset) break; // hit the start/end of the file
        newOffset = step;
      }
      if (newOffset == _anchorOffset) continue; // hit a boundary
      // Derive the line number from the actual newOffset (blindly adding n near EOF/BOF would
      // drift): the file head is always line 0; lineAtOffset is exact once indexed; otherwise
      // fall back to the clamped running sum (marked as an estimate).
      int newLine;
      bool exact;
      if (newOffset == 0) {
        newLine = 0;
        exact = true;
      } else {
        final la = await file.absoluteLineAt(newOffset);
        if (la.exact) {
          newLine = la.line;
          exact = true;
        } else {
          newLine = _anchorLine < 0
              ? -1
              : (_anchorLine + n < 0 ? 0 : _anchorLine + n);
          exact = _anchorLineExact;
        }
      }
      // Fold-aware read (a plain readWindow would paint the hidden lines
      // while scrolling — the folds only LOOKED open).
      final win = await _readVisibleWindow(
        file,
        newOffset,
        _visibleCount + 1,
        newLine,
      );
      if (!mounted) break;
      setState(() {
        _anchorOffset = newOffset;
        _anchorLine = newLine;
        _anchorLineExact = exact;
        _window = win;
        _windowSplices.clear();
      });
    }
  }

  // Scrollbar / fractional jump (a random byte jump → line number unknown until the index
  // fills it in)
  Future<void> _jumpFraction(double f) async {
    final file = _doc;
    if (file == null) return;
    if (_hexMode) {
      // hex: jump straight to the row at that byte fraction (aligned to 16), no line start
      // to find.
      final t = (f.clamp(0.0, 1.0) * file.length).round();
      final base = (t - t % hexBytesPerRow).clamp(0, _hexMaxBase(file.length));
      _anchorOffset = base;
      await _reloadHex();
      return;
    }
    final target = (f.clamp(0.0, 1.0) * file.size).round();
    final off = await file.alignToLineStart(target);
    final la = await file.absoluteLineAt(off); // exact within the indexed prefix, else estimated
    _anchorLineExact = la.exact;
    await _setAnchor(off, la.line);
  }

  // Go to line N (1-based); requires the index to be built
  // On the caret queue like every other caret move, so it cannot interleave
  // with a queued edit that reads _caretOffset after an await.
  Future<void> _gotoLine(int oneBased, {int? column}) =>
      _runQueued(() => _gotoLineNow(oneBased, column: column));

  Future<void> _gotoLineNow(int oneBased, {int? column}) async {
    final file = _doc;
    if (file == null) return;
    if (!file.indexDone) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_l10n.tr('snack_need_index'))));
      return;
    }
    final line = (oneBased - 1).clamp(0, file.absoluteLineCount - 1);
    final off = await file.byteOffsetOfLine(line);
    _anchorLineExact = true; // the line number is user-specified, so treat it as exact
    await _setAnchor(off, line);
    // The caret goes to that line too (VS Code semantics), which also lets
    // Go Back return to where the user came from. An optional column
    // (`120:15`, 1-based characters, clamped to the line) lands inside it.
    var target = off;
    if (column != null && column > 1 && !_hexMode) {
      final le = await file.lineEndOf(off);
      var len = le - off;
      if (len > 1 << 20) len = 1 << 20; // a column deep in a huge line: cap
      if (len > 0) {
        final d = await file.readRangeDecoded(off, len);
        final ci = column - 1 > d.text.length ? d.text.length : column - 1;
        target = off + d.byteForCodeUnit(ci);
      }
    }
    if (!_hexMode && target != _caretOffset) {
      _recordJumpFrom(_caretOffset);
      // What _moveCaretTo does for every other move (it is not used here
      // because the jump is recorded unconditionally, the anchor having
      // already been scrolled to the target): extra cursors collapse, the
      // completion popup closes, the auto-inserted pair is forgotten —
      // otherwise typing after ctrl+g with three cursors went to four places.
      if (_multi) _clearExtra();
      if (_completion != null) _closeCompletion();
      _autoClosedAt = null;
      _colBlock = null;
      _selAnchor = null;
      _caretOffset = target;
      _goalColumn = null;
      _undo.breakCoalescing();
      _ensureCaretVisibleX(off);
      if (mounted) setState(_restartBlink);
    }
  }

  // Is [offset] on a row currently painted (fully or partly)?
  bool _isOffsetOnScreen(int offset) {
    final win = _window;
    if (win == null || win.offsets.isEmpty || _rows.isEmpty) return false;
    if (offset < win.offsets.first) return false;
    if (offset >= win.nextOffset && !win.atEof) return false;
    final ri = _rowIndexOf(offset);
    return ri >= 0 && ri < _fullRowCount + 1;
  }

  void _startIndexing() {
    final file = _doc;
    if (file == null) return;
    file.startIndexing();
    setState(() => _indexing = true);
    _bump();
  }

  // Status-bar "not indexed" label: what the line index is for, why this
  // file did not get one automatically, and a button to build it now.
  Future<void> _showIndexInfo() async {
    final file = _doc;
    if (file == null) return;
    // Also the File-menu entry point: say so when there is nothing to build.
    if (file.indexDone) return _toast(_l10n.tr('status_indexed'));
    if (_indexing) {
      return _toast(
        _l10n.trf('status_indexing', [(file.fractionIndexed * 100).floor()]),
      );
    }
    final sizeMB = (file.size + (1 << 20) - 1) >> 20;
    final build = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l10n = AppLocalizations.of(ctx);
        return AlertDialog(
          title: Text(l10n.tr('index_info_title')),
          content: SizedBox(
            width: 460,
            child: Text(
              l10n.trf('index_info_body', [
                sizeMB,
                AppSettings.instance.autoIndexMaxMB,
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.tr('common_close')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.tr('item_build_index')),
            ),
          ],
        );
      },
    );
    if (build == true && mounted) _startIndexing();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final r = _resolver;
    if (r == null) return KeyEventResult.ignored;
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Completion popup first: it owns Enter/Tab/Esc/arrows while open.
    if (_completion != null && _composing.isEmpty && _completionKey(e)) {
      return KeyEventResult.handled;
    }

    // Hex mode handles caret/scrolling itself: the units here are bytes and "rows (16
    // bytes)", unlike the keybinding caret.* semantics (lines/characters), so it bypasses
    // the resolver.
    if (_hexMode) {
      final handled = _onKeyHex(e);
      if (handled != null) return handled;
    }

    // Editing control keys (when not composing): edit the document directly.
    // (Character input and Enter arrive as IME deltas; backspace/delete produce no delta
    // because the baseline is empty, so they are handled here.)
    if (_composing.isEmpty &&
        _doc != null &&
        !Mods.ctrl) {
      final k = e.logicalKey;
      if (k == LogicalKeyboardKey.backspace) {
        _enqueueCaret(() async {
          await _forEachCursor((_) => _doBackspace());
          await _completionAfterTyping('');
        });
        _recordStep(const MacroKey('backspace'));
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.delete) {
        _enqueueCaret(() => _forEachCursor((_) => _doDeleteForward()));
        _recordStep(const MacroKey('delete'));
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.tab) {
        final shift = Mods.shift;
        _enqueueCaret(
          () => shift ? _indentLines(-1) : _forEachCursor((_) => _tabKey()),
        );
        _recordStep(MacroKey(shift ? 'shiftTab' : 'tab'));
        return KeyEventResult.handled;
      }
    }
    if (_composing.isEmpty && e.logicalKey == LogicalKeyboardKey.escape) {
      // Escape: first stops a running macro, then drops extra cursors —
      // before anything else sees it.
      if (_macroPlaying) {
        _macroCancel = true;
        return KeyEventResult.handled;
      }
      if (_multi) {
        clearCursors();
        return KeyEventResult.handled;
      }
    }

    final chord = _chordFromEvent(e);
    if (chord == null) return KeyEventResult.ignored;

    final res = r.input(chord, _keyContext);
    switch (res.kind) {
      case ResolveKind.fired:
        _chordTimer?.cancel();
        _lastFiredChord = chord.canonical;
        _lastFiredAt = DateTime.now();
        _registry.dispatch(res.command!, this, res.args, res.count);
        _recordStep(
          MacroCommand(res.command!, args: res.args, count: res.count),
        );
        setState(() {});
        return KeyEventResult.handled;
      case ResolveKind.pending:
        _armChordTimer();
        setState(() {});
        return KeyEventResult.handled;
      case ResolveKind.none:
        // Only the misses are logged: rare in normal use, and the one thing
        // that separates "the key never reached us" (nothing at all in the
        // log — the OS or the text system took it) from "it arrived as a
        // chord nothing is bound to".
        Log.instance.d('key: no binding for ${chord.canonical}');
        _chordTimer?.cancel();
        setState(() {});
        return KeyEventResult.ignored; // let it through (a read-only viewer has no text input)
    }
  }

  // Hex-mode key handling; null = not a key handled here, let it take the normal path.
  KeyEventResult? _onKeyHex(KeyEvent e) {
    final k = e.logicalKey;
    final sel = Mods.shift;
    final ctrl = Mods.accel;
    final doc = _doc;
    if (doc == null) return null;
    // IME composing in the text column: arrows/Enter/Esc belong to the IME.
    if (_composing.isNotEmpty) return KeyEventResult.ignored;
    const row = hexBytesPerRow;
    final page = (_visibleCount > 2 ? _visibleCount - 2 : 1) * row;

    // Insert: toggle insert / overwrite mode
    if (k == LogicalKeyboardKey.insert) {
      setState(() {
        _hexInsertMode = !_hexInsertMode;
        _hexNibble = 0;
      });
      _undo.breakCoalescing(); // mode change → the next edit is its own undo entry
      return KeyEventResult.handled;
    }
    // Tab: switch input focus between the hex and ascii columns (ctrl+tab is reserved for
    // tab switching)
    if (k == LogicalKeyboardKey.tab && !ctrl) {
      setState(() {
        _hexArea = _hexArea == HexArea.hex ? HexArea.ascii : HexArea.hex;
        _hexNibble = 0;
      });
      _syncIme();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete) {
      _enqueueCaret(
        () => _selEnd > _selStart
            ? _hexDelete(_selStart, _selEnd - _selStart)
            : _hexDelete(_caretOffset, 1),
      );
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _enqueueCaret(
        () => _selEnd > _selStart
            ? _hexDelete(_selStart, _selEnd - _selStart)
            : _hexDelete(_caretOffset - 1, 1),
      );
      return KeyEventResult.handled;
    }

    final inHex = _hexArea != HexArea.ascii;
    // Moves go through the caret queue like the hex edits: _hexTypeDigit
    // awaits the overwrite and only then steps a nibble from the CURRENT
    // caret, so an arrow key slipping in between made the caret jump twice.
    // (Home/End read _caretOffset when the op runs, i.e. after queued edits.)
    if (k == LogicalKeyboardKey.arrowLeft) {
      // The hex column moves by nibble (high↔low); the ascii column has no nibbles and moves
      // by whole byte
      _enqueueCaret(
        () => inHex
            ? _hexMoveNibble(-1, select: sel)
            : _hexMoveCaret(-1, select: sel),
      );
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _enqueueCaret(
        () => inHex
            ? _hexMoveNibble(1, select: sel)
            : _hexMoveCaret(1, select: sel),
      );
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _enqueueCaret(() => _hexMoveCaret(-row, select: sel, keepNibble: true));
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _enqueueCaret(() => _hexMoveCaret(row, select: sel, keepNibble: true));
    } else if (k == LogicalKeyboardKey.pageUp && !ctrl) {
      // ctrl+pgup/pgdn is reserved for tab switching
      _enqueueCaret(() => _hexMoveCaret(-page, select: sel, keepNibble: true));
    } else if (k == LogicalKeyboardKey.pageDown && !ctrl) {
      _enqueueCaret(() => _hexMoveCaret(page, select: sel, keepNibble: true));
    } else if (k == LogicalKeyboardKey.home) {
      _enqueueCaret(
        () => _hexMoveCaret(
          ctrl ? -_caretOffset : -(_caretOffset % row),
          select: sel,
        ),
      );
    } else if (k == LogicalKeyboardKey.end) {
      _enqueueCaret(
        () => _hexMoveCaret(
          ctrl ? doc.length - _caretOffset : row - 1 - (_caretOffset % row),
          select: sel,
        ),
      );
    } else if (!ctrl) {
      // Typing: hex column takes 0-9a-fA-F only. The text column's characters
      // arrive through the IME connection (updateEditingValueWithDeltas), so
      // they are not taken from the key event here — that would insert each
      // one twice; without a connection (widget tests) the event's character
      // still works.
      final ch = e.character;
      if (ch == null || ch.isEmpty) return null;
      final c = ch.codeUnitAt(0);
      if (_hexArea == HexArea.hex) {
        final d = _hexDigitValue(c);
        if (d == null) return null;
        _enqueueCaret(() => _hexTypeDigit(d));
      } else {
        if (_ime != null) return null;
        if (c < 0x20 || c == 0x7F) return null; // control keys
        _enqueueCaret(() => _hexTypeAscii(ch));
      }
    } else {
      return null;
    }
    return KeyEventResult.handled;
  }

  // '0'-'9' / 'a'-'f' / 'A'-'F' → 0–15; anything else null.
  int? _hexDigitValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    return null;
  }

  Map<String, Object?> _keyContext() => {
    'mode': _resolver?.mode,
    'editorFocus': true,
    'hasSelection': _selEnd > _selStart,
    'indexed': _doc?.indexDone ?? false,
    // Lets a preset carry a platform-specific binding — needed where the
    // portable chord is taken by the OS (macOS owns ⌥⌘D for the Dock, so
    // ctrl+alt+d never reaches us there).
    'platform': Platform.operatingSystem, // 'macos' | 'windows' | 'linux'
  };

  void _armChordTimer() {
    _chordTimer?.cancel();
    _chordTimer = Timer(const Duration(milliseconds: 800), () {
      final t = _resolver?.flushTimeout();
      if (t != null && t.kind == ResolveKind.fired) {
        _registry.dispatch(t.command!, this, t.args, t.count);
      }
      if (mounted) setState(() {});
    });
  }

  // KeyEvent → KeyChord (modifiers + normalized base key)
  KeyChord? _chordFromEvent(KeyEvent e) => chordFromKeyEvent(e);

  @override
  void dispose() {
    widget.controller._detach(this);
    _chordTimer?.cancel();
    _blinkTimer?.cancel();
    _tailTimer?.cancel();
    _foldTimer?.cancel();
    _wordScanTimer?.cancel();
    _bracketTimer?.cancel();
    _fullHlDebounce?.cancel();
    _hlSession?.close();
    _hlSession = null;
    _detachIme();
    // close() throws if a read is still in flight (closing a tab right after
    // a reload/while indexing); swallow it — the process-level handle cleanup
    // is not our problem at that point.
    _doc?.close().catchError((_) {});
    UserKeymap.instance.removeListener(_onUserKeymapChanged);
    AppSettings.instance.removeListener(_onSettingsChanged);
    _focus.removeListener(_onFocusChange);
    _jumpCtrl.dispose();
    _focus.dispose();
    _searchCtl.dispose();
    _searchFocus.dispose();
    _replaceCtl.dispose();
    _replaceFocus.dispose();
    _gotoCtl.dispose();
    _gotoFocus.dispose();
    super.dispose();
  }

  // The find bar above the viewport: pattern field + regex/case toggles +
  // prev/next/close. Esc closes, Enter finds next (F3 / shift+F3 also work
  // here — the keys bubble up from the field to this Focus).
  Widget _buildSearchBar() {
    Widget toggle(String label, String tooltip, bool on, VoidCallback flip) =>
        Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: () {
              flip();
              _searchFocus.requestFocus();
            },
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: on ? _selColor : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: on ? _fg : _gutterFg,
                  fontSize: 12,
                  fontFamily: editorMonoFont,
                ),
              ),
            ),
          ),
        );

    Widget btn(IconData icon, String tooltip, VoidCallback? onTap) =>
        IconButton(
          icon: Icon(icon, size: 16),
          tooltip: tooltip,
          color: _gutterFg,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          onPressed: onTap,
        );

    return Focus(
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          _closeSearch();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.f3) {
          _find(forward: !Mods.shift);
          return KeyEventResult.handled;
        }
        // VS Code's find-widget toggles: alt+c case, alt+r regex,
        // alt+w whole word, alt+l in selection.
        if (HardwareKeyboard.instance.isAltPressed && !_byteSearch) {
          final k = e.logicalKey;
          if (k == LogicalKeyboardKey.keyC) {
            setState(() => _searchCase = !_searchCase);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.keyR) {
            setState(() => _searchRegex = !_searchRegex);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.keyW) {
            setState(() => _searchWord = !_searchWord);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.keyL) {
            _toggleSearchInSel();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: _chromeBg,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.search, size: 16, color: _gutterFg),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _searchCtl,
                    focusNode: _searchFocus,
                    style: TextStyle(color: _fg, fontSize: 13),
                    cursorColor: _caretColor,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: _l10n.tr(
                        _byteSearch ? 'search_hint_hex' : 'search_hint',
                      ),
                      hintStyle: TextStyle(color: _gutterFg, fontSize: 13),
                    ),
                    onSubmitted: (_) {
                      _find(forward: true);
                      _searchFocus.requestFocus(); // keep typing/enter cycling
                    },
                  ),
                ),
                const SizedBox(width: 4),
                // Hex mode: bytes toggle; regex/case only apply to text.
                if (_hexMode) ...[
                  toggle(
                    '0x',
                    _l10n.tr('tip_search_hex'),
                    _searchHex,
                    () => setState(() => _searchHex = !_searchHex),
                  ),
                  const SizedBox(width: 4),
                ],
                if (!_byteSearch) ...[
                  toggle(
                    '.*',
                    _l10n.tr('tip_search_regex'),
                    _searchRegex,
                    () => setState(() => _searchRegex = !_searchRegex),
                  ),
                  const SizedBox(width: 4),
                  toggle(
                    'Aa',
                    _l10n.tr('tip_search_case'),
                    _searchCase,
                    () => setState(() => _searchCase = !_searchCase),
                  ),
                  const SizedBox(width: 4),
                  toggle(
                    'ab',
                    _l10n.tr('tip_search_word'),
                    _searchWord,
                    () => setState(() => _searchWord = !_searchWord),
                  ),
                  const SizedBox(width: 4),
                  toggle(
                    '≡',
                    _l10n.tr('tip_search_in_sel'),
                    _searchInSel,
                    _toggleSearchInSel,
                  ),
                  const SizedBox(width: 4),
                ],
                if (_searching)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...[
                  btn(
                    Icons.keyboard_arrow_up,
                    _l10n.tr('tip_search_prev'),
                    () => _find(forward: false),
                  ),
                  btn(
                    Icons.keyboard_arrow_down,
                    _l10n.tr('tip_search_next'),
                    () => _find(forward: true),
                  ),
                ],
                btn(Icons.close, _l10n.tr('tip_search_close'), _closeSearch),
              ],
            ),
            if (_replaceOpen)
              Row(
                children: [
                  Icon(Icons.find_replace, size: 16, color: _gutterFg),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _replaceCtl,
                      focusNode: _replaceFocus,
                      style: TextStyle(color: _fg, fontSize: 13),
                      cursorColor: _caretColor,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: _l10n.tr('replace_hint'),
                        hintStyle: TextStyle(color: _gutterFg, fontSize: 13),
                      ),
                      onSubmitted: (_) {
                        _replaceCurrent();
                        _replaceFocus.requestFocus();
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _searching ? null : _replaceCurrent,
                    child: Text(
                      _l10n.tr('btn_replace'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: _searching ? null : _replaceAll,
                    child: Text(
                      _l10n.tr('btn_replace_all'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final file = _doc;
    // Recompute the content width only when the window changed (not on every scroll build).
    final winChanged = !identical(_hlWindow, _window);
    _ensureContentW();
    if (winChanged && !_hexMode) {
      _hlWindow = _window;
      final m = _maxScrollX;
      if (!_rtlLayoutActive && _scrollX > m) _scrollX = m; // the new window is narrower → clamp back
    }
    if (_rtlLayoutActive) {
      // Mirrored scroll origin: keep the distance from the right edge.
      final m = _maxScrollX;
      _scrollXv = (m - _hScrollFromRight).clamp(0.0, m);
    }
    // Recompute window spans when the window changed OR the whole-file cache became available/changed.
    final spansChanged = winChanged || _fullHlRev != _hlFullRevSeen;
    if (spansChanged) {
      _hlFullRevSeen = _fullHlRev;
      final sw = Stopwatch()..start();
      _spans = _computeWindowSpans();
      _slow(
        'window spans (${_window?.lines.length} lines, '
        '${_fullHl == null ? 'window-parse' : 'cache'}, ${_hl.description})',
        sw,
      );
    }
    // Window / spans / wrap columns changed → re-expand the visual rows.
    final rowsKey =
        '$_wrapMode/$_wrapColumns/${_wrapMode == 'window' ? _textViewW.round() : 0}';
    if (spansChanged || _rowsKey != rowsKey) {
      final sw = Stopwatch()..start();
      _rebuildRows();
      _slow('rebuild rows ($rowsKey, ${_rows.length} rows)', sw);
    }
    _maybeScheduleFullHl(); // (re)compute whole-file spans when a small file becomes eligible
    _smartWord = _computeSmartWord();
    return ColoredBox(
      color: _bg,
      // No document yet (the brief gap while loading): paint only the background, with a
      // progress spinner while opening. Opening lives in the menubar (File → Open); startup
      // provides an untitled document by default.
      child: file == null
          ? Center(
              child: _opening
                  ? const CircularProgressIndicator()
                  : const SizedBox.shrink(),
            )
          : LayoutBuilder(
              builder: (ctx, box) {
                // A docking split can squeeze a pane to a few pixels; the
                // fixed-height bars would overflow the Column then, so shed
                // them (status first, input bars next) and keep only the
                // shrinkable editor viewport.
                final showStatus = box.maxHeight >= 64;
                final showBars = box.maxHeight >= 170;
                return Column(
                  children: [
                    if (showBars && _searchOpen) _buildSearchBar(),
                    if (showBars && _gotoOpen) _buildGotoBar(),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (ctx, c) {
                          final h = c.maxHeight;
                          _viewportW = c.maxWidth;
                          if ((h - _viewportH).abs() > _lineHeight) {
                            _viewportH = h;
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => _reload(),
                            );
                          } else {
                            _viewportH = h;
                          }
                          return Listener(
                            // Raw down, before the gesture arena: marks the
                            // press as not yet handled (see _pressHandled).
                            onPointerDown: (e) {
                              _pressHandled = false;
                              _pressPos = e.localPosition;
                            },
                            onPointerSignal: (sig) {
                              if (sig is PointerScrollEvent) {
                                // accel+wheel → font zoom (one step per
                                // notch, sign only — trackpad pinch on
                                // Windows arrives as ctrl+wheel too). On macOS
                                // that is ⌘, like every other `ctrl` binding —
                                // and ⌃+scroll is the OS screen zoom there.
                                if (Mods.accel) {
                                  final dy = sig.scrollDelta.dy;
                                  if (dy != 0) zoomFont(dy < 0 ? 1 : -1);
                                  return;
                                }
                                // shift+wheel → horizontal scroll; a trackpad's dx is horizontal too
                                final shift =
                                    Mods.shift;
                                final dx =
                                    sig.scrollDelta.dx +
                                    (shift ? sig.scrollDelta.dy : 0);
                                if (dx != 0) _scrollXBy(dx);
                                final dy = shift ? 0.0 : sig.scrollDelta.dy;
                                if (dy != 0) _accumScroll(dy);
                              }
                            },
                            // Trackpad two-finger pans (macOS only) arrive as
                            // pan/zoom events, never as scroll signals — we
                            // scroll (and pinch-zoom) on them here, and keep
                            // them away from the drag recognizer below.
                            onPointerPanZoomStart: (_) => _panZoomStart(),
                            onPointerPanZoomUpdate: _panZoomUpdate,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // Everything but the trackpad: Flutter feeds a
                              // trackpad pan to the drag recognizers as if the
                              // primary button were held (that is how it
                              // scrolls a Scrollable on macOS), so without
                              // this a two-finger scroll silently drag-selects
                              // — or, when the last press armed the move-drag,
                              // drops the selection somewhere else.
                              supportedDevices: _pointerDragDevices,
                              // Click places the caret (shift extends the
                              // selection); drag selects; double/triple
                              // click selects word/line and a drag from
                              // there extends by that unit (see _onPress).
                              onTapDown: (d) {
                                _focus.requestFocus();
                                _onPress(d.localPosition);
                              },
                              onSecondaryTapDown: (d) {
                                _focus.requestFocus();
                                _showContextMenu(
                                  d.localPosition,
                                  d.globalPosition,
                                );
                              },
                              onPanStart: (d) {
                                _focus.requestFocus();
                                // alt is held for adding cursors: a jittery
                                // alt+click must not become a drag-select.
                                if (_pressAlt) {
                                  return;
                                }
                                // A fast drag beats the tap recognizer and
                                // onTapDown never fires: count the press
                                // here so double-click+drag still selects
                                // by words. Otherwise the press already
                                // placed the caret / selected the unit.
                                if (!_pressHandled) _onPress(_pressPos);
                              },
                              onTapUp: (d) {
                                // Click inside the selection without a
                                // drag: place the caret now (deferred from
                                // the press, see _onPress).
                                if (_dragMode == _DragMode.move) {
                                  _moveDragCancel();
                                  _placeCaretAt(_pressPos, select: false);
                                }
                              },
                              onPanUpdate: (d) {
                                if (_pressAlt) {
                                  return;
                                }
                                switch (_dragMode) {
                                  case _DragMode.char:
                                    _placeCaretAt(
                                      d.localPosition,
                                      select: true,
                                    );
                                  case _DragMode.word:
                                  case _DragMode.line:
                                    _extendDragTo(d.localPosition);
                                  case _DragMode.move:
                                    _moveDragHover(d.localPosition);
                                }
                              },
                              onPanEnd: (_) {
                                if (_dragMode == _DragMode.move) {
                                  _moveDragDrop(
                                    copy: Mods.ctrl,
                                  );
                                }
                              },
                              onPanCancel: () {
                                if (_dragMode == _DragMode.move) {
                                  _moveDragCancel();
                                }
                              },
                              child: Focus(
                                focusNode: _focus,
                                onKeyEvent: _onKey,
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: _hexMode
                                          ? HexViewport(
                                              key: _hexKey,
                                              bytes: _hexBytes,
                                              base: _anchorOffset,
                                              docLength: file.length,
                                              caretOffset: _caretForPaint,
                                              caretNibble: _hexNibble,
                                              activeArea: _hexArea,
                                              insertMode: _hexInsertMode,
                                              caretOn: _caretOn,
                                              caretFocused: _caretFocused,
                                              selStart: _selStart,
                                              selEnd: _selEnd,
                                              scrollX: _scrollX,
                                              settingsEpoch: _settingsEpoch,
                                              textCells: _hexCells,
                                              composing: _composing,
                                            )
                                          : TextViewport(
                                              window: _window,
                                              rows: _rows,
                                              rowSpans: _rowSpans,
                                              anchorLine: _anchorLine,
                                              anchorOffset: _anchorOffset,
                                              totalBytes: file.size,
                                              caretOffset: _caretForPaint,
                                              caretAtRowEnd: _caretAtRowEnd,
                                              smartWord: _smartWord,
                                              selStart: _selStart,
                                              selEnd: _selEnd,
                                              block: _columnMode
                                                  ? _colBlock
                                                  : null,
                                              caretOn: _caretOn,
                                              caretFocused: _caretFocused,
                                              composing: _composing,
                                              spans: _spans,
                                              scrollX: _scrollX,
                                              contentW: _contentW,
                                              rtlMode: _rtlMode,
                                              settingsEpoch: _settingsEpoch,
                                              bookmarks: _bookmarksView,
                                              brackets: _bracketPair,
                                              extraCarets: _extraCaretsView,
                                              extraSels: _extraSelsView,
                                              foldable: _foldableView,
                                              folded: _foldedView,
                                              dropCaret: _dropOffset,
                                            ),
                                    ),
                                    if (_completion != null && !_hexMode)
                                      _completionPopup(),
                                    // Right-hand scrollbar drag zone: byte-fraction jump
                                    Positioned(
                                      top: 0,
                                      bottom: 0,
                                      right: 0,
                                      width: 16,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        supportedDevices: _pointerDragDevices,
                                        onTapDown: (d) => _jumpFraction(
                                          d.localPosition.dy / h,
                                        ),
                                        onVerticalDragUpdate: (d) =>
                                            _jumpFraction(
                                              d.localPosition.dy / h,
                                            ),
                                      ),
                                    ),
                                    // Bottom horizontal scrollbar drag zone (mounted only
                                    // when the content is wider than the view, so it does
                                    // not swallow clicks on the bottom row of text); the
                                    // right end is left to the vertical scrollbar.
                                    if (_maxScrollX > 0)
                                      Positioned(
                                        left: 0,
                                        right: 16,
                                        bottom: 0,
                                        height: 14,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.translucent,
                                          supportedDevices: _pointerDragDevices,
                                          onTapDown: (d) =>
                                              _hScrollTo(d.localPosition.dx),
                                          onHorizontalDragUpdate: (d) =>
                                              _hScrollTo(d.localPosition.dx),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (showStatus) _statusBar(file),
                  ],
                );
              },
            ),
    );
  }

  // Go to line: an inline input bar in the style of the search bar (requires the index).
  // Mutually exclusive with the search bar, so two bars never stack above the edit area.
  bool _gotoOpen = false;
  final TextEditingController _gotoCtl = TextEditingController();
  final FocusNode _gotoFocus = FocusNode();

  void _promptGotoLine() {
    if (_doc == null) return;
    setState(() {
      _gotoOpen = true;
      _searchOpen = false;
      _replaceOpen = false;
    });
    _gotoFocus.requestFocus();
    _gotoCtl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _gotoCtl.text.length,
    );
  }

  void _closeGoto() {
    setState(() => _gotoOpen = false);
    _focus.requestFocus();
  }

  void _submitGoto() {
    if (!_submitGotoText(_gotoCtl.text)) return;
    _closeGoto();
  }

  // Shared by the goto bar and the status-bar jump field: hex mode takes a
  // byte offset (decimal / 0x hex / trailing h), text mode a 1-based line.
  // Returns false when the entry did not parse (the bar stays open).
  bool _submitGotoText(String text) {
    if (_hexMode) {
      final off = parseOffsetInput(text);
      if (off == null) return false;
      _gotoOffset(off);
      return true;
    }
    // `120` or `120:15` (also `120,15`): line, optionally a 1-based column.
    final m = RegExp(r'^\s*(\d+)\s*(?:[:,]\s*(\d+))?\s*$').firstMatch(text);
    if (m == null) return false;
    final n = int.tryParse(m.group(1)!);
    if (n == null) return false;
    final col = m.group(2) == null ? null : int.tryParse(m.group(2)!);
    _gotoLine(n, column: col);
    return true;
  }

  // Hex mode go-to: park the caret on byte [offset] (clamped; insert mode may
  // sit past the last byte) and scroll it into view. No index needed — rows
  // are fixed 16 bytes.
  void _gotoOffset(int offset) => _enqueueCaret(() async {
    final doc = _doc;
    if (doc == null || !_hexMode) return;
    final maxOff = doc.length; // after the last byte is a valid position
    final off = offset < 0 ? 0 : (offset > maxOff ? maxOff : offset);
    setState(() {
      _selAnchor = null;
      _caretOffset = off;
      _hexNibble = 0;
    });
    _undo.breakCoalescing();
    _restartBlink();
    await _ensureCaretVisibleHex();
    _bump();
  });

  // Goto entry filter: text mode digits plus the `line:col` / `line,col`
  // separators; hex mode also 0x / a-f / h.
  List<TextInputFormatter> get _gotoFormatters => [
    if (_hexMode)
      FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-FxXhH]'))
    else
      FilteringTextInputFormatter.allow(RegExp('[0-9:,]')),
  ];

  Widget _buildGotoBar() {
    return Focus(
      onKeyEvent: (node, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          _closeGoto();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: _chromeBg,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.tag, size: 16, color: _gutterFg),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _gotoCtl,
                focusNode: _gotoFocus,
                keyboardType: _hexMode
                    ? TextInputType.text
                    : TextInputType.number,
                inputFormatters: _gotoFormatters,
                style: TextStyle(color: _fg, fontSize: 13),
                cursorColor: _caretColor,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: _l10n.tr(_hexMode ? 'goto_hint_hex' : 'goto_hint'),
                  hintStyle: TextStyle(color: _gutterFg, fontSize: 13),
                ),
                onSubmitted: (_) => _submitGoto(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward, size: 16),
              tooltip: _l10n.tr(
                _hexMode ? 'tip_goto_offset' : 'item_goto_line',
              ),
              color: _gutterFg,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: _submitGoto,
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: _l10n.tr('tip_search_close'),
              color: _gutterFg,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: _closeGoto,
            ),
          ],
        ),
      ),
    );
  }

  // Left segment of the status bar in hex mode: the current row's offset + the value of the
  // byte under the caret.
  String _hexStatusText(Document file) {
    final o = _caretOffset;
    final i = o - _anchorOffset;
    final b = (i >= 0 && i < _hexBytes.length) ? _hexBytes[i] : null;
    final hex = o.toRadixString(16).toUpperCase().padLeft(8, '0');
    final val = b == null
        ? ''
        : _l10n.trf('hex_value_fmt', [
            b.toRadixString(16).toUpperCase().padLeft(2, '0'),
            b.toString().padLeft(3),
          ]);
    final area = _hexArea == HexArea.hex
        ? _l10n.trf('hex_area_fmt', [
            _l10n.tr(_hexNibble == 0 ? 'hex_high' : 'hex_low'),
          ])
        : 'ASCII';
    final mode = _hexInsertMode ? 'INS' : 'OVR';
    return _l10n.trf('hex_status_fmt', [area, mode, hex, val]);
  }

  // The status bar's selection field: column mode reports the rectangle's size (the column
  // count is visible; the line count is only exact with an index, and the difference of
  // line-start offsets is not intuitive → reporting the covered line count directly would
  // need a line scan, so only the column count and the top/bottom bounds are shown).
  // Selection field; '' when there is nothing to say (the caret's own
  // position is already the line/column/byte fields).
  String _selectionText() {
    final b = _colBlock;
    if (_columnMode) {
      if (b == null || b.isEmpty) return _l10n.tr('status_caret_col');
      return _l10n.trf('status_block', [
        b.leftCol,
        b.rightCol,
        b.rightCol - b.leftCol,
        b.topLine,
        b.bottomLine,
      ]);
    }
    return _selEnd > _selStart
        ? _l10n.trf('status_sel', [_selEnd - _selStart])
        : '';
  }

  // ── Status-bar caret position (line / character column) ──
  // Everything in the status bar is caret-based (VS Code / Notepad++
  // convention). While the caret is inside the window this is a sync lookup
  // on the rows; scrolled away from it, the position is computed once
  // asynchronously (absoluteLineAt + a decoded line prefix) and cached by
  // offset until the caret moves or the document changes.
  ({int offset, int line, bool exact, int? col})? _caretPosCache;
  int? _caretPosPending; // offset whose async lookup is in flight

  ({int line, bool exact, int? col})? _caretLineCol() {
    final win = _window;
    final doc = _doc;
    if (win == null || doc == null) return null;
    final c = _caretOffset;
    final inWindow =
        _rows.isNotEmpty &&
        win.offsets.isNotEmpty &&
        c >= win.offsets.first &&
        (c < win.nextOffset || win.atEof);
    if (inWindow) {
      final ri = _rowIndexOf(c);
      if (ri >= 0 && ri < _rows.length) {
        final row = _rows[ri];
        final lineText = row.lineIndex < win.lines.length
            ? win.lines[row.lineIndex]
            : row.text;
        final within = row.charOfByte(
          (c - row.offset).clamp(0, row.contentBytes),
        );
        final ln = win.lineNumberAt(row.lineIndex);
        return (
          line: ln >= 0 ? ln : _anchorLine + row.lineIndex,
          exact: _anchorLineExact,
          col: charColumn(lineText, row.charStart + within, _tabSize),
        );
      }
    }
    final cache = _caretPosCache;
    if (cache != null && cache.offset == c) {
      return (line: cache.line, exact: cache.exact, col: cache.col);
    }
    if (_caretPosPending != c) {
      _caretPosPending = c;
      _lookupCaretPos(doc, c);
    }
    return null;
  }

  Future<void> _lookupCaretPos(Document doc, int c) =>
      _offQueue('caret position', () => _lookupCaretPosNow(doc, c));

  Future<void> _lookupCaretPosNow(Document doc, int c) async {
    try {
      final la = await doc.absoluteLineAt(c);
      final ls = await doc.lineStartOf(c);
      int? col;
      if (c - ls <= _wrapBackScanCap) {
        final d = await doc.readRangeDecoded(ls, c - ls);
        col = charColumn(d.text, d.text.length, _tabSize);
      }
      if (!mounted || _doc != doc) return;
      _caretPosCache = (offset: c, line: la.line, exact: la.exact, col: col);
    } catch (_) {
      // Document closed / reloaded underneath: leave the field blank.
    } finally {
      if (_caretPosPending == c) _caretPosPending = null;
    }
    if (mounted && _caretOffset == c) setState(() {});
  }

  // Status-bar encoding field: current codec + how it was chosen.
  String _encodingText(Document file) {
    final g = _encGuess;
    final tag = _encManual
        ? ''
        : (g != null && !g.confident ? _l10n.tr('enc_default_tag') : '');
    return _l10n.trf('status_encoding', [file.codec.name, tag]);
  }

  Widget _statusBar(Document file) {
    final totalText = file.indexDone
        ? ' / ${file.absoluteLineCount}'
        : (file.absoluteLineCount > 0 ? ' / ~${file.absoluteLineCount}' : '');
    final pos = _hexMode ? null : _caretLineCol();
    final lineText = _l10n.trf('status_line_fmt', [
      pos == null ? '–' : '${pos.line + 1}',
      pos == null || pos.exact ? '' : _l10n.tr('status_line_est'),
      totalText,
      pos?.col == null ? '–' : '${pos!.col}',
    ]);
    final bytePct = file.size == 0
        ? 0
        : (_caretOffset / file.size * 100).floor();
    return Container(
      height: 30,
      color: _chromeBg,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      // A narrow docking split can't fit the fixed-width jump field: shed it
      // (the scrollable text section shrinks to zero on its own).
      child: LayoutBuilder(
        builder: (_, c) {
          final showJump = c.maxWidth >= 220;
          return Row(
            children: [
              // Status texts vary a lot by locale/window width: let them scroll
              // horizontally instead of overflowing (a RenderFlex overflow is a
              // hard failure in tests and a paint glitch in the app).
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // Mode indicator (only for modal keymaps such as vim) + pending chord sequence
                      if (_resolver?.defaultMode != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          color: const Color(0xFF0E639C),
                          child: Text(
                            (_resolver?.mode ?? '').toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if ((_resolver?.hasPending ?? false)) ...[
                        Text(
                          _resolver!.pendingText,
                          style: const TextStyle(
                            color: Color(0xFFE5C07B),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Text(
                        _hexMode ? _hexStatusText(file) : lineText,
                        style: TextStyle(color: _gutterFg, fontSize: 12),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        _l10n.trf('status_bytes', [
                          _caretOffset,
                          file.size,
                          bytePct,
                        ]),
                        style: TextStyle(color: _gutterFg, fontSize: 12),
                      ),
                      if (_selectionText().isNotEmpty) ...[
                        const SizedBox(width: 16),
                        Text(
                          _selectionText(),
                          style: TextStyle(
                            color:
                                (_colBlock != null && !_colBlock!.isEmpty) ||
                                    _selEnd > _selStart
                                ? _fg
                                : _gutterFg,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(width: 16),
                      Text(
                        _encodingText(file),
                        style: TextStyle(color: _gutterFg, fontSize: 12),
                      ),
                      // Index state: nothing once indexed (the normal case),
                      // progress while building, otherwise a link to an
                      // explanation dialog that can also start the build.
                      if (_indexing && !file.indexDone) ...[
                        const SizedBox(width: 16),
                        Text(
                          _l10n.trf('status_indexing', [
                            (file.fractionIndexed * 100).floor(),
                          ]),
                          style: TextStyle(color: _gutterFg, fontSize: 12),
                        ),
                      ] else if (!file.indexDone) ...[
                        const SizedBox(width: 16),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: _showIndexInfo,
                            child: Text(
                              _l10n.tr('status_unindexed'),
                              style: TextStyle(
                                color: _gutterFg,
                                fontSize: 12,
                                decoration: TextDecoration.underline,
                                decorationColor: _gutterFg,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (showJump) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 130,
                  height: 24,
                  child: TextField(
                    controller: _jumpCtrl,
                    style: TextStyle(color: _fg, fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: _l10n.tr(
                        _hexMode ? 'goto_hint_hex' : 'goto_hint',
                      ),
                      hintStyle: TextStyle(color: _gutterFg, fontSize: 11),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: _hexMode
                        ? TextInputType.text
                        : TextInputType.number,
                    inputFormatters: _gotoFormatters,
                    onSubmitted: (s) {
                      _submitGotoText(s);
                      _focus.requestFocus();
                    },
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// A user-script failure inside the transform callback; toString is the bare
// message (a StateError would prefix the toast with "Bad state:").
class _ScriptRunError implements Exception {
  _ScriptRunError(this.message);
  final String message;
  @override
  String toString() => message;
}

// Word-count dialog: streams the byte range through StatsAccumulator with a
// progress bar; counting stops when the dialog is dismissed. Chunk edges are
// re-aligned to character boundaries (the trailing, possibly cut char of
// each chunk is dropped and re-read next round, surrogate pairs included).
/// Modal "working…" dialog (indeterminate) for a long run such as a user
/// script; closes itself when [done] completes and cannot be dismissed.
class _BusyDialog extends StatefulWidget {
  const _BusyDialog({
    required this.title,
    required this.body,
    required this.done,
    this.onCancel,
  });
  final String title;
  final String body;
  final Future<void> done;

  /// When given, a Cancel button asks the work to stop (the dialog still
  /// closes only once [done] completes).
  final VoidCallback? onCancel;

  @override
  State<_BusyDialog> createState() => _BusyDialogState();
}

class _BusyDialogState extends State<_BusyDialog> {
  @override
  void initState() {
    super.initState();
    widget.done.whenComplete(() {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.body),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: widget.onCancel == null
          ? null
          : [
              TextButton(
                onPressed: widget.onCancel,
                child: Text(AppLocalizations.of(context).tr('common_cancel')),
              ),
            ],
    ),
  );
}

/// Modal progress shown while the first edit of a big file waits for the line
/// index (see _EditorViewState._onIndexWait). Closes itself when [done]
/// completes; cannot be dismissed — the edit is already committed to waiting.
class _IndexWaitDialog extends StatefulWidget {
  const _IndexWaitDialog({required this.doc, required this.done});
  final Document doc;
  final Future<void> done;

  @override
  State<_IndexWaitDialog> createState() => _IndexWaitDialogState();
}

class _IndexWaitDialogState extends State<_IndexWaitDialog> {
  StreamSubscription<IndexProgress>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.doc.progress.listen((_) {
      if (mounted) setState(() {});
    });
    widget.done.whenComplete(() {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pct = (widget.doc.fractionIndexed * 100).floor();
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l10n.tr('index_wait_title')),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.tr('index_wait_body')),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: widget.doc.fractionIndexed),
              const SizedBox(height: 8),
              Text(l10n.trf('status_indexing', [pct])),
            ],
          ),
        ),
      ),
    );
  }
}

class _WordCountDialog extends StatefulWidget {
  const _WordCountDialog({
    required this.doc,
    required this.start,
    required this.end,
    required this.selection,
  });

  final Document doc;
  final int start;
  final int end;
  final bool selection;

  @override
  State<_WordCountDialog> createState() => _WordCountDialogState();
}

class _WordCountDialogState extends State<_WordCountDialog> {
  TextStats? _stats;
  double _progress = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _run() async {
    final acc = StatsAccumulator();
    final end = widget.end;
    final total = end - widget.start;
    var pos = widget.start;
    while (pos < end) {
      if (_disposed) return;
      final readLen = (end - pos) < (1 << 20) ? (end - pos) : (1 << 20);
      final d = await widget.doc.readRangeDecoded(pos, readLen);
      final text = d.text;
      var nextPos = pos + readLen;
      if (pos + readLen < end && text.length > 1) {
        // Drop the final (possibly cut) char; a low surrogate at the end
        // means the pair starts one unit earlier.
        var cut = text.length - 1;
        final cu = text.codeUnitAt(cut);
        if (cu >= 0xDC00 && cu <= 0xDFFF && cut > 0) cut--;
        acc.feed(text.substring(0, cut));
        final aligned = pos + d.byteForCodeUnit(cut);
        nextPos = aligned > pos ? aligned : pos + readLen;
      } else {
        acc.feed(text);
      }
      pos = nextPos;
      if (mounted && total > 0) {
        setState(() => _progress = (pos - widget.start) / total);
      }
    }
    if (mounted) setState(() => _stats = acc.finish(total));
  }

  static String _n(int v) {
    final s = '$v';
    final sb = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) sb.write(',');
      sb.write(s[i]);
    }
    return sb.toString();
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(label), const SizedBox(width: 32), Text(value)],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final st = _stats;
    return AlertDialog(
      title: Text(l10n.tr('wc_title')),
      content: ResizableDialogBox(
        id: 'wordCount',
        initialWidth: 320,
        child: st == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 8),
                  Text('${(_progress * 100).floor()}%'),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.tr(widget.selection ? 'wc_scope_sel' : 'wc_scope_all'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  _row(l10n.tr('wc_lines'), _n(st.lines)),
                  _row(l10n.tr('wc_chars'), _n(st.chars)),
                  _row(l10n.tr('wc_chars_no_ws'), _n(st.charsNoWs)),
                  _row(l10n.tr('wc_words'), _n(st.words)),
                  _row(l10n.tr('wc_cjk'), _n(st.cjk)),
                  _row(l10n.tr('wc_bytes'), _n(st.bytes)),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.tr('common_close')),
        ),
      ],
    );
  }
}

/// State of the word-completion popup (see _EditorViewState._completion).
class _CompletionState {
  _CompletionState({
    required this.prefix,
    required this.items,
    required this.selected,
    required this.anchor,
  });
  final String prefix;
  final List<Completion> items;
  int selected;
  final Offset anchor; // just below the caret, viewport coordinates
}
