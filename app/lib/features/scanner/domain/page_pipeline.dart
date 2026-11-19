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

/// A prepared page: [jpeg] is what goes into the document. [original] is the whole
/// upright photo and [corners] (normalised 0..1, TL TR BR BL) where [jpeg] was cut
/// from it, so the crop can be adjusted later. Null corners = the whole photo.
typedef PageCrop = ({
  Uint8List jpeg,
  bool cropped,
  Uint8List? original,
  List<Pt>? corners,
});

PageCrop _cropOf(img.Image full, List<Pt>? corners) {
  final crop = corners == null ? null : warpNormalized(full, corners);
  final original = img.encodeJpg(full, quality: 90);
  return (
    jpeg: crop == null ? original : img.encodeJpg(crop, quality: 92),
    cropped: crop != null,
    original: original,
    corners: corners,
  );
}

/// Imported photo → (auto-cropped) page. [cropped] is false when no sheet was found.
PageCrop prepareImportedPhoto(Uint8List bytes) {
  final full = _fit(_decode(bytes), maxPageDim);
  return _cropOf(full, findPageCorners(full));
}

/// Pagecrane camera shot → cropped page. Uses [hint] (the corners shown live,
/// normalised 0..1 in a frame of aspect [hintAspect] = width / height) when the photo
/// has the same framing, so the page matches the outline the user saw; otherwise
/// detects again on the full photo.
PageCrop prepareCameraPhoto(
  ({Uint8List bytes, List<Pt>? hint, double hintAspect}) a,
) {
  final full = _fit(_decode(a.bytes), maxPageDim);
  final hint = a.hint;
  final aspect = full.width / full.height;
  final corners =
      hint != null && (aspect - a.hintAspect).abs() / a.hintAspect < 0.03
      ? insetCorners(hint)
      : findPageCorners(full);
  return _cropOf(full, corners);
}

/// Re-cuts a page from its [original] photo along [corners] (null = whole photo).
Uint8List cropPage(({Uint8List original, List<Pt>? corners}) a) {
  if (a.corners == null) return a.original;
  return img.encodeJpg(
    warpNormalized(_decode(a.original), a.corners!),
    quality: 92,
  );
}

/// Auto-detected corners of the sheet in an encoded photo (null if none found).
List<Pt>? detectCorners(Uint8List bytes) =>
    findPageCorners(_fit(_decode(bytes), 1200));

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

/// Estimated PDF size for [pages] pages of [perPage] JPEG bytes each (same overhead
/// model as the compress estimate).
int estimatePdfBytes(int perPage, int pages) =>
    perPage * pages + 1200 + pages * 400;

/// Plans a whole-PDF re-encode that fits [target] bytes, from a sample [page]:
/// the largest resolution scale whose best JPEG quality is still decent (≥ 50),
/// else the first that fits at all. Aims 8 % under the target since pages differ.
/// [fits] is false when even the smallest setting is too big ([estimate] = that).
({int quality, double scale, int estimate, bool fits}) planForTarget(
  ({Uint8List page, int pages, int target}) a,
) {
  const scales = [1.0, 0.85, 0.72, 0.6, 0.5, 0.42, 0.35, 0.28, 0.22, 0.17];
  final budget = (a.target * 0.92).floor();
  final base = _fit(_decode(a.page), maxPageDim);
  ({int quality, double scale, int estimate, bool fits})? fallback;
  var smallest = 0;
  for (final s in scales) {
    final im = s == 1.0
        ? base
        : img.copyResize(
            base,
            width: math.max(1, (base.width * s).round()),
            interpolation: img.Interpolation.average,
          );
    int est(int q) =>
        estimatePdfBytes(img.encodeJpg(im, quality: q).length, a.pages);
    final floor = est(30);
    smallest = floor;
    if (floor > budget) continue;
    var lo = 30, hi = 88, best = 30, bestEst = floor;
    while (lo <= hi) {
      final q = (lo + hi) >> 1;
      final e = est(q);
      if (e <= budget) {
        best = q;
        bestEst = e;
        lo = q + 1;
      } else {
        hi = q - 1;
      }
    }
    final plan = (quality: best, scale: s, estimate: bestEst, fits: true);
    if (best >= 50) return plan;
    fallback ??= plan;
  }
  return fallback ??
      (quality: 30, scale: scales.last, estimate: smallest, fits: false);
}

/// Reshapes a page to paper proportions [ratio] (height / width, portrait).
/// Landscape pages get landscape paper. [fill] false = fit inside with white
/// margins (nothing lost); true = fill the page, trimming the overflow evenly.
Uint8List fitToPaper(({Uint8List src, double ratio, bool fill}) a) {
  final im = _decode(a.src);
  final r = im.width > im.height ? 1 / a.ratio : a.ratio;
  final imgR = im.height / im.width;
  late img.Image out;
  if (a.fill) {
    // Crop the centre to the paper shape.
    final (cw, ch) = imgR > r
        ? (im.width, (im.width * r).round())
        : ((im.height / r).round(), im.height);
    out = img.copyCrop(
      im,
      x: (im.width - cw) ~/ 2,
      y: (im.height - ch) ~/ 2,
      width: cw,
      height: ch,
    );
  } else {
    // Paper big enough to hold the whole page, white around it.
    final (cw, ch) = imgR > r
        ? ((im.height / r).round(), im.height)
        : (im.width, (im.width * r).round());
    out = img.Image(width: cw, height: ch, numChannels: 3);
    img.fill(out, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(
      out,
      im,
      dstX: (cw - im.width) ~/ 2,
      dstY: (ch - im.height) ~/ 2,
    );
  }
  return img.encodeJpg(_fit(out, maxPageDim), quality: 90);
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
