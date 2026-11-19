import 'package:flutter/foundation.dart' show compute;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../pdf_tools/domain/pdf_builder.dart';
import '../../scanner/domain/page_pipeline.dart';
import 'stored_doc.dart';

/// A save failed (usually: the device is out of space). [message] is user-facing.
class StorageException implements Exception {
  const StorageException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  /// ENOSPC is 28 on both iOS (Darwin) and Android (Linux).
  static StorageException from(Object e) =>
      e is FileSystemException && e.osError?.errorCode == 28
      ? StorageException(
          'Not enough free space on this device. Free up some space and try again.',
          e,
        )
      : StorageException('Couldn’t save the document. Please try again.', e);

  @override
  String toString() => 'StorageException: $message ($cause)';
}

/// Sandbox file store: `<AppDocuments>/PDFit/index.json` + one folder per doc
/// (`page_000.jpg…`, `thumb.jpg`, `document.pdf`, `meta.json`).
/// Nothing leaves the device unless the user shares it.
///
/// **Crash safety.** A document folder is never edited in place. New contents are
/// written to `.staging-<id>/` with `meta.json` last (its presence marks the
/// staging complete), then swapped in by renaming; deletes go through
/// `.trash-<id>/`. On launch [load] finishes or rolls back any half-done swap and
/// reconciles `index.json` with each folder's `meta.json`, so a kill or a full disk
/// at any point leaves every document either fully old or fully new.
///
/// The folder keeps the working name "PDFit" on purpose: it is never shown to users,
/// and renaming it to "Pagecrane" would hide every document saved by earlier builds.
class DocRepository {
  DocRepository(this.root);
  final Directory root;

  static Future<DocRepository> open() async {
    final base = await getApplicationDocumentsDirectory();
    final root = Directory('${base.path}/PDFit');
    await root.create(recursive: true);
    return DocRepository(root);
  }

  File get _index => File('${root.path}/index.json');
  Directory dirOf(String id) => Directory('${root.path}/$id');
  Directory _staging(String id) => Directory('${root.path}/.staging-$id');
  Directory _old(String id) => Directory('${root.path}/.old-$id');
  Directory _trash(String id) => Directory('${root.path}/.trash-$id');
  File pdfOf(String id) => File('${dirOf(id).path}/document.pdf');
  File thumbOf(String id) => File('${dirOf(id).path}/thumb.jpg');
  File _metaIn(Directory d) => File('${d.path}/meta.json');
  File pageOf(String id, int i) =>
      File('${dirOf(id).path}/page_${i.toString().padLeft(3, '0')}.jpg');
  List<File> pagesOf(StoredDoc d) => [
    for (var i = 0; i < d.pageCount; i++) pageOf(d.id, i),
  ];

  // ---- index -------------------------------------------------------------------

  /// Loads the library, first repairing anything an interrupted write left behind.
  Future<List<StoredDoc>> load() async {
    await _recover();
    final metas = <String, StoredDoc>{};
    final noMeta = <String>{};
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final id = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (id.startsWith('.')) continue;
      final m = await _readMeta(e);
      if (m == null) {
        noMeta.add(id);
      } else {
        metas[id] = m;
      }
    }

