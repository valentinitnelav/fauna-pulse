// Pollinator Monitor — time-lapse capture of the ROI while a visit is active.
//
// Rules (from CLAUDE.md):
//  * When an insect (track) first appears, take a photo immediately, then one
//    every [stepMs] for up to [durationMs]; after that, stop for that track.
//  * Each track has its own window, so a track that starts later still gets its
//    full duration.
//  * If several tracks are active at the same instant, take ONE shared photo
//    (the whole ROI is the same image) rather than one per track — this avoids
//    overloading the phone. The single filename is logged against every track
//    that was due at that moment.
//
// Photos are full-resolution stills (CameraX ImageCapture via the plugin's
// capturePhoto), cropped to the ROI square. Cropping decodes the JPEG, so it is
// done on a background isolate (compute) to keep the camera preview smooth.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../models/roi.dart';
import '../models/track.dart';

/// Native fast-crop channel: decodes only the ROI rectangle from the full-res
/// JPEG (Android BitmapRegionDecoder), avoiding a whole-image decode in Dart.
const MethodChannel _cropChannel = MethodChannel('pollinator/crop');

/// Reads only a JPEG's pixel dimensions (width, height) on a background isolate.
/// Used once at startup to learn the full-resolution still size so the UI can
/// show the true ROI resolution (the analysis frame fed to the model is much
/// smaller than the saved photo). Returns null if the bytes can't be decoded.
Future<(int, int)?> probeJpegSize(Uint8List bytes) async {
  final wh = await compute(_jpegSize, bytes);
  if (wh == null) return null;
  return (wh[0], wh[1]);
}

List<int>? _jpegSize(Uint8List bytes) {
  final decoded = img.decodeJpg(bytes);
  if (decoded == null) return null;
  return [decoded.width, decoded.height];
}

/// A capture that is due this frame: the deterministic file name and the track
/// ids that share it. Returned synchronously by [RoiCaptureScheduler.evaluate]
/// so the caller can write the filename into this frame's detection records
/// before the (asynchronous) image grab finishes.
class PendingCapture {
  /// File name (not full path) of the JPEG to be written, in the ROI frames
  /// folder.
  final String fileName;

  /// Track ids that were "due" and will share this image.
  final List<int> trackIds;

  /// When the capture is for (ms since epoch).
  final int capturedAtMs;

  const PendingCapture({
    required this.fileName,
    required this.trackIds,
    required this.capturedAtMs,
  });
}

/// One completed ROI-photo save, reported via [RoiCaptureScheduler.onStat] so the
/// session log can record how costly photo-saving is (to diagnose frame-rate dips).
class CaptureStat {
  final String fileName;
  final List<int> trackIds;

  /// Wall-clock milliseconds for the whole grab (+ crop) + write.
  final double totalMs;

  /// Size of the saved JPEG in bytes.
  final int bytes;

  /// True for the full-resolution still path (which briefly stalls the camera),
  /// false for the fast live-frame crop.
  final bool fullRes;

  const CaptureStat({
    required this.fileName,
    required this.trackIds,
    required this.totalMs,
    required this.bytes,
    required this.fullRes,
  });
}

/// Schedules and performs ROI captures. Call [onTracks] once per processed
/// frame while recording.
class RoiCaptureScheduler {
  /// Where ROI JPEGs are written (created if missing).
  final Directory framesDir;

  /// Short session identifier embedded in filenames.
  final String sessionId;

  /// Milliseconds between photos for a given track.
  final int stepMs;

  /// Total milliseconds to keep photographing a track from first sight.
  final int durationMs;

  /// Grabs the image to save. Returns null if unavailable. When
  /// [cropAfterCapture] is true this returns a full-frame still that still needs
  /// cropping to the ROI; when false it already returns the ROI crop.
  final Future<Uint8List?> Function() captureFn;

  /// Current ROI (may change if the user adjusts it mid-session). Only used when
  /// [cropAfterCapture] is true.
  final Roi Function() roiProvider;

  /// Whether [captureFn]'s bytes are a full frame that must still be cropped to
  /// the ROI (full-res still path), vs already an ROI crop (fast live-frame path).
  final bool cropAfterCapture;

  /// Optional sink for per-photo timing/size, called after each successful write.
  /// Used to log a `capture` diagnostics record; never affects capture itself.
  final void Function(CaptureStat stat)? onStat;

  RoiCaptureScheduler({
    required this.framesDir,
    required this.sessionId,
    required this.stepMs,
    required this.durationMs,
    required this.captureFn,
    required this.roiProvider,
    this.cropAfterCapture = false,
    this.onStat,
  });

  final Map<int, _Window> _windows = {};
  bool _busy = false;

