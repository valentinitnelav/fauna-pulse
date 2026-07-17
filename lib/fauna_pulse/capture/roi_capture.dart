// FaunaPulse — time-lapse capture of the ROI while a visit is active.
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
// Each photo comes from one of two sources (see [RoiCaptureMode] in
// session_config.dart): a cheap crop of the live analysis frame, or a
// full-resolution high-res photo (CameraX ImageCapture via the plugin's
// capturePhoto) cropped to the ROI square. In auto mode the choice is made per
// photo by [chooseCapturePath]: pay for a high-res photo only when the ROI is
// too small in the stream to meet the user's minimum saved size. Cropping one decodes JPEG
// data, so it is done natively off the platform thread (with a background-
// isolate Dart fallback) to keep the camera preview smooth.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../logging/app_error_hooks.dart';

import '../models/roi.dart';
import '../models/session_config.dart';
import '../models/track.dart';

/// The source a given photo is taken from: [fast] = crop of the live analysis
/// frame (no camera stall), [highRes] = full-resolution photo, region-cropped
/// (renamed from "still" in round 112 — the old name wrongly suggested crisp
/// images; these are the slower, motion-blur-prone ones).
enum CapturePath {
  fast,
  highRes;

  /// The FROZEN wire name logged as `path` in every `capture` record:
  /// [highRes] still writes `"still"` — that value is in every session ever
  /// recorded and external parsers key on it, so the Dart rename must not
  /// change the log format. Mirrors `_captureModeWireName` in
  /// session_config.dart.
  String get wireName => this == CapturePath.highRes ? 'still' : name;

  /// The user-facing name (round 112 rename): what on-screen readouts and
  /// the summary display — never what goes into the log.
  String get uiName => this == CapturePath.highRes ? 'high-res' : 'fast';
}

/// Builds the on-disk name of one saved ROI photo, e.g.
/// `roi_k7x2_2026-07-14_153045_123.jpg`: the per-session random [token] (see
/// [RoiCaptureScheduler.sessionToken]) followed by the TRIGGER moment
/// [epochMs] — the frame on which the photo became due, NOT the moment the
/// JPEG finished writing — as a fixed-width LOCAL-time stamp (date, HHmmss,
/// milliseconds).
///
/// The token comes first so that photos from many sessions/phones pooled into
/// one folder (post-processing, model training) sort grouped by session;
/// within a session the token is constant and the stamp is zero-padded to a
/// fixed width, so alphabetical order equals capture order — the gallery
/// export relies on this. Pattern for downstream parsing:
/// `^roi_([a-z0-9]+)_(\d{4}-\d{2}-\d{2})_(\d{6})_(\d{3})\.jpg$`
String roiPhotoFileName(int epochMs, String token) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-'
      '${two(t.day)}';
  final time = '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  final ms = t.millisecond.toString().padLeft(3, '0');
  return 'roi_${token}_${date}_${time}_$ms.jpg';
}

/// A high-res photo exactly as the camera delivered it: JPEG bytes that are NOT
/// yet rotated upright, plus the clockwise rotation (0/90/180/270) and the
/// front-camera mirror flag needed to interpret them. Skipping the upfront
/// full-frame rotation is the round-63 lag fix: rotating the whole 12 MP
/// photo took ~1.5 s per photo ON THE MAIN THREAD (freezing preview and
/// detector); now only the small cropped square is rotated.
class RawHighRes {
  final Uint8List bytes;
  final int rotationDegrees;
  final bool isFront;

  /// Round 108: how old the frame's CONTENT is relative to the capture
  /// request, in ms. NEGATIVE = the camera's zero-shutter-lag really served
  /// a frame from before the request; large positive = the photo shows the
  /// scene ~that long AFTER the detection that triggered it (a fast insect
  /// will have left). Null on odd HALs or fallback capture paths.
  final double? contentLagMs;

  /// Round 108: plain shutter-to-bytes wait in ms (request → JPEG in hand).
  final double? callbackLagMs;

  /// Round 114: the content's sensor-exposure moment as EPOCH ms — the same
  /// wall clock as the frame timestamps in `detections` records, so logged
  /// boxes can be time-matched to this photo. Null on odd HALs and on the
  /// preview-snapshot fallback path.
  final double? contentAtMs;

