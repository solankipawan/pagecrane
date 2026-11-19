import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'doc_detect.dart';
import 'filters.dart';

/// Entry points meant for `compute(fn, arg)` — pure top-level functions on bytes only.
/// (Don't wrap them in closures for Isolate.run inside async methods: such closures can
/// capture the method's async state, which isn't sendable to another isolate.)

const maxPageDim = 2400;

img.Image _decode(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  if (im == null) throw const FormatException('Unsupported image');
  return img.bakeOrientation(im);
}

img.Image _fit(img.Image im, int maxDim) {
  final m = math.max(im.width, im.height);
  if (m <= maxDim) return im;
  final k = maxDim / m;
  return img.copyResize(
    im,
    width: (im.width * k).round(),
    height: (im.height * k).round(),
    interpolation: img.Interpolation.average,
  );
}

/// Imported photo → (auto-cropped) page JPEG. [cropped] is false when no sheet was found.
({Uint8List jpeg, bool cropped}) prepareImportedPhoto(Uint8List bytes) {
  final full = _fit(_decode(bytes), maxPageDim);
  final crop = autoCrop(full);
  return (
    jpeg: img.encodeJpg(crop ?? full, quality: 92),
    cropped: crop != null,
  );
}

/// Native-scanner page (already cropped by VisionKit / ML Kit) → normalised JPEG.
Uint8List prepareScannedPage(Uint8List bytes) =>
    img.encodeJpg(_fit(_decode(bytes), maxPageDim), quality: 92);

/// Applies filter + rotation. Used both for the review preview (small [maxDim])
/// and for the final saved page.
Uint8List renderPage(
  ({
    Uint8List src,
    ScanFilter filter,
    int quarterTurns,
    int maxDim,
    int quality,
  })
  a,
) {
  var im = _fit(_decode(a.src), a.maxDim);
  im = applyFilter(im, a.filter);
  final turns = a.quarterTurns % 4;
  if (turns != 0) im = img.copyRotate(im, angle: 90 * turns);
  return img.encodeJpg(im, quality: a.quality);
}

/// Pixel size of an encoded image, or null if it can't be decoded.
(int, int)? imageDims(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  return im == null ? null : (im.width, im.height);
}

Uint8List makeThumb(Uint8List jpeg, {int maxDim = 240}) =>
    img.encodeJpg(_fit(_decode(jpeg), maxDim), quality: 80);

/// Re-encodes a page at a compression level (quality + resolution scale).
Uint8List reencode(({Uint8List src, double scale, int quality}) a) {
  var im = _decode(a.src);
  if (a.scale < 1) {
    im = img.copyResize(
      im,
      width: math.max(1, (im.width * a.scale).round()),
      interpolation: img.Interpolation.average,
    );
  }
  return img.encodeJpg(im, quality: a.quality);
}

enum ExportFormat { jpg, png }

/// PDF → images: one stored page → JPG/PNG, optionally capped at [maxDim] px.
/// When nothing changes (JPG, original size, quality ≥ 95) the stored bytes are returned as-is.
Uint8List exportPage(
  ({Uint8List src, ExportFormat format, int quality, int? maxDim}) a,
) {
  if (a.format == ExportFormat.jpg && a.maxDim == null && a.quality >= 95) {
    return a.src;
  }
  var im = _decode(a.src);
  if (a.maxDim != null) im = _fit(im, a.maxDim!);
  return a.format == ExportFormat.png
      ? img.encodePng(im, level: 6)
      : img.encodeJpg(im, quality: a.quality);
}

/// "Under N KB": binary search on JPEG quality; only shrink pixels when quality
/// would drop below 40 (docs/ARCHITECTURE.md §5).
({Uint8List bytes, int width, int height, int quality})? compressToTarget(
  ({Uint8List src, int targetBytes}) a,
) {
  final original = _decode(a.src);
  ({Uint8List bytes, int width, int height, int quality})? fallback;
  var scale = 1.0;
  for (var round = 0; round < 14 && scale > 0.05; round++, scale *= 0.85) {
    final im = scale == 1.0
        ? original
        : img.copyResize(
            original,
            width: math.max(1, (original.width * scale).round()),
            interpolation: img.Interpolation.average,
          );
    final top = img.encodeJpg(im, quality: 92);
    if (top.length <= a.targetBytes) {
      return (bytes: top, width: im.width, height: im.height, quality: 92);
    }
    var lo = 5, hi = 92;
    Uint8List? best;
    var bestQ = 0;
    while (lo <= hi) {
      final q = (lo + hi) >> 1;
      final out = img.encodeJpg(im, quality: q);
      if (out.length <= a.targetBytes) {
        best = out;
        bestQ = q;
        lo = q + 1;
      } else {
        hi = q - 1;
      }
    }
    if (best != null && bestQ >= 40) {
      return (bytes: best, width: im.width, height: im.height, quality: bestQ);
    }
    if (best != null) {
      fallback ??= (
        bytes: best,
        width: im.width,
        height: im.height,
        quality: bestQ,
      );
    }
  }
  return fallback;
}
