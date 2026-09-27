// Three-way merge pane (View → Three-Way Merge…).
//
// Top: left | base | right, aligned by merge chunk (one ListView paints all
// three columns per row, so they can never scroll apart). Bottom: the merged
// result, recomputed from the conflict choices. Conflicts are resolved with
// the header buttons (or keys 1 left / 2 base / 3 right / 4 left+right /
// 5 right+left / 0 unresolve) for the current conflict; F8 / Shift+F8 walk
// the conflicts, F5 reloads. "Save" writes the result with the left file's
// encoding and newline style; unresolved conflicts are written with git
// markers after a confirmation.

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
import 'merge3.dart';

class MergeView extends StatefulWidget {
  const MergeView({
    super.key,
    required this.basePath,
    required this.leftPath,
    required this.rightPath,
    this.onSave,
    this.onOpenLine,
  });

  final String basePath, leftPath, rightPath;

  /// Save the merged text: pick a location, write, open it. Returns the path
  /// written (null = cancelled).
  final Future<String?> Function(
    String text,
    String codecName,
    String suggestedName,
  )?
  onSave;

  /// Double-click on a row: open that file at that (1-based) line.
  final void Function(String path, int line)? onOpenLine;

  @override
  State<MergeView> createState() => _MergeViewState();
}

const _leftBg = Color(0x2E1E88E5);
const _rightBg = Color(0x2E8E24AA);
const _bothBg = Color(0x2E43A047);
const _conflictBg = Color(0x33E53935);
const _resolvedBg = Color(0x2EFDD835);
const _fillBg = Color(0x14808080);
const _conflictStrong = Color(0xAAE53935);
const _markerFg = Color(0xFFE53935);

class _MergeViewState extends State<MergeView> {
  MergeData? _data;
  List<MergeChoice> _choices = const [];
  List<MergeOutLine> _out = const [];
  String? _error;
  bool _loading = true;
  int _maxLineChars = 0;
  int _conflict = -1; // index into result.conflicts
  double _split = 0.6; // top pane share of the height