  const RawHighRes({
    required this.bytes,
    required this.rotationDegrees,
    required this.isFront,
    this.contentLagMs,
    this.callbackLagMs,
    this.contentAtMs,
  });
}

/// Where an upright-frame rectangle lands inside the RAW (not yet rotated)
/// high-res photo. Android hands photos over "as the sensor sees them" plus the
/// clockwise rotation that would make them upright; instead of rotating the
/// full photo we map the crop rectangle into raw coordinates, cut there, and
/// rotate only the small square afterwards. Edges are exclusive on the
/// right/bottom. Mirrored by `rawRectForUprightRect` in MainActivity.kt —
/// keep the two in sync.
({int left, int top, int right, int bottom}) rawRectForUprightRect({
  required int rotationDegrees,
  required int rawW,
  required int rawH,
  required int left,
  required int top,
  required int right,
  required int bottom,
}) {
  switch (rotationDegrees.remainder(360)) {
    case 90: // upright = raw rotated 90° clockwise (portrait back camera)
      return (
        left: top,
        top: rawH - right,
        right: bottom,
        bottom: rawH - left,
      );
    case 180:
      return (
        left: rawW - right,
        top: rawH - bottom,
        right: rawW - left,
        bottom: rawH - top,
      );
    case 270:
      return (
        left: rawW - bottom,
        top: left,
        right: rawW - top,
        bottom: right,
      );
    default:
      return (left: left, top: top, right: right, bottom: bottom);
  }
}

/// Side (pixels) an ROI crop of [sideFraction] has when cut from a `w`×`h`
/// source: the nearest multiple of 32, capped at the largest multiple of 32
/// that fits the source's short side. This is the SAME math every crop path
/// (native fast crop, native high-res crop, Dart fallback) applies, so callers
/// can predict the saved size without decoding anything. Returns 0 when the
/// source size is not yet known.
int savedSidePx(double sideFraction, int w, int h) {
  if (w <= 0 || h <= 0) return 0;
  final cap = (math.min(w, h) ~/ 32) * 32;
  final px = snapToMultipleOf32(sideFraction * w);
  return px.clamp(32, math.max(32, cap));
}

/// Applies the user's "max saved side" cap: sides larger than the cap are
/// downscaled to the largest multiple of 32 that fits it. `maxPx <= 0` = no cap.
int capSavedSidePx(int sidePx, int maxPx) {
  if (maxPx <= 0) return sidePx;
  final cap = math.max(32, (maxPx ~/ 32) * 32);
  return math.min(sidePx, cap);
}

/// Decides, for one photo, which source to use. Pure function so the decision
/// table is unit-testable without a camera:
///
///  * fast mode     → always the live-frame crop;
///  * high-res mode → the full high-res photo, unless its size is unknown (the
///    one-time probe failed), in which case degrade to fast rather than save
///    nothing;
///  * auto mode     → the live-frame crop when it already meets [targetPx],
///    otherwise the high-res photo (same probe-failure fallback).
CapturePath chooseCapturePath({
  required RoiCaptureMode mode,
  required int targetPx,
  required double roiSideFraction,
  required int streamW,
  required int streamH,
  required int highResW,
  required int highResH,
}) {
  final highResKnown = highResW > 0 && highResH > 0;
  switch (mode) {
    case RoiCaptureMode.fast:
      return CapturePath.fast;
    case RoiCaptureMode.highRes:
      return highResKnown ? CapturePath.highRes : CapturePath.fast;
    case RoiCaptureMode.auto:
      if (savedSidePx(roiSideFraction, streamW, streamH) >= targetPx) {
        return CapturePath.fast;
      }
      return highResKnown ? CapturePath.highRes : CapturePath.fast;
  }
}

/// Stream-grid side (px) of a logged ROI block — the number the user saw on
/// screen while recording. `roi` is the `roi` sub-object of a
/// `start_of_session` / `roi_update` record, whose `width_px`/`frame_width_px`
/// may be expressed against the full-resolution photo frame (that is what made the
/// summary show a non-÷32 "1333 × 1333" for an on-screen 480 ROI). The pair is
/// still a valid width FRACTION, so re-projecting it onto the analysis frame
/// with the same snap/cap math as the live readout ([savedSidePx]) recovers
/// the on-screen value exactly. Round-109+ records carry the value directly as
/// `roi_side_stream_px`; this is the fallback for older logs. Returns null
/// when the block or the analysis dims are unusable.
int? roiStreamSideFromLog(Map<dynamic, dynamic> roi, int analysisW, int analysisH) {
  final widthPx = (roi['width_px'] as num?)?.toDouble();
  final frameW = (roi['frame_width_px'] as num?)?.toDouble();
  if (widthPx == null || frameW == null || widthPx <= 0 || frameW <= 0) {
    return null;
  }
  if (analysisW <= 0 || analysisH <= 0) return null;
  return savedSidePx(widthPx / frameW, analysisW, analysisH);
}

