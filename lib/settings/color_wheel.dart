// HSV color wheel for the color picker dialog: a hue ring around a
// saturation × value square, both draggable. Self-contained (CustomPaint +
// GestureDetector) so the app does not pull in a picker package. The
// geometry / hit-testing is a pure class ([ColorWheelGeometry]) so it can be
// unit-tested without a widget tree.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which control a pointer landed on.
enum WheelRegion { ring, square, none }

/// Pixel geometry of the wheel for a given [size] (a square of that side).
/// Ring = the outer band; square = the largest axis-aligned square inside
/// the ring's inner radius (with a small gap).
class ColorWheelGeometry {
  ColorWheelGeometry(this.size, {double? ringWidth})
    : ringWidth = ringWidth ?? (size * 0.11).clamp(14.0, 28.0);

  final double size;
  final double ringWidth;

  Offset get center => Offset(size / 2, size / 2);
  double get outerRadius => size / 2;
  double get innerRadius => outerRadius - ringWidth;

  /// The SV square (inset from the inner circle so it never touches the ring).
  Rect get square {
    final half = (innerRadius - 4) / math.sqrt2;
    return Rect.fromCenter(center: center, width: half * 2, height: half * 2);
  }

  WheelRegion regionAt(Offset p) {
    if (square.contains(p)) return WheelRegion.square;
    final d = (p - center).distance;
    if (d >= innerRadius - 2 && d <= outerRadius + 6) return WheelRegion.ring;
    return WheelRegion.none;
  }

  /// Hue (0–360) for a pointer anywhere: the angle from the center, 0° at
  /// 3 o'clock, increasing clockwise (screen y grows downward).
  double hueAt(Offset p) {
    final v = p - center;
    var deg = math.atan2(v.dy, v.dx) * 180 / math.pi;
    if (deg < 0) deg += 360;
    return deg;
  }

  /// Saturation (x, 0 left → 1 right) and value (y, 1 top → 0 bottom) for a
  /// pointer, clamped to the square so a drag past its edge still tracks.
  (double, double) svAt(Offset p) {
    final r = square;
    final s = ((p.dx - r.left) / r.width).clamp(0.0, 1.0);
    final v = 1 - ((p.dy - r.top) / r.height).clamp(0.0, 1.0);
    return (s, v);
  }

  /// Marker position on the ring for [hue].
  Offset ringMarker(double hue) {
    final rad = hue * math.pi / 180;
    final r = outerRadius - ringWidth / 2;
    return center + Offset(math.cos(rad) * r, math.sin(rad) * r);
  }

  /// Marker position in the square for ([s], [v]).
  Offset squareMarker(double s, double v) {
    final r = square;
    return Offset(r.left + s * r.width, r.top + (1 - v) * r.height);
  }
}

class ColorWheel extends StatefulWidget {
  const ColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
    this.size = 220,
  });

  /// Current color (alpha ignored; the dialog has its own slider for it).
  final HSVColor color;
  final ValueChanged<HSVColor> onChanged;
  final double size;

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  late final ColorWheelGeometry _geo = ColorWheelGeometry(widget.size);
  WheelRegion _dragging = WheelRegion.none;

  void _apply(Offset p) {
    final c = widget.color;
    switch (_dragging) {
      case WheelRegion.ring:
        widget.onChanged(c.withHue(_geo.hueAt(p)));
      case WheelRegion.square:
        final (s, v) = _geo.svAt(p);
        widget.onChanged(c.withSaturation(s).withValue(v));
      case WheelRegion.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // The control is chosen from the raw pointer-DOWN position: a pan's
    // start position is where the drag was recognized (past the touch
    // slop), so a fast flick from the square onto the ring would have
    // grabbed the ring instead. Pan updates only move the chosen control.
    return Semantics(
      label: 'color wheel',
      child: Listener(
        onPointerDown: (e) {
          _dragging = _geo.regionAt(e.localPosition);
          _apply(e.localPosition);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => _apply(d.localPosition),
          onPanEnd: (_) => _dragging = WheelRegion.none,
          onPanCancel: () => _dragging = WheelRegion.none,
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _WheelPainter(widget.color, _geo),
          ),
        ),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.color, this.geo);

  final HSVColor color;
  final ColorWheelGeometry geo;

  @override
  void paint(Canvas canvas, Size size) {
    final c = geo.center;
    // Hue ring: a sweep gradient through the six primaries, drawn as a
    // stroked circle of the ring's width.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = geo.ringWidth
      ..shader = SweepGradient(
        colors: [
          for (var h = 0; h <= 360; h += 30) HSVColor.fromAHSV(1, h % 360, 1, 1).toColor(),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: geo.outerRadius));
    canvas.drawCircle(c, geo.outerRadius - geo.ringWidth / 2, ring);

    // SV square for the current hue: white → hue left to right, then a
    // transparent → black overlay top to bottom.
    final sq = geo.square;
    final hueColor = HSVColor.fromAHSV(1, color.hue, 1, 1).toColor();
    canvas.drawRect(
      sq,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hueColor],
        ).createShader(sq),
    );
    canvas.drawRect(
      sq,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(sq),
    );
    canvas.drawRect(
      sq,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black26,
    );

    // Markers: a ring on the hue band and a ring at the S/V point, drawn
    // white-on-black so they read on any color.
    void marker(Offset p, double r) {
      canvas.drawCircle(
        p,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.black54,
      );
      canvas.drawCircle(
        p,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white,
      );
    }

    marker(geo.ringMarker(color.hue), geo.ringWidth / 2 - 2);
    marker(geo.squareMarker(color.saturation, color.value), 6);
  }

  @override
  bool shouldRepaint(_WheelPainter old) =>
      old.color != color || old.geo.size != geo.size;
}
