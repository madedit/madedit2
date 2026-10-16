part of 'editor_view.dart';

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
    this.searchMarks = const [],
    this.searchScope,
    required this.extraCarets,
    required this.extraSels,
    required this.foldable,
    required this.folded,
    required this.dropCaret,
    this.zoom = 1,
    this.tabSize = 4,
  });

  /// Drop indicator while the selection is being dragged (null = none).
  final int? dropCaret;

  /// This pane's quick-zoom factor (font size / row height multiplier).
  final double zoom;

  /// Tab width for this pane (global setting or `.editorconfig`).
  final int tabSize;

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

  /// Byte offsets of every match of the current find query (capped scan, see
  /// [collectMatches]) — ticks on the vertical scrollbar. Fresh list on
  /// change, same identical-check contract as [bookmarks].
  final List<int> searchMarks;

  /// Find-in-selection scope [start, end] (document bytes): a faint band
  /// behind the text inside it. Null = no scope shown.
  final (int, int)? searchScope;

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
        searchMarks: searchMarks,
        searchScope: searchScope,
        extraCarets: extraCarets,
        extraSels: extraSels,
        foldable: foldable,
        folded: folded,
        dropCaret: dropCaret,
        zoom: zoom,
        tabSize: tabSize,
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
      ..searchMarks = searchMarks
      ..searchScope = searchScope
      ..extraCarets = extraCarets
      ..extraSels = extraSels
      ..foldable = foldable
      ..folded = folded
      ..dropCaret = dropCaret
      ..zoom = zoom
      ..tabSize = tabSize;
  }
}

