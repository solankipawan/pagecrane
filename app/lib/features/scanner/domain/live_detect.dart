import 'dart:math' as math;
import 'dart:typed_data';

import 'doc_detect.dart';

/// Live edge detection for the camera screen: turn a camera frame's luma plane into
/// a small upright grey image, find the sheet on it, and decide when to auto-capture.
/// Pure Dart (no Flutter), so it is unit-tested directly.

typedef Luma = ({Uint8List g, int w, int h});

/// Samples the Y plane of a camera frame ([width]×[height] in sensor orientation,
/// [rowStride] bytes per row) into an upright image whose short side is ~[shortSide]
/// px. [rotation] is the clockwise turn (0/90/180/270) that makes the frame upright,
/// i.e. the camera's sensor orientation for a portrait UI. Each output pixel is the
/// mean of a 2×2 block, which smooths sensor noise before thresholding.
Luma uprightLuma(
  Uint8List y,
  int width,
  int height,
  int rowStride,
  int rotation, {
  int shortSide = 160,
}) {
  final step = math.max(2, math.min(width, height) ~/ shortSide);
  final sw = (width - 1) ~/ step, sh = (height - 1) ~/ step;
  final rot = rotation % 360;
  final turned = rot == 90 || rot == 270;
  final ow = turned ? sh : sw, oh = turned ? sw : sh;
  final out = Uint8List(ow * oh);
  var o = 0;
  for (var yo = 0; yo < oh; yo++) {
    for (var xo = 0; xo < ow; xo++, o++) {
      final int sx, sy;
      switch (rot) {
        case 90:
          sx = yo;
          sy = sh - 1 - xo;
        case 180:
          sx = sw - 1 - xo;
          sy = sh - 1 - yo;
        case 270:
          sx = sw - 1 - yo;
          sy = xo;
        default:
          sx = xo;
          sy = yo;
      }
      final a = sy * step * rowStride + sx * step;
      out[o] = (y[a] + y[a + 1] + y[a + rowStride] + y[a + rowStride + 1]) >> 2;
    }
  }
  return (g: out, w: ow, h: oh);
}

/// Detects the sheet on [l] and returns its corners TL, TR, BR, BL normalised to 0..1.
List<Pt>? detectNormalized(Luma l) {
  final q = detectQuadGray(l.g, l.w, l.h);
  if (q == null) return null;
  return [for (final (x, y) in q) ((x + 0.5) / l.w, (y + 0.5) / l.h)];
}

/// Whether [q] (normalised TL TR BR BL in a frame of width/height [aspect]) looks
/// like a sheet seen by a camera: convex, every corner between 50° and 130°, and at
/// least 8 % of the frame. Rejects the odd twisted outlines from cluttered scenes.
bool plausibleQuad(List<Pt> q, double aspect) {
  final p = [for (final (x, y) in q) (x * aspect, y)];
  var sign = 0;
  var area = 0.0;
  for (var i = 0; i < 4; i++) {
    final o = p[i], a = p[(i + 1) % 4], b = p[(i + 2) % 4];
    final c = (a.$1 - o.$1) * (b.$2 - a.$2) - (a.$2 - o.$2) * (b.$1 - a.$1);
    if (c.abs() < 1e-9) return false;
    final s = c > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
    area += o.$1 * a.$2 - a.$1 * o.$2;
    final prev = p[(i + 3) % 4];
    final v1 = (prev.$1 - o.$1, prev.$2 - o.$2),
        v2 = (a.$1 - o.$1, a.$2 - o.$2);
    final len =
        math.sqrt(v1.$1 * v1.$1 + v1.$2 * v1.$2) *
        math.sqrt(v2.$1 * v2.$1 + v2.$2 * v2.$2);
    if (len == 0) return false;
    final cos = (v1.$1 * v2.$1 + v1.$2 * v2.$2) / len;
    if (cos.abs() > 0.643) return false; // outside 50°–130°
  }
  return area.abs() / 2 >= 0.08 * aspect;
}

