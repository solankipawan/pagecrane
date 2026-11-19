import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfit/features/scanner/domain/page_pipeline.dart';

/// A noisy 1600×2200 "scan" so JPEG sizes behave like a real page.
Uint8List _page() {
  final im = img.Image(width: 1600, height: 2200);
  final r = math.Random(7);
  for (final p in im) {
    final v = 225 + r.nextInt(25);
    p
      ..r = v
      ..g = v
      ..b = v - 4;
  }
  for (var y = 200; y < 2000; y += 46) {
    img.fillRect(
      im,
      x1: 160,
      y1: y,
      x2: 1440 - (y * 13) % 400,
      y2: y + 14,
      color: img.ColorRgb8(40, 42, 50),
    );
  }
  return img.encodeJpg(im, quality: 92);
}

void main() {
  final page = _page();
  final full = estimatePdfBytes(page.length, 7);

  test('plans a re-encode under a reachable target with margin', () {
    final target = (full * 0.3).round();
    final p = planForTarget((page: page, pages: 7, target: target));
    expect(p.fits, isTrue);
    expect(p.estimate, lessThanOrEqualTo((target * 0.92).floor()));
    expect(p.quality, inInclusiveRange(30, 88));
  });

  test('keeps full resolution when the target is generous', () {
    final p = planForTarget((
      page: page,
      pages: 7,
      target: (full * 0.8).round(),
    ));
    expect(p.fits, isTrue);
    expect(p.scale, 1.0);
  });

  test('reports an unreachable target with the smallest possible size', () {
    final p = planForTarget((page: page, pages: 7, target: 5000));
    expect(p.fits, isFalse);
    expect(p.estimate, greaterThan(5000));
  });
}
