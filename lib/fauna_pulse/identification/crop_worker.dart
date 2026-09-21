// FaunaPulse (round 208): cutting model-ready crops out of session photos.
//
// Per plan section 11.2: a square on the box's longer side (the same rule as
// `make_bbox_square()` in insect-detect-post, Sittinger 2026, re-implemented)
// plus a margin, centred on the box; parts outside the photo are padded with the CLIP mean
// colour (neutral after the model's normalisation) instead of shifting the
// square; a direct antialiased resize to the model input (no centre crop,
// matching pybioclip); and per-crop quality features (pixel size, padding
// fraction, sharpness as the variance of the Laplacian). The geometry is a
// pure function (tested); the pixel work runs in a worker isolate.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// CLIP mean colour in 8-bit RGB (0.4815, 0.4578, 0.4082 × 255).
const int kPadR = 123, kPadG = 117, kPadB = 104;

/// Where the square crop lands, in photo pixels.
class SquareCropPlan {
  /// Square (may extend beyond the photo).
  final int sx, sy, side;

  /// Intersection of the square with the photo (what is actually copied).
  final int ix, iy, iw, ih;

  /// Longer side of the raw box in photo pixels (before the margin).
  final int cropPx;

  /// Padded share of the square's area (0 = fully inside the photo).
  final double padFrac;

  const SquareCropPlan({
    required this.sx,
    required this.sy,
    required this.side,
    required this.ix,
    required this.iy,
    required this.iw,
    required this.ih,
    required this.cropPx,
    required this.padFrac,
  });

  bool get needsPadding => padFrac > 0;
}

/// Plans the square for a normalised box (edges 0..1) on a [imgW]×[imgH]
/// photo with [margin] extra per side (0.15 = 15 % of the side each way).
SquareCropPlan planSquareCrop({
  required int imgW,
  required int imgH,
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double margin,
}) {
  final l = left.clamp(0.0, 1.0) * imgW;
  final r = right.clamp(0.0, 1.0) * imgW;
  final t = top.clamp(0.0, 1.0) * imgH;
  final b = bottom.clamp(0.0, 1.0) * imgH;
  final w = r - l, h = b - t;
  final longer = w > h ? w : h;
  final cropPx = longer.round();
  var side = (longer * (1 + 2 * margin)).round();
  if (side < 1) side = 1;
  final cx = (l + r) / 2, cy = (t + b) / 2;
  final sx = (cx - side / 2).round();
  final sy = (cy - side / 2).round();
  final ix = sx < 0 ? 0 : sx;
  final iy = sy < 0 ? 0 : sy;
  final ex = (sx + side) > imgW ? imgW : sx + side;
  final ey = (sy + side) > imgH ? imgH : sy + side;
  final iw = ex - ix > 0 ? ex - ix : 0;
  final ih = ey - iy > 0 ? ey - iy : 0;
  final inside = iw * ih;
  final padFrac = side > 0 ? 1 - inside / (side * side) : 1.0;
  return SquareCropPlan(
    sx: sx,
    sy: sy,
    side: side,
    ix: ix,
    iy: iy,
    iw: iw,
    ih: ih,
    cropPx: cropPx,
    padFrac: padFrac.clamp(0.0, 1.0),
  );
}

/// Variance of the 4-neighbour Laplacian of the luminance of an RGB buffer:
/// a standard "how sharp" measure (higher = more fine detail).
double laplacianVariance(Uint8List rgb, int w, int h) {
  if (w < 3 || h < 3) return 0;
  final lum = Float32List(w * h);
  var j = 0;
  for (var i = 0; i < w * h; i++) {
    lum[i] = 0.299 * rgb[j] + 0.587 * rgb[j + 1] + 0.114 * rgb[j + 2];
    j += 3;
  }
  var sum = 0.0, sumSq = 0.0;
  final n = (w - 2) * (h - 2);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final c = lum[y * w + x];
      final lap =
          4 * c -
          lum[(y - 1) * w + x] -
          lum[(y + 1) * w + x] -
          lum[y * w + x - 1] -
          lum[y * w + x + 1];
      sum += lap;
      sumSq += lap * lap;
    }
  }
  final mean = sum / n;
  return sumSq / n - mean * mean;
}

