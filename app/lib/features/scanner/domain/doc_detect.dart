import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'filters.dart';

typedef Pt = (double, double);

/// Finds a light sheet of paper on a darker background:
/// Otsu threshold → largest bright blob → 4 extreme corners (TL, TR, BR, BL).
/// Same algorithm as the web prototype; the camera path uses VisionKit / ML Kit
/// instead, this one powers "Import photo → auto-crop".
List<Pt>? detectQuad(Rgba p) {
  final w = p.w, h = p.h, n = w * h, data = p.d;
  final g = Uint8List(n);
  final hist = List<int>.filled(256, 0);
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    final v = (data[j] * 77 + data[j + 1] * 150 + data[j + 2] * 29) >> 8;
    g[i] = v;
    hist[v]++;
  }
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0.0, th = 128, mBack = 0.0, mFore = 0.0;
  for (var i = 0; i < 256; i++) {
    wB += hist[i];
    if (wB == 0) continue;
    final wF = n - wB;
    if (wF == 0) break;
    sumB += i * hist[i];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      th = i;
      mBack = mB;
      mFore = mF;
    }
  }
  if (mFore - mBack < 35) return null;

  final lab = Int32List(n), stack = Int32List(n);
  var cur = 0, bestLab = 0, bestSize = 0;
  for (var i = 0; i < n; i++) {
    if (g[i] <= th || lab[i] != 0) continue;
    cur++;
    var sp = 0, size = 0;
    stack[sp++] = i;
    lab[i] = cur;
    while (sp > 0) {
      final q = stack[--sp];
      size++;
      final x = q % w;
      if (x > 0 && lab[q - 1] == 0 && g[q - 1] > th) {
        lab[q - 1] = cur;
        stack[sp++] = q - 1;
      }
      if (x < w - 1 && lab[q + 1] == 0 && g[q + 1] > th) {
        lab[q + 1] = cur;
        stack[sp++] = q + 1;
      }
      if (q >= w && lab[q - w] == 0 && g[q - w] > th) {
        lab[q - w] = cur;
        stack[sp++] = q - w;
      }
      if (q < n - w && lab[q + w] == 0 && g[q + w] > th) {
        lab[q + w] = cur;
        stack[sp++] = q + w;
      }
    }
    if (size > bestSize) {
      bestSize = size;
      bestLab = cur;
    }
  }
  final frac = bestSize / n;
  if (frac < 0.08 || frac > 0.9) return null;

  Pt tl = (0, 0), tr = (0, 0), br = (0, 0), bl = (0, 0);
  var minS = 1 << 30, maxS = -1, minD = 1 << 30, maxD = -(1 << 30);
  for (var i = 0; i < n; i++) {
    if (lab[i] != bestLab) continue;
    final x = i % w, y = i ~/ w, s = x + y, dd = x - y;
    if (s < minS) {
      minS = s;
      tl = (x.toDouble(), y.toDouble());
    }
    if (s > maxS) {
      maxS = s;
      br = (x.toDouble(), y.toDouble());
    }
    if (dd > maxD) {
      maxD = dd;
      tr = (x.toDouble(), y.toDouble());
    }
    if (dd < minD) {
      minD = dd;
      bl = (x.toDouble(), y.toDouble());
    }
  }
  final quad = [tl, tr, br, bl];
  var area = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = quad[i], b = quad[(i + 1) % 4];
    area += a.$1 * b.$2 - b.$1 * a.$2;
  }
  area = area.abs() / 2;
  if (area < n * 0.08 || bestSize / area < 0.6) return null;
  return quad;
}

/// Projective map from the unit square to quad TL,TR,BR,BL (Heckbert).
({
  double a,
  double b,
  double c,
  double d,
  double e,
  double f,
  double g,
  double h,
})
_sq2quad(List<Pt> q) {
  final (x0, y0) = q[0];
  final (x1, y1) = q[1];
  final (x2, y2) = q[2];
  final (x3, y3) = q[3];
  final sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3;
  if (sx.abs() < 1e-9 && sy.abs() < 1e-9) {
    return (
      a: x1 - x0,
      b: x3 - x0,
      c: x0,
      d: y1 - y0,
      e: y3 - y0,
      f: y0,
      g: 0.0,
      h: 0.0,
    );
  }
  final dx1 = x1 - x2,
      dx2 = x3 - x2,
      dy1 = y1 - y2,
      dy2 = y3 - y2,
      den = dx1 * dy2 - dx2 * dy1;
  final g = (sx * dy2 - dx2 * sy) / den, h = (dx1 * sy - sx * dy1) / den;
  return (
    a: x1 - x0 + g * x1,
    b: x3 - x0 + h * x3,
    c: x0,
    d: y1 - y0 + g * y1,
    e: y3 - y0 + h * y3,
    f: y0,
    g: g,
    h: h,
  );
}

/// Perspective-corrects [src] inside [q] into an upright rectangle (bilinear).
img.Image warp(Rgba src, List<Pt> q, {int maxDim = 2400}) {
  double dist(Pt a, Pt b) =>
      math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));
  var ow = math.max(dist(q[0], q[1]), dist(q[3], q[2]));
  var oh = math.max(dist(q[0], q[3]), dist(q[1], q[2]));
  final k = math.min(1.0, maxDim / math.max(ow, oh));
  final w = math.max(1, (ow * k).round()), h = math.max(1, (oh * k).round());
  final m = _sq2quad(q);
  final out = Uint8List(w * h * 4), sd = src.d, sw = src.w, sh = src.h;
  var o = 0;
  for (var y = 0; y < h; y++) {
    final v = (y + 0.5) / h;
    for (var x = 0; x < w; x++, o += 4) {
      final u = (x + 0.5) / w;
      final den = m.g * u + m.h * v + 1;
      final sx = ((m.a * u + m.b * v + m.c) / den - 0.5).clamp(0.0, sw - 1.001);
      final sy = ((m.d * u + m.e * v + m.f) / den - 0.5).clamp(0.0, sh - 1.001);
      final x0 = sx.floor(), y0 = sy.floor(), fx = sx - x0, fy = sy - y0;
      final i00 = (y0 * sw + x0) * 4,
          i10 = i00 + 4,
          i01 = i00 + sw * 4,
          i11 = i01 + 4;
      for (var c = 0; c < 3; c++) {
        final top = sd[i00 + c] + (sd[i10 + c] - sd[i00 + c]) * fx;
        final bot = sd[i01 + c] + (sd[i11 + c] - sd[i01 + c]) * fx;
        out[o + c] = (top + (bot - top) * fy).round();
      }
      out[o + 3] = 255;
    }
  }
  return Rgba(w, h, out).toImage();
}

/// Detect on a 160 px copy, warp at full resolution. Returns null if no sheet found.
img.Image? autoCrop(img.Image full) {
  const sw = 160;
  final sh = math.max(1, (sw * full.height / full.width).round());
  final small = Rgba.of(
    img.copyResize(
      full,
      width: sw,
      height: sh,
      interpolation: img.Interpolation.average,
    ),
  );
  final q = detectQuad(small);
  if (q == null) return null;
  final kx = full.width / sw, ky = full.height / sh;
  var pts = [for (final (x, y) in q) ((x + 0.5) * kx, (y + 0.5) * ky)];
  // Pull corners in 1 % so no background shows on the edges.
  final cx = pts.fold(0.0, (a, p) => a + p.$1) / 4,
      cy = pts.fold(0.0, (a, p) => a + p.$2) / 4;
  pts = [for (final (x, y) in pts) (x + (cx - x) * 0.01, y + (cy - y) * 0.01)];
  return warp(Rgba.of(full), pts);
}
