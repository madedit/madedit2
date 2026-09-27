// Side-by-side file comparison pane (View → Compare Files…).
//
// The diff itself is computed off the UI isolate (diff.dart, Isolate.run);
// this widget only renders the aligned rows: one lazily-built ListView whose
// every row paints both sides (so the two halves can never scroll apart),
// a minimap of the difference blocks on the right (click / drag = jump), a
// header with the file names, counts and next/previous navigation, and a
// horizontal scroll for long lines (shift+wheel, or drag the bottom bar).
// Wheel and keys are handled here (the list itself never scrolls on its
// own) so shift+wheel can mean "horizontal" without also moving the list.

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'keybinding/chord_from_event.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../settings/app_settings.dart';
import 'diff.dart';
import 'editor_theme.dart';

class DiffView extends StatefulWidget {
  const DiffView({
    super.key,
    required this.leftPath,
    required this.rightPath,
    this.onOpenLine,
  });

  final String leftPath;
  final String rightPath;

  /// Double-click on a row: open that file at that (1-based) line.
  final void Function(String path, int line)? onOpenLine;

  @override
  State<DiffView> createState() => _DiffViewState();
}

// Row backdrops (translucent so they work on both dark and light themes).
const _delBg = Color(0x33E53935);
const _addBg = Color(0x3343A047);
const _chgBg = Color(0x2EFDD835);
const _fillBg = Color(0x14808080); // the empty side of an add/delete
const _delStrong = Color(0x66E53935);
const _addStrong = Color(0x6643A047);
const _chgStrong = Color(0x66FDD835);

/// A run of consecutive non-equal rows [start, end) and which kinds it holds
/// (bit 1 del, 2 add, 4 change) — the minimap's unit.
class _Run {
  const _Run(this.start, this.end, this.kinds);
  final int start, end, kinds;
}

class _DiffViewState extends State<DiffView> {
  DiffResult? _result;
  String? _error;
  bool _loading = true;
  List<_Run> _runs = const [];
  int _maxLineChars = 0;