/// One box to cut out of a photo.
class CropRequest {
  final String key;
  final double left, top, right, bottom;
  const CropRequest(this.key, this.left, this.top, this.right, this.bottom);
}

/// The model-ready crop (or why it was skipped).
class CropResult {
  final String key;

  /// outSize × outSize × 3 interleaved RGB, or null when skipped.
  final Uint8List? rgb;
  final int cropPx;
  final double padFrac;
  final double sharpness;
  final String? skipped;

  const CropResult({
    required this.key,
    required this.rgb,
    required this.cropPx,
    required this.padFrac,
    required this.sharpness,
    this.skipped,
  });
}

class CropBatchArgs {
  final Uint8List jpegBytes;
  final List<CropRequest> requests;
  final double margin;
  final int minCropPx;
  final int outSize;
  const CropBatchArgs({
    required this.jpegBytes,
    required this.requests,
    required this.margin,
    required this.minCropPx,
    required this.outSize,
  });
}

/// Decodes the photo once and cuts every requested crop (synchronous; the
/// job runs it through [cropBatch] on a worker isolate).
List<CropResult> cropBatchSync(CropBatchArgs a) {
  final decoded = img.decodeJpg(a.jpegBytes) ?? img.decodeImage(a.jpegBytes);
  if (decoded == null) {
    return [
      for (final r in a.requests)
        CropResult(key: r.key, rgb: null, cropPx: 0, padFrac: 1, sharpness: 0, skipped: 'decode'),
    ];
  }
  final photo = decoded.numChannels == 3
      ? decoded
      : decoded.convert(numChannels: 3);
  final out = <CropResult>[];
  for (final r in a.requests) {
    final plan = planSquareCrop(
      imgW: photo.width,
      imgH: photo.height,
      left: r.left,
      top: r.top,
      right: r.right,
      bottom: r.bottom,
      margin: a.margin,
    );
    if (plan.cropPx < a.minCropPx || plan.iw <= 0 || plan.ih <= 0) {
      out.add(
        CropResult(
          key: r.key,
          rgb: null,
          cropPx: plan.cropPx,
          padFrac: plan.padFrac,
          sharpness: 0,
          skipped: plan.cropPx < a.minCropPx ? 'too_small' : 'outside',
        ),
      );
      continue;
    }
    var square = img.copyCrop(
      photo,
      x: plan.ix,
      y: plan.iy,
      width: plan.iw,
      height: plan.ih,
    );
    if (plan.needsPadding) {
      final canvas = img.Image(width: plan.side, height: plan.side, numChannels: 3);
      img.fill(canvas, color: img.ColorRgb8(kPadR, kPadG, kPadB));
      img.compositeImage(canvas, square, dstX: plan.ix - plan.sx, dstY: plan.iy - plan.sy);
      square = canvas;
    }
    final resized = img.copyResize(
      square,
      width: a.outSize,
      height: a.outSize,
      interpolation: square.width > a.outSize
          ? img.Interpolation.average
          : img.Interpolation.linear,
    );
    final rgb = Uint8List(a.outSize * a.outSize * 3);
    var j = 0;
    for (final p in resized) {
      rgb[j++] = p.r.toInt();
      rgb[j++] = p.g.toInt();
      rgb[j++] = p.b.toInt();
    }
    out.add(
      CropResult(
        key: r.key,
        rgb: rgb,
        cropPx: plan.cropPx,
        padFrac: plan.padFrac,
        sharpness: laplacianVariance(rgb, a.outSize, a.outSize),
      ),
    );
  }
  return out;
}

/// [cropBatchSync] on a worker isolate (JPEG decode + resize are CPU work).
Future<List<CropResult>> cropBatch(CropBatchArgs a) =>
    Isolate.run(() => cropBatchSync(a));
