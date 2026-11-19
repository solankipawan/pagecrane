import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfit/core/format.dart';
import 'package:pdfit/features/pdf_tools/domain/pdf_builder.dart';
import 'package:pdfit/features/scanner/domain/doc_detect.dart';
import 'package:pdfit/features/scanner/domain/filters.dart';
import 'package:pdfit/features/scanner/domain/page_pipeline.dart';

/// A white 400×560 "page" with dark text bars on a dark desk, plus a shadow gradient.
img.Image deskPhoto() {
  final im = img.Image(width: 800, height: 1000);
  img.fill(im, color: img.ColorRgb8(45, 32, 22));
  img.fillRect(
    im,
    x1: 200,
    y1: 220,
    x2: 599,
    y2: 779,
    color: img.ColorRgb8(240, 238, 230),
  );
  for (var y = 280; y < 740; y += 24) {
    img.fillRect(
      im,
      x1: 240,
      y1: y,
      x2: 240 + 200 + (y * 7) % 110,
      y2: y + 6,
      color: img.ColorRgb8(50, 54, 70),
    );
  }
  // uneven light across the page
  for (var y = 220; y < 780; y++) {
    for (var x = 200; x < 600; x++) {
      final p = im.getPixel(x, y);
      final k = 1 - 0.25 * ((x - 200) + (y - 220)) / 960;
      p
        ..r = p.r * k
        ..g = p.g * k
        ..b = p.b * k;
    }
  }
  return im;
}

void main() {
  group('fmtSize', () {
    test('decimal units, floor rounding', () {
      expect(fmtSize(999), '999 B');
      expect(fmtSize(99999), '99.9 KB'); // never rounds up past a limit
      expect(fmtSize(100000), '100 KB');
      expect(fmtSize(2480000), '2.4 MB');
    });
  });

  group('auto-crop', () {
    test('finds the page and warps to its size', () {
      final out = autoCrop(deskPhoto());
      expect(out, isNotNull);
      expect(out!.width, inInclusiveRange(380, 410));
      expect(out.height, inInclusiveRange(540, 570));
      // corners are paper, not desk
      expect(out.getPixel(3, 3).r, greaterThan(150));
      expect(out.getPixel(out.width - 4, out.height - 4).r, greaterThan(120));
    });

    test('returns null when there is no page', () {
      final flat = img.Image(width: 320, height: 400);
      img.fill(flat, color: img.ColorRgb8(90, 90, 90));
      expect(autoCrop(flat), isNull);
    });
  });

  group('filters', () {
    test('Magic Color flattens the shadow to white paper', () {
      final page = autoCrop(deskPhoto())!;
      final magic = applyFilter(page, ScanFilter.magic);
      final px = magic.getPixel(
        magic.width - 20,
        magic.height - 20,
      ); // darkest corner before
      expect(px.r, greaterThan(240));
    });

    test('B&W produces near-binary output', () {
      final bw = applyFilter(autoCrop(deskPhoto())!, ScanFilter.bw);
      var mid = 0;
      for (final p in bw) {
        if (p.r > 40 && p.r < 215) mid++;
      }
      expect(mid / (bw.width * bw.height), lessThan(0.05));
    });

    test('every filter keeps dimensions', () {
      final page = autoCrop(deskPhoto())!;
      for (final f in ScanFilter.values) {
        final out = applyFilter(page, f);
        expect(
          (out.width, out.height),
          (page.width, page.height),
          reason: f.name,
        );
      }
    });
  });

  test('compressToTarget lands under the limit', () {
    final rnd = Random(7);
    final noisy = img.Image(width: 1600, height: 1200);
    for (final p in noisy) {
      p
        ..r = rnd.nextInt(256)
        ..g = rnd.nextInt(256)
        ..b = rnd.nextInt(256);
    }
    final src = img.encodeJpg(noisy, quality: 95);
    final r = compressToTarget((src: src, targetBytes: 100000));
    expect(r, isNotNull);
    expect(r!.bytes.length, lessThanOrEqualTo(100000));
    expect(src.length, greaterThan(100000));
  });

  group('exportPage', () {
    final page = Uint8List.fromList(
      img.encodeJpg(autoCrop(deskPhoto())!, quality: 90),
    );

    test('JPG at original size and high quality returns the stored bytes untouched', () {
      expect(
        identical(
          exportPage((
            src: page,
            format: ExportFormat.jpg,
            quality: 95,
            maxDim: null,
          )),
          page,
        ),
        isTrue,
      );
    });

    test('PNG output is a real PNG with the same dimensions', () {
      final png = exportPage((
        src: page,
        format: ExportFormat.png,
        quality: 90,
        maxDim: null,
      ));
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final a = img.decodeJpg(page)!, b = img.decodePng(png)!;
      expect((b.width, b.height), (a.width, a.height));
    });

    test('max size caps the long edge and keeps aspect ratio', () {
      final out = img.decodeJpg(
        exportPage((
          src: page,
          format: ExportFormat.jpg,
          quality: 80,
          maxDim: 300,
        )),
      )!;
      final src = img.decodeJpg(page)!;
      expect(out.height, 300); // portrait page: height is the long edge
      expect(out.width / out.height, closeTo(src.width / src.height, 0.01));
    });
  });

  test('buildPdf writes one page per image', () async {
    final page = Uint8List.fromList(
      img.encodeJpg(autoCrop(deskPhoto())!, quality: 80),
    );
    final pdf = await buildPdf([page, page]);
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    expect(
      RegExp(r'/Type\s*/Page[^s]').allMatches(String.fromCharCodes(pdf)).length,
      2,
    );
  });
}
