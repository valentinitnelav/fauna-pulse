// FaunaPulse — offline tracker replay harness (round 105).
//
// Purpose: compare frame-association algorithms (ByteTrack vs C-BIoU, or two
// tunings of the same one) on REAL field data instead of trusting published
// pedestrian benchmarks. A session recorded with Settings → AI → Visit
// tracking → Advanced → "Log raw detections" carries one `raw_detections`
// record per processed frame — the detector's boxes BEFORE tracking, in the
// exact coordinate space the tracker was fed. This file replays those frames
// through any [InsectTracker] and reports the numbers the app actually
// exists to produce: how many visits, and how long each lasted.
//
// It runs anywhere `flutter test` runs (no device needed):
//
//   flutter test test/fauna_pulse/tracker_replay_test.dart \
//       --dart-define=REPLAY_SESSION=/absolute/path/to/session.jsonl
//
// (Without the define, that test file just runs its synthetic unit tests.)
//
// Metrics are deliberately NOT MOTA/HOTA: the app's deliverable is anonymous
// event count + duration, so the comparison is "how many visits did each
// tracker count and for how long" — to be judged against a hand count from
// the session's saved photos.

import 'dart:convert';
import 'dart:ui';

import '../models/track.dart';
import 'tracker.dart';

/// One replayable frame: its wall-clock timestamp and the detector's boxes.
class ReplayFrame {
  final int timestampMs;
  final List<Detection> detections;
  const ReplayFrame({required this.timestampMs, required this.detections});
}

/// Parses the `raw_detections` records out of session.jsonl lines. All other
/// record types are skipped, as are unparseable lines (a crash-truncated last
/// line must not kill a replay).
///
/// Payload format (KEEP IN SYNC with `SessionRecorder.recordFrame`):
/// `{"type":"raw_detections","frame_ms":<int>,`
/// `"boxes":[[left,top,right,bottom,confidence,classIndex],...]}`
/// with boxes frame-normalized 0..1.
List<ReplayFrame> parseRawDetectionLines(Iterable<String> lines) {
  final frames = <ReplayFrame>[];
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> rec;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) continue;
      rec = decoded.cast<String, dynamic>();
    } catch (_) {
      continue; // truncated/corrupt line
    }
    if (rec['type'] != 'raw_detections') continue;
    final ts = (rec['frame_ms'] as num?)?.toInt();
    final boxes = rec['boxes'];
    if (ts == null || boxes is! List) continue;
    final dets = <Detection>[];
    for (final b in boxes) {
      if (b is! List || b.length < 6) continue;
      final l = (b[0] as num).toDouble();
      final t = (b[1] as num).toDouble();
      final r = (b[2] as num).toDouble();
      final bt = (b[3] as num).toDouble();
      dets.add(
        Detection(
          box: Rect.fromLTRB(l, t, r, bt),
          confidence: (b[4] as num).toDouble(),
          classIndex: (b[5] as num).toInt(),
          className: 'class${(b[5] as num).toInt()}',
        ),
      );
    }
    frames.add(ReplayFrame(timestampMs: ts, detections: dets));
  }
  frames.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  return frames;
}

// --- Frame-stream degraders (round 107) -------------------------------------
// Irregular-delivery stress scenarios: the same recorded detections, thinned
// the way a hot/throttled phone would deliver them. Timestamps are always the
// ORIGINAL ones — only which frames survive changes — so the trackers' time
// handling is what gets exercised.

/// Keeps every [n]-th frame (n=2 halves the rate, n=3 thirds it, ...).
List<ReplayFrame> keepEveryNth(List<ReplayFrame> frames, int n) => [
  for (var i = 0; i < frames.length; i++)
    if (i % n == 0) frames[i],
];

/// Periodically removes whole blocks of frames: every [everySeconds] of
/// stream time, the frames inside the next [gapSeconds] are dropped —
/// isolated 0.5–2 s stalls, like a camera hiccup or a burst of high-res photos.
List<ReplayFrame> injectGaps(
  List<ReplayFrame> frames, {
  required double gapSeconds,
  required double everySeconds,
}) {
  if (frames.isEmpty) return frames;
  final t0 = frames.first.timestampMs;
  final everyMs = (everySeconds * 1000).round();
  final gapMs = (gapSeconds * 1000).round();
  return [
    for (final f in frames)
      if ((f.timestampMs - t0) % everyMs >= gapMs) f,
  ];
}

