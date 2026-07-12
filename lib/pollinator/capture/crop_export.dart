// Pollinator Monitor — export a user-drawn crop of a saved ROI photo.
//
// The summary photo viewer lets the user drag a rectangle around one insect;
// this module cuts that rectangle OUT OF THE ORIGINAL SAVED JPEG (never from
// the screen — screen pixels are already downscaled to the ~320-px viewer) and
// either saves it to the phone's Gallery (MediaStore, the Android system index
// of shared photos, under Pictures/PollinatorMonitor) or hands it to the
// Android share sheet, so an identification app (Google Lens, iNaturalist/
// Seek, ObsIdentify) can take it from there.
//
// The geometry helpers are pure functions so the drag→rectangle math is unit
// tested without widgets; the JPEG decode/crop/encode runs on a background
// isolate (a separate worker thread) like the capture-time crop in
// roi_capture.dart, so the UI never freezes on a large photo.

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../logging/app_error_hooks.dart';

/// Smallest allowed crop side in image pixels. Anything smaller carries too
/// little detail to identify and is more likely a stray tap than a real box.
const int kMinCropSidePx = 16;

/// Turns a drag from [a] to [b] — both in the square photo's content ("scene")
/// coordinates, 0..[side] on each axis — into the crop rectangle. With
/// [square] the rectangle is forced to 1:1: anchored at the drag start,
/// following the drag direction, and SHRUNK near an edge so it never leaves
/// the photo (clamping only the corners would silently break the 1:1 promise).
Rect sceneRectForDrag(Offset a, Offset b, double side, {required bool square}) {
  double cl(double v) => v.clamp(0.0, side);
  a = Offset(cl(a.dx), cl(a.dy));
  b = Offset(cl(b.dx), cl(b.dy));
  if (square) {
    final sx = b.dx >= a.dx ? 1.0 : -1.0;
    final sy = b.dy >= a.dy ? 1.0 : -1.0;
    var s = max((b.dx - a.dx).abs(), (b.dy - a.dy).abs());
    final roomX = sx > 0 ? side - a.dx : a.dx;
    final roomY = sy > 0 ? side - a.dy : a.dy;
    s = min(s, min(roomX, roomY));
    b = Offset(a.dx + sx * s, a.dy + sy * s);
  }
  return Rect.fromLTRB(
    min(a.dx, b.dx),
    min(a.dy, b.dy),
    max(a.dx, b.dx),
    max(a.dy, b.dy),
  );
}

/// Shifts an existing crop rectangle by [delta] (scene coordinates), clamped
/// so the whole rectangle stays on the photo. The size — and therefore an
/// enforced 1:1 aspect — is preserved exactly.
Rect moveSceneRect(Rect r, Offset delta, double side) {
  final dx = delta.dx.clamp(-r.left, side - r.right);
  final dy = delta.dy.clamp(-r.top, side - r.bottom);
  return r.shift(Offset(dx, dy));
}

/// Scene rectangle (0..[side]) → normalized 0..1 fractions of the photo, the
/// resolution-independent form the pixel crop is computed from.
Rect normalizedRect(Rect scene, double side) => Rect.fromLTRB(
  scene.left / side,
  scene.top / side,
  scene.right / side,
  scene.bottom / side,
);

/// Name for an exported crop: the source photo's stem plus `_crop_HHMMSS.jpg`,
/// so a crop in the Gallery stays traceable to its session photo.
String cropExportName(String sourceName, {DateTime? now}) {
  final dot = sourceName.lastIndexOf('.');
  final stem = dot > 0 ? sourceName.substring(0, dot) : sourceName;
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${stem}_crop_${two(t.hour)}${two(t.minute)}${two(t.second)}.jpg';
}

/// An encoded crop plus its true pixel size (for the confirmation message —
/// the honest number that tells the user whether the crop is big enough to
/// identify from).
class CroppedImage {
  final Uint8List jpeg;
  final int width;
  final int height;
  const CroppedImage(this.jpeg, this.width, this.height);
}

