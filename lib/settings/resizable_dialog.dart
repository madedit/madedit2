// A dialog content box the user can resize by dragging its right edge,
// bottom edge or bottom-right corner. AlertDialog sizes itself to its
// content, so changing this box's size resizes the dialog; the size is
// remembered per dialog [id] in settings.json (`dialogs.sizes`), so the
// editors the user enlarged stay that way.
//
// Two kinds of dialog:
//   - fixed height ([initialHeight] given): width and height both resize
//     and both are remembered;
//   - content-sized height ([initialHeight] null — the advanced settings,
//     run, print… dialogs): the height follows the content until the user
//     drags it, and can then only be made TALLER than the content (a
//     shorter box would overflow, as such content is not scrollable by
//     contract). Only the width is remembered: the content's natural height
//     differs per open (lists that load, locale), so a stored height could
//     be shorter than the content next time.

import 'package:flutter/material.dart';

import 'app_settings.dart';

class ResizableDialogBox extends StatefulWidget {
  const ResizableDialogBox({
    super.key,
    required this.id,
    required this.initialWidth,
    this.initialHeight,
    required this.child,
    this.minWidth = 320,
    this.minHeight = 240,
  });

  /// Settings key the size is remembered under (e.g. 'colors', 'keymap').
  final String id;
  final double initialWidth;

  /// Null = content-sized (see the file comment).
  final double? initialHeight;
  final double minWidth;

  /// Lower bound for a fixed-height box; a content-sized box uses its own
  /// content height as the bound instead.
  final double minHeight;
  final Widget child;

  @override
  State<ResizableDialogBox> createState() => _ResizableDialogBoxState();
}

enum _Grip { right, bottom, corner }

class _ResizableDialogBoxState extends State<ResizableDialogBox> {
  late double _w = () {
    final saved = AppSettings.instance.dialogSize(widget.id);
    return saved?.$1 ?? widget.initialWidth;
  }();

  /// Null while content-sized (no drag yet).
  late double? _h = () {
    if (widget.initialHeight == null) return null;
    final saved = AppSettings.instance.dialogSize(widget.id);
    return saved != null && saved.$2 > 0 ? saved.$2 : widget.initialHeight;
  }();

  /// The content height the first vertical drag started from: the floor for
  /// a content-sized box.
  double? _contentFloor;

  static const double _gripThickness = 8;

  double _maxW(Size screen) =>
      (screen.width - 80).clamp(widget.minWidth, double.infinity);
  double _maxH(Size screen) =>
      (screen.height - 200).clamp(_minH, double.infinity);
  double get _minH => _contentFloor ?? widget.minHeight;

  void _drag(_Grip g, Offset delta, Size screen) {
    // Leave room for the dialog's own title/actions/insets (~200px tall,
    // ~80px wide) so the content can never push the dialog off-screen.
    var w = _w, h = _h;
    if (g != _Grip.bottom) w = (w + delta.dx).clamp(widget.minWidth, _maxW(screen));
    if (g != _Grip.right) {
      if (h == null) {
        // First vertical drag of a content-sized box: start from, and never
        // go below, the height the content has right now.
        final now = context.size?.height;
        if (now == null) return;
        _contentFloor = now;
        h = now;
      }
      h = (h + delta.dy).clamp(_minH, _maxH(screen));
    }
    if (w == _w && h == _h) return;
    setState(() {
      _w = w;
      _h = h;
    });
  }

  void _remember() => AppSettings.instance.setDialogSize(
    widget.id,
    _w,
    widget.initialHeight == null ? 0 : (_h ?? 0), // 0 = not remembered
  );

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    // Clamp a remembered size to the current screen too (moved to a smaller
    // monitor since).
    final w = _w.clamp(widget.minWidth, _maxW(screen));
    final h = _h?.clamp(_minH, _maxH(screen));
    Widget grip(
      _Grip g, {
      double? left,
      double? top,
      double? right,
      double? bottom,
      double? width,
      double? height,
      required MouseCursor cursor,
    }) {
      return Positioned(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        width: width,
        height: height,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (d) => _drag(g, d.delta, screen),
            onPanEnd: (_) => _remember(),
            onPanCancel: _remember,
          ),
        ),
      );
    }

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Content-sized: the child sets the height, so it cannot be
          // Positioned.fill (that needs a bounded Stack).
          if (h == null) widget.child else Positioned.fill(child: widget.child),
          grip(
            _Grip.right,
            top: 0,
            bottom: _gripThickness,
            right: -_gripThickness / 2,
            width: _gripThickness,
            cursor: SystemMouseCursors.resizeLeftRight,
          ),
          grip(
            _Grip.bottom,
            left: 0,
            right: _gripThickness,
            bottom: -_gripThickness / 2,
            height: _gripThickness,
            cursor: SystemMouseCursors.resizeUpDown,
          ),
          grip(
            _Grip.corner,
            right: -_gripThickness / 2,
            bottom: -_gripThickness / 2,
            width: _gripThickness * 2,
            height: _gripThickness * 2,
            cursor: SystemMouseCursors.resizeDownRight,
          ),
          // A small visual hint at the corner.
          Positioned(
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Icon(
                Icons.drag_handle,
                size: 14,
                color: Theme.of(context).disabledColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
