import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfit/features/documents/data/doc_repository.dart';

Uint8List _page([int shade = 200]) {
  final im = img.Image(width: 60, height: 80);
  img.fill(im, color: img.ColorRgb8(shade, shade, shade));
  return img.encodeJpg(im);
}

void main() {
  late Directory root;
  late DocRepository repo;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pagecrane_repo_');
    repo = DocRepository(root);
  });
  tearDown(() {
    if (root.existsSync()) {
      Process.runSync('chmod', ['-R', 'u+w', root.path]);
      root.deleteSync(recursive: true);
    }
  });

  Future<String> saved(String name, int pages) async {
    final d = await repo.create(
      name: name,
      folder: 'Scans',
      pages: [for (var i = 0; i < pages; i++) _page()],
    );
    await repo.load(); // adopts the new folder into the index, like a relaunch
    return d.id;
  }

  String metaPath(String dir) => '${root.path}/$dir/meta.json';
  Map<String, Object?> meta(String dir) =>
      (jsonDecode(File(metaPath(dir)).readAsStringSync()) as Map)
          .cast<String, Object?>();
  List<String> entries() =>
      root
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList()
        ..sort();

  test(
    'create writes a complete folder with meta.json and no leftovers',
    () async {
      final id = await saved('Tax', 2);
      final docs = await repo.load();
      expect(docs.single.pageCount, 2);
      expect(meta(id)['name'], 'Tax');
      expect(File('${root.path}/$id/document.pdf').existsSync(), isTrue);
      expect(entries().where((e) => e.startsWith('.')), isEmpty);
    },
  );

  test('replacePages swaps contents and leaves no staging behind', () async {
    final id = await saved('Tax', 3);
    final doc = (await repo.load()).single;
    final next = await repo.replacePages(doc, [_page(10)]);
    expect(next.pageCount, 1);
    expect(File('${root.path}/$id/page_002.jpg').existsSync(), isFalse);
    expect(entries().where((e) => e.startsWith('.')), isEmpty);
  });

  test('kill after the original moved aside: complete staging is swapped in '
      'and the index is reconciled', () async {
    final id = await saved('Tax', 3);
    // Simulate: staging fully written (meta last) with 1 page, live → .old, then kill.
    final live = Directory('${root.path}/$id');
    final staging = Directory('${root.path}/.staging-$id')..createSync();
    for (final f in live.listSync().whereType<File>()) {
      if (!f.path.endsWith('meta.json')) {
        f.copySync('${staging.path}/${f.uri.pathSegments.last}');
      }
    }
    final m = meta(id)
      ..['pageCount'] = 1
      ..['sizeBytes'] = 123
      ..['updatedAt'] = DateTime.now()
          .add(const Duration(minutes: 1))
          .toIso8601String();
    File('${staging.path}/meta.json').writeAsStringSync(jsonEncode(m));
    live.renameSync('${root.path}/.old-$id');

    final docs = await repo.load();
    expect(docs.single.pageCount, 1, reason: 'new contents adopted');
    expect(docs.single.sizeBytes, 123);
    expect(Directory('${root.path}/$id').existsSync(), isTrue);
    expect(entries().where((e) => e.startsWith('.')), isEmpty);
  });

  test(
    'kill while staging was still being written: original restored',
    () async {
      final id = await saved('Tax', 3);
      Directory('${root.path}/.staging-$id').createSync(); // no meta.json yet
      Directory('${root.path}/$id').renameSync('${root.path}/.old-$id');

      final docs = await repo.load();
      expect(docs.single.pageCount, 3);
      expect(File('${root.path}/$id/page_002.jpg').existsSync(), isTrue);
      expect(entries().where((e) => e.startsWith('.')), isEmpty);
    },
  );

  test('saved but not indexed (kill before index write) is adopted', () async {
    final doc = await repo.create(
      name: 'Receipt',
      folder: 'Scans',
      pages: [_page()],
    );
    // No saveIndex: the app died right after the folder appeared.
    final docs = await repo.load();
    expect(docs.map((d) => d.id), [doc.id]);
    expect(docs.single.name, 'Receipt');
  });

  test(
    'corrupt index is rebuilt from the folders, with current names',
    () async {
      final id = await saved('Old name', 1);
      final d = (await repo.load()).single;
      await repo.writeMeta(d.copyWith(name: 'New name', starred: true));
      File('${root.path}/index.json').writeAsStringSync('{not json');

      final docs = await repo.load();
      expect(docs.single.id, id);
      expect(docs.single.name, 'New name');
      expect(docs.single.starred, isTrue);
    },
  );

  test(
    'half-finished delete is completed; dangling index entries dropped',
    () async {
      final a = await saved('A', 1);
      final b = await saved('B', 1);
      Directory('${root.path}/$a').renameSync('${root.path}/.trash-$a');
      final docs = await repo.load();
      expect(docs.map((d) => d.id), [b]);
      expect(entries().where((e) => e.startsWith('.')), isEmpty);
    },
  );

  test(
    'a failed write raises StorageException and leaves no partial folder',
    () async {
      Process.runSync('chmod', [
        'u-w',
        root.path,
      ]); // like a full / read-only disk
      await expectLater(
        repo.create(name: 'X', folder: 'Scans', pages: [_page()]),
        throwsA(isA<StorageException>()),
      );
      Process.runSync('chmod', ['u+w', root.path]);
      expect(entries(), isEmpty);
    },
  );

  test('saving zero pages is refused, not a crash', () async {
    await expectLater(
      repo.create(name: 'Empty', folder: 'Scans', pages: const []),
      throwsA(isA<StorageException>()),
    );
  });
}
