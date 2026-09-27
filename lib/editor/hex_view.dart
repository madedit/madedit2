// Hex view: renders a byte window as the classic three-column layout
//
//   00000000  48 65 6c 6c 6f 20 77 6f  72 6c 64 0a 41 42 43 44  |Hello world.ABCD|
//   └ offset ┘└──────────────── hex ────────────────────────┘  └──── ascii ────┘
//
// Every row is exactly [hexBytesPerRow] bytes, so a row's offset is `base + row * 16` — the
// byte-anchor model needs no line scanning at all here, which is why hex works on GB files with no
// index. The row is drawn as ONE monospace paragraph with colored runs, so a byte's on-screen x is
// just "column × char width" — the same formula the hit-test uses in reverse.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'editor_theme.dart';

/// Bytes per row (fixed, like every other hex editor).
const int hexBytesPerRow = 16;

const int _offsetDigits = 8; // 32-bit style offset column; widened for big files
const String _gapAfterOffset = '  ';
const String _gapBeforeAscii = ' ';

/// Column (in characters) where the offset of a row ends, given the digit count in use.
int _hexAreaStart(int offsetDigits) => offsetDigits + _gapAfterOffset.length;

/// Character column of the high nibble of byte [i] within a row.
int hexCharCol(int i, int offsetDigits) =>
    _hexAreaStart(offsetDigits) + i * 3 + (i >= hexBytesPerRow ~/ 2 ? 1 : 0);

/// Width (in characters) of the whole hex area, including the trailing gap.
int _hexAreaWidth() => hexBytesPerRow * 3 + 1;

/// Character column of byte [i] in the ascii area.
int asciiCharCol(int i, int offsetDigits) =>
    _hexAreaStart(offsetDigits) +
    _hexAreaWidth() +
    _gapBeforeAscii.length +
    1 + // the opening '|'
    i;

/// How many hex digits the offset column needs for a document of [length] bytes.
int hexOffsetDigits(int length) {
  var digits = _offsetDigits;
  var max = length;
  var need = 1;
  while (max >= 16) {
    max >>= 4;
    need++;
  }
  if (need > digits) digits = need;
  return digits;
}

/// Total width (characters) of a full row, used to size the horizontal extent.
int hexRowChars(int offsetDigits) =>
    asciiCharCol(hexBytesPerRow, offsetDigits) + 1;

String _hex(int v, int digits) =>
    v.toRadixString(16).toUpperCase().padLeft(digits, '0');

/// Printable ascii, everything else as '.' (same convention as `xxd`).
String _asciiOf(int b) => (b >= 0x20 && b < 0x7F) ? String.fromCharCode(b) : '.';

/// The three column texts of one row, laid out so that byte [i] sits exactly at [hexCharCol]/
/// [asciiCharCol] — the caret, selection and hit-test all rely on that, so it is built here (and
/// checked by test/hex_view_test.dart) rather than inline in paint().
///
/// [count] < [hexBytesPerRow] (the last row) pads with blanks so the ascii column stays aligned.
///
/// [blankText] leaves the text column as blanks (borders only): used when the
/// caller paints codec-decoded characters cell by cell instead (a paragraph
/// would let wide CJK glyphs push the following cells out of the grid).
({String offset, String hex, String ascii}) hexRowTexts(
  Uint8List bytes,
  int rowStart,
  int count,
  int rowOffset,
  int digits, {
  bool blankText = false,
}) {
  final hex = StringBuffer();
  final ascii = StringBuffer();
  for (var i = 0; i < hexBytesPerRow; i++) {
    if (i == hexBytesPerRow ~/ 2) hex.write(' ');
    if (i < count) {
      hex.write('${_hex(bytes[rowStart + i], 2)} ');
      ascii.write(blankText ? ' ' : _asciiOf(bytes[rowStart + i]));
    } else {
      hex.write('   ');
      ascii.write(' ');
    }
  }
  return (
    offset: '${_hex(rowOffset, digits)}$_gapAfterOffset',
    hex: hex.toString(),
    ascii: '$_gapBeforeAscii|${ascii.toString()}|',
  );
}

