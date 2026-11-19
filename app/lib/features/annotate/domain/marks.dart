import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/rendering.dart';

/// Annotation marks, stored in page-relative coordinates (0..1 of page width/height)
/// so the same mark paints identically on screen and at full resolution when flattened.
sealed class Mark {
  const Mark();

  void paint(Canvas canvas, Size page);

  /// Bounds in page pixels (for hit-testing and selection outlines).
  Rect bounds(Size page);

  Mark moved(Offset deltaNorm);

  /// Text and signatures can be resized; ink can't.
  Mark scaled(double factor) => this;

  bool get resizable => false;
}

Offset _px(Offset n, Size s) => Offset(n.dx * s.width, n.dy * s.height);

class InkMark extends Mark {
  const InkMark({
    required this.points,
    required this.color,
    required this.width,
    this.highlighter = false,
  });

  final List<Offset> points;
  final Color color;

  /// Stroke width as a fraction of page width.
  final double width;
  final bool highlighter;

  InkMark adding(Offset p) => InkMark(
    points: [...points, p],
    color: color,
    width: width,
    highlighter: highlighter,
  );

  @override
  void paint(Canvas canvas, Size page) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = highlighter ? color.withValues(alpha: 0.38) : color
      ..strokeWidth = width * page.width
      ..style = PaintingStyle.stroke
      ..strokeCap = highlighter ? StrokeCap.square : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    // Note: BlendMode.multiply would look slightly nicer for highlights, but inside a
    // CustomPaint it doesn't composite against the page image under Impeller (iOS),
    // so highlights use plain translucent ink everywhere.
    if (points.length == 1) {
      canvas.drawPoints(PointMode.points, [_px(points.first, page)], paint);
      return;
    }
    final first = _px(points.first, page);
    final path = Path()..moveTo(first.dx, first.dy);
    // Quadratic smoothing through midpoints.
    for (var i = 1; i < points.length - 1; i++) {
      final p = _px(points[i], page), next = _px(points[i + 1], page);
      path.quadraticBezierTo(
        p.dx,
        p.dy,
        (p.dx + next.dx) / 2,
        (p.dy + next.dy) / 2,
      );
    }
    final last = _px(points.last, page);
    path.lineTo(last.dx, last.dy);
    canvas.drawPath(path, paint);
  }

  @override
  Rect bounds(Size page) {
    final xs = points.map((p) => p.dx * page.width),
        ys = points.map((p) => p.dy * page.height);
    return Rect.fromLTRB(
      xs.reduce(math.min),
      ys.reduce(math.min),
      xs.reduce(math.max),
      ys.reduce(math.max),
    ).inflate(width * page.width / 2);
  }

  @override
  Mark moved(Offset d) => InkMark(
    points: [for (final p in points) p + d],
    color: color,
    width: width,
    highlighter: highlighter,
  );
}

class TextMark extends Mark {
  const TextMark({
    required this.pos,
    required this.text,
    required this.color,
    required this.size,
  });

  /// Top-left, normalized.
  final Offset pos;
  final String text;
  final Color color;

  /// Font size as a fraction of page width.
  final double size;

  TextPainter _layout(Size page) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size * page.width,
        fontWeight: FontWeight.w500,
        height: 1.2,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(1, page.width * (1 - pos.dx)));

  @override
  void paint(Canvas canvas, Size page) =>
      _layout(page).paint(canvas, _px(pos, page));

  @override
  Rect bounds(Size page) => _px(pos, page) & _layout(page).size;

  @override
  Mark moved(Offset d) =>
      TextMark(pos: pos + d, text: text, color: color, size: size);

  @override
  Mark scaled(double factor) => TextMark(
    pos: pos,
    text: text,
    color: color,
    size: (size * factor).clamp(0.012, 0.2),
  );

  @override
  bool get resizable => true;
}

/// A drawn signature: [strokes] are normalized to the signature's own box (0..1),
/// [box] is where that box sits on the page (normalized).
class SignatureMark extends Mark {
  const SignatureMark({
    required this.strokes,
    required this.box,
    required this.color,
  });

  final List<List<Offset>> strokes;
  final Rect box;
  final Color color;

  Rect _boxPx(Size page) => Rect.fromLTWH(
    box.left * page.width,
    box.top * page.height,
    box.width * page.width,
    box.height * page.height,
  );

  @override
  void paint(Canvas canvas, Size page) {
    final b = _boxPx(page);
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(1.2, b.width * 0.018)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset at(Offset n) =>
        Offset(b.left + n.dx * b.width, b.top + n.dy * b.height);
    for (final s in strokes) {
      if (s.isEmpty) continue;
      if (s.length == 1) {
        canvas.drawPoints(PointMode.points, [at(s.first)], paint);
        continue;
      }
      final start = at(s.first);
      final path = Path()..moveTo(start.dx, start.dy);
      for (final p in s.skip(1)) {
        final q = at(p);
        path.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  Rect bounds(Size page) => _boxPx(page);

  @override
  Mark moved(Offset d) =>
      SignatureMark(strokes: strokes, box: box.shift(d), color: color);

  @override
  Mark scaled(double factor) {
    final w = (box.width * factor).clamp(0.08, 0.95);
    final h = box.height * w / box.width;
    return SignatureMark(
      strokes: strokes,
      box: Rect.fromCenter(center: box.center, width: w, height: h),
      color: color,
    );
  }

  @override
  bool get resizable => true;
}

/// Paints marks (+ the in-progress stroke and a selection outline) over a page.
class MarksPainter extends CustomPainter {
  MarksPainter({
    required this.marks,
    this.active,
    this.selected,
    this.selectionColor = const Color(0xFF4C5BFF),
  });

  final List<Mark> marks;
  final Mark? active;
  final int? selected;
  final Color selectionColor;

  @override
  void paint(Canvas canvas, Size size) {
    for (final m in marks) {
      m.paint(canvas, size);
    }
    active?.paint(canvas, size);
    final s = selected;
    if (s != null && s < marks.length) {
      final r = marks[s].bounds(size).inflate(6);
      final p = Paint()
        ..color = selectionColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), p);
      if (marks[s].resizable) {
        canvas.drawCircle(r.bottomRight, 6, Paint()..color = selectionColor);
      }
    }
  }

  @override
  bool shouldRepaint(MarksPainter old) =>
      old.marks != marks || old.active != active || old.selected != selected;
}