    final indexed = await _readIndex();
    var changed = false;
    final List<StoredDoc> docs;
    if (indexed == null) {
      // Missing or corrupt index: rebuild from the folders.
      docs = [...metas.values];
      changed = docs.isNotEmpty || await _index.exists();
    } else {
      docs = [];
      final seen = <String>{};
      for (final d in indexed) {
        if (!metas.containsKey(d.id) && !noMeta.contains(d.id)) {
          changed = true; // folder gone: drop the dangling entry
          continue;
        }
        seen.add(d.id);
        final m = metas[d.id];
        if (m != null &&
            m.updatedAt.isAfter(d.updatedAt) &&
            (m.pageCount != d.pageCount || m.sizeBytes != d.sizeBytes)) {
          // Contents were swapped in but the index write didn't happen.
          docs.add(
            d.copyWith(
              pageCount: m.pageCount,
              sizeBytes: m.sizeBytes,
              updatedAt: m.updatedAt,
            ),
          );
          changed = true;
        } else {
          docs.add(d);
          // Older builds wrote no meta.json: add one so the index can be rebuilt.
          if (m == null) await _tryWriteMeta(dirOf(d.id), d);
        }
      }
      for (final m in metas.values) {
        if (!seen.contains(m.id)) {
          docs.add(m); // saved, but the app died before indexing it
          changed = true;
        }
      }
    }
    if (changed) await saveIndex(docs);
    return docs;
  }

  Future<List<StoredDoc>?> _readIndex() async {
    if (!await _index.exists()) return null;
    try {
      final list = jsonDecode(await _index.readAsString()) as List<Object?>;
      return [
        for (final j in list)
          StoredDoc.fromJson((j! as Map).cast<String, Object?>()),
      ];
    } catch (_) {
      return null; // corrupt index: rebuilt from meta.json files
    }
  }

  Future<void> saveIndex(List<StoredDoc> docs) async {
    try {
      await _writeAtomically(
        _index,
        utf8.encode(jsonEncode([for (final d in docs) d.toJson()])),
      );
    } catch (e) {
      throw StorageException.from(e);
    }
  }

  /// Keeps a document's own metadata (name, star…) in step with the index, so a
  /// rebuilt index shows current names. Best effort.
  Future<void> writeMeta(StoredDoc d) => _tryWriteMeta(dirOf(d.id), d);

  // ---- documents ---------------------------------------------------------------

  /// Writes pages + thumbnail + PDF for a new document.
  Future<StoredDoc> create({
    required String name,
    required String folder,
    required List<Uint8List> pages,
  }) async {
    if (pages.isEmpty) {
      throw const StorageException('There are no pages to save.');
    }
    final now = DateTime.now();
    final id = 'd${now.microsecondsSinceEpoch}';
    final doc = StoredDoc(
      id: id,
      name: name,
      folder: folder,
      createdAt: now,
      updatedAt: now,
      pageCount: pages.length,
      sizeBytes: 0,
    );
    final staging = _staging(id);
    final size = await _build(staging, doc, pages);
    try {
      await staging.rename(dirOf(id).path);
    } catch (e) {
      await _tryDelete(staging);
      throw StorageException.from(e);
    }
    return doc.copyWith(sizeBytes: size);
  }

  /// Replaces all pages of [doc] (Compress, Resize, Reorder, Annotate…) and rebuilds
  /// its PDF. The live folder is only touched by renames once everything is written.
  Future<StoredDoc> replacePages(StoredDoc doc, List<Uint8List> pages) async {
    if (pages.isEmpty) {
      throw const StorageException('There are no pages to save.');
    }
    final next = doc.copyWith(
      pageCount: pages.length,
      updatedAt: DateTime.now(),
    );
    final staging = _staging(doc.id);
    final size = await _build(staging, next, pages);
    final live = dirOf(doc.id), old = _old(doc.id);
    try {
      await _tryDelete(old);
      if (await live.exists()) await live.rename(old.path);
      await staging.rename(live.path);
    } catch (e) {
      // Put the original back if it was moved aside.
      if (!await live.exists() && await old.exists()) {
        await old.rename(live.path);
      }
      await _tryDelete(staging);
      throw StorageException.from(e);
    }
    await _tryDelete(old);
    return next.copyWith(sizeBytes: size);
  }

  Future<List<Uint8List>> readPages(StoredDoc d) =>
      Future.wait([for (final f in pagesOf(d)) f.readAsBytes()]);

  Future<void> delete(String id) async {
    final d = dirOf(id), t = _trash(id);
    if (!await d.exists()) return;
    await _tryDelete(t);
    await d.rename(
      t.path,
    ); // gone from the library at once, even if the wipe stops
    await _tryDelete(t);
  }

  // ---- internals ---------------------------------------------------------------

  /// Writes a complete document folder at [dir]; `meta.json` goes last.
  Future<int> _build(
    Directory dir,
    StoredDoc doc,
    List<Uint8List> pages,
  ) async {
    try {
      await _tryDelete(dir);
      await dir.create(recursive: true);
      for (var i = 0; i < pages.length; i++) {
        final name = 'page_${i.toString().padLeft(3, '0')}.jpg';
        await File('${dir.path}/$name').writeAsBytes(pages[i], flush: true);
      }
      final thumb = await compute(makeThumb, pages.first);
      await File('${dir.path}/thumb.jpg').writeAsBytes(thumb, flush: true);
      final pdf = await compute(buildPdf, pages);
      await File('${dir.path}/document.pdf').writeAsBytes(pdf, flush: true);
      await _writeAtomically(
        _metaIn(dir),
        utf8.encode(jsonEncode(doc.copyWith(sizeBytes: pdf.length).toJson())),
      );
      return pdf.length;
    } catch (e) {
      await _tryDelete(dir);
      throw e is StorageException ? e : StorageException.from(e);
    }
  }

  /// Finishes or rolls back swaps interrupted by a kill / crash.
  Future<void> _recover() async {
    final staging = <String>[], old = <String>[], trash = <Directory>[];
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('.staging-')) staging.add(name.substring(9));
      if (name.startsWith('.old-')) old.add(name.substring(5));
      if (name.startsWith('.trash-')) trash.add(e);
    }
    for (final t in trash) {
      await _tryDelete(t);
    }
    // A complete staging folder whose live folder is missing was mid-swap: finish it.
    for (final id in staging) {
      final s = _staging(id);
      if (!await dirOf(id).exists() && await _metaIn(s).exists()) {
        try {
          await s.rename(dirOf(id).path);
          continue;
        } catch (_) {}
      }
      await _tryDelete(s);
    }
    // The original moved aside: restore it if nothing replaced it, else drop it.
    for (final id in old) {
      final o = _old(id);
      if (await dirOf(id).exists()) {
        await _tryDelete(o);
      } else {
        try {
          await o.rename(dirOf(id).path);
        } catch (_) {}
      }
    }
    final tmp = File('${_index.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
  }

  Future<StoredDoc?> _readMeta(Directory dir) async {
    final f = _metaIn(dir);
    if (!await f.exists()) return null;
    try {
      return StoredDoc.fromJson(
        (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _tryWriteMeta(Directory dir, StoredDoc d) async {
    try {
      if (await dir.exists()) {
        await _writeAtomically(
          _metaIn(dir),
          utf8.encode(jsonEncode(d.toJson())),
        );
      }
    } catch (_) {}
  }

  static Future<void> _writeAtomically(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> _tryDelete(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}