/// One laid-out line kept for reuse across paints. The paragraph is valid
/// only while every input that shaped it is unchanged, so the entry carries
/// them for an exact re-check on the next frame.
class _ParaCacheEntry {
  const _ParaCacheEntry(
    this.para,
    this.line,
    this.spans,
    this.startColumn,
    this.baseRtl,
  );
  final _LinePara para;
  final String line;
  final List<HlSpan>? spans;
  final int startColumn;
  final bool? baseRtl;
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
    this._searchMarks = const [],
    this._searchScope,
    required this._extraCarets,
    required this._extraSels,
    required this._foldable,
    required this._folded,
    required this._dropCaret,
    this._zoom = 1,
    this._tabSize = 4,
  });

  int? _dropCaret;
  set dropCaret(int? v) {
    if (v == _dropCaret) return;
    _dropCaret = v;
    markNeedsPaint();
  }

  // The pane's quick-zoom factor. The members below shadow the top-level
  // metric getters / line builders with this pane's zoom applied, so the
  // painting code reads the same as before zoom became per tab — and MUST
  // stay identical to _EditorViewState's (hit-tests mirror the painter).
  double _zoom;
  set zoom(double v) {
    if (v == _zoom) return;
    _zoom = v;
    _paraCache.clear();
    markNeedsPaint();
  }

  // Tab width follows the pane's .editorconfig when one applies. Like zoom,
  // the render object and state must agree or clicks miss the painted glyphs.
  int _tabSize;
  set tabSize(int v) {
    if (v == _tabSize) return;
    _tabSize = v;
    _paraCache.clear();
    markNeedsPaint();
  }

  double get _fontSize => editorFontSizeAt(_zoom);
  double get _lineHeight => editorLineHeightAt(_zoom);
  double get editorCharWidth => editorCharWidthAt(_zoom);
  double _gutterWidthFor(int anchorLine, int linesInWindow) =>
      _gutterWidthAt(anchorLine, linesInWindow, _zoom);
  _LinePara _buildLine(
    String raw,
    double maxWidth, [
    Color? textColor,
    int startColumn = 0,
    bool? baseRtl,
  ]) => _buildLineAt(
    _zoom,
    raw,
    maxWidth,
    textColor,
    startColumn,
    baseRtl,
    _tabSize,
  );
  _LinePara _buildLineStyled(
    String raw,
    double maxWidth,
    List<HlSpan>? spans, {
    int startColumn = 0,
    bool? baseRtl,
  }) => _buildLineStyledAt(
    _zoom,
    raw,
    maxWidth,
    spans,
    startColumn: startColumn,
    baseRtl: baseRtl,
    tabSize: _tabSize,
  );

  // Shaping + laying out every visible line dominates paint cost, yet the
  // rows barely change while scrolling, so cache the laid-out paragraph per
  // row start offset and reuse it across frames. An entry is reused only
  // when its text, highlight spans, wrap start column and RTL base are all
  // identical; zoom / tab width / theme changes reflow every line and clear
  // the whole cache (their setters below). Bounded LRU so native paragraph
  // memory tracks the viewport, not the file size.
  final Map<int, _ParaCacheEntry> _paraCache = {};
  static const int _paraCacheCap = 512;

  /// Cache misses (real paragraph builds) since the last reset; lets a test
  /// prove scrolling reuses cached rows instead of reshaping every line.
  @visibleForTesting
  int paraBuildsForTest = 0;

  _LinePara _paraFor(
    int rowStart,
    String line,
    List<HlSpan>? spans,
    int startColumn,
    bool? baseRtl,
  ) {
    final hit = _paraCache[rowStart];
    if (hit != null &&
        hit.line == line &&
        hit.startColumn == startColumn &&
        hit.baseRtl == baseRtl &&
        _sameSpans(hit.spans, spans)) {
      _paraCache
        ..remove(rowStart)
        ..[rowStart] = hit; // refresh recency
      return hit.para;
    }
    final para = _buildLineStyled(
      line,
      _layoutMaxW,
      spans,
      startColumn: startColumn,
      baseRtl: baseRtl,
    );
    paraBuildsForTest++;
    _paraCache[rowStart] = _ParaCacheEntry(
      para,
      line,
      spans,
      startColumn,
      baseRtl,
    );
    if (_paraCache.length > _paraCacheCap) {
      _paraCache.remove(_paraCache.keys.first);
    }
    return para;
  }

  static bool _sameSpans(List<HlSpan>? a, List<HlSpan>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.start != y.start || x.end != y.end || x.style != y.style) {
        return false;
      }
    }
    return true;
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

  List<int> _searchMarks;
  set searchMarks(List<int> v) {
    if (identical(v, _searchMarks)) return;
    _searchMarks = v;
    markNeedsPaint();
  }

  (int, int)? _searchScope;
  set searchScope((int, int)? v) {
    if (v == _searchScope) return; // records compare by value
    _searchScope = v;
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
    _paraCache.clear();
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
        final para = _paraFor(
          rowStart,
          line,
          rowSpans,
          _rowStartColumn(win, row, _tabSize),
          _rtlMode == 2 ? true : null,
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

        // Find-in-selection scope: a faint band over this row's scoped bytes
        // (beneath the selection, which keeps its own color).
        final scope = _searchScope;
        if (scope != null && scope.$2 > rowStart && scope.$1 < rowEnd) {
          final sB = (scope.$1 - rowStart).clamp(0, contentBytes);
          final eB = (scope.$2 - rowStart).clamp(0, contentBytes);
          if (eB > sB) {
            final x0 = rowX + para.xOf(row.charOfByte(sB));
            final x1 = rowX + para.xOf(row.charOfByte(eB));
            if (x1 > x0) {
              canvas.drawRect(
                Rect.fromLTWH(x0, y, x1 - x0, _lineHeight),
                Paint()..color = _selColor.withValues(alpha: 0.15),
              );
            }
          }
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
          gw - _gutterPad * 2 - _foldColW,
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

  // Paint right-aligned line-number text. Laid out unbounded, never at
  // [maxWidth]: a single-line paragraph with an ellipsis silently drops the
  // last digit when it is a fraction of a pixel too wide. A number that does
  // not fit spills left into the padding instead of being cut.
  void _paintRight(
    Canvas canvas,
    String text,
    double x,
    double y,
    double maxWidth,
  ) {
    final p = _buildLine(text, _layoutMaxW, _gutterFg);
    canvas.drawParagraph(
      p.para,
      Offset(x + maxWidth - p.width, y + (_lineHeight - p.height) / 2),
    );
  }

  // Byte-proportional scrollbar (needs no total line count)
  void _paintScrollbar(Canvas canvas, Offset offset) {
    if (_totalBytes <= 0) return;
    const w = 8.0;
    final trackH = size.height;
    if (trackH <= 24.0) return; // viewport smaller than the min thumb

    // Marks first, so the thumb slides over them: bookmarks solid, find
    // matches dim. Byte-proportional, like the thumb itself.
    final x = offset.dx + size.width - w - 2;
    final scale = trackH / _totalBytes;
    for (final b in _bookmarks) {
      canvas.drawRect(
        Rect.fromLTWH(x, offset.dy + b * scale, w, 2),
        Paint()..color = _selColor,
      );
    }
    final markPaint = Paint()..color = _selColor.withValues(alpha: 0.55);
    for (final b in _searchMarks) {
      canvas.drawRect(
        Rect.fromLTWH(x, offset.dy + b * scale, w, 2),
        markPaint,
      );
    }

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
