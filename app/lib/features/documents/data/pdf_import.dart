import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

/// Renders an outside PDF into page JPEGs so it becomes a normal library document
/// (then merge, split, compress, sign and export all work on it).
///
/// Trade-off: pages are rasterised, so the imported copy has no selectable text.
/// The original file is left untouched.
class PdfImporter {
  /// Target resolution for rendered pages, capped like scanned pages.
  static const dpi = 200.0;
  static const maxDim = 2400;

  /// System file picker filtered to PDFs. Null if cancelled.
  static Future<({String path, String name})?> pick() async {
    // Single-file picker: one tap selects (pickFiles opens in multi-select mode on iOS).
    final f = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (f == null || f.path == null) return null;
    return (
      path: f.path!,
      name: f.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
    );
  }

  /// Opens [path]; [askPassword] is called (repeatedly) for encrypted files and may
  /// return null to give up, which throws [PdfPasswordException].
  static Future<PdfDocument> open(
    String path, {
    required Future<String?> Function() askPassword,
  }) async {
    await pdfrxFlutterInitialize();
    return PdfDocument.openFile(path, passwordProvider: askPassword);
  }

  /// Renders every page of [doc] to JPEG. Disposes [doc] when done.
  static Future<List<Uint8List>> render(
    PdfDocument doc, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final out = <Uint8List>[];
    try {
      final pages = doc.pages;
      for (var i = 0; i < pages.length; i++) {
        if (isCancelled?.call() ?? false) throw const PdfImportCancelled();
        final page = pages[i];
        final (w, h) = renderSize(page.width, page.height);
        final image = await page.render(
          fullWidth: w.toDouble(),
          fullHeight: h.toDouble(),
          backgroundColor: 0xFFFFFFFF,
        );
        if (image == null) {
          throw StateError('Page ${i + 1} could not be rendered');
        }
        final bgra = Uint8List.fromList(
          image.pixels,
        ); // copy out of PDFium's buffer before dispose
        final iw = image.width, ih = image.height;
        image.dispose();
        out.add(
          await compute(encodeBgraAsJpeg, (
            bgra: bgra,
            w: iw,
            h: ih,
            quality: 88,
          )),
        );
        onProgress?.call(i + 1, pages.length);
      }
      return out;
    } finally {
      await doc.dispose();
    }
  }

  /// Pixel size for a page of [wPt]×[hPt] points at [dpi], long edge capped at [maxDim].
  static (int, int) renderSize(double wPt, double hPt) {
    var w = wPt * dpi / 72, h = hPt * dpi / 72;
    final k = math.min(1.0, maxDim / math.max(w, h));
    w *= k;
    h *= k;
    return (math.max(1, w.round()), math.max(1, h.round()));
  }
}

class PdfImportCancelled implements Exception {
  const PdfImportCancelled();
}

/// PDFium renders BGRA; pages are opaque (white background), so alpha is ignored.
Uint8List encodeBgraAsJpeg(({Uint8List bgra, int w, int h, int quality}) a) =>
    img.encodeJpg(
      img.Image.fromBytes(
        width: a.w,
        height: a.h,
        bytes: a.bgra.buffer,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      ),
      quality: a.quality,
    );
