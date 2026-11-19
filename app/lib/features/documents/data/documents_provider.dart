import 'package:flutter/foundation.dart' show compute;

import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pdf_tools/domain/compression.dart';
import '../../pdf_tools/domain/page_ranges.dart';
import '../../scanner/domain/page_pipeline.dart';
import 'doc_repository.dart';
import 'stored_doc.dart';

final repoProvider = FutureProvider<DocRepository>(
  (ref) => DocRepository.open(),
);

/// The document library. All mutations persist `index.json` immediately.
class DocumentsNotifier extends AsyncNotifier<List<StoredDoc>> {
  late DocRepository _repo;

  @override
  Future<List<StoredDoc>> build() async {
    _repo = await ref.watch(repoProvider.future);
    final docs = await _repo.load();
    docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return docs;
  }

  List<StoredDoc> get _docs => switch (state) {
    AsyncData(:final value) => value,
    _ => const [],
  };

  StoredDoc? byId(String id) => _docs.where((d) => d.id == id).firstOrNull;

  Future<void> _commit(List<StoredDoc> next) async {
    state = AsyncData(next);
    await _repo.saveIndex(next);
  }

  Future<StoredDoc> add({
    required String name,
    required String folder,
    required List<Uint8List> pages,
  }) async {
    final doc = await _repo.create(name: name, folder: folder, pages: pages);
    await _commit([doc, ..._docs]);
    return doc;
  }

  Future<void> remove(String id) async {
    await _commit([..._docs.where((d) => d.id != id)]);
    await _repo.delete(id);
  }

  Future<void> toggleStar(String id) => _commit([
    for (final d in _docs) d.id == id ? d.copyWith(starred: !d.starred) : d,
  ]);

  Future<void> rename(String id, String name) => _commit([
    for (final d in _docs)
      d.id == id ? d.copyWith(name: name, updatedAt: DateTime.now()) : d,
  ]);

  /// Merge = concatenate the source documents' pages, in the given order.
  Future<StoredDoc> merge(List<String> ids, String name) async {
    final sources = [for (final id in ids) byId(id)!];
    final pages = <Uint8List>[
      for (final d in sources) ...await _repo.readPages(d),
    ];
    return add(name: name, folder: sources.first.folder, pages: pages);
  }

  /// Split: one new document per group of 0-based page indices. The original is kept.
  Future<List<StoredDoc>> split(String id, List<List<int>> groups) async {
    final d = byId(id)!;
    final pages = await _repo.readPages(d);
    final created = <StoredDoc>[];
    for (final g in groups) {
      created.add(
        await _repo.create(
          name: '${d.name} · p${formatPageRanges(g)}',
          folder: d.folder,
          pages: [for (final i in g) pages[i]],
        ),
      );
    }
    await _commit([...created.reversed, ..._docs]);
    return created;
  }

  /// Replaces individual pages (e.g. after flattening annotations) and rebuilds the PDF.
  Future<StoredDoc> updatePages(String id, Map<int, Uint8List> changed) async {
    final d = byId(id)!;
    final pages = await _repo.readPages(d);
    changed.forEach((i, bytes) => pages[i] = bytes);
    final updated = await _repo.replacePages(d, pages);
    for (final f in [..._repo.pagesOf(updated), _repo.thumbOf(d.id)]) {
      FileImage(f).evict();
    }
    await _commit([updated, ..._docs.where((x) => x.id != id)]);
    return updated;
  }

  /// Sampling estimate: re-encode page 1 at [level], scale by page count.
  Future<int> estimate(String id, CompressLevel level) async {
    final d = byId(id)!;
    final first = await _repo.pageOf(d.id, 0).readAsBytes();
    final out = await compute(reencode, (
      src: first,
      scale: level.scale,
      quality: level.quality,
    ));
    final est = out.length * d.pageCount + 1200 + d.pageCount * 400;
    return est < d.sizeBytes ? est : d.sizeBytes;
  }

  /// Re-encodes every page and rebuilds the PDF. Keeps the original if the result isn't smaller.
  Future<({int before, int after})> compress(
    String id,
    CompressLevel level, {
    void Function(double)? onProgress,
  }) async {
    final d = byId(id)!;
    final pages = await _repo.readPages(d);
    final out = <Uint8List>[];
    for (var i = 0; i < pages.length; i++) {
      final src = pages[i];
      out.add(
        await compute(reencode, (
          src: src,
          scale: level.scale,
          quality: level.quality,
        )),
      );
      onProgress?.call((i + 1) / pages.length);
    }
    final updated = await _repo.replacePages(d, out);
    for (final f in [..._repo.pagesOf(updated), _repo.thumbOf(d.id)]) {
      FileImage(f).evict(); // same paths, new pixels
    }
    await _commit([updated, ..._docs.where((x) => x.id != id)]);
    return (before: d.sizeBytes, after: updated.sizeBytes);
  }
}

final documentsProvider =
    AsyncNotifierProvider<DocumentsNotifier, List<StoredDoc>>(
      DocumentsNotifier.new,
    );