  late String _left = widget.leftPath;
  late String _right = widget.rightPath;

  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  double _scrollX = 0;
  double _viewportH = 0;
  double _halfW = 0;
  int _hunk = -1; // index into hunkRows of the block last jumped to

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onSettings);
    _scroll.addListener(_onScrolled);
    _load();
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettings);
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSettings() {
    if (mounted) setState(() {});
  }

  void _onScrolled() {
    if (mounted) setState(() {}); // minimap viewport marker
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _hunk = -1;
    });
    try {
      final res = await _diffInIsolate(_left, _right);
      if (!mounted) return;
      var maxChars = 0;
      for (final s in [res.left, res.right]) {
        for (final line in s.lines) {
          if (line.length > maxChars) maxChars = line.length;
        }
      }
      setState(() {
        _result = res;
        _runs = _computeRuns(res.rows);
        _maxLineChars = maxChars > 20000 ? 20000 : maxChars;
        _loading = false;
      });
    } on DiffTooLarge catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _l10n.trf('diff_too_large', [
          e.path,
          (e.bytes / (1 << 20)).toStringAsFixed(1),
          diffMaxBytes >> 20,
        ]);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _l10n.trf('diff_failed', [e.toString()]);
        _loading = false;
      });
    }
  }

  static List<_Run> _computeRuns(List<DiffRow> rows) {
    final out = <_Run>[];
    var i = 0;
    while (i < rows.length) {
      if (rows[i].kind == DiffRow.equal) {
        i++;
        continue;
      }
      final start = i;
      var kinds = 0;
      while (i < rows.length && rows[i].kind != DiffRow.equal) {
        kinds |= switch (rows[i].kind) {
          DiffRow.del => 1,
          DiffRow.add => 2,
          _ => 4,
        };
        i++;
      }
      out.add(_Run(start, i, kinds));
    }
    return out;
  }

  double get _lineH => editorLineHeight;

  double get _contentW => _maxLineChars * editorCharWidth + editorCharWidth * 2;

  double get _maxScrollX {
    final m = _contentW - (_halfW - _gutterW);
    return m > 0 ? m : 0;
  }

  double get _gutterW {
    final r = _result;
    final lines = r == null
        ? 1
        : math.max(r.left.lines.length, r.right.lines.length);
    final digits = lines.toString().length;
    return (digits + 1) * editorCharWidth + 8;
  }

  void _setScrollX(double x) {
    final nx = x.clamp(0.0, _maxScrollX);
    if (nx != _scrollX) setState(() => _scrollX = nx);
  }

  void _scrollBy(double dy) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _scroll.jumpTo((p.pixels + dy).clamp(0.0, p.maxScrollExtent));
  }

  void _jumpToRow(int row, {bool center = true}) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final target = row * _lineH - (center ? _viewportH / 3 : 0);
    _scroll.jumpTo(target.clamp(0.0, p.maxScrollExtent));
  }

  void _gotoHunk(int i) {
    final r = _result;
    if (r == null || r.hunkRows.isEmpty) return;
    final n = r.hunkRows.length;
    final idx = ((i % n) + n) % n;
    setState(() => _hunk = idx);
    _jumpToRow(r.hunkRows[idx]);
  }

  // The block containing (or the next after) the top visible row, so
  // "next" from an arbitrary scroll position feels right.
  int _hunkFromScroll(int dir) {
    final r = _result!;
    if (_hunk >= 0) return _hunk + dir;
    final top = _scroll.hasClients ? (_scroll.offset / _lineH).floor() : 0;
    var i = 0;
    while (i < r.hunkRows.length && r.hunkRows[i] < top) {
      i++;
    }
    return dir > 0 ? i : i - 1;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final shift = Mods.shift;
    final page = math.max(_viewportH - _lineH, _lineH);
    if (k == LogicalKeyboardKey.arrowDown) {
      _scrollBy(_lineH);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _scrollBy(-_lineH);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _scrollBy(page);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _scrollBy(-page);
    } else if (k == LogicalKeyboardKey.home) {
      _scrollBy(-1e12);
    } else if (k == LogicalKeyboardKey.end) {
      _scrollBy(1e12);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _setScrollX(_scrollX - editorCharWidth * 8);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _setScrollX(_scrollX + editorCharWidth * 8);
    } else if (k == LogicalKeyboardKey.f8 || k == LogicalKeyboardKey.f7) {
      if (_result != null) _gotoHunk(_hunkFromScroll(shift ? -1 : 1));
    } else if (k == LogicalKeyboardKey.f5) {
      _load();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _onWheel(PointerSignalEvent sig) {
    if (sig is! PointerScrollEvent) return;
    final shift = Mods.shift;
    final dx = sig.scrollDelta.dx + (shift ? sig.scrollDelta.dy : 0);
    if (dx != 0) _setScrollX(_scrollX + dx);
    final dy = shift ? 0.0 : sig.scrollDelta.dy;
    if (dy != 0) _scrollBy(dy);
  }

  void _swap() {
    final t = _left;
    _left = _right;
    _right = t;
    _load();
  }

  String _name(String p) =>
      p.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final r = _result;
    final dim = editorGutterFg;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) => _focus.requestFocus(),
        child: Material(
          color: editorBg,
          child: Column(
            children: [
              // ── header ──
              Container(
                color: editorGutterBg,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: _left,
                        child: Text(
                          _name(_left),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: editorFg, fontSize: 12.5),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Tooltip(
                        message: _right,
                        child: Text(
                          _name(_right),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: editorFg, fontSize: 12.5),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (r != null)
                      Text(
                        r.identical
                            ? l10n.tr('diff_identical')
                            : '${r.hunkRows.length}  '
                                  '+${r.added}  −${r.deleted}  ~${r.changed}'
                                  '${r.coarse ? '  ${l10n.tr('diff_coarse')}' : ''}',
                        style: TextStyle(color: dim, fontSize: 12),
                      ),
                    if (r != null && r.hunkRows.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Text(
                        _hunk < 0 ? '' : '${_hunk + 1}/${r.hunkRows.length}',
                        style: TextStyle(color: dim, fontSize: 12),
                      ),
                    ],
                    IconButton(
                      tooltip: l10n.tr('diff_prev'),
                      onPressed: r == null || r.identical
                          ? null
                          : () => _gotoHunk(_hunkFromScroll(-1)),
                      icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                    ),
                    IconButton(
                      tooltip: l10n.tr('diff_next'),
                      onPressed: r == null || r.identical
                          ? null
                          : () => _gotoHunk(_hunkFromScroll(1)),
                      icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                    ),
                    IconButton(
                      tooltip: l10n.tr('diff_swap'),
                      onPressed: _loading ? null : _swap,
                      icon: const Icon(Icons.swap_horiz, size: 18),
                    ),
                    IconButton(
                      tooltip: l10n.tr('diff_refresh'),
                      onPressed: _loading ? null : _load,
                      icon: const Icon(Icons.refresh, size: 18),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // ── body ──
              Expanded(child: _body(context)),
              // ── horizontal scroll bar ──
              if (r != null && _maxScrollX > 0)
                SizedBox(
                  height: 10,
                  child: LayoutBuilder(
                    builder: (_, c) {
                      final track = c.maxWidth;
                      final visible = _halfW - _gutterW;
                      final thumb = (track * visible / _contentW).clamp(
                        24.0,
                        track,
                      );
                      final x = (track - thumb) * (_scrollX / _maxScrollX);
                      return GestureDetector(
                        onHorizontalDragUpdate: (d) => _setScrollX(
                          _scrollX +
                              d.delta.dx *
                                  (_maxScrollX / math.max(1, track - thumb)),
                        ),
                        child: CustomPaint(
                          painter: _BarPainter(x, thumb, dim),
                          size: Size(track, 10),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 200, child: LinearProgressIndicator()),
            const SizedBox(height: 8),
            Text(
              _l10n.tr('diff_loading'),
              style: TextStyle(color: editorGutterFg),
            ),
          ],
        ),
      );
    }
    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(err, style: TextStyle(color: editorFg)),
        ),
      );
    }
    final r = _result!;
    final settings = AppSettings.instance;
    return LayoutBuilder(
      builder: (_, c) {
        const mapW = 14.0;
        _viewportH = c.maxHeight;
        _halfW = (c.maxWidth - mapW - 1) / 2;
        final rowW = c.maxWidth - mapW;
        return Row(
          children: [
            Expanded(
              child: Listener(
                onPointerSignal: _onWheel,
                child: ListView.builder(
                  controller: _scroll,
                  physics: const NeverScrollableScrollPhysics(),
                  itemExtent: _lineH,
                  itemCount: r.rows.length,
                  itemBuilder: (_, i) {
                    final row = r.rows[i];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTapDown: (d) {
                        final open = widget.onOpenLine;
                        if (open == null) return;
                        final leftSide = d.localPosition.dx < _halfW;
                        final li = leftSide ? row.ia : row.ib;
                        if (li >= 0) {
                          open(leftSide ? _left : _right, li + 1);
                        }
                      },
                      child: RepaintBoundary(
                        child: CustomPaint(
                          size: Size(rowW, _lineH),
                          painter: _RowPainter(
                            row: row,
                            result: r,
                            halfW: _halfW,
                            gutterW: _gutterW,
                            scrollX: _scrollX,
                            tabSize: settings.tabSize,
                            fontFamily: editorMonoFont,
                            fontSize: editorFontSize,
                            lineH: _lineH,
                            fg: editorFg,
                            bg: editorBg,
                            gutterBg: editorGutterBg,
                            gutterFg: editorGutterFg,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            SizedBox(
              width: mapW,
              child: GestureDetector(
                onTapDown: (d) => _mapJump(d.localPosition.dy, c.maxHeight),
                onVerticalDragUpdate: (d) =>
                    _mapJump(d.localPosition.dy, c.maxHeight),
                child: CustomPaint(
                  painter: _MapPainter(
                    runs: _runs,
                    rows: r.rows.length,
                    viewTop: _scroll.hasClients ? _scroll.offset / _lineH : 0,
                    viewRows: _viewportH / _lineH,
                    bg: editorGutterBg,
                    fg: editorGutterFg,
                  ),
                  size: Size(mapW, c.maxHeight),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _mapJump(double y, double h) {
    final r = _result;
    if (r == null || h <= 0) return;
    final row = (y / h * r.rows.length).round();
    _jumpToRow(row);
  }
}

// Top-level on purpose: a closure created inside a State method shares that
// method's context object, which (through `this`, setState callbacks and
// the widget tree) reaches Timers and other unsendable objects — and
// Isolate.run refuses the whole graph. Here the closure captures only the
// two paths.
Future<DiffResult> _diffInIsolate(String left, String right) =>
    Isolate.run(() => computeFileDiff(left, right));

/// Expand tabs to the next tab stop (the diff rows are plain text painting,
/// so tabs must become spaces to line up).
String _expandTabs(String s, int tabSize) {
  if (!s.contains('\t')) return s;
  final sb = StringBuffer();
  var col = 0;
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u == 0x09) {
      final n = tabSize - col % tabSize;
      sb.write(' ' * n);
      col += n;
    } else {
      sb.writeCharCode(u);
      col++;
    }
  }
  return sb.toString();
}

class _RowPainter extends CustomPainter {
  _RowPainter({
    required this.row,
    required this.result,
    required this.halfW,
    required this.gutterW,
    required this.scrollX,
    required this.tabSize,
    required this.fontFamily,
    required this.fontSize,
    required this.lineH,
    required this.fg,
    required this.bg,
    required this.gutterBg,
    required this.gutterFg,
  });

  final DiffRow row;
  final DiffResult result;
  final double halfW, gutterW, scrollX, fontSize, lineH;
  final int tabSize;
  final String fontFamily;
  final Color fg, bg, gutterBg, gutterFg;

  static const int _maxPaintChars = 10000;

  @override
  void paint(Canvas canvas, Size size) {
    final leftText = row.ia < 0 ? null : result.left.lines[row.ia];
    final rightText = row.ib < 0 ? null : result.right.lines[row.ib];
    String? el = leftText == null ? null : _expandTabs(leftText, tabSize);
    String? er = rightText == null ? null : _expandTabs(rightText, tabSize);
    if (el != null && el.length > _maxPaintChars) {
      el = el.substring(0, _maxPaintChars);
    }
    if (er != null && er.length > _maxPaintChars) {
      er = er.substring(0, _maxPaintChars);
    }
    (int, int, int, int)? span;
    if (row.kind == DiffRow.change && el != null && er != null) {
      span = changedSpan(el, er);
    }
    _side(canvas, 0, row.ia, el, row.kind, true, span);
    canvas.drawRect(
      Rect.fromLTWH(halfW, 0, 1, size.height),
      Paint()..color = gutterFg.withValues(alpha: 0.5),
    );
    _side(canvas, halfW + 1, row.ib, er, row.kind, false, span);
  }

  void _side(
    Canvas canvas,
    double x0,
    int lineIndex,
    String? text,
    int kind,
    bool left,
    (int, int, int, int)? span,
  ) {
    final Color rowBg;
    Color? strong;
    switch (kind) {
      case DiffRow.del:
        rowBg = left ? _delBg : _fillBg;
      case DiffRow.add:
        rowBg = left ? _fillBg : _addBg;
      case DiffRow.change:
        rowBg = _chgBg;
        strong = _chgStrong;
      default:
        rowBg = bg;
    }
    // Gutter + line number.
    canvas.drawRect(
      Rect.fromLTWH(x0, 0, gutterW, lineH),
      Paint()..color = gutterBg,
    );
    if (lineIndex >= 0) {
      final tp = TextPainter(
        text: TextSpan(
          text: '${lineIndex + 1}',
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            color: gutterFg,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(x0 + gutterW - 4 - tp.width, (lineH - tp.height) / 2),
      );
    }
    // Content.
    final cx = x0 + gutterW;
    final cw = halfW - gutterW;
    canvas.drawRect(Rect.fromLTWH(cx, 0, cw, lineH), Paint()..color = rowBg);
    if (text == null) {
      // Empty side of an add/delete: a faint hatch so it reads as "no line".
      final p = Paint()
        ..color = gutterFg.withValues(alpha: 0.15)
        ..strokeWidth = 1;
      for (var x = cx - lineH; x < cx + cw; x += 8) {
        canvas.drawLine(Offset(x, lineH), Offset(x + lineH, 0), p);
      }
      return;
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(cx, 0, cw, lineH));
    canvas.translate(cx + 4 - scrollX, 0);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: fontFamily, fontSize: fontSize, color: fg),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    if (span != null && strong != null) {
      final (s, e) = left ? (span.$1, span.$2) : (span.$3, span.$4);
      if (e > s) {
        for (final b in tp.getBoxesForSelection(
          TextSelection(baseOffset: s, extentOffset: e),
        )) {
          canvas.drawRect(
            Rect.fromLTWH(b.left, 0, b.right - b.left, lineH),
            Paint()..color = strong,
          );
        }
      } else if (kind == DiffRow.change) {
        // Whole-line difference that a prefix/suffix scan cannot localize
        // (e.g. pure whitespace change): mark the line edge.
        canvas.drawRect(
          Rect.fromLTWH(-4, 0, 3, lineH),
          Paint()..color = strong,
        );
      }
    } else if (kind == DiffRow.del || kind == DiffRow.add) {
      canvas.drawRect(
        Rect.fromLTWH(-4, 0, 3, lineH),
        Paint()..color = kind == DiffRow.del ? _delStrong : _addStrong,
      );
    }
    tp.paint(canvas, Offset(0, (lineH - tp.height) / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RowPainter old) =>
      old.row != row ||
      old.result != result ||
      old.halfW != halfW ||
      old.gutterW != gutterW ||
      old.scrollX != scrollX ||
      old.tabSize != tabSize ||
      old.fontFamily != fontFamily ||
      old.fontSize != fontSize ||
      old.lineH != lineH ||
      old.fg != fg ||
      old.bg != bg ||
      old.gutterBg != gutterBg ||
      old.gutterFg != gutterFg;
}

class _MapPainter extends CustomPainter {
  const _MapPainter({
    required this.runs,
    required this.rows,
    required this.viewTop,
    required this.viewRows,
    required this.bg,
    required this.fg,
  });
  final List<_Run> runs;
  final int rows;
  final double viewTop, viewRows;
  final Color bg, fg;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    if (rows == 0) return;
    final scale = size.height / rows;
    for (final r in runs) {
      final y = r.start * scale;
      final h = math.max(2.0, (r.end - r.start) * scale);
      final color = switch (r.kinds) {
        1 => _delStrong,
        2 => _addStrong,
        _ => _chgStrong,
      };
      canvas.drawRect(
        Rect.fromLTWH(2, y, size.width - 4, h),
        Paint()..color = color.withValues(alpha: 1),
      );
    }
    // Viewport marker.
    final vy = viewTop * scale;
    final vh = math.max(4.0, viewRows * scale);
    canvas.drawRect(
      Rect.fromLTWH(0, vy, size.width, vh),
      Paint()..color = fg.withValues(alpha: 0.18),
    );
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.runs != runs ||
      old.rows != rows ||
      old.viewTop != viewTop ||
      old.viewRows != viewRows ||
      old.bg != bg ||
      old.fg != fg;
}

class _BarPainter extends CustomPainter {
  const _BarPainter(this.x, this.w, this.color);
  final double x, w;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 2, w, size.height - 4),
        const Radius.circular(3),
      ),
      Paint()..color = color.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.x != x || old.w != w || old.color != color;
}
