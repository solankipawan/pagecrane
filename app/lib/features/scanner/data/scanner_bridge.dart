import 'package:flutter/foundation.dart' show compute;

import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/page_pipeline.dart';

typedef CapturedPage = PageCrop;

/// Two capture paths (docs/ARCHITECTURE.md §1):
///  * camera → native scanner (VisionKit on iOS, ML Kit on Android): live edge
///    detection, auto-capture, perspective correction, batch pages.
///  * import → photos from the library, auto-cropped by our Dart pipeline.
class ScannerBridge {
  /// Returns null if the user cancelled. Throws [ScannerUnavailable] where the
  /// native scanner can't run (e.g. the iOS Simulator has no camera).
  static Future<List<CapturedPage>?> scanWithCamera() async {
    final ScanResult? result;
    try {
      result = await CunningDocumentScanner.scanDocuments(
        scannerSource: ScannerSource.camera,
      );
    } catch (e) {
      throw ScannerUnavailable('$e');
    }
    if (result == null || result.images.isEmpty) return null;
    final pages = <CapturedPage>[];
    for (final path in result.images) {
      final bytes = await File(path).readAsBytes();
      pages.add((
        jpeg: await compute(prepareScannedPage, bytes),
        cropped: true,
        original: null, // already cut by the system scanner
        corners: null,
      ));
    }
    await CunningDocumentScanner.cleanCache();
    return pages;
  }

  /// Step 1 of import: the system photo picker. Null if cancelled.
  static Future<List<XFile>?> pickPhotos() async {
    final files = await ImagePicker().pickMultiImage(
      requestFullMetadata: false,
    );
    return files.isEmpty ? null : files;
  }

  /// Page images from the Files app (iCloud Drive, Downloads…). Null if cancelled.
  static Future<List<XFile>?> pickImageFiles() async {
    // pickFiles is multi-select by default.
    final r = await FilePicker.pickFiles(type: FileType.image);
    final files = [
      for (final f in r)
        if (f.path != null) XFile(f.path!),
    ];
    return files.isEmpty ? null : files;
  }

  /// Step 2 of import: decode + auto-crop each photo (in isolates).
  static Future<List<CapturedPage>> processPhotos(List<XFile> files) async {
    final pages = <CapturedPage>[];
    for (final f in files) {
      final bytes = await f.readAsBytes();
      pages.add(await compute(prepareImportedPhoto, bytes));
    }
    return pages;
  }
}

class ScannerUnavailable implements Exception {
  ScannerUnavailable(this.detail);
  final String detail;
  @override
  String toString() => 'ScannerUnavailable: $detail';
}
