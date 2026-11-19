import 'package:flutter/foundation.dart' show compute;

import 'dart:math' as math;
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

  Future<void> toggleStar(String id) =>
      _update(id, (d) => d.copyWith(starred: !d.starred));

  Future<void> rename(String id, String name) =>
      _update(id, (d) => d.copyWith(name: name, updatedAt: DateTime.now()));

  /// Index + the document's own meta.json (so a rebuilt index keeps the change).
  Future<void> _update(String id, StoredDoc Function(StoredDoc) f) async {
    final next = [for (final d in _docs) d.id == id ? f(d) : d];
    await _commit(next);
    final d = next.where((d) => d.id == id).firstOrNull;
    if (d != null) await _repo.writeMeta(d);
  }

  /// Merge = concatenate the source documents' pages, in the given order.
  /// Rewrites document [id] with its pages in [order] (old 0-based indices).
  Future<void> reorderPages(String id, List<int> order) async {
    final d = byId(id)!;
    final pages = await _repo.readPages(d);
    final updated = await _repo.replacePages(d, [
      for (final i in order) pages[i],
    ]);
    for (final f in [..._repo.pagesOf(updated), _repo.thumbOf(d.id)]) {
      FileImage(f).evict(); // same paths, new pixels
    }
    await _commit([updated, ..._docs.where((x) => x.id != id)]);
  }

  /// Reshapes every page of [id] to paper proportions [ratio] (h/w, portrait),
  /// fitting with white margins or filling (see [fitToPaper]), then rebuilds the PDF.
  Future<void> resizePages(
    String id, {
    required double ratio,
    required bool fill,
    void Function(double)? onProgress,
  }) async {
    final d = byId(id)!;
    final pages = await _repo.readPages(d);
    final out = <Uint8List>[];
    for (var i = 0; i < pages.length; i++) {
      out.add(
        await compute(fitToPaper, (src: pages[i], ratio: ratio, fill: fill)),
      );
      onProgress?.call((i + 1) / pages.length);
    }
    final updated = await _repo.replacePages(d, out);
    for (final f in [..._repo.pagesOf(updated), _repo.thumbOf(d.id)]) {
      FileImage(f).evict(); // same paths, new pixels
    }
    await _commit([updated, ..._docs.where((x) => x.id != id)]);
  }

  /// The page images of a stored document (for merging with outside PDFs).
  Future<List<Uint8List>> pagesOf(String id) => _repo.readPages(byId(id)!);

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
    final out = await _reencodeAll(
      pages,
      level.quality,
      level.scale,
      onProgress,
    );
    return _keepIfSmaller(d, pages, out);
  }

  /// Plans a "fit under [targetBytes]" re-encode from a page-1 sample (see
  /// [planForTarget]); used for the live estimate.
  Future<({int quality, double scale, int estimate, bool fits})> planTarget(
    String id,
    int targetBytes,
  ) async {
    final d = byId(id)!;
    final first = await _repo.pageOf(d.id, 0).readAsBytes();
    return compute(planForTarget, (
      page: first,
      pages: d.pageCount,
      target: targetBytes,
    ));
  }

  /// Compresses so the PDF fits under [targetBytes]. Starts from the page-1 plan,
  /// then checks the real total and tightens up to twice if pages turned out
  /// heavier than the sample. Always re-encodes from the original pages.
  Future<({int before, int after, bool reached})> compressToTarget(
    String id,
    int targetBytes, {
    void Function(double)? onProgress,
  }) async {
    final d = byId(id)!;
    final pages = await _repo.readPages(d);
    final plan = await compute(planForTarget, (
      page: pages.first,
      pages: pages.length,
      target: targetBytes,
    ));
    var q = plan.quality;
    var s = plan.scale;
    const passes = 3;
    late List<Uint8List> out;
    for (var pass = 0; pass < passes; pass++) {
      out = await _reencodeAll(pages, q, s, (v) {
        onProgress?.call((pass + v) / passes);
      });
      final total = out.fold(0, (a, b) => a + b.length);
      final est = total + 1200 + pages.length * 400;
      if (est <= targetBytes) break;
      // Bytes scale roughly with pixel count: shrink by the square root of the gap.
      s = math.max(0.12, s * math.sqrt(targetBytes / est) * 0.95);
      q = math.max(30, q - 6);
    }
    onProgress?.call(1);
    final r = await _keepIfSmaller(d, pages, out);
    return (before: r.before, after: r.after, reached: r.after <= targetBytes);
  }

  Future<List<Uint8List>> _reencodeAll(
    List<Uint8List> pages,
    int quality,
    double scale,
    void Function(double)? onProgress,
  ) async {
    final out = <Uint8List>[];
    for (var i = 0; i < pages.length; i++) {
      out.add(
        await compute(reencode, (
          src: pages[i],
          scale: scale,
          quality: quality,
        )),
      );
      onProgress?.call((i + 1) / pages.length);
    }
    return out;
  }

  Future<({int before, int after})> _keepIfSmaller(
    StoredDoc d,
    List<Uint8List> before,
    List<Uint8List> after,
  ) async {
    final oldBytes = before.fold(0, (a, b) => a + b.length);
    final newBytes = after.fold(0, (a, b) => a + b.length);
    if (newBytes >= oldBytes) return (before: d.sizeBytes, after: d.sizeBytes);
    final updated = await _repo.replacePages(d, after);
    for (final f in [..._repo.pagesOf(updated), _repo.thumbOf(d.id)]) {
      FileImage(f).evict(); // same paths, new pixels
    }
    await _commit([updated, ..._docs.where((x) => x.id != d.id)]);
    return (before: d.sizeBytes, after: updated.sizeBytes);
  }
}

final documentsProvider =
    AsyncNotifierProvider<DocumentsNotifier, List<StoredDoc>>(
      DocumentsNotifier.new,
    );