  /// Decides, synchronously, whether a photo is due this frame. If so it
  /// returns the (deterministic) file name plus the due track ids, and marks
  /// those tracks as photographed now so they are not re-scheduled. Returns
  /// null when nothing is due or a previous capture is still in flight.
  ///
  /// Call [capture] with the returned value to actually grab and save the JPEG.
  PendingCapture? evaluate(List<Track> tracks, int nowMs) {
    if (_busy) return null;

    final activeIds = <int>{};
    final dueIds = <int>[];
    for (final t in tracks) {
      activeIds.add(t.id);
      final w = _windows.putIfAbsent(
        t.id,
        () => _Window(startMs: nowMs, lastCaptureMs: null, lastSeenMs: nowMs),
      );
      w.lastSeenMs = nowMs;
      final expired = nowMs - w.startMs > durationMs;
      if (expired) continue;
      final due = w.lastCaptureMs == null || nowMs - w.lastCaptureMs! >= stepMs;
      if (due) dueIds.add(t.id);
    }

    // Forget a window only after the track has been GONE for longer than the
    // capture duration — i.e. the tracker has truly dropped it (track ids are
    // never reused, so it can't come back). A momentary "lost" blip must NOT
    // delete the window, or the same id returning would wrongly restart a fresh
    // capture window and double the photos.
    _windows.removeWhere(
      (id, w) => !activeIds.contains(id) && nowMs - w.lastSeenMs > durationMs,
    );

    if (dueIds.isEmpty) return null;

    // Optimistically mark as photographed so the next frames respect the step.
    for (final id in dueIds) {
      _windows[id]?.lastCaptureMs = nowMs;
    }
    return PendingCapture(
      fileName: 'roi_${sessionId}_$nowMs.jpg',
      trackIds: dueIds,
      capturedAtMs: nowMs,
    );
  }

  /// Grabs the image and writes [pending.fileName]. Safe to fire-and-forget;
  /// overlapping calls are skipped via the busy flag. In the fast path the bytes
  /// are already an ROI crop; in the full-res path they're a full still that is
  /// cropped here (native region-decode, with a pure-Dart fallback).
  Future<void> capture(PendingCapture pending) async {
    if (_busy) return;
    _busy = true;
    final sw = Stopwatch()..start();
    try {
      final bytes = await captureFn();
      if (bytes == null) return;

      Uint8List finalBytes = bytes;
      if (cropAfterCapture) {
        final roi = roiProvider();
        Uint8List? native;
        try {
          native = await _cropChannel.invokeMethod<Uint8List>('cropRoiJpeg', {
            'bytes': bytes,
            'cx': roi.centerX,
            'cy': roi.centerY,
            'side': roi.sideFraction,
            'quality': 90,
          });
        } catch (_) {
          native = null;
        }
        finalBytes =
            native ??
            await compute<_CropArgs, Uint8List>(
              _cropJpeg,
              _CropArgs(bytes, roi.centerX, roi.centerY, roi.sideFraction),
            );
      }
      final outFile = File('${framesDir.path}/${pending.fileName}');
      outFile.parent.createSync(recursive: true);
      await outFile.writeAsBytes(finalBytes, flush: true);
      sw.stop();
      onStat?.call(
        CaptureStat(
          fileName: pending.fileName,
          trackIds: pending.trackIds,
          totalMs: sw.elapsedMicroseconds / 1000.0,
          bytes: finalBytes.length,
          fullRes: cropAfterCapture,
        ),
      );
    } finally {
      _busy = false;
    }
  }
}

class _Window {
  final int startMs;
  int? lastCaptureMs;
  int lastSeenMs;
  _Window({
    required this.startMs,
    required this.lastCaptureMs,
    required this.lastSeenMs,
  });
}

class _CropArgs {
  final Uint8List bytes;
  final double centerX;
  final double centerY;
  final double sideFraction;
  const _CropArgs(this.bytes, this.centerX, this.centerY, this.sideFraction);
}

/// Runs on a background isolate: decode the JPEG, crop a SQUARE centred on the
/// ROI, re-encode JPEG. The square's side is taken from the captured image's own
/// width, so the saved crop is square in real pixels no matter how the still's
/// shape compares to the smaller analysis frame. Falls back to the original
/// bytes if decoding fails.
Uint8List _cropJpeg(_CropArgs args) {
  final decoded = img.decodeJpg(args.bytes);
  if (decoded == null) return args.bytes;
  final w = decoded.width;
  final h = decoded.height;
  // Side length in this image's pixels, snapped to a multiple of 32 (model
  // friendly) and never larger than the shorter edge.
  final maxSide = (w < h ? w : h);
  var side = snapToMultipleOf32(args.sideFraction * w);
  if (side > maxSide) side = (maxSide ~/ 32) * 32;
  if (side < 32) side = maxSide < 32 ? maxSide : 32;
  // Top-left of the square, centred on the ROI and kept fully inside the image.
  final x = (args.centerX * w - side / 2).round().clamp(0, w - side);
  final y = (args.centerY * h - side / 2).round().clamp(0, h - side);
  final cropped = img.copyCrop(decoded, x: x, y: y, width: side, height: side);
  return Uint8List.fromList(img.encodeJpg(cropped, quality: 90));
}