/// Thins the stream to a repeating staircase of FPS caps: the stream time is
/// split into consecutive [segmentSeconds] segments cycling through
/// [fpsSteps] (e.g. `[15, 3, 10]`), and within each segment frames closer
/// than 1/fps to the last kept frame are dropped. Models the auto-throttle
/// ramping the rate up and down mid-session.
List<ReplayFrame> staircaseFps(
  List<ReplayFrame> frames,
  List<double> fpsSteps, {
  double segmentSeconds = 10,
}) {
  if (frames.isEmpty || fpsSteps.isEmpty) return frames;
  final t0 = frames.first.timestampMs;
  final segMs = (segmentSeconds * 1000).round();
  final kept = <ReplayFrame>[];
  var lastKeptTs = -1 << 62;
  for (final f in frames) {
    final seg = ((f.timestampMs - t0) ~/ segMs) % fpsSteps.length;
    final minIntervalMs = (1000 / fpsSteps[seg]).round();
    if (f.timestampMs - lastKeptTs >= minIntervalMs) {
      kept.add(f);
      lastKeptTs = f.timestampMs;
    }
  }
  return kept;
}

/// What one replay run produced, in visitation-rate terms.
class TrackerReplayReport {
  /// Which algorithm ran ([InsectTracker.algorithmName]).
  final String algorithm;

  /// Frames fed in / detections across all of them.
  final int frames;
  final int detections;

  /// Distinct confirmed track ids — the visit count this tracker would have
  /// reported for the session.
  final int visits;

  /// Per-visit durations in seconds (first to last matched frame), in
  /// confirmation order. A fragmenting tracker shows up here as MORE, SHORTER
  /// visits than the hand count; a merging one as fewer, longer.
  final List<double> visitDurationsS;

  /// Most tracks confirmed simultaneously in any single frame.
  final int maxConcurrent;

  /// Largest working set the tracker ever held (tentative + confirmed +
  /// lost) — a memory/cost proxy.
  final int peakActiveTracks;

  /// Tracker cost per frame in milliseconds (mean and 95th percentile),
  /// measured around `update()` on the replaying machine — comparative
  /// between variants, not an on-phone absolute.
  final double meanTrackMs;
  final double p95TrackMs;

  const TrackerReplayReport({
    required this.algorithm,
    required this.frames,
    required this.detections,
    required this.visits,
    required this.visitDurationsS,
    required this.maxConcurrent,
    required this.peakActiveTracks,
    required this.meanTrackMs,
    required this.p95TrackMs,
  });

  double get totalVisitS => visitDurationsS.fold(0.0, (sum, d) => sum + d);

  double get meanVisitS =>
      visitDurationsS.isEmpty ? 0 : totalVisitS / visitDurationsS.length;