/// Mean absolute difference of two same-sized grey images (0–255).
double meanAbsDiff(Uint8List a, Uint8List b) {
  if (a.length != b.length || a.isEmpty) return 255;
  var s = 0;
  for (var i = 0; i < a.length; i++) {
    s += (a[i] - b[i]).abs();
  }
  return s / a.length;
}

/// Smooths the detected quad between frames and decides when it is steady enough to
/// auto-capture. After a capture it waits for the scene to change (page turned,
/// sheet removed) before it captures again, so one page is not shot twice.
class QuadTracker {
  QuadTracker({
    this.hold = const Duration(milliseconds: 1100),
    this.moveTolerance = 0.025,
    this.sceneChange = 12,
  });

  /// How long the sheet must stay still before auto-capture.
  final Duration hold;

  /// Max corner movement (fraction of the frame) that still counts as "still".
  final double moveTolerance;

  /// Mean grey change that counts as a new page after a capture.
  final double sceneChange;

  /// Frame width / height, so shape checks measure real angles.
  double aspect = 9 / 16;

  /// The outline to show (null = none).
  List<Pt>? quad;
  DateTime? _stillSince;
  int _misses = 0;
  bool _armed = true;
  DateTime? _armedAt;
  Uint8List? _shotRef;

  /// A detection that disagrees with what is shown; adopted only if the next frame
  /// agrees with it. Stops the outline leaping on one odd frame.
  List<Pt>? _candidate;

  static const _jump = 0.08, _agree = 0.04, _deadZone = 0.012;

  static double _dist(List<Pt> a, List<Pt> b) {
    var m = 0.0;
    for (var i = 0; i < 4; i++) {
      m = math.max(
        m,
        math.max((a[i].$1 - b[i].$1).abs(), (a[i].$2 - b[i].$2).abs()),
      );
    }
    return m;
  }

  void update(List<Pt>? q, Uint8List frame, DateTime now) {
    if (!_armed && _shotRef != null) {
      if (q == null || meanAbsDiff(frame, _shotRef!) > sceneChange) {
        _armed = true;
        _armedAt = now;
      }
    }
    if (q != null && !plausibleQuad(q, aspect)) q = null;
    if (q == null) {
      _candidate = null;
      // Keep the outline through a couple of missed frames so it doesn't flicker.
      if (++_misses >= 3) {
        quad = null;
        _stillSince = null;
      }
      return;
    }
    _misses = 0;
    final prev = quad;
    final cand = _candidate;
    if (prev == null || _dist(prev, q) > _jump) {
      // New or very different outline: show it only once two frames agree.
      _stillSince = now;
      if (cand != null && _dist(cand, q) < _agree) {
        quad = q;
        _candidate = null;
      } else {
        _candidate = q;
      }
      return;
    }
    _candidate = null;
    final moved = _dist(prev, q);
    if (moved > moveTolerance) _stillSince = now;
    if (moved < _deadZone) return; // sensor noise: keep the outline still
    // Glide towards the new position instead of snapping.
    final k = moved > moveTolerance ? 0.5 : 0.25;
    quad = [
      for (var i = 0; i < 4; i++)
        (
          prev[i].$1 + (q[i].$1 - prev[i].$1) * k,
          prev[i].$2 + (q[i].$2 - prev[i].$2) * k,
        ),
    ];
  }

  /// 0..1: how far through the hold the steady sheet is (0 when none or not re-armed).
  double progress(DateTime now) {
    final since = _stillSince;
    if (quad == null || since == null || !_armed) return 0;
    final from = _armedAt != null && _armedAt!.isAfter(since)
        ? _armedAt!
        : since;
    return (now.difference(from).inMilliseconds / hold.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  bool shouldCapture(DateTime now) => progress(now) >= 1;

  /// Call when a page was captured; [frame] is the grey frame at that moment.
  void captured(Uint8List frame) {
    _armed = false;
    _armedAt = null;
    _shotRef = frame;
  }

  void reset() {
    quad = null;
    _stillSince = null;
    _misses = 0;
    _armed = true;
    _armedAt = null;
    _shotRef = null;
    _candidate = null;
  }
}