/// One row as the single string the columns are measured against.
String hexRowLine(
  Uint8List bytes,
  int rowStart,
  int count,
  int rowOffset,
  int digits,
) {
  final t = hexRowTexts(bytes, rowStart, count, rowOffset, digits);
  return '${t.offset}${t.hex}${t.ascii}';
}

/// Caret position in the hex column counted in **nibbles**: `offset * 2 + nibble`.
/// Left/right move by one of these, so the caret steps high nibble → low nibble → next byte.
/// Returns the position clamped into a document of [length] bytes (empty document → 0).
///
/// [allowEnd] (insert mode) lets the caret sit one past the last byte, so bytes can be appended
/// at the end of the file; in overwrite mode there is nothing to overwrite there.
int hexClampNibblePos(int pos, int length, {bool allowEnd = false}) {
  if (length <= 0) return 0;
  final max = allowEnd ? length * 2 : length * 2 - 1;
  return pos < 0 ? 0 : (pos > max ? max : pos);
}

/// Where a click landed in the hex view.
enum HexArea { offset, hex, ascii }

/// Result of hit-testing a point: which byte, in which area, and (for the hex area) which nibble.
class HexHit {
  const HexHit(this.offset, this.area, this.nibble);
  final int offset; // document byte offset
  final HexArea area;
  final int nibble; // 0 = high, 1 = low (hex area only)
}

/// Self-drawn hex viewport: paints only the byte window it is given.
class HexViewport extends LeafRenderObjectWidget {
  const HexViewport({
    super.key,
    required this.bytes,
    required this.base,
    required this.docLength,
    required this.caretOffset,
    required this.caretNibble,
    required this.activeArea,
    required this.insertMode,
    required this.caretOn,
    this.caretFocused = true,
    required this.selStart,
    required this.selEnd,
    required this.scrollX,
    required this.settingsEpoch,
    this.textCells,
    this.composing = '',
  });

  /// The visible bytes, starting at [base] (a multiple of [hexBytesPerRow]).
  final Uint8List bytes;

  /// Codec-decoded text column, one cell per byte of [bytes] (see
  /// hex_cells.dart). Null = plain ASCII rendering.
  final List<String>? textCells;

  /// IME text being composed in the text column (drawn at the caret cell,
  /// not yet in the document).
  final String composing;

  final int base;
  final int docLength;
  final int caretOffset; // -1 = no caret
  final int caretNibble;

  /// Which column input currently goes to (that column's caret is drawn more prominently).
  final HexArea activeArea;

  /// Insert mode: the caret is a thin bar between bytes (overwrite mode draws
  /// a block covering the whole nibble instead).
  final bool insertMode;
  final bool caretOn;
  /// False while the editor lacks keyboard focus or the window is inactive:
  /// the caret is drawn steady and dimmed (see TextViewport.caretFocused).
  final bool caretFocused;
  final int selStart; // selStart == selEnd -> no selection
  final int selEnd;
  final double scrollX;
  final int settingsEpoch;

  @override
  RenderHexViewport createRenderObject(BuildContext context) =>
      RenderHexViewport(
        bytes: bytes,
        base: base,
        docLength: docLength,
        caretOffset: caretOffset,
        caretNibble: caretNibble,
        activeArea: activeArea,
        insertMode: insertMode,
        caretOn: caretOn,
        caretFocused: caretFocused,
        selStart: selStart,
        selEnd: selEnd,
        scrollX: scrollX,
        settingsEpoch: settingsEpoch,
        textCells: textCells,
        composing: composing,
      );

  @override
  void updateRenderObject(BuildContext context, RenderHexViewport renderObject) {
    renderObject
      ..bytes = bytes
      ..base = base
      ..docLength = docLength
      ..caretOffset = caretOffset
      ..caretNibble = caretNibble
      ..activeArea = activeArea
      ..insertMode = insertMode
      ..caretOn = caretOn
      ..caretFocused = caretFocused
      ..selStart = selStart
      ..selEnd = selEnd
      ..scrollX = scrollX
      ..settingsEpoch = settingsEpoch
      ..textCells = textCells
      ..composing = composing;
  }
}

