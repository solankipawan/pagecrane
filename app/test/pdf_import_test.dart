import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfit/features/documents/data/pdf_import.dart';
import 'package:pdfit/features/pdf_tools/domain/pdf_builder.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  group('renderSize', () {
    test('A4 at 200 DPI', () {
      expect(PdfImporter.renderSize(595, 842), (1653, 2339));
    });

    test('long edge capped at 2400 px, aspect kept', () {
      final (w, h) = PdfImporter.renderSize(1190, 1684); // A2-ish
      expect(h, 2400);
      expect(w / h, closeTo(1190 / 1684, 0.002));
    });
  });

  test('BGRA pixels become a correctly coloured JPEG', () {
    // 2×1: pure blue, pure red — in BGRA byte order.
    final bgra = Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]);
    final out = img.decodeJpg(
      encodeBgraAsJpeg((bgra: bgra, w: 2, h: 1, quality: 100)),
    )!;
    expect(out.getPixel(0, 0).b, greaterThan(150));
    expect(out.getPixel(0, 0).r, lessThan(100));
    expect(out.getPixel(1, 0).r, greaterThan(150));
    expect(out.getPixel(1, 0).b, lessThan(100));
  });

  testWidgets('round trip: our PDF → PDFium → page JPEGs', (tester) async {
    // pdfrx asks path_provider for a cache dir; there is no plugin in unit tests.
    final tmp = Directory.systemTemp.createTempSync('pdfrx_test').path;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tmp,
    );
    await tester.runAsync(() async {
      // Two pages: dark grey and light grey, A4-ish aspect.
      Uint8List page(int v) {
        final im = img.Image(width: 300, height: 424);
        img.fill(im, color: img.ColorRgb8(v, v, v));
        return Uint8List.fromList(img.encodeJpg(im, quality: 95));
      }

      final pdf = await buildPdf([page(60), page(200)]);
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openData(pdf);
      expect(doc.pages.length, 2);
      final progress = <int>[];
      final pages = await PdfImporter.render(
        doc,
        onProgress: (d, _) => progress.add(d),
      );
      expect(progress, [1, 2]);
      final a = img.decodeJpg(pages[0])!, b = img.decodeJpg(pages[1])!;
      expect(a.width / a.height, closeTo(300 / 424, 0.01));
      expect(a.getPixel(a.width ~/ 2, a.height ~/ 2).r, closeTo(60, 12));
      expect(b.getPixel(b.width ~/ 2, b.height ~/ 2).r, closeTo(200, 12));
    });
  });
}
