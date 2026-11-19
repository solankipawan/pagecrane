import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Builds a PDF with one full-bleed page per JPEG. Page width is A4 (595 pt);
/// height follows each image's aspect ratio. Pure Dart — call via Isolate.run.
Future<Uint8List> buildPdf(List<Uint8List> jpegPages) async {
  final doc = pw.Document(compress: true, producer: 'Pagecrane');
  for (final bytes in jpegPages) {
    final image = pw.MemoryImage(bytes);
    final w = (image.width ?? 1).toDouble(), h = (image.height ?? 1).toDouble();
    const pageW = 595.0;
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(pageW, pageW * h / w),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(image, fit: pw.BoxFit.fill),
      ),
    );
  }
  return doc.save();
}
