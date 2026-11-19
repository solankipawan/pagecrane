import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfit/features/pdf_tools/domain/pdf_builder.dart';
import 'package:pdfit/features/scanner/domain/page_pipeline.dart';

void main() {
  const a4 = 841.89 / 595.28;

  img.Image page(int w, int h) {
    final im = img.Image(width: w, height: h);
    img.fill(im, color: img.ColorRgb8(30, 60, 200)); // blue, so margins show
    return im;
  }

  img.Image run(img.Image src, {required bool fill}) => img.decodeJpg(
    fitToPaper((src: img.encodeJpg(src), ratio: a4, fill: fill)),
  )!;

  group('fitToPaper', () {
    test('fit keeps the whole page and adds white margins', () {
      final out = run(page(1000, 1000), fill: false);
      expect(out.height / out.width, closeTo(a4, 0.01));
      expect(out.width, 1000); // nothing scaled away
      expect(out.getPixel(out.width ~/ 2, 3).r, greaterThan(240)); // margin
      expect(out.getPixel(out.width ~/ 2, out.height ~/ 2).b, greaterThan(150));
    });

    test('fill trims the overflow so no margins appear', () {
      final out = run(page(1000, 2000), fill: true);
      expect(out.height / out.width, closeTo(a4, 0.01));
      expect(out.getPixel(2, 2).b, greaterThan(150)); // edge is page, not white
    });

    test('landscape pages get landscape paper', () {
      final out = run(page(2000, 1000), fill: false);
      expect(out.width / out.height, closeTo(a4, 0.01));
    });
  });

  test('pageWidthFor gives exact paper widths, else A4 width', () {
    expect(pageWidthFor(2000, 2000 * a4), closeTo(595.28, 0.01));
    expect(pageWidthFor(850, 1100), 612); // Letter
    expect(pageWidthFor(1100, 850), 792); // Letter landscape
    expect(pageWidthFor(850, 1400), 612); // Legal
    expect(pageWidthFor(1000, 1600), 595); // not a paper shape: unchanged
  });
}