/// Picks the analysis stream size the app should default to when the user has
/// never chosen one: the SMALLEST device-supported size whose short side is at
/// least [minShortSide]. Rationale: [savedSidePx] caps fast live-frame crops
/// at the stream's short side, so a short side ≥ the default saved-photo
/// target (1024) lets auto capture mode reach the target via the fast path
/// more often, avoiding the laggy high-res path (round 108: ~0.4–0.8 s
/// behind the trigger on the Xiaomi). "Smallest that qualifies" keeps the
/// per-frame conversion cost — and therefore heat — as low as the goal allows.
///
/// [options] are HAL-probed `"WxH"` strings (malformed entries are ignored).
/// Candidates whose area exceeds [ceilingArea] (> 0 = the round-56 analysis
/// ceiling: the size above which the pipeline silently delivers less than
/// requested) are skipped. Round 122: when NO size reaches [minShortSide]
/// (a phone weaker than the target), the largest size under the ceiling is
/// returned instead — the best fast crops that phone can produce. Returns
/// null only when nothing is usable at all — the caller keeps the current
/// setting.
(int, int)? autoStreamResolution(
  List<String> options, {
  int ceilingArea = 0,
  int minShortSide = 1024,
}) {
  (int, int)? best;
  (int, int)? largest;
  for (final opt in options) {
    final parts = opt.toLowerCase().split('x');
    if (parts.length != 2) continue;
    final w = int.tryParse(parts[0].trim());
    final h = int.tryParse(parts[1].trim());
    if (w == null || h == null || w <= 0 || h <= 0) continue;
    if (ceilingArea > 0 && w * h > ceilingArea) continue;
    if (largest == null || w * h > largest.$1 * largest.$2) {
      largest = (w, h);
    }
    if (math.min(w, h) < minShortSide) continue;
    if (best == null ||
        w * h < best.$1 * best.$2 ||
        (w * h == best.$1 * best.$2 &&
            math.max(w, h) < math.max(best.$1, best.$2))) {
      best = (w, h);
    }
  }
  return best ?? largest;
}

/// Native fast-crop channel: decodes only the ROI rectangle from the full-res
/// JPEG (Android BitmapRegionDecoder), avoiding a whole-image decode in Dart.
const MethodChannel _cropChannel = MethodChannel('faunapulse/crop');

/// Reads only a JPEG's pixel dimensions (width, height) on a background isolate.
/// Upright (as-displayed) dimensions of a high-res photo that was delivered with
/// [rotationDegrees], given the (w, h) a JPEG decoder reported for it.
///
/// Round 64 bug fix: some JPEG decoders honour the EXIF orientation tag and
/// report the image already upright, while others report the raw sensor
/// orientation — blindly swapping w/h for a 90°/270° rotation double-rotated
/// the startup probe (session_97: the app predicted 1024 px photos and saved
/// 992 px ones, because every prediction ran against a 4000-px-wide frame
/// that is really 3000 px wide upright). The phone is held portrait in this
/// app, so for a sideways rotation the upright frame must be portrait: swap
/// only when the reported dims are still landscape.
(int, int) uprightHighResDims(int rotationDegrees, int w, int h) {
  final rot = ((rotationDegrees.remainder(360)) + 360) % 360;
  final sideways = rot == 90 || rot == 270;
  if (sideways && w > h) return (h, w);
  return (w, h);
}

