import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfit/features/scanner/domain/live_detect.dart';
import 'package:pdfit/features/scanner/domain/page_pipeline.dart';

Uint8List _frame(int w, int h, bool Function(int x, int y) bright) {
  final b = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      b[y * w + x] = bright(x, y) ? 225 : 40;
    }
  }
  return b;
}

void main() {
  group('uprightLuma', () {
    test('rotates a landscape sensor frame 90° clockwise to portrait', () {
      // Bright block in the sensor's top-left corner.
      final y = _frame(400, 200, (x, y) => x < 100 && y < 50);
      final l = uprightLuma(y, 400, 200, 400, 90, shortSide: 50);
      expect(l.w < l.h, isTrue, reason: 'portrait output');
      // Sensor top-left ends up at the upright top-right.
      expect(l.g[l.w - 1], greaterThan(200));
      expect(l.g[0], lessThan(60));
      expect(l.g[(l.h - 1) * l.w], lessThan(60));
    });

    test('honours row stride padding', () {
      const w = 64, h = 32, stride = 80;
      final y = Uint8List(stride * h)..fillRange(0, stride * h, 255);
      for (var r = 0; r < h; r++) {
        y.fillRange(r * stride, r * stride + w, 50); // padding stays 255
      }
      final l = uprightLuma(y, w, h, stride, 0, shortSide: 16);
      expect(l.g.every((v) => v == 50), isTrue);
    });
  });

  test('detectNormalized finds a sheet and returns 0..1 corners', () {
    const w = 120, h = 200;
    final g = _frame(w, h, (x, y) => x >= 30 && x < 90 && y >= 40 && y < 160);
    final q = detectNormalized((g: g, w: w, h: h));
    expect(q, isNotNull);
    final (tlx, tly) = q![0];
    final (brx, bry) = q[2];
    expect(tlx, closeTo(30 / w, 0.02));
    expect(tly, closeTo(40 / h, 0.02));
    expect(brx, closeTo(90 / w, 0.02));
    expect(bry, closeTo(160 / h, 0.02));
  });

  group('open notebook', () {
    // Wide frame, two pages joined by a shadowed (but still light) gutter.
    const w = 200, h = 120;
    Uint8List spread() {
      final b = Uint8List(w * h)..fillRange(0, w * h, 40);
      for (var y = 10; y < 110; y++) {
        for (var x = 10; x < 190; x++) {
          b[y * w + x] = (x >= 86 && x < 92) ? 150 : 225;
        }
      }
      return b;
    }

    test('keeps only the page under the frame centre', () {
      final q = detectNormalized((g: spread(), w: w, h: h))!;
      // Centre (x=100) is on the right page: x 92..190.
      expect(q[0].$1, greaterThan(90 / w));
      expect(q[3].$1, greaterThan(90 / w));
      expect(q[1].$1, closeTo(190 / w, 0.02));
    });

    test('a single page with no gutter is not split', () {
      final g = _frame(
        w,
        h,
        (x, y) => x >= 30 && x < 170 && y >= 10 && y < 110,
      );
      final q = detectNormalized((g: g, w: w, h: h))!;
      expect(q[0].$1, closeTo(30 / w, 0.02));
      expect(q[1].$1, closeTo(170 / w, 0.02));
    });
  });

  test('plausibleQuad rejects twisted and skinny outlines', () {
    const rect = [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8)];
    const bowTie = [(0.2, 0.2), (0.8, 0.8), (0.8, 0.2), (0.2, 0.8)];
    const sliver = [(0.1, 0.5), (0.9, 0.5), (0.9, 0.52), (0.1, 0.52)];
    const sheared = [(0.1, 0.4), (0.5, 0.4), (0.95, 0.6), (0.55, 0.6)];
    expect(plausibleQuad(rect, 9 / 16), isTrue);
    expect(plausibleQuad(bowTie, 9 / 16), isFalse);
    expect(plausibleQuad(sliver, 9 / 16), isFalse);
    expect(plausibleQuad(sheared, 9 / 16), isFalse);
  });

  test('cropPage re-cuts from the original; null corners = whole photo', () {
    final photo = img.Image(width: 400, height: 600);
    img.fill(photo, color: img.ColorRgb8(240, 240, 240));
    final original = img.encodeJpg(photo);
    final whole = cropPage((original: original, corners: null));
    expect(identical(whole, original), isTrue);
    final half = img.decodeJpg(
      cropPage((
        original: original,
        corners: const [(0, 0), (0.5, 0), (0.5, 1), (0, 1)],
      )),
    )!;
    expect(half.width / half.height, closeTo(200 / 600, 0.02));
  });

  test('prepareCameraPhoto crops to the live outline when framing matches', () {
    // 900×1600 photo, sheet occupying x 0.2–0.8, y 0.25–0.75.
    final photo = img.Image(width: 900, height: 1600);
    img.fill(photo, color: img.ColorRgb8(50, 40, 35));
    img.fillRect(
      photo,
      x1: 180,
      y1: 400,
      x2: 720,
      y2: 1200,
      color: img.ColorRgb8(245, 245, 240),
    );
    final out = prepareCameraPhoto((
      bytes: img.encodeJpg(photo),
      hint: const [(0.2, 0.25), (0.8, 0.25), (0.8, 0.75), (0.2, 0.75)],
      hintAspect: 900 / 1600,
    ));
    expect(out.cropped, isTrue);
    final page = img.decodeJpg(out.jpeg)!;
    expect(page.width / page.height, closeTo(540 / 800, 0.02));
    // Corners are page, not desk.
    expect(page.getPixel(2, 2).r, greaterThan(200));
    expect(page.getPixel(page.width - 3, page.height - 3).r, greaterThan(200));
  });

  group('QuadTracker', () {
    const quad = [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8)];
    final t0 = DateTime(2026, 11, 19, 12);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    final page1 = _frame(40, 60, (x, y) => x > 8 && x < 32 && y > 8 && y < 52);
    final page2 = _frame(40, 60, (x, y) => (x + y).isEven);

    test('captures once the sheet holds still, then waits for a new page', () {
      final t = QuadTracker();
      for (var ms = 0; ms <= 1000; ms += 100) {
        t.update(quad, page1, at(ms));
      }
      expect(t.shouldCapture(at(1000)), isFalse);
      t.update(quad, page1, at(1200));
      expect(t.shouldCapture(at(1200)), isTrue);

      t.captured(page1);
      // Same page left in place: never shoots it again.
      for (var ms = 1300; ms <= 4000; ms += 100) {
        t.update(quad, page1, at(ms));
        expect(t.shouldCapture(at(ms)), isFalse);
      }
      // Page turned: same outline, different content → re-arms after the hold.
      t.update(quad, page2, at(4100));
      expect(t.shouldCapture(at(4100)), isFalse);
      for (var ms = 4200; ms <= 5300; ms += 100) {
        t.update(quad, page2, at(ms));
      }
      expect(t.shouldCapture(at(5300)), isTrue);
    });

    test('movement restarts the hold; brief misses keep the outline', () {
      final t = QuadTracker();
      t.update(quad, page1, at(0));
      t.update(quad, page1, at(900));
      const moved = [(0.3, 0.3), (0.9, 0.3), (0.9, 0.9), (0.3, 0.9)];
      t.update(moved, page1, at(1000));
      expect(t.progress(at(1100)), lessThan(0.2));

      t.update(null, page1, at(1200));
      expect(t.quad, isNotNull, reason: 'one missed frame keeps the outline');
      t.update(null, page1, at(1300));
      t.update(null, page1, at(1400));
      expect(t.quad, isNull);
    });
  });
}