  double get medianVisitS {
    if (visitDurationsS.isEmpty) return 0;
    final sorted = List<double>.from(visitDurationsS)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// One human-readable block, for printing from the replay test.
  String summary() =>
      '$algorithm: $visits visit(s) over $frames frames '
      '($detections detections), '
      'durations mean ${meanVisitS.toStringAsFixed(1)} s / '
      'median ${medianVisitS.toStringAsFixed(1)} s / '
      'total ${totalVisitS.toStringAsFixed(1)} s, '
      'max concurrent $maxConcurrent, peak active $peakActiveTracks, '
      'track ${meanTrackMs.toStringAsFixed(3)} ms/frame '
      '(p95 ${p95TrackMs.toStringAsFixed(3)})';
}

/// Replays [frames] through [tracker], reproducing the live pipeline's
/// seconds→frames behavior:
///
///  * the detector-FPS estimate is an EMA of the frame gaps (pauses — gaps
///    far above the rhythm — are skipped, mirroring the round-85 resume
///    guard), and the tracker's frame budgets are re-derived from it about
///    once a second, exactly like the camera screen does;
///  * a gap longer than [occlusionSeconds] expires lost tracks first,
///    mirroring what `FrameProcessor.setGateIdle` does on a motion-gate wake
///    (while the gate sleeps, no `raw_detections` records were written, so
///    the gap in timestamps IS the sleep).
///
/// The budget formulas mirror `SessionConfig.occlusionFramesFor` /
/// `minHitsFramesFor` — KEEP IN SYNC.
TrackerReplayReport replayTracker({
  required InsectTracker tracker,
  required List<ReplayFrame> frames,
  double occlusionSeconds = 3.0,
  double minHitsSeconds = 0.2,
}) {
  tracker.reset();
  var fpsEma = 0.0;
  var lastTs = 0;
  var lastBudgetTs = 0;
  var detections = 0;
  var maxConcurrent = 0;
  var peakActive = 0;
  final trackMsSamples = <double>[];
  // id -> (firstSeenMs, lastSeenMs) of every track ever seen confirmed.
  final firstSeen = <int, int>{};
  final lastSeen = <int, int>{};
  final confirmOrder = <int>[];

  int framesFor(double seconds, double fps) {
    final f = (fps.isFinite && fps > 0) ? fps : 15.0;
    final n = (seconds * f).round().clamp(1, 600);
    return n;
  }

  for (final frame in frames) {
    if (lastTs > 0) {
      final dt = frame.timestampMs - lastTs;
      // A long stall (motion-gate sleep, throttle pause) is not a frame rate.
      final resumeMs = fpsEma > 0
          ? (5000.0 / fpsEma).clamp(2000.0, double.infinity)
          : 2000.0;
      if (dt > 0 && dt <= resumeMs) {
        final inst = 1000.0 / dt;
        fpsEma = fpsEma == 0 ? inst : 0.1 * inst + 0.9 * fpsEma;
      }
      // The live pipeline expires lost tracks when the gate wakes after
      // sleeping longer than the occlusion tolerance. One empty update first:
      // live, the still-but-empty frames before the gate slept would already
      // have aged any active track to "lost"; a replayed log jumps straight
      // from the last busy frame to the wake, so that aging must be
      // reproduced here or a pre-gap track could survive the expiry and
      // wrongly inherit its id across the gap.
      if (dt > occlusionSeconds * 1000) {
        tracker.update(const [], lastTs + 1);
        tracker.expireLostTracks();
      }
    }
    lastTs = frame.timestampMs;

    if (frame.timestampMs - lastBudgetTs >= 1000) {
      lastBudgetTs = frame.timestampMs;
      final buffer = framesFor(occlusionSeconds, fpsEma);
      final hits = framesFor(minHitsSeconds, fpsEma);
      if (buffer != tracker.trackBuffer || hits != tracker.minHitsToConfirm) {
        tracker.setFrameBudgets(trackBuffer: buffer, minHitsToConfirm: hits);
      }
    }

    detections += frame.detections.length;
    final sw = Stopwatch()..start();
    final tracks = tracker.update(frame.detections, frame.timestampMs);
    sw.stop();
    // The replay scores counts/durations only; drain the lifecycle events
    // (round 116) so they can't pile up across thousands of frames.
    tracker.drainEvents();
    trackMsSamples.add(sw.elapsedMicroseconds / 1000.0);
    if (tracks.length > maxConcurrent) maxConcurrent = tracks.length;
    if (tracker.activeTrackCount > peakActive) {
      peakActive = tracker.activeTrackCount;
    }
    for (final t in tracks) {
      if (!firstSeen.containsKey(t.id)) {
        firstSeen[t.id] = t.firstSeenMs;
        confirmOrder.add(t.id);
      }
      lastSeen[t.id] = t.lastSeenMs;
    }
  }

  trackMsSamples.sort();
  final meanMs = trackMsSamples.isEmpty
      ? 0.0
      : trackMsSamples.reduce((a, b) => a + b) / trackMsSamples.length;
  final p95Ms = trackMsSamples.isEmpty
      ? 0.0
      : trackMsSamples[((trackMsSamples.length - 1) * 0.95).floor()];

  return TrackerReplayReport(
    algorithm: tracker.algorithmName,
    frames: frames.length,
    detections: detections,
    visits: tracker.totalConfirmed,
    visitDurationsS: [
      for (final id in confirmOrder)
        ((lastSeen[id] ?? firstSeen[id]!) - firstSeen[id]!) / 1000.0,
    ],
    maxConcurrent: maxConcurrent,
    peakActiveTracks: peakActive,
    meanTrackMs: meanMs,
    p95TrackMs: p95Ms,
  );
}
