import 'package:flutter/foundation.dart' show compute;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import 'marks.dart';

/// Burns [marks] into a page JPEG at full resolution ("flatten on save"),
/// so any PDF viewer shows them. Rendering uses the same painter as the editor.
Future<Uint8List> flattenPage(
  Uint8List jpeg,
  List<Mark> marks, {
  int quality = 90,
}) async {
  final codec = await ui.instantiateImageCodec(jpeg);
  final page = (await codec.getNextFrame()).image;
  codec.dispose();
  final w = page.width, h = page.height;
  final size = Size(w.toDouble(), h.toDouble());

  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawImage(page, Offset.zero, Paint());
  MarksPainter(marks: marks).paint(canvas, size);
  final rendered = await rec.endRecording().toImage(w, h);
  final data = (await rendered.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  page.dispose();
  rendered.dispose();

  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return compute(encodeRgbaAsJpeg, (rgba: rgba, w: w, h: h, quality: quality));
}

/// Opaque page → JPEG (alpha is 255 everywhere, so premultiplication doesn't matter).
Uint8List encodeRgbaAsJpeg(({Uint8List rgba, int w, int h, int quality}) a) =>
    img.encodeJpg(
      img.Image.fromBytes(
        width: a.w,
        height: a.h,
        bytes: a.rgba.buffer,
        bytesOffset: a.rgba.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      ),
      quality: a.quality,
    );
