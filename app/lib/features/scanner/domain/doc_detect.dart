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
  final n = p.w * p.h, data = p.d;
  final g = Uint8List(n);
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    g[i] = (data[j] * 77 + data[j + 1] * 150 + data[j + 2] * 29) >> 8;
  }
  return detectQuadGray(g, p.w, p.h);
}

/// [detectQuad] on 8-bit luma (row-major, [w]×[h]): what the live camera feeds in.
List<Pt>? detectQuadGray(Uint8List g, int w, int h) {
  final n = w * h;
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < n; i++) {
    hist[g[i]]++;
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

  // Open notebook / book: keep only the page under the frame centre.
  final cut = _gutter(g, lab, bestLab, w, h, mBack, mFore - mBack);
  bool kept(int x, int y) {
    if (cut == null) return true;
    final v = cut.vertical ? x : y;
    return cut.keepLow ? v <= cut.at : v >= cut.at;
  }

  Pt tl = (0, 0), tr = (0, 0), br = (0, 0), bl = (0, 0);
  var minS = 1 << 30, maxS = -1, minD = 1 << 30, maxD = -(1 << 30);
  var keptSize = 0;
  for (var i = 0; i < n; i++) {
    if (lab[i] != bestLab) continue;
    final x = i % w, y = i ~/ w, s = x + y, dd = x - y;
    if (!kept(x, y)) continue;
    keptSize++;
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
  if (area < n * 0.08 || keptSize / area < 0.6) return null;
  return quad;
}

/// Looks for a page gutter: a narrow dark band running straight through the sheet
/// blob ([label] in [lab]), splitting it into two sizeable halves, like the fold of an
/// open notebook. Pixels outside the blob count as background ([back]), so a gutter
/// dark enough to fall below the threshold is found too. Returns where to cut and
/// which side to keep (the one holding the frame centre, where the user is aiming).
({bool vertical, int at, bool keepLow})? _gutter(
  Uint8List g,
  Int32List lab,
  int label,
  int w,
  int h,
  double back,
  double contrast,
) {
  var x0 = w, x1 = -1, y0 = h, y1 = -1;
  for (var i = 0; i < w * h; i++) {
    if (lab[i] != label) continue;
    final x = i % w, y = i ~/ w;
    if (x < x0) x0 = x;
    if (x > x1) x1 = x;
    if (y < y0) y0 = y;
    if (y > y1) y1 = y;
  }
  final bw = x1 - x0 + 1, bh = y1 - y0 + 1;
  if (bw < 12 || bh < 12) return null;

  ({bool vertical, int at, bool keepLow})? scan(bool vertical) {
    final len = vertical ? bw : bh, span = vertical ? bh : bw;
    final sum = Float64List(len), cnt = Int32List(len);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final i = y * w + x;
        if (lab[i] != label) continue;
        final k = vertical ? x - x0 : y - y0;
        sum[k] += g[i];
        cnt[k]++;
      }
    }
    final prof = Float64List(len);
    for (var k = 0; k < len; k++) {
      prof[k] = (sum[k] + (span - cnt[k]) * back) / span;
    }
    final smooth = Float64List(len);
    for (var k = 0; k < len; k++) {
      final a = prof[math.max(0, k - 1)], b = prof[math.min(len - 1, k + 1)];
      smooth[k] = (a + prof[k] + b) / 3;
    }
    final sorted = [...smooth]..sort();
    final median = sorted[len ~/ 2];
    final lo = (len * 0.15).floor(), hi = (len * 0.85).ceil();
    var at = -1;
    var minV = double.infinity;
    for (var k = lo; k < hi; k++) {
      if (smooth[k] < minV) {
        minV = smooth[k];
        at = k;
      }
    }
    if (at < 0) return null;
    final depth = median - minV;
    if (depth < math.max(12, 0.2 * contrast)) return null;
    // Narrow: a gutter, not a wide dark region such as a photo on the page.
    final half = median - depth / 2;
    var bLo = at, bHi = at;
    while (bLo > 0 && smooth[bLo - 1] < half) {
      bLo--;
    }
    while (bHi < len - 1 && smooth[bHi + 1] < half) {
      bHi++;
    }
    if (bHi - bLo + 1 > len * 0.12) return null;
    // Unique: lines of text make many similar dips; a gutter is one clear dip.
    var other = double.infinity;
    for (var k = lo; k < hi; k++) {
      if (k >= bLo - 2 && k <= bHi + 2) continue;
      if (smooth[k] < other) other = smooth[k];
    }
    if (median - other > depth * 0.5) return null;
    // Both halves must be real pages, not a sliver.
    var low = 0, high = 0;
    for (var k = 0; k < len; k++) {
      if (k < bLo) low += cnt[k];
      if (k > bHi) high += cnt[k];
    }
    final total = low + high;
    if (total == 0 || low < total * 0.12 || high < total * 0.12) return null;
    final base = vertical ? x0 : y0;
    final centre = (vertical ? w : h) / 2;
    final keepLow = centre < base + at || (centre == base + at && low > high);
    return (
      vertical: vertical,
      // Cut just past the whole gutter band on the side being dropped.
      at: keepLow ? base + bLo - 1 : base + bHi + 1,
      keepLow: keepLow,
    );
  }

  // A side-by-side spread is wide; a top-and-bottom one is tall.
  if (bw >= bh * 0.8) {
    final v = scan(true);
    if (v != null) return v;
  }
  if (bh >= bw * 0.8) return scan(false);
  return null;
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

/// Pulls corners 1 % towards their centre so no background shows on the edges.
List<Pt> insetCorners(List<Pt> q, [double k = 0.01]) {
  final cx = q.fold(0.0, (a, p) => a + p.$1) / 4,
      cy = q.fold(0.0, (a, p) => a + p.$2) / 4;
  return [for (final (x, y) in q) (x + (cx - x) * k, y + (cy - y) * k)];
}

/// Detects the sheet on a 160 px copy of [full]. Returns its corners TL, TR, BR, BL
/// normalised to 0..1 and already inset, or null if no sheet was found.
List<Pt>? findPageCorners(img.Image full) {
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
  return insetCorners([
    for (final (x, y) in q) ((x + 0.5) / sw, (y + 0.5) / sh),
  ]);
}

/// Perspective-corrects [full] inside normalised corners [c].
img.Image warpNormalized(img.Image full, List<Pt> c) => warp(Rgba.of(full), [
  for (final (x, y) in c) (x * full.width, y * full.height),
]);

/// Detect on a 160 px copy, warp at full resolution. Returns null if no sheet found.
img.Image? autoCrop(img.Image full) {
  final c = findPageCorners(full);
  return c == null ? null : warpNormalized(full, c);
}