/// Used once at startup to learn the full-resolution photo size so the UI can
/// show the true ROI resolution (the analysis frame fed to the model is much
/// smaller than the saved photo). Returns null if the bytes can't be decoded.
/// NOTE: the decode is EXIF-aware, so the reported size may already be
/// upright — always interpret it through [uprightHighResDims].
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

  /// The trigger moment (ms since epoch): the frame on which the photo became
  /// due — the same instant the filename stamp encodes. The `capture` record
  /// itself is logged AFTER the write finishes (its `time_ms` is the
  /// saved-to-storage moment), so this field is what the summary's photo
  /// browser shows as "Captured".
  final int capturedAtMs;

  /// Wall-clock milliseconds for the whole grab (+ crop) + write.
  final double totalMs;

  /// Size of the saved JPEG in bytes.
  final int bytes;

  /// Which source this photo came from (per-photo in auto mode).
  final CapturePath path;

  /// Side (pixels) of the saved square, predicted with [savedSidePx] +
  /// [capSavedSidePx] — the same math the crops apply, so no decode needed.
  final int savedPx;

  /// How long the image grab alone took (the high-res/fast capture function),
  /// ms — the rest of [totalMs] is crop + encode + write (round 108).
  final double? grabMs;

  /// High-res path only (round 108): content/callback lag from [RawHighRes] —
  /// negative content lag = zero-shutter-lag actually worked for this photo.
  final double? contentLagMs;
  final double? callbackLagMs;

  /// Sync companion (round 108): when a high-res-path photo also saved the
  /// trigger-moment live-frame crop next to it, its filename/size. Null when
  /// the companion is disabled, the path was fast, or the grab failed.
  final String? liveJpeg;
  final int? liveBytes;
  final int? liveSavedPx;

  /// How long after the trigger moment the companion's frame was grabbed
  /// (ms, round 112) — an upper bound on how much the companion's CONTENT
  /// can lag the trigger (it serves the newest stream frame at grab time,
  /// so typically well under one frame interval plus scheduling delay).
  /// The high-res photo's [contentLagMs] is the number to compare it against.
  final int? liveLagMs;

  /// Round 114: the high-res photo's content moment as EPOCH ms (from
  /// [RawHighRes.contentAtMs]) — what the summary/post-processing match
  /// detection frames against. Null on the fast path and odd HALs.
  final int? contentAtMs;

  /// True for the full-resolution high-res path (which briefly stalls the camera),
  /// false for the fast live-frame crop.
  bool get fullRes => path == CapturePath.highRes;

  const CaptureStat({
    required this.fileName,
    required this.trackIds,
    required this.capturedAtMs,
    required this.totalMs,
    required this.bytes,
    required this.path,
    required this.savedPx,
    this.grabMs,
    this.contentLagMs,
    this.callbackLagMs,
    this.liveJpeg,
    this.liveBytes,
    this.liveSavedPx,
    this.liveLagMs,
    this.contentAtMs,
  });
}

/// Schedules and performs ROI captures. Call [onTracks] once per processed
/// frame while recording.
class RoiCaptureScheduler {
  /// Where ROI JPEGs are written (created if missing).
  final Directory framesDir;

  /// Short per-session random token embedded in every photo filename (see
  /// [roiPhotoFileName]). Generated once per session by SessionRecorder and
  /// logged as `file_token` in the start record, it keeps names unique even
  /// when two phones capture in the same millisecond and their photos are
  /// later merged into one folder.
  final String sessionToken;

  /// Milliseconds between photos for a given track.
  final int stepMs;

  /// Total milliseconds to keep photographing a track from first sight.
  final int durationMs;

  /// Grabs an ROI crop straight from the live analysis frame (fast path),
  /// already capped to [targetPx] natively. Returns null if unavailable.
  final Future<Uint8List?> Function() fastCaptureFn;

  /// Grabs a full-resolution photo (high-res path) as the camera delivered it
  /// (unrotated + rotation info; see [RawHighRes]). The bytes are a FULL frame
  /// that this scheduler then crops to the ROI. Returns null if unavailable.
  final Future<RawHighRes?> Function() highResCaptureFn;

  /// Current ROI (may change if the user adjusts it mid-session).
  final Roi Function() roiProvider;

  /// Photo source policy (fast / high-res / auto) — see [RoiCaptureMode].
  final RoiCaptureMode mode;

  /// The single saved-side setting (px): auto-decision threshold AND downscale
  /// cap, so photos save at exactly this size whenever the ROI can supply it.
  final int targetPx;

  /// Live analysis-frame size (w, h) — the fast path's crop source.
  final (int, int) Function() streamDims;

  /// Full-resolution photo size (w, h) learned by the one-time probe; (0, 0)
  /// when the probe hasn't succeeded (the high-res path then degrades to fast).
  final (int, int) Function() highResDims;