class RenderHexViewport extends RenderBox {
  RenderHexViewport({
    required this._bytes,
    required this._base,
    required this._docLength,
    required this._caretOffset,
    required this._caretNibble,
    required this._activeArea,
    required this._insertMode,
    required this._caretOn,
    bool caretFocused = true,
    required this._selStart,
    required this._selEnd,
    required this._scrollX,
    required this._settingsEpoch,
    List<String>? textCells,
    String composing = '',
  }) : _caretFocused = caretFocused, // ignore: prefer_initializing_formals
       _textCells = textCells, // ignore: prefer_initializing_formals
       _composing = composing; // ignore: prefer_initializing_formals

  String _composing;
  set composing(String v) {
    if (v == _composing) return;
    _composing = v;
    markNeedsPaint();
  }

  Uint8List _bytes;
  set bytes(Uint8List v) {
    if (identical(v, _bytes)) return;
    _bytes = v;
    markNeedsPaint();
  }

  List<String>? _textCells;
  set textCells(List<String>? v) {
    if (identical(v, _textCells)) return;
    _textCells = v;
    markNeedsPaint();
  }

  int _base;
  set base(int v) {
    if (v == _base) return;
    _base = v;
    markNeedsPaint();
  }

  int _docLength;
  set docLength(int v) {
    if (v == _docLength) return;
    _docLength = v;
    markNeedsPaint();
  }

  int _caretOffset;
  set caretOffset(int v) {
    if (v == _caretOffset) return;
    _caretOffset = v;
    markNeedsPaint();
  }

  int _caretNibble;
  set caretNibble(int v) {
    if (v == _caretNibble) return;
    _caretNibble = v;
    markNeedsPaint();
  }

  HexArea _activeArea;
  set activeArea(HexArea v) {
    if (v == _activeArea) return;
    _activeArea = v;
    markNeedsPaint();
  }

