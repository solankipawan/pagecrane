import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Paper sizes in points (portrait) that pages can be resized to.
const paperSizes = <String, (double, double)>{
  'A4': (595.28, 841.89),
  'Letter': (612, 792),
  'Legal': (612, 1008),
};

/// PDF page width (pt) for a page image of [w]×[h] px: the exact paper width when
/// the image has a paper's shape (portrait or landscape), else A4 width (595 pt).
double pageWidthFor(double w, double h) {
  final r = h / w;
  for (final (pw, ph) in paperSizes.values) {
    if ((r - ph / pw).abs() / (ph / pw) < 0.004) return pw;
    if ((r - pw / ph).abs() / (pw / ph) < 0.004) return ph;
  }
  return 595.0;
}

/// Builds a PDF with one full-bleed page per JPEG. Height follows each image's
/// aspect ratio; width is A4's unless the page is shaped like a known paper
/// size ([pageWidthFor]). Pure Dart — call via Isolate.run.
Future<Uint8List> buildPdf(List<Uint8List> jpegPages) async {
  final doc = pw.Document(compress: true, producer: 'Pagecrane');
  for (final bytes in jpegPages) {
    final image = pw.MemoryImage(bytes);
    final w = (image.width ?? 1).toDouble(), h = (image.height ?? 1).toDouble();
    final pageW = pageWidthFor(w, h);
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
