import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfit/features/annotate/domain/flatten.dart';
import 'package:pdfit/features/annotate/domain/marks.dart';
import 'package:pdfit/features/annotate/presentation/signature_pad.dart';
import 'package:pdfit/features/documents/data/doc_repository.dart';
import 'package:pdfit/features/documents/data/documents_provider.dart';
import 'package:pdfit/features/pdf_tools/domain/page_ranges.dart';

Uint8List whitePage(int w, int h, {int shade = 255}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(shade, shade, shade));
  return Uint8List.fromList(img.encodeJpg(im, quality: 95));
}

void main() {
  group('page ranges', () {
    test('parses lists, ranges and open ends', () {
      expect(parsePageRanges('1-3, 7', 10), [0, 1, 2, 6]);
      expect(parsePageRanges(' 9- ', 10), [8, 9]);
      expect(parsePageRanges('-2,2,2', 10), [0, 1]);
      expect(parsePageRanges('', 10), isEmpty);
    });

    test('rejects bad input', () {
      expect(() => parsePageRanges('0', 5), throwsFormatException);
      expect(() => parsePageRanges('4-2', 5), throwsFormatException);
      expect(() => parsePageRanges('6', 5), throwsFormatException);
      expect(() => parsePageRanges('abc', 5), throwsFormatException);
    });

    test('formats compactly and chunks', () {
      expect(formatPageRanges([0, 1, 2, 6]), '1-3, 7');
      expect(formatPageRanges([4]), '5');
      expect(chunkPages(5, 2), [
        [0, 1],
        [2, 3],
        [4],
      ]);
    });
  });

  test('split creates one document per group and keeps the original', () async {
    final dir = await Directory.systemTemp.createTemp('pdfit_split');
    addTearDown(() => dir.delete(recursive: true));
    final c = ProviderContainer(
      overrides: [repoProvider.overrideWith((ref) async => DocRepository(dir))],
    );
    addTearDown(c.dispose);
    await c.read(documentsProvider.future);
    final n = c.read(documentsProvider.notifier);

    final src = await n.add(
      name: 'Contract',
      folder: 'Legal',
      pages: [
        whitePage(60, 80, shade: 250),
        whitePage(60, 80, shade: 200),
        whitePage(60, 80, shade: 150),
      ],
    );
    final parts = await n.split(src.id, [
      [0],
      [1, 2],
    ]);

    expect(parts.map((d) => d.pageCount), [1, 2]);
    expect(parts.map((d) => d.name), ['Contract · p1', 'Contract · p2-3']);
    final docs = await c.read(documentsProvider.future);
    expect(docs.length, 3);
    expect(docs.firstWhere((d) => d.id == src.id).pageCount, 3);
    // The second part really holds original pages 2 and 3 (told apart by brightness).
    final repo = DocRepository(dir);
    final p = await repo.readPages(parts[1]);
    expect(img.decodeJpg(p[0])!.getPixel(30, 40).r, closeTo(200, 6));
    expect(img.decodeJpg(p[1])!.getPixel(30, 40).r, closeTo(150, 6));
    expect(
      String.fromCharCodes(
        (await repo.pdfOf(parts[1].id).readAsBytes()).take(5),
      ),
      '%PDF-',
    );
  });

  testWidgets('flatten burns ink, signature and highlight into the page', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final out = await flattenPage(whitePage(400, 600), const [
        InkMark(
          points: [Offset(0.1, 0.1), Offset(0.9, 0.1)],
          color: Color(0xFF000000),
          width: 0.02,
        ),
        SignatureMark(
          strokes: [
            [Offset(0, 0.5), Offset(1, 0.5)],
          ],
          box: Rect.fromLTWH(0.2, 0.6, 0.6, 0.2),
          color: Color(0xFF1F3FBF),
        ),
        InkMark(
          points: [Offset(0.1, 0.4), Offset(0.9, 0.4)],
          color: Color(0xFFFFD60A),
          width: 0.05,
          highlighter: true,
        ),
      ]);
      final im = img.decodeJpg(out)!;
      expect((im.width, im.height), (400, 600)); // full resolution kept
      expect(im.getPixel(200, 60).r, lessThan(60)); // black pen line at y = 0.1
      final sig = im.getPixel(200, 420); // signature line at (0.6 + 0.1) × 600
      expect(sig.b, greaterThan(sig.r + 40));
      final hl = im.getPixel(
        200,
        240,
      ); // translucent yellow: blue channel drops
      expect(hl.b, lessThan(hl.r - 40));
      expect(
        im.getPixel(200, 560).r,
        greaterThan(240),
      ); // untouched paper stays white
    });
  });

  test('signature normalizes to its bounding box and round-trips', () {
    final s = SignatureData.fromRaw([
      [const Offset(100, 50), const Offset(300, 90)],
      [const Offset(150, 70)],
    ])!;
    for (final p in s.strokes.expand((x) => x)) {
      expect(p.dx, inInclusiveRange(0, 1));
      expect(p.dy, inInclusiveRange(0, 1));
    }
    expect(s.aspect, lessThan(0.5)); // wide signature
    final back = SignatureData.fromJson(jsonEncodeSig(s));
    expect(back?.strokes.length, 2);
    expect(back!.aspect, closeTo(s.aspect, 1e-9));
    expect(SignatureData.fromJson('not json'), isNull);
  });
}

String jsonEncodeSig(SignatureData s) {
  final strokes = s.strokes
      .map((st) => '[${st.map((p) => '[${p.dx},${p.dy}]').join(',')}]')
      .join(',');
  return '{"aspect":${s.aspect},"strokes":[$strokes]}';
}