/// Decodes [bytes], cuts the normalized rectangle out and re-encodes it.
/// Returns null when the image can't be decoded or the rectangle comes out
/// smaller than [kMinCropSidePx] on either side. Pure and synchronous so it is
/// unit-testable; the viewer calls it through [cropJpegNormRect] (isolate).
CroppedImage? cropJpegRectSync(Uint8List bytes, Rect norm) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // Corrupt/truncated file: fall through to the null return below.
  }
  if (decoded == null) return null;
  final l = (norm.left.clamp(0.0, 1.0) * decoded.width).round();
  final r = (norm.right.clamp(0.0, 1.0) * decoded.width).round();
  final t = (norm.top.clamp(0.0, 1.0) * decoded.height).round();
  final b = (norm.bottom.clamp(0.0, 1.0) * decoded.height).round();
  final w = r - l, h = b - t;
  if (w < kMinCropSidePx || h < kMinCropSidePx) return null;
  final crop = img.copyCrop(decoded, x: l, y: t, width: w, height: h);
  return CroppedImage(
    Uint8List.fromList(img.encodeJpg(crop, quality: 90)),
    w,
    h,
  );
}

class _CropRectArgs {
  final Uint8List bytes;
  final double left, top, right, bottom;
  const _CropRectArgs(this.bytes, this.left, this.top, this.right, this.bottom);
}

CroppedImage? _cropRectWorker(_CropRectArgs a) =>
    cropJpegRectSync(a.bytes, Rect.fromLTRB(a.left, a.top, a.right, a.bottom));

/// Crops the normalized rectangle [norm] (0..1) out of the saved JPEG [src]
/// on a background isolate.
Future<CroppedImage?> cropJpegNormRect(File src, Rect norm) async {
  final bytes = await src.readAsBytes();
  return compute(
    _cropRectWorker,
    _CropRectArgs(bytes, norm.left, norm.top, norm.right, norm.bottom),
    debugLabel: 'cropExport',
  );
}

/// Same channel MainActivity registers for the capture-time still crop; the
/// gallery save is just one more method on it.
const MethodChannel _channel = MethodChannel('pollinator/crop');

/// Where a crop ended up, for the confirmation SnackBar. [inGallery] is false
/// when the MediaStore save wasn't possible (pre-Android-10, or it failed)
/// and the crop was kept in the session folder instead.
class CropSaveResult {
  final bool inGallery;
  final String location;
  const CropSaveResult(this.inGallery, this.location);
}

/// Saves [jpeg] into the shared Gallery via MediaStore; on failure falls back
/// to [fallbackDir] (the session's `crops/` folder — at least reachable over
/// USB). Returns null only when both fail.
Future<CropSaveResult?> saveCropToGallery(
  Uint8List jpeg,
  String displayName, {
  required Directory fallbackDir,
}) async {
  try {
    final ok = await _channel.invokeMethod<bool>('saveImageToGallery', {
      'bytes': jpeg,
      'displayName': displayName,
    });
    if (ok == true) {
      return const CropSaveResult(true, 'Gallery ▸ Pictures/PollinatorMonitor');
    }
  } catch (e) {
    logSwallowed('crop_gallery_save', e);
  }
  try {
    if (!await fallbackDir.exists()) await fallbackDir.create(recursive: true);
    final f = File('${fallbackDir.path}/$displayName');
    await f.writeAsBytes(jpeg, flush: true);
    return CropSaveResult(false, f.path);
  } catch (e) {
    logSwallowed('crop_fallback_save', e);
    return null;
  }
}

/// Opens the OS share sheet with the crop attached (same pattern as
/// ErrorReporter.share), letting the user hand it straight to Google Lens,
/// iNaturalist, etc. The temp copy is small and the OS clears the cache dir.
Future<void> shareCrop(Uint8List jpeg, String displayName) async {
  final dir = await getTemporaryDirectory();
  final crops = Directory('${dir.path}/crops');
  if (!await crops.exists()) await crops.create(recursive: true);
  final f = File('${crops.path}/$displayName');
  await f.writeAsBytes(jpeg, flush: true);
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
}
