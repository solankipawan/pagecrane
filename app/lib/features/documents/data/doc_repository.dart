import 'package:flutter/foundation.dart' show compute;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../pdf_tools/domain/pdf_builder.dart';
import '../../scanner/domain/page_pipeline.dart';
import 'stored_doc.dart';

/// Sandbox file store: `<AppDocuments>/PDFit/index.json` + one folder per doc.
/// Nothing leaves the device unless the user shares it.
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
  File pdfOf(String id) => File('${dirOf(id).path}/document.pdf');
  File thumbOf(String id) => File('${dirOf(id).path}/thumb.jpg');
  File pageOf(String id, int i) =>
      File('${dirOf(id).path}/page_${i.toString().padLeft(3, '0')}.jpg');
  List<File> pagesOf(StoredDoc d) => [
    for (var i = 0; i < d.pageCount; i++) pageOf(d.id, i),
  ];

  Future<List<StoredDoc>> load() async {
    if (!await _index.exists()) return [];
    try {
      final list = jsonDecode(await _index.readAsString()) as List<Object?>;
      return [
        for (final j in list)
          StoredDoc.fromJson((j! as Map).cast<String, Object?>()),
      ];
    } on FormatException {
      return []; // corrupt index: start clean rather than crash
    }
  }

  Future<void> saveIndex(List<StoredDoc> docs) async {
    final tmp = File('${_index.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final d in docs) d.toJson()]));
    await tmp.rename(_index.path); // atomic replace
  }

  /// Writes pages + thumbnail + PDF for a new document.
  Future<StoredDoc> create({
    required String name,
    required String folder,
    required List<Uint8List> pages,
  }) async {
    final now = DateTime.now();
    final id = 'd${now.microsecondsSinceEpoch}';
    await dirOf(id).create(recursive: true);
    final size = await _writeContents(id, pages);
    return StoredDoc(
      id: id,
      name: name,
      folder: folder,
      createdAt: now,
      updatedAt: now,
      pageCount: pages.length,
      sizeBytes: size,
    );
  }

  /// Replaces all pages of [doc] (used by Compress) and rebuilds its PDF.
  Future<StoredDoc> replacePages(StoredDoc doc, List<Uint8List> pages) async {
    for (final f in pagesOf(doc)) {
      if (await f.exists()) await f.delete();
    }
    final size = await _writeContents(doc.id, pages);
    return doc.copyWith(
      pageCount: pages.length,
      sizeBytes: size,
      updatedAt: DateTime.now(),
    );
  }

  Future<List<Uint8List>> readPages(StoredDoc d) =>
      Future.wait([for (final f in pagesOf(d)) f.readAsBytes()]);

  Future<void> delete(String id) async {
    final d = dirOf(id);
    if (await d.exists()) await d.delete(recursive: true);
  }

  Future<int> _writeContents(String id, List<Uint8List> pages) async {
    for (var i = 0; i < pages.length; i++) {
      await pageOf(id, i).writeAsBytes(pages[i], flush: true);
    }
    final first = pages.first;
    final thumb = await compute(makeThumb, first);
    await thumbOf(id).writeAsBytes(thumb);
    final pdf = await compute(buildPdf, pages);
    await pdfOf(id).writeAsBytes(pdf, flush: true);
    return pdf.length;
  }
}