  final ScrollController _top = ScrollController();
  final ScrollController _bottom = ScrollController();
  final FocusNode _focus = FocusNode();
  double _scrollX = 0;
  double _topH = 0, _bottomH = 0;
  double _colW = 0;

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onSettings);
    _load();
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettings);
    _top.dispose();
    _bottom.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSettings() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _data = null;
      _conflict = -1;
    });
    try {
      final d = await _mergeInIsolate(
        widget.basePath,
        widget.leftPath,
        widget.rightPath,
      );
      if (!mounted) return;
      var maxChars = 0;
      for (final s in [d.base, d.left, d.right]) {
        for (final line in s.lines) {
          if (line.length > maxChars) maxChars = line.length;
        }
      }
      setState(() {
        _data = d;
        _choices = List.filled(
          d.result.conflicts.length,
          MergeChoice.unresolved,
        );
        _maxLineChars = maxChars > 20000 ? 20000 : maxChars;
        _loading = false;
        _conflict = d.result.conflicts.isEmpty ? -1 : 0;
      });
      _rebuildOutput();
      if (_conflict >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _gotoConflict(0));
      }
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

  void _rebuildOutput() {
    final d = _data;
    if (d == null) return;
    setState(() {
      _out = mergeOutput(
        d.result,
        d.base.lines,
        d.left.lines,
        d.right.lines,
        _choices,
        leftLabel: _name(widget.leftPath),
        baseLabel: _name(widget.basePath),
        rightLabel: _name(widget.rightPath),
      );
    });
  }

  int get _unresolved =>
      _choices.where((c) => c == MergeChoice.unresolved).length;

  double get _lineH => editorLineHeight;
  double get _contentW => _maxLineChars * editorCharWidth + editorCharWidth * 2;
  double get _maxScrollX {
    final m = _contentW - (_colW - _gutterW);
    return m > 0 ? m : 0;
  }

  double get _gutterW {
    final d = _data;
    final lines = d == null
        ? 1
        : math.max(
            d.base.lines.length,
            math.max(d.left.lines.length, d.right.lines.length),
          );
    final digits = math.max(lines, _out.length).toString().length;
    return (digits + 1) * editorCharWidth + 8;
  }

  void _setScrollX(double x) {
    final nx = x.clamp(0.0, _maxScrollX);
    if (nx != _scrollX) setState(() => _scrollX = nx);
  }

  void _scrollBy(ScrollController c, double dy) {
    if (!c.hasClients) return;
    final p = c.position;
    c.jumpTo((p.pixels + dy).clamp(0.0, p.maxScrollExtent));
  }

  void _jumpTo(ScrollController c, int row, double viewH) {
    if (!c.hasClients) return;
    final p = c.position;
    final target = row * _lineH - viewH / 3;
    c.jumpTo(target.clamp(0.0, p.maxScrollExtent));
  }

  // First output row of chunk [chunk] (the result list is in chunk order).
  int _outRowOfChunk(int chunk) {
    for (var i = 0; i < _out.length; i++) {
      if (_out[i].chunk == chunk) return i;
    }
    return 0;
  }

  void _gotoConflict(int i) {
    final d = _data;
    if (d == null || d.result.conflicts.isEmpty) return;
    final n = d.result.conflicts.length;
    final idx = ((i % n) + n) % n;
    setState(() => _conflict = idx);
    final chunk = d.result.conflicts[idx];
    _jumpTo(_top, d.chunkRows[chunk], _topH);
    _jumpTo(_bottom, _outRowOfChunk(chunk), _bottomH);
  }

  void _choose(MergeChoice c) {
    if (_conflict < 0 || _conflict >= _choices.length) return;
    _choices = List.of(_choices)..[_conflict] = c;
    _rebuildOutput();
  }

  void _chooseAll(MergeChoice c) {
    _choices = List.filled(_choices.length, c);
    _rebuildOutput();
  }

  // Click on a top row: make its chunk the current conflict (if it is one).
  void _selectRow(int row) {
    final d = _data;
    if (d == null || row < 0 || row >= d.rows.length) return;
    final chunk = d.rows[row].chunk;
    final ci = d.result.conflicts.indexOf(chunk);
    if (ci >= 0 && ci != _conflict) setState(() => _conflict = ci);
  }

  Future<void> _save() async {
    final d = _data;
    final save = widget.onSave;
    if (d == null || save == null) return;
    final l10n = _l10n;
    if (_unresolved > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.tr('merge_save')),
          content: Text(l10n.trf('merge_unresolved_warn', [_unresolved])),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.tr('common_cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.tr('merge_save_anyway')),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final nl = d.left.crlf ? '\r\n' : '\n';
    final sb = StringBuffer();
    for (final line in _out) {
      sb.write(line.text);
      sb.write(nl);
    }
    await save(sb.toString(), d.left.codecName, _name(widget.leftPath));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final shift = Mods.shift;
    final page = math.max(_topH - _lineH, _lineH);
    if (k == LogicalKeyboardKey.arrowDown) {
      _scrollBy(_top, _lineH);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _scrollBy(_top, -_lineH);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _scrollBy(_top, page);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _scrollBy(_top, -page);
    } else if (k == LogicalKeyboardKey.home) {
      _scrollBy(_top, -1e12);
    } else if (k == LogicalKeyboardKey.end) {
      _scrollBy(_top, 1e12);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _setScrollX(_scrollX - editorCharWidth * 8);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _setScrollX(_scrollX + editorCharWidth * 8);
    } else if (k == LogicalKeyboardKey.f8 || k == LogicalKeyboardKey.f7) {
      _gotoConflict(_conflict + (shift ? -1 : 1));
    } else if (k == LogicalKeyboardKey.f5) {
      _load();
    } else if (k == LogicalKeyboardKey.digit1) {
      _choose(MergeChoice.left);
    } else if (k == LogicalKeyboardKey.digit2) {
      _choose(MergeChoice.base);
    } else if (k == LogicalKeyboardKey.digit3) {
      _choose(MergeChoice.right);
    } else if (k == LogicalKeyboardKey.digit4) {
      _choose(MergeChoice.leftRight);
    } else if (k == LogicalKeyboardKey.digit5) {
      _choose(MergeChoice.rightLeft);
    } else if (k == LogicalKeyboardKey.digit0) {
      _choose(MergeChoice.unresolved);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _onWheel(ScrollController c, PointerSignalEvent sig) {
    if (sig is! PointerScrollEvent) return;
    final shift = Mods.shift;
    final dx = sig.scrollDelta.dx + (shift ? sig.scrollDelta.dy : 0);
    if (dx != 0) _setScrollX(_scrollX + dx);
    final dy = shift ? 0.0 : sig.scrollDelta.dy;
    if (dy != 0) _scrollBy(c, dy);
  }

  String _name(String p) =>
      p.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final d = _data;
    final dim = editorGutterFg;
    final hasConflict = d != null && d.result.conflicts.isNotEmpty;
    final cur = _conflict >= 0 && _conflict < _choices.length
        ? _choices[_conflict]
        : null;
    Widget choiceBtn(MergeChoice c, String key, IconData icon) => IconButton(
      tooltip: l10n.tr(key),
      isSelected: cur == c,
      onPressed: hasConflict && _conflict >= 0 ? () => _choose(c) : null,
      icon: Icon(icon, size: 18),
    );
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        d == null
                            ? ''
                            : d.result.conflicts.isEmpty
                            ? l10n.tr('merge_no_conflicts')
                            : l10n.trf('merge_conflicts', [
                                _conflict + 1,
                                d.result.conflicts.length,
                                _unresolved,
                              ]),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: editorFg, fontSize: 12.5),
                      ),
                    ),
                    if (d != null && d.result.coarse)
                      Text(
                        l10n.tr('diff_coarse'),
                        style: TextStyle(color: dim, fontSize: 12),
                      ),
                    IconButton(
                      tooltip: l10n.tr('merge_prev'),
                      onPressed: hasConflict
                          ? () => _gotoConflict(_conflict - 1)
                          : null,
                      icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                    ),
                    IconButton(
                      tooltip: l10n.tr('merge_next'),
                      onPressed: hasConflict
                          ? () => _gotoConflict(_conflict + 1)
                          : null,
                      icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                    ),
                    const SizedBox(width: 8),
                    choiceBtn(MergeChoice.left, 'merge_take_left', Icons.west),
                    choiceBtn(
                      MergeChoice.base,
                      'merge_take_base',
                      Icons.vertical_align_center,
                    ),
                    choiceBtn(
                      MergeChoice.right,
                      'merge_take_right',
                      Icons.east,
                    ),
                    choiceBtn(
                      MergeChoice.leftRight,
                      'merge_take_both_lr',
                      Icons.merge_type,
                    ),
                    choiceBtn(
                      MergeChoice.rightLeft,
                      'merge_take_both_rl',
                      Icons.call_merge,
                    ),
                    choiceBtn(
                      MergeChoice.unresolved,
                      'merge_unresolve',
                      Icons.block,
                    ),
                    PopupMenuButton<MergeChoice>(
                      tooltip: l10n.tr('merge_all'),
                      enabled: hasConflict,
                      icon: const Icon(Icons.done_all, size: 18),
                      onSelected: _chooseAll,
                      itemBuilder: (_) => [
                        for (final (c, key) in [
                          (MergeChoice.left, 'merge_all_left'),
                          (MergeChoice.right, 'merge_all_right'),
                          (MergeChoice.unresolved, 'merge_all_unresolve'),
                        ])
                          PopupMenuItem(
                            height: AppSettings.instance.menuRowHeight,
                            value: c,
                            child: Text(l10n.tr(key)),
                          ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: l10n.tr('diff_refresh'),
                      onPressed: _loading ? null : _load,
                      icon: const Icon(Icons.refresh, size: 18),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: d == null || widget.onSave == null
                          ? null
                          : _save,
                      icon: const Icon(Icons.save, size: 16),
                      label: Text(l10n.tr('merge_save')),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _body(context)),
              if (d != null && _maxScrollX > 0)
                SizedBox(
                  height: 10,
                  child: LayoutBuilder(
                    builder: (_, c) {
                      final track = c.maxWidth;
                      final visible = _colW - _gutterW;
                      final thumb = (track * visible / _contentW).clamp(
                        24.0,
                        track,
                      );
                      final x = (track - thumb) * (_scrollX / _maxScrollX);
                      return GestureDetector(
                        onHorizontalDragUpdate: (dd) => _setScrollX(
                          _scrollX +
                              dd.delta.dx *
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

  Widget _colHeader(String path, Color accent) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: editorGutterBg,
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Tooltip(
        message: path,
        child: Text(
          _name(path),
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: editorFg, fontSize: 12),
        ),
      ),
    ),
  );

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
    final d = _data!;
    final settings = AppSettings.instance;
    final curChunk = _conflict >= 0 && _conflict < d.result.conflicts.length
        ? d.result.conflicts[_conflict]
        : -1;
    return LayoutBuilder(
      builder: (_, c) {
        const handleH = 6.0;
        const headerH = 22.0;
        final total = c.maxHeight - handleH - headerH * 2;
        _topH = math.max(40, total * _split);
        _bottomH = math.max(40, total - _topH);
        _colW = (c.maxWidth - 2) / 3;
        return Column(
          children: [
            SizedBox(
              height: headerH,
              child: Row(
                children: [
                  _colHeader(widget.leftPath, const Color(0xFF1E88E5)),
                  _colHeader(widget.basePath, editorGutterFg),
                  _colHeader(widget.rightPath, const Color(0xFF8E24AA)),
                ],
              ),
            ),
            SizedBox(
              height: _topH,
              child: Listener(
                onPointerSignal: (s) => _onWheel(_top, s),
                child: ListView.builder(
                  controller: _top,
                  physics: const NeverScrollableScrollPhysics(),
                  itemExtent: _lineH,
                  itemCount: d.rows.length,
                  itemBuilder: (_, i) {
                    final row = d.rows[i];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (_) => _selectRow(i),
                      onDoubleTapDown: (dd) {
                        final open = widget.onOpenLine;
                        if (open == null) return;
                        final col = (dd.localPosition.dx / (_colW + 1)).floor();
                        final (p, li) = switch (col) {
                          0 => (widget.leftPath, row.il),
                          1 => (widget.basePath, row.ib),
                          _ => (widget.rightPath, row.ir),
                        };
                        if (li >= 0) open(p, li + 1);
                      },
                      child: RepaintBoundary(
                        child: CustomPaint(
                          size: Size(c.maxWidth, _lineH),
                          painter: _RowPainter(
                            row: row,
                            data: d,
                            current: row.chunk == curChunk,
                            choice: _choiceOfChunk(d, row.chunk),
                            colW: _colW,
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
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (dd) => setState(() {
                  _split = (_split + dd.delta.dy / math.max(1, total)).clamp(
                    0.15,
                    0.85,
                  );
                }),
                child: Container(
                  height: handleH,
                  color: editorGutterBg,
                  alignment: Alignment.center,
                  child: Container(
                    width: 48,
                    height: 2,
                    color: editorGutterFg.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: headerH,
              child: Row(
                children: [
                  _colHeader(_l10n.tr('merge_result'), const Color(0xFF43A047)),
                ],
              ),
            ),
            SizedBox(
              height: _bottomH,
              child: Listener(
                onPointerSignal: (s) => _onWheel(_bottom, s),
                child: ListView.builder(
                  controller: _bottom,
                  physics: const NeverScrollableScrollPhysics(),
                  itemExtent: _lineH,
                  itemCount: _out.length,
                  itemBuilder: (_, i) {
                    final line = _out[i];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (_) {
                        final ci = d.result.conflicts.indexOf(line.chunk);
                        if (ci >= 0 && ci != _conflict) {
                          setState(() => _conflict = ci);
                        }
                      },
                      child: RepaintBoundary(
                        child: CustomPaint(
                          size: Size(c.maxWidth, _lineH),
                          painter: _OutPainter(
                            index: i,
                            line: line,
                            kind: line.chunk < 0
                                ? MergeKind.conflict
                                : d.result.chunks[line.chunk].kind,
                            current: line.chunk == curChunk,
                            choice: _choiceOfChunk(d, line.chunk),
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
          ],
        );
      },
    );
  }

  MergeChoice? _choiceOfChunk(MergeData d, int chunk) {
    if (chunk < 0) return MergeChoice.unresolved;
    final ci = d.result.conflicts.indexOf(chunk);
    if (ci < 0 || ci >= _choices.length) return null;
    return _choices[ci];
  }
}

// Top-level on purpose (see diff_view.dart): the closure must capture only
// the paths, never the State.
Future<MergeData> _mergeInIsolate(String base, String left, String right) =>
    Isolate.run(() => computeFileMerge(base, left, right));

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

Color _chunkBg(MergeKind kind, MergeChoice? choice, Color bg) => switch (kind) {
  MergeKind.same => bg,
  MergeKind.leftOnly => _leftBg,
  MergeKind.rightOnly => _rightBg,
  MergeKind.bothSame => _bothBg,
  MergeKind.conflict =>
    choice == null || choice == MergeChoice.unresolved
        ? _conflictBg
        : _resolvedBg,
};

const int _maxPaintChars = 10000;

void _paintCell(
  Canvas canvas,
  double x0,
  double w,
  double gutterW,
  double lineH,
  double scrollX,
  int lineIndex,
  String? text,
  Color cellBg,
  Color fg,
  Color gutterBg,
  Color gutterFg,
  String fontFamily,
  double fontSize, {
  int tabSize = 4,
  Color? textColor,
}) {
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
  final cx = x0 + gutterW;
  final cw = w - gutterW;
  canvas.drawRect(Rect.fromLTWH(cx, 0, cw, lineH), Paint()..color = cellBg);
  if (text == null) {
    final p = Paint()
      ..color = gutterFg.withValues(alpha: 0.15)
      ..strokeWidth = 1;
    for (var x = cx - lineH; x < cx + cw; x += 8) {
      canvas.drawLine(Offset(x, lineH), Offset(x + lineH, 0), p);
    }
    return;
  }
  var t = _expandTabs(text, tabSize);
  if (t.length > _maxPaintChars) t = t.substring(0, _maxPaintChars);
  canvas.save();
  canvas.clipRect(Rect.fromLTWH(cx, 0, cw, lineH));
  canvas.translate(cx + 4 - scrollX, 0);
  final tp = TextPainter(
    text: TextSpan(
      text: t,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        color: textColor ?? fg,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  tp.paint(canvas, Offset(0, (lineH - tp.height) / 2));
  canvas.restore();
}

class _RowPainter extends CustomPainter {
  _RowPainter({
    required this.row,
    required this.data,
    required this.current,
    required this.choice,
    required this.colW,
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

  final MergeRow row;
  final MergeData data;
  final bool current;
  final MergeChoice? choice;
  final double colW, gutterW, scrollX, fontSize, lineH;
  final int tabSize;
  final String fontFamily;
  final Color fg, bg, gutterBg, gutterFg;

  @override
  void paint(Canvas canvas, Size size) {
    final chunk = data.result.chunks[row.chunk];
    final cellBg = _chunkBg(chunk.kind, choice, bg);
    final sides = [
      (row.il, data.left.lines, 0.0),
      (row.ib, data.base.lines, colW + 1),
      (row.ir, data.right.lines, 2 * (colW + 1)),
    ];
    for (final (li, lines, x0) in sides) {
      // A side that has no line on this row inside a non-equal chunk is a
      // "no line here" hatch; inside an equal chunk every side has a line.
      final text = li < 0 ? null : lines[li];
      final Color cb;
      if (chunk.kind == MergeKind.same) {
        cb = bg;
      } else if (text == null) {
        cb = _fillBg;
      } else {
        cb = cellBg;
      }
      _paintCell(
        canvas,
        x0,
        colW,
        gutterW,
        lineH,
        scrollX,
        li,
        text,
        cb,
        fg,
        gutterBg,
        gutterFg,
        fontFamily,
        fontSize,
        tabSize: tabSize,
      );
    }
    final sep = Paint()..color = gutterFg.withValues(alpha: 0.5);
    canvas.drawRect(Rect.fromLTWH(colW, 0, 1, size.height), sep);
    canvas.drawRect(Rect.fromLTWH(2 * colW + 1, 0, 1, size.height), sep);
    if (current) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, 3, size.height),
        Paint()..color = _conflictStrong,
      );
    }
  }

  @override
  bool shouldRepaint(_RowPainter old) =>
      old.row != row ||
      old.data != data ||
      old.current != current ||
      old.choice != choice ||
      old.colW != colW ||
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

class _OutPainter extends CustomPainter {
  _OutPainter({
    required this.index,
    required this.line,
    required this.kind,
    required this.current,
    required this.choice,
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

  final int index;
  final MergeOutLine line;
  final MergeKind kind;
  final bool current;
  final MergeChoice? choice;
  final double gutterW, scrollX, fontSize, lineH;
  final int tabSize;
  final String fontFamily;
  final Color fg, bg, gutterBg, gutterFg;

  @override
  void paint(Canvas canvas, Size size) {
    _paintCell(
      canvas,
      0,
      size.width,
      gutterW,
      lineH,
      scrollX,
      index,
      line.text,
      line.marker ? _conflictBg : _chunkBg(kind, choice, bg),
      fg,
      gutterBg,
      gutterFg,
      fontFamily,
      fontSize,
      tabSize: tabSize,
      textColor: line.marker ? _markerFg : null,
    );
    if (current) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, 3, size.height),
        Paint()..color = _conflictStrong,
      );
    }
  }

  @override
  bool shouldRepaint(_OutPainter old) =>
      old.index != index ||
      old.line != line ||
      old.kind != kind ||
      old.current != current ||
      old.choice != choice ||
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
