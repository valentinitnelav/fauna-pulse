// FaunaPulse — export a user-drawn crop of a saved ROI photo.
//
// The summary photo viewer lets the user drag a rectangle around one insect;
// this module cuts that rectangle OUT OF THE ORIGINAL SAVED JPEG (never from
// the screen — screen pixels are already downscaled to the ~320-px viewer) and
// either saves it to the phone's Gallery (MediaStore, the Android system index
// of shared photos, under Pictures/FaunaPulse) or hands it to the
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

/// Metadata stamped into an exported crop's EXIF (round 126): the photo's
/// trigger moment as DateTimeOriginal and, when the session recorded one, the
/// GPS position — so identification apps (ObsIdentify, iNaturalist, Google
/// Lens) read where-and-when straight from the file. Deliberately ONLY on
/// user-exported crops: the capture pipeline itself stays EXIF-free (round
/// 98 invariant — that is what keeps training data orientation-safe), and no
/// orientation tag is ever written here either.
class CropExifInfo {
  /// The crop's source-photo trigger moment (epoch ms; rendered in LOCAL
  /// time, which is what EXIF DateTimeOriginal means by convention).
  final int? capturedAtMs;
  final double? latitude;
  final double? longitude;
  const CropExifInfo({this.capturedAtMs, this.latitude, this.longitude});

  bool get isEmpty =>
      capturedAtMs == null && (latitude == null || longitude == null);
}

/// One coordinate as the EXIF degrees/minutes/seconds triplet (all EXIF GPS
/// values are unsigned rationals; the hemisphere goes in the *Ref tag).
img.IfdValueRational exifDmsRational(double absDegrees) {
  final deg = absDegrees.floor();
  final minutesFull = (absDegrees - deg) * 60;
  final minutes = minutesFull.floor();
  // Seconds ×100 as the denominator keeps ~0.3 m precision in integers.
  final sec100 = ((minutesFull - minutes) * 60 * 100).round();
  // The image package doesn't export its Rational type, so the three
  // (numerator, denominator) pairs are fed to the public
  // IfdValueRational.data constructor as big-endian uint32s.
  final bytes = <int>[];
  void u32(int v) => bytes.addAll([
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ]);
  u32(deg);
  u32(1);
  u32(minutes);
  u32(1);
  u32(sec100);
  u32(100);
  return img.IfdValueRational.data(
    img.InputBuffer(Uint8List.fromList(bytes), bigEndian: true),
    3,
  );
}