  /// Optional sink for per-photo timing/size, called after each successful write.
  /// Used to log a `capture` diagnostics record; never affects capture itself.
  final void Function(CaptureStat stat)? onStat;

  /// Optional sink for a failed capture (grab, crop or JPEG write threw).
  /// [capture] is fired-and-forgotten from the frame callback, so without
  /// this a failed photo save would be an unhandled async error nobody sees.
  final void Function(String fileName, Object error)? onError;

  /// Round 108: when a photo takes the HIGH-RES path, first save the
  /// live-frame fast crop of the trigger moment as `<name>_live.jpg` next to
  /// it. High-res photos land ~0.5–1 s after the detection that scheduled
  /// them (measured 760 ms median on the Xiaomi even with zero-shutter-lag
  /// granted), so a fast insect is often gone from them; the companion is
  /// small but shows the trigger moment. Written even when the high-res
  /// photo itself later fails.
  final bool syncCompanion;

  RoiCaptureScheduler({
    required this.framesDir,
    required this.sessionToken,
    required this.stepMs,
    required this.durationMs,
    required this.fastCaptureFn,
    required this.highResCaptureFn,
    required this.roiProvider,
    required this.mode,
    required this.targetPx,
    required this.streamDims,
    required this.highResDims,
    this.syncCompanion = false,
    this.onStat,
    this.onError,
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
      fileName: roiPhotoFileName(nowMs, sessionToken),
      trackIds: dueIds,
      capturedAtMs: nowMs,
    );
  }

  // Motion-only capture mode: no tracker runs, so there is one shared window
  // per "motion event" instead of one per track id.
  _Window? _motionWindow;

  /// Motion-driven counterpart of [evaluate] (motion-only capture mode, where
  /// the detector never runs and no track ids exist). Call it on every awake
  /// motion event; independent of the per-track windows.
  ///
  /// Same cadence semantics as a track window: first photo immediately when
  /// motion starts, then one every [stepMs] while motion persists, stopping
  /// [durationMs] after the event began. A NEW event = a gate sleep→wake
  /// cycle: [resetMotionWindow] re-arms when the gate goes idle, so the next
  /// wake bursts again (round 96 — the on-screen chip IS the re-arm state).
  /// The gap>durationMs forget rule below survives only as a backstop for
  /// paused streams (settings sheet, blackout); while the gate is awake the
  /// stream emissions never pause, so it cannot fire — it originally doubled
  /// as the re-arm rule and silently required ~wakeSeconds+duration of total
  /// stillness before a second burst (the round-96 field bug).
  PendingCapture? evaluateMotion(int nowMs) {
    if (_busy) return null;

    var w = _motionWindow;
    if (w != null && nowMs - w.lastSeenMs > durationMs) w = null;
    w ??= _Window(startMs: nowMs, lastCaptureMs: null, lastSeenMs: nowMs);
    _motionWindow = w;
    w.lastSeenMs = nowMs;

    if (nowMs - w.startMs > durationMs) return null; // window exhausted
    final due = w.lastCaptureMs == null || nowMs - w.lastCaptureMs! >= stepMs;
    if (!due) return null;

    w.lastCaptureMs = nowMs;
    return PendingCapture(
      fileName: roiPhotoFileName(nowMs, sessionToken),
      trackIds: const [],
      capturedAtMs: nowMs,
    );
  }

  /// Re-arms the motion time-lapse: the next [evaluateMotion] starts a fresh
  /// window (immediate first photo). Called when the motion gate goes idle —
  /// a sleep→wake cycle is what defines a new motion event.
  void resetMotionWindow() {
    _motionWindow = null;
  }