  bool _insertMode;
  set insertMode(bool v) {
    if (v == _insertMode) return;
    _insertMode = v;
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

  // Caret alpha multiplier: dimmed while unfocused (drawn steady then).
  double get _dim => _caretFocused ? 1 : 0.45;

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

  double _scrollX;
  set scrollX(double v) {
    if (v == _scrollX) return;
    _scrollX = v;
    markNeedsPaint();
  }

  // Font/colors are read from the settings at paint time, so this is what says "they changed".
  int _settingsEpoch;
  set settingsEpoch(int v) {
    if (v == _settingsEpoch) return;
    _settingsEpoch = v;
    markNeedsPaint();
  }

  int get _offsetDigitsInUse => hexOffsetDigits(_docLength);

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  /// Total content width in pixels (for the horizontal scrollbar).
  double get contentWidth =>
      hexRowChars(_offsetDigitsInUse) * editorCharWidth + _gutterPad * 2;

  static const double _gutterPad = 10;

  /// Map a local point to a byte (used by the widget layer for click positioning).
  /// [allowEnd]: the position after the last byte is a valid hit (insert
  /// mode, or extending a selection so the last byte can be included).
  HexHit? hitTest2(Offset local, {bool allowEnd = false}) {
    final rowH = editorLineHeight;
    final row = (local.dy / rowH).floor();
    if (row < 0) return null;
    final cw = editorCharWidth;
    final col = ((local.dx + _scrollX - _gutterPad) / cw).floor();
    final digits = _offsetDigitsInUse;
    final rowBase = _base + row * hexBytesPerRow;

    // ascii area?
    final aStart = asciiCharCol(0, digits);
    if (col >= aStart) {
      final i = (col - aStart).clamp(0, hexBytesPerRow - 1);
      return HexHit(_clampOffset(rowBase + i, allowEnd), HexArea.ascii, 0);
    }
    // hex area?
    final hStart = hexCharCol(0, digits);
    if (col >= hStart) {
      for (var i = hexBytesPerRow - 1; i >= 0; i--) {
        final c = hexCharCol(i, digits);
        if (col >= c) {
          return HexHit(
            _clampOffset(rowBase + i, allowEnd),
            HexArea.hex,
            col > c ? 1 : 0,
          );
        }
      }
    }
    return HexHit(_clampOffset(rowBase, allowEnd), HexArea.offset, 0);
  }

  int _clampOffset(int o, bool allowEnd) {
    final max = allowEnd ? _docLength : (_docLength > 0 ? _docLength - 1 : 0);
    return o < 0 ? 0 : (o > max ? max : o);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.drawRect(offset & size, Paint()..color = editorBg);

    final rowH = editorLineHeight;
    final digits = _offsetDigitsInUse;
    final rows = (size.height / rowH).ceil() + 1;
    final selLo = _selStart < _selEnd ? _selStart : _selEnd;
    final selHi = _selStart < _selEnd ? _selEnd : _selStart;

    canvas.save();
    canvas.clipRect(offset & size);
    canvas.translate(offset.dx - _scrollX + _gutterPad, offset.dy);

    // One more (empty) row is painted past the end of the file: in insert
    // mode the caret may sit after the last byte (= append at EOF).
    final tailRowStart = _bytes.length - _bytes.length % hexBytesPerRow;
    final wantTailRow =
        _caretOffset >= _base + _bytes.length &&
        _base + _bytes.length == _docLength;

    for (var r = 0; r < rows; r++) {
      final rowStart = r * hexBytesPerRow;
      final n = (_bytes.length - rowStart).clamp(0, hexBytesPerRow);
      if (n <= 0 && !(wantTailRow && rowStart == tailRowStart)) break;
      final y = r * rowH;
      final rowOffset = _base + rowStart;

      // Current-byte backdrop: the caret byte's hex pair and its text-column
      // cell, blink-independent, beneath the selection and the caret box.
      // (The insert-mode append position past the last byte has no cell.)
      if (_caretOffset >= rowOffset && _caretOffset < rowOffset + n) {
        final i = _caretOffset - rowOffset;
        _fillCols(
            canvas, hexCharCol(i, digits), 2, y, rowH, editorCurrentLineColor);
        _fillCols(canvas, asciiCharCol(i, digits), 1, y, rowH,
            editorCurrentLineColor);
      }

      // Selection / caret highlights sit behind the text.
      for (var i = 0; i < n; i++) {
        final off = rowOffset + i;
        if (off >= selLo && off < selHi) {
          _fillCols(canvas, hexCharCol(i, digits), 2, y, rowH, editorSelColor);
          _fillCols(canvas, asciiCharCol(i, digits), 1, y, rowH, editorSelColor);
        }
      }
      final caretInRow =
          _caretOffset >= rowOffset &&
          (_caretOffset < rowOffset + n ||
              (wantTailRow && _caretOffset == rowOffset + n));
      if (_caretOn && caretInRow) {
        final i = _caretOffset - rowOffset;
        // Hex side: box the nibble being edited; ascii side: box the whole byte.
        final hexActive = _activeArea != HexArea.ascii;
        if (_insertMode) {
          // Insert mode: a thin bar at the insertion point rather than a block covering a nibble.
          _caretBar(
            canvas,
            hexCharCol(i, digits) + _caretNibble,
            y,
            rowH,
            editorCaretColor.withValues(alpha: (hexActive ? 1 : 0.4) * _dim),
          );
          _caretBar(
            canvas,
            asciiCharCol(i, digits),
            y,
            rowH,
            editorCaretColor.withValues(alpha: (hexActive ? 0.4 : 1) * _dim),
          );
        } else {
          _fillCols(
            canvas,
            hexCharCol(i, digits) + _caretNibble,
            1,
            y,
            rowH,
            editorCaretColor.withValues(
              alpha: (hexActive ? 0.55 : 0.2) * _dim,
            ),
          );
          _fillCols(
            canvas,
            asciiCharCol(i, digits),
            1,
            y,
            rowH,
            editorCaretColor.withValues(
              alpha: (hexActive ? 0.2 : 0.55) * _dim,
            ),
          );
        }
      }

      // The row as a single paragraph: offset | hex | ascii, each its own color run.
      final cells = _textCells;
      final t = hexRowTexts(_bytes, rowStart, n, rowOffset, digits,
          blankText: cells != null);
      final para = buildMonoParagraph([
        (t.offset, editorGutterFg),
        (t.hex, editorFg),
        (t.ascii, editorGutterFg),
      ]);
      canvas.drawParagraph(para, Offset(0, y + (rowH - para.height) / 2));

      // IME composition in the text column: drawn over the caret cell (and
      // whatever follows) with an underline, like the text view's overlay.
      if (_composing.isNotEmpty && _activeArea == HexArea.ascii && caretInRow) {
        final i = _caretOffset - rowOffset;
        final x = asciiCharCol(i, digits) * editorCharWidth;
        final cp = buildMonoParagraph([(_composing, editorFg)]);
        canvas.drawRect(
          Rect.fromLTWH(x, y, cp.longestLine, rowH),
          Paint()..color = editorBg,
        );
        canvas.drawParagraph(cp, Offset(x, y + (rowH - cp.height) / 2));
        canvas.drawRect(
          Rect.fromLTWH(x, y + rowH - 2, cp.longestLine, 1.5),
          Paint()..color = editorFg,
        );
      }

      // Codec-decoded text column: one glyph per character, positioned at its
      // first byte's cell so wide glyphs can't push later cells out of grid.
      if (cells != null) {
        for (var i = 0; i < n; i++) {
          final s = rowStart + i < cells.length ? cells[rowStart + i] : '';
          if (s.isEmpty) continue;
          final cp = _cellParagraph(s);
          canvas.drawParagraph(
            cp,
            Offset(asciiCharCol(i, digits) * editorCharWidth,
                y + (rowH - cp.height) / 2),
          );
        }
      }
    }
    canvas.restore();
    _paintScrollbar(canvas, offset);
  }

  // Per-character paragraph cache for the decoded text column (a window
  // repaints on every caret blink; ~500 tiny layouts per frame would hurt).
  final Map<String, ui.Paragraph> _cellCache = {};
  int _cellCacheEpoch = -1;

  ui.Paragraph _cellParagraph(String s) {
    if (_cellCacheEpoch != _settingsEpoch) {
      _cellCache.clear();
      _cellCacheEpoch = _settingsEpoch;
    }
    return _cellCache[s] ??= buildMonoParagraph([(s, editorGutterFg)]);
  }

  // Right-hand byte-proportional scrollbar (same look as text mode).
  void _paintScrollbar(ui.Canvas canvas, Offset offset) {
    if (_docLength <= 0) return;
    const w = 8.0;
    final trackH = size.height;
    if (trackH <= 24.0) return; // viewport smaller than the min thumb
    final viewBytes = (size.height / editorLineHeight) * hexBytesPerRow;
    final thumbH = (viewBytes / _docLength * trackH).clamp(24.0, trackH);
    final t = (_base / _docLength).clamp(0.0, 1.0).toDouble();
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          offset.dx + size.width - w - 2,
          offset.dy + t * (trackH - thumbH),
          w,
          thumbH,
        ),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0x66AAAAAA),
    );
  }

  // A thin vertical caret at the left edge of character column [col] (insert mode).
  void _caretBar(ui.Canvas canvas, int col, double y, double rowH, Color color) {
    canvas.drawRect(
      Rect.fromLTWH(col * editorCharWidth - 1, y + 1, 2, rowH - 2),
      Paint()..color = color,
    );
  }

  // Fill [count] character cells starting at character column [col].
  void _fillCols(
    ui.Canvas canvas,
    int col,
    int count,
    double y,
    double rowH,
    Color color,
  ) {
    final cw = editorCharWidth;
    canvas.drawRect(
      Rect.fromLTWH(col * cw, y, cw * count, rowH),
      Paint()..color = color,
    );
  }
}
