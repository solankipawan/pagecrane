import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Scanner filters (docs/ARCHITECTURE.md §5). Pure Dart, run inside isolates.
enum ScanFilter {
  original('Original'),
  magic('Magic Color'),
  gray('Grayscale'),
  bw('B&W'),
  photo('Photo');

  const ScanFilter(this.label);
  final String label;
}

/// Packed RGBA8 pixels — the working format for all pixel loops.
class Rgba {
  Rgba(this.w, this.h, this.d);
  final int w, h;
  final Uint8List d;

  factory Rgba.of(img.Image im) {
    final four = im.numChannels == 4 && im.format == img.Format.uint8
        ? im
        : im.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
    return Rgba(
      four.width,
      four.height,
      Uint8List.fromList(four.getBytes(order: img.ChannelOrder.rgba)),
    );
  }

  img.Image toImage() => img.Image.fromBytes(
    width: w,
    height: h,
    bytes: d.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
}

int _clamp255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

(int, int) _percentiles(List<int> hist, int n, double a, double b) {
  var acc = 0, lo = 0, hi = 255;
  for (var i = 0; i < 256; i++) {
    acc += hist[i];
    if (acc >= n * a) {
      lo = i;
      break;
    }
  }
  acc = 0;
  for (var i = 255; i >= 0; i--) {
    acc += hist[i];
    if (acc >= n * (1 - b)) {
      hi = i;
      break;
    }
  }
  return (lo, hi > lo ? hi : lo + 1);
}

/// Paper-brightness estimate: downscale, 5×5 max filter (drops ink), smooth upscale.
Uint8List _backgroundMap(img.Image src) {
  final bw = (src.width / 28).round().clamp(4, 1 << 20);
  final bh = (src.height / 28).round().clamp(4, 1 << 20);
  final small = Rgba.of(
    img.copyResize(
      src,
      width: bw,
      height: bh,
      interpolation: img.Interpolation.average,
    ),
  );
  final out = Uint8List(small.d.length);
  for (var y = 0; y < bh; y++) {
    for (var x = 0; x < bw; x++) {
      final o = (y * bw + x) * 4;
      for (var c = 0; c < 3; c++) {
        var m = 0;
        for (
          var yy = (y - 2).clamp(0, bh - 1);
          yy <= (y + 2).clamp(0, bh - 1);
          yy++
        ) {
          for (
            var xx = (x - 2).clamp(0, bw - 1);
            xx <= (x + 2).clamp(0, bw - 1);
            xx++
          ) {
            final v = small.d[(yy * bw + xx) * 4 + c];
            if (v > m) m = v;
          }
        }
        out[o + c] = m;
      }
      out[o + 3] = 255;
    }
  }
  final big = img.copyResize(
    Rgba(bw, bh, out).toImage(),
    width: src.width,
    height: src.height,
    interpolation: img.Interpolation.linear,
  );
  return Rgba.of(big).d;
}

img.Image applyFilter(img.Image src, ScanFilter f) {
  if (f == ScanFilter.original) return src;
  final p = Rgba.of(src);
  final d = p.d, n = p.w * p.h;
  switch (f) {
    case ScanFilter.magic:
    case ScanFilter.bw:
      final bg = _backgroundMap(src);
      for (var i = 0; i < d.length; i += 4) {
        var r = d[i] / (bg[i] < 1 ? 1 : bg[i]) * 255;
        var g = d[i + 1] / (bg[i + 1] < 1 ? 1 : bg[i + 1]) * 255;
        var b = d[i + 2] / (bg[i + 2] < 1 ? 1 : bg[i + 2]) * 255;
        if (f == ScanFilter.bw) {
          final l = 0.299 * r + 0.587 * g + 0.114 * b;
          final v = _clamp255((l - 150) * 4.2);
          d[i] = v;
          d[i + 1] = v;
          d[i + 2] = v;
        } else {
          r = (r - 128) * 1.18 + 140;
          g = (g - 128) * 1.18 + 140;
          b = (b - 128) * 1.18 + 140;
          final l = 0.299 * r + 0.587 * g + 0.114 * b;
          d[i] = _clamp255(l + (r - l) * 1.35);
          d[i + 1] = _clamp255(l + (g - l) * 1.35);
          d[i + 2] = _clamp255(l + (b - l) * 1.35);
        }
      }
    case ScanFilter.gray:
      final lum = Uint8List(n);
      final hist = List<int>.filled(256, 0);
      for (var i = 0, j = 0; j < n; i += 4, j++) {
        final l = (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8;
        lum[j] = l;
        hist[l]++;
      }
      final (lo, hi) = _percentiles(hist, n, 0.01, 0.99);
      final s = 255 / (hi - lo);
      for (var i = 0, j = 0; j < n; i += 4, j++) {
        final v = _clamp255((lum[j] - lo) * s);
        d[i] = v;
        d[i + 1] = v;
        d[i + 2] = v;
      }
    case ScanFilter.photo:
      final hs = List.generate(3, (_) => List<int>.filled(256, 0));
      for (var i = 0; i < d.length; i += 4) {
        hs[0][d[i]]++;
        hs[1][d[i + 1]]++;
        hs[2][d[i + 2]]++;
      }
      final lv = [for (final h in hs) _percentiles(h, n, 0.005, 0.995)];
      for (var i = 0; i < d.length; i += 4) {
        final r = (d[i] - lv[0].$1) * 255 / (lv[0].$2 - lv[0].$1);
        final g = (d[i + 1] - lv[1].$1) * 255 / (lv[1].$2 - lv[1].$1);
        final b = (d[i + 2] - lv[2].$1) * 255 / (lv[2].$2 - lv[2].$1);
        final l = 0.299 * r + 0.587 * g + 0.114 * b;
        d[i] = _clamp255(l + (r - l) * 1.12);
        d[i + 1] = _clamp255(l + (g - l) * 1.12);
        d[i + 2] = _clamp255(l + (b - l) * 1.12);
      }
    case ScanFilter.original:
      break;
  }
  return p.toImage();
}