  /// Grabs the image and writes [pending.fileName]. Safe to fire-and-forget;
  /// overlapping calls are skipped via the busy flag. The photo source is
  /// chosen HERE, per photo (see [chooseCapturePath]): fast-path bytes arrive
  /// already cropped to the ROI; high-res-path bytes are a full frame that is
  /// cropped (and, above [maxPx], downscaled) here — native region-decode,
  /// with a pure-Dart fallback.
  Future<void> capture(PendingCapture pending) async {
    if (_busy) return;
    _busy = true;
    final sw = Stopwatch()..start();
    try {
      final roi = roiProvider();
      final (streamW, streamH) = streamDims();
      final (highResW, highResH) = highResDims();
      final path = chooseCapturePath(
        mode: mode,
        targetPx: targetPx,
        roiSideFraction: roi.sideFraction,
        streamW: streamW,
        streamH: streamH,
        highResW: highResW,
        highResH: highResH,
      );

      Uint8List finalBytes;
      int savedPx;
      double? grabMs;
      double? contentLagMs;
      double? callbackLagMs;
      int? contentAtMs;
      String? liveJpeg;
      int? liveBytes;
      int? liveSavedPx;
      int? liveLagMs;
      if (path == CapturePath.highRes) {
        // Sync companion FIRST (round 108): the live-frame crop is a cheap
        // memory grab of (nearly) the trigger moment — taken before the
        // high-res photo so the ~0.5–1 s shutter wait can't age it.
        // Best-effort: a companion failure must never cost the photo.
        if (syncCompanion) {
          try {
            final live = await fastCaptureFn();
            if (live != null) {
              // Measured at grab return, BEFORE the file write (writing
              // doesn't age the content): how far behind the trigger this
              // companion's content can be (round 112).
              liveLagMs =
                  DateTime.now().millisecondsSinceEpoch - pending.capturedAtMs;
              final liveName = pending.fileName.replaceFirst(
                RegExp(r'\.jpg$'),
                '_live.jpg',
              );
              final liveFile = File('${framesDir.path}/$liveName');
              liveFile.parent.createSync(recursive: true);
              await liveFile.writeAsBytes(live, flush: true);
              liveJpeg = liveName;
              liveBytes = live.length;
              liveSavedPx = capSavedSidePx(
                savedSidePx(roi.sideFraction, streamW, streamH),
                targetPx,
              );
            }
          } catch (e) {
            logSwallowed('sync_companion', e);
          }
        }
        final grabSw = Stopwatch()..start();
        final raw = await highResCaptureFn();
        grabSw.stop();
        grabMs = grabSw.elapsedMicroseconds / 1000.0;
        contentLagMs = raw?.contentLagMs;
        callbackLagMs = raw?.callbackLagMs;
        contentAtMs = raw?.contentAtMs?.round();
        if (raw == null) {
          // The high-res photo failed, but a companion may already be on
          // disk — report it so the log (and the photo count) reflect what
          // really saved.
          if (liveJpeg != null) {
            sw.stop();
            onStat?.call(
              CaptureStat(
                fileName: liveJpeg,
                trackIds: pending.trackIds,
                capturedAtMs: pending.capturedAtMs,
                totalMs: sw.elapsedMicroseconds / 1000.0,
                bytes: liveBytes ?? 0,
                path: CapturePath.fast,
                savedPx: liveSavedPx ?? 0,
                grabMs: grabMs,
              ),
            );
          }
          return;
        }
        savedPx = capSavedSidePx(
          savedSidePx(roi.sideFraction, highResW, highResH),
          targetPx,
        );
        Uint8List? native;
        try {
          native = await _cropChannel.invokeMethod<Uint8List>('cropRoiJpeg', {
            'bytes': raw.bytes,
            'cx': roi.centerX,
            'cy': roi.centerY,
            'side': roi.sideFraction,
            'quality': 90,
            'maxPx': targetPx,
            // The high-res photo is NOT rotated upright (round-63 lag fix);
            // the native crop maps the ROI into raw coordinates and rotates
            // only the small square.
            'rotationDegrees': raw.rotationDegrees,
            'isFront': raw.isFront,
          });
        } catch (e) {
          // The Dart fallback crop below still saves the photo, just slower.
          logSwallowed('native_still_crop', e);
          native = null;
        }
        finalBytes =
            native ??
            await compute<_CropArgs, Uint8List>(
              _cropJpeg,
              _CropArgs(
                raw.bytes,
                roi.centerX,
                roi.centerY,
                roi.sideFraction,
                targetPx,
                raw.rotationDegrees,
                raw.isFront,
              ),
            );
      } else {
        final grabSw = Stopwatch()..start();
        final bytes = await fastCaptureFn();
        grabSw.stop();
        grabMs = grabSw.elapsedMicroseconds / 1000.0;
        if (bytes == null) return;
        finalBytes = bytes;
        // Fast-path bytes come already cropped AND capped to the target
        // natively (ImageUtils.cropRoiFromFrame), so just predict the size.
        savedPx = capSavedSidePx(
          savedSidePx(roi.sideFraction, streamW, streamH),
          targetPx,
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
          capturedAtMs: pending.capturedAtMs,
          totalMs: sw.elapsedMicroseconds / 1000.0,
          bytes: finalBytes.length,
          path: path,
          savedPx: savedPx,
          grabMs: grabMs,
          contentLagMs: contentLagMs,
          callbackLagMs: callbackLagMs,
          liveJpeg: liveJpeg,
          liveBytes: liveBytes,
          liveSavedPx: liveSavedPx,
          liveLagMs: liveLagMs,
          contentAtMs: contentAtMs,
        ),
      );
    } catch (e) {
      // The Dart-fallback crop and the final file write were previously only
      // wrapped in try/finally: a full disk here became an invisible unhandled
      // async error. Report it so the session log gets an app_error line.
      onError?.call(pending.fileName, e);
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
  final int maxPx;
  final int rotationDegrees;
  final bool isFront;
  const _CropArgs(
    this.bytes,
    this.centerX,
    this.centerY,
    this.sideFraction,
    this.maxPx,
    this.rotationDegrees,
    this.isFront,
  );
}

/// Runs on a background isolate (fallback when the native crop fails): decode
/// the JPEG, crop a SQUARE centred on the ROI, downscale if it exceeds the
/// user's target side, rotate the small square upright, re-encode JPEG. The
/// ROI is defined on the UPRIGHT frame; the bytes may be unrotated (see
/// [RawHighRes]), so the crop rectangle is mapped into raw coordinates with
/// [rawRectForUprightRect]. Falls back to the original bytes if decoding fails.
Uint8List _cropJpeg(_CropArgs args) {
  final decoded = img.decodeJpg(args.bytes);
  if (decoded == null) return args.bytes;
  var rot = args.rotationDegrees.remainder(360);
  // Some JPEG decoders honour the EXIF orientation tag and hand the image
  // back already upright. Phones report 90/270 for portrait shots on a
  // landscape sensor, so if the decoded image is already portrait the
  // rotation has been applied for us — skip the mapping. (180° can't be told
  // apart this way; back cameras report 90/270 in practice.)
  if ((rot == 90 || rot == 270) && decoded.height > decoded.width) rot = 0;
  final rawW = decoded.width;
  final rawH = decoded.height;
  // Upright dimensions — the frame the ROI fractions refer to.
  final w = (rot == 90 || rot == 270) ? rawH : rawW;
  final h = (rot == 90 || rot == 270) ? rawW : rawH;
  // Side length in upright pixels, snapped to a multiple of 32 (model
  // friendly) and never larger than the shorter edge.
  final maxSide = (w < h ? w : h);
  var side = snapToMultipleOf32(args.sideFraction * w);
  if (side > maxSide) side = (maxSide ~/ 32) * 32;
  if (side < 32) side = maxSide < 32 ? maxSide : 32;
  // Top-left of the square, centred on the ROI and kept fully inside the image.
  var x = (args.centerX * w - side / 2).round().clamp(0, w - side);
  final y = (args.centerY * h - side / 2).round().clamp(0, h - side);
  // Front cameras are shown mirrored; the ROI was placed on the mirrored
  // preview, so un-mirror its X before mapping into raw coordinates.
  if (args.isFront) x = w - side - x;
  final rr = rawRectForUprightRect(
    rotationDegrees: rot,
    rawW: rawW,
    rawH: rawH,
    left: x,
    top: y,
    right: x + side,
    bottom: y + side,
  );
  var cropped = img.copyCrop(
    decoded,
    x: rr.left,
    y: rr.top,
    width: side,
    height: side,
  );
  // Downscale (never upscale) to the target side BEFORE rotating — cheaper to
  // rotate the smaller square. Cubic interpolation keeps edges/detail well
  // when shrinking; the classifier loses far less to this than to JPEG
  // storage bloat at native size.
  final capped = capSavedSidePx(side, args.maxPx);
  if (capped < side) {
    cropped = img.copyResize(
      cropped,
      width: capped,
      height: capped,
      interpolation: img.Interpolation.cubic,
    );
  }
  if (rot != 0) cropped = img.copyRotate(cropped, angle: rot);
  if (args.isFront) cropped = img.flipHorizontal(cropped);
  return Uint8List.fromList(img.encodeJpg(cropped, quality: 90));
}