/// EXIF datetime string ("YYYY:MM:DD hh:mm:ss", local time) for [epochMs].
String exifDateTime(int epochMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}:${two(t.month)}:${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// Writes [info] into [im]'s EXIF block (encodeJpg emits it). Kept pure so a
/// unit test can round-trip encode→decode and read the tags back.
void applyCropExif(img.Image im, CropExifInfo info) {
  // Explicit IfdValue objects throughout: the directory setter only
  // auto-converts plain values for tags whose type it knows, and the GPS
  // tags carry no type in the package's tables.
  final at = info.capturedAtMs;
  if (at != null) {
    im.exif.exifIfd['DateTimeOriginal'] = img.IfdValueAscii(exifDateTime(at));
    im.exif.imageIfd['DateTime'] = img.IfdValueAscii(exifDateTime(at));
  }
  final lat = info.latitude, lon = info.longitude;
  if (lat != null && lon != null) {
    final gps = im.exif.gpsIfd;
    // Round 127: version + datum first — exiftool/PIL don't need them, but
    // stricter mobile parsers expect GPSVersionID to head the GPS IFD.
    gps['GPSVersionID'] = img.IfdByteValue.list(
      Uint8List.fromList([2, 3, 0, 0]),
    );
    gps['GPSLatitudeRef'] = img.IfdValueAscii(lat >= 0 ? 'N' : 'S');
    gps['GPSLatitude'] = exifDmsRational(lat.abs());
    gps['GPSLongitudeRef'] = img.IfdValueAscii(lon >= 0 ? 'E' : 'W');
    gps['GPSLongitude'] = exifDmsRational(lon.abs());
    gps['GPSMapDatum'] = img.IfdValueAscii('WGS-84');
  }
}

/// Decodes [bytes], cuts the normalized rectangle out and re-encodes it,
/// stamping [exif] (when given) into the crop on the way. Returns null when
/// the image can't be decoded or the rectangle comes out smaller than
/// [kMinCropSidePx] on either side. Pure and synchronous so it is
/// unit-testable; the viewer calls it through [cropJpegNormRect] (isolate).
CroppedImage? cropJpegRectSync(
  Uint8List bytes,
  Rect norm, {
  CropExifInfo? exif,
}) {
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
  if (exif != null && !exif.isEmpty) applyCropExif(crop, exif);
  return CroppedImage(
    Uint8List.fromList(img.encodeJpg(crop, quality: 90)),
    w,
    h,
  );
}

class _CropRectArgs {
  final Uint8List bytes;
  final double left, top, right, bottom;
  final int? capturedAtMs;
  final double? lat, lon;
  const _CropRectArgs(
    this.bytes,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.capturedAtMs,
    this.lat,
    this.lon,
  );
}

CroppedImage? _cropRectWorker(_CropRectArgs a) => cropJpegRectSync(
  a.bytes,
  Rect.fromLTRB(a.left, a.top, a.right, a.bottom),
  exif: CropExifInfo(
    capturedAtMs: a.capturedAtMs,
    latitude: a.lat,
    longitude: a.lon,
  ),
);

/// Crops the normalized rectangle [norm] (0..1) out of the saved JPEG [src]
/// on a background isolate, stamping [exif] into the result when given.
Future<CroppedImage?> cropJpegNormRect(
  File src,
  Rect norm, {
  CropExifInfo? exif,
}) async {
  final bytes = await src.readAsBytes();
  return compute(
    _cropRectWorker,
    _CropRectArgs(
      bytes,
      norm.left,
      norm.top,
      norm.right,
      norm.bottom,
      exif?.capturedAtMs,
      exif?.latitude,
      exif?.longitude,
    ),
    debugLabel: 'cropExport',
  );
}

/// Same channel MainActivity registers for the capture-time high-res crop; the
/// gallery save is just one more method on it.
const MethodChannel _channel = MethodChannel('faunapulse/crop');

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
      return const CropSaveResult(true, 'Gallery ▸ Pictures/FaunaPulse');
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

/// One chunk per channel call for the whole-session gallery export: small
/// enough that the progress bar moves visibly, large enough that the per-call
/// overhead is noise (only path strings cross the channel, never image bytes).
const int kGalleryExportChunk = 25;

/// Album folder name for a session under Pictures/FaunaPulse. Session
/// folders are already limited to letters/digits/space/_/- when created
/// (session_recorder.dart), but MediaStore is stricter about odd names than
/// the file system, so this re-sanitizes as a safety net: no path separators,
/// no leading dot (a leading dot hides the folder from the Gallery).
String galleryAlbumName(String sessionFolderName) {
  // Strip leading dots/spaces BEFORE the character sweep — otherwise the
  // sweep turns a leading dot into a leading underscore and hides nothing.
  var s = sessionFolderName.replaceFirst(RegExp(r'^[. ]+'), '');
  s = s.replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '_').trim();
  return s.isEmpty ? 'session' : s;
}

/// Counts from one whole-session gallery export, for the completion message.
/// [supported] is false when the phone runs Android 9 or older, where the app
/// can't write into the shared Gallery without a legacy permission.
class GalleryExportResult {
  final bool supported;
  final int exported;
  final int skipped;
  final int failed;
  const GalleryExportResult(
    this.supported,
    this.exported,
    this.skipped,
    this.failed,
  );
}

/// Round 93: copies [photos] into the shared Gallery under
/// Pictures/FaunaPulse/[album], in chunks so [onProgress] can drive a
/// determinate progress bar. Photos already exported (same file name in that
/// folder) are skipped natively, so re-running is safe. Never throws: a chunk
/// that fails is counted in [GalleryExportResult.failed] (and logged via
/// logSwallowed) and the remaining chunks still go out.
Future<GalleryExportResult> exportPhotosToGallery(
  List<File> photos,
  String album, {
  void Function(int done, int total)? onProgress,
}) async {
  final total = photos.length;
  var exported = 0, skipped = 0, failed = 0;
  for (var i = 0; i < total; i += kGalleryExportChunk) {
    final chunk = photos.sublist(i, min(i + kGalleryExportChunk, total));
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
        'saveImagesToGallery',
        {'paths': chunk.map((f) => f.path).toList(), 'album': album},
      );
      if (r == null) throw StateError('null reply from saveImagesToGallery');
      if (r['supported'] != true) {
        // Pre-Android-10 phone: no point sending the remaining chunks.
        return const GalleryExportResult(false, 0, 0, 0);
      }
      exported += (r['exported'] as int?) ?? 0;
      skipped += (r['skipped'] as int?) ?? 0;
      failed += (r['failed'] as int?) ?? 0;
    } catch (e) {
      logSwallowed('gallery_batch_export', e);
      failed += chunk.length;
    }
    onProgress?.call(min(i + kGalleryExportChunk, total), total);
  }
  return GalleryExportResult(true, exported, skipped, failed);
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
