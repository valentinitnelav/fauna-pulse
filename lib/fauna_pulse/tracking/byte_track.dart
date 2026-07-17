// FaunaPulse — a lightweight ByteTrack-style multi-object tracker.
//
// Goal: given the detector's per-frame boxes, follow each insect across frames
// and hand it a stable "track id". This is what turns a stream of detections
// into countable, timeable *visits*.
//
// ByteTrack idea (simplified here, pure Dart, motion only — no appearance/Kalman):
//   1. Predict where each existing track will be (shift its box by its velocity).
//   2. First pass: match existing tracks to HIGH-confidence detections using
//      box overlap (IoU = Intersection-over-Union; 1.0 = identical boxes,
//      0.0 = no overlap).
//   3. Second pass: match still-unmatched tracks to LOW-confidence detections.
//      Keeping low-score boxes is ByteTrack's key trick — a partly occluded
//      bee often drops in confidence but should not lose its id.
//   4. Unmatched tracks are kept alive ("lost") for up to [trackBuffer] frames
//      (occlusion tolerance) before being discarded.
//   5. Unmatched HIGH-confidence detections start brand-new tracks.
//
// Matching uses a simple greedy strategy (take the highest-IoU pair first),
// which is more than enough for the handful of insects on a single flower.

import 'dart:ui';

import '../models/track.dart';
import 'tracker.dart';

/// Tunable tracker parameters, surfaced to the user in the Advanced tab.
class ByteTrackParams {
  /// Detections at or above this confidence are "high score" and may both
  /// match tracks and create new tracks. (ByteTrack's high/low split.)
  final double highThresh;

  /// Minimum box overlap (IoU) to accept a match in the first (high) pass.
  /// Larger = stricter matching ("movement tolerance": smaller allows faster
  /// frame-to-frame motion).
  final double matchThresh;

  /// Minimum box overlap (IoU) to accept a match in the second (low) pass.
  final double lowMatchThresh;

  /// How many consecutive un-matched frames a track survives before it is
  /// dropped ("occlusion tolerance" / track buffer).
  final int trackBuffer;

  /// How many matched frames before a tentative track becomes confirmed.
  final int minHitsToConfirm;

  /// Smoothing factor for the velocity estimate (0..1). The tracker predicts
  /// where a hidden insect will be by shifting its last box along its measured
  /// velocity; this controls how much weight the newest frame-to-frame motion
  /// gets. Higher = snappier but noisier prediction (good for fast movers);
  /// lower = steadier, effectively "assume it barely moved" (good for slow,
  /// landed insects).
  final double velocitySmoothing;

  const ByteTrackParams({
    this.highThresh = 0.5,
    this.matchThresh = 0.1,
    this.lowMatchThresh = 0.1,
    this.trackBuffer = 30,
    this.minHitsToConfirm = 3,
    this.velocitySmoothing = 0.5,
  });

  ByteTrackParams copyWith({
    double? highThresh,
    double? matchThresh,
    double? lowMatchThresh,
    int? trackBuffer,
    int? minHitsToConfirm,
    double? velocitySmoothing,
  }) => ByteTrackParams(
    highThresh: highThresh ?? this.highThresh,
    matchThresh: matchThresh ?? this.matchThresh,
    lowMatchThresh: lowMatchThresh ?? this.lowMatchThresh,
    trackBuffer: trackBuffer ?? this.trackBuffer,
    minHitsToConfirm: minHitsToConfirm ?? this.minHitsToConfirm,
    velocitySmoothing: velocitySmoothing ?? this.velocitySmoothing,
  );

  Map<String, dynamic> toJson() => {
    'highThresh': highThresh,
    'matchThresh': matchThresh,
    'lowMatchThresh': lowMatchThresh,
    'trackBuffer': trackBuffer,
    'minHitsToConfirm': minHitsToConfirm,
    'velocitySmoothing': velocitySmoothing,
  };

  factory ByteTrackParams.fromJson(Map<String, dynamic> j) => ByteTrackParams(
    highThresh: (j['highThresh'] as num?)?.toDouble() ?? 0.5,
    matchThresh: (j['matchThresh'] as num?)?.toDouble() ?? 0.1,
    lowMatchThresh: (j['lowMatchThresh'] as num?)?.toDouble() ?? 0.1,
    trackBuffer: (j['trackBuffer'] as num?)?.toInt() ?? 30,
    minHitsToConfirm: (j['minHitsToConfirm'] as num?)?.toInt() ?? 3,
    velocitySmoothing: (j['velocitySmoothing'] as num?)?.toDouble() ?? 0.5,
  );
}

/// Intersection-over-Union of two rectangles. 0 when they do not overlap.
double iou(Rect a, Rect b) {
  final interLeft = a.left > b.left ? a.left : b.left;
  final interTop = a.top > b.top ? a.top : b.top;
  final interRight = a.right < b.right ? a.right : b.right;
  final interBottom = a.bottom < b.bottom ? a.bottom : b.bottom;
  final interW = interRight - interLeft;
  final interH = interBottom - interTop;
  if (interW <= 0 || interH <= 0) return 0;
  final interArea = interW * interH;
  final union = a.width * a.height + b.width * b.height - interArea;
  if (union <= 0) return 0;
  return interArea / union;
}

/// Diagonal length of a rectangle (normalized units), used to scale the
/// distance-association gate to the detection's own size.
double _diagonal(Rect r) => Offset(r.width, r.height).distance;

/// How the third association pass re-links tracks that failed both IoU
/// passes (round 107, internal evaluation variant — not a user setting):
///
///  * [distance] — the field-tested default: re-link by centre distance from
///    the track's last observed position, gated by a size-scaled radius with
///    an absolute floor.
///  * [bufferedIou] — the C-BIoU idea applied only as the fallback: enlarge
///    the last-observed box and the detection box (each by a fraction of its
///    own size, with the same absolute reach floor) and re-link on their
///    overlap, which also respects box shape, not just centre position.
enum FallbackMode { distance, bufferedIou }

/// The ByteTrack-style tracker. Call [update] once per processed frame.
class ByteTracker with TrackEventBuffer implements InsectTracker {
  ByteTrackParams params;

  /// Distance-association gate, as a multiple of the detection box's diagonal.
  /// After the IoU passes fail (e.g. the velocity-predicted box overshot a
  /// near-stationary insect at low frame rate), an existing track is re-linked to
  /// a detection whose centre is within `distanceGateFactor × box-diagonal` of the
  /// track's last observed centre. This is what stops one insect being split into
  /// many ids. Not user-exposed (auto-derived from box size).
  final double distanceGateFactor;

  /// Absolute clamp on the distance gate (normalized frame units), so a very
  /// large or tiny box can't make the gate absurd.
  static const double _minDistGate = 0.05;
  static const double _maxDistGate = 0.20;

  /// Round-107 evaluation variant: read velocity as normalized units PER
  /// SECOND of real elapsed time instead of per frame. Frame gaps swing
  /// widely on-device (throttle: ~130 ms to ~950 ms in field logs), so the
  /// per-frame reading systematically over/under-shoots across gaps. Internal
  /// flag for the replay harness — becomes the only behavior if it wins.
  final bool timeAwareMotion;

  /// Round-107 evaluation variant: which third-pass fallback to use.
  final FallbackMode fallbackMode;

  /// Buffered-IoU fallback tuning (only used with [FallbackMode.bufferedIou]):
  /// each box's reach grows by `max(size × scale, floor)` per side. The
  /// absolute floor mirrors [_minDistGate] — it is what kept the distance
  /// fallback working on tiny boxes where pure size-scaled buffers fell short
  /// (round 106 finding).
  static const double _fallbackBufferScale = 0.5;
  static const double _minFallbackReach = 0.05;

  /// Minimum buffered overlap to accept a fallback match (same floor idea as
  /// the C-BIoU tracker's).
  static const double _minFallbackBiou = 0.05;

  /// Coasting/prediction horizon cap (seconds) for [timeAwareMotion]: after a
  /// long unmatched stretch the velocity is stale guesswork, so prediction
  /// stops extrapolating past this. (The legacy per-frame path has the same
  /// property implicitly — its shift shrinks with FPS.)
  static const double _maxPredictSeconds = 2.0;

  final List<Track> _tracks = [];
  int _nextId = 1;

  /// Timestamp of the previous processed frame (0 before the first) — the
  /// time base for [timeAwareMotion] prediction and coasting.
  int _lastFrameTs = 0;

  /// Total number of tracks that have ever reached the "confirmed" state this
  /// session — i.e. the count of distinct insects actually counted as visits.
  /// (Each id is counted once; a track returning from "lost" is not recounted.)
  @override
  int totalConfirmed = 0;

  ByteTracker({
    this.params = const ByteTrackParams(),
    this.distanceGateFactor = 1.5,
    this.timeAwareMotion = false,
    this.fallbackMode = FallbackMode.distance,
  });

  /// All currently confirmed tracks (the ones worth showing/logging as visits).
  @override
  List<Track> get confirmedTracks =>
      _tracks.where((t) => t.state == TrackState.confirmed).toList();

  @override
  String get algorithmName => TrackerAlgorithm.bytetrack.name;

  @override
  int get activeTrackCount => _tracks.length;

  @override
  int get trackBuffer => params.trackBuffer;

  @override
  int get minHitsToConfirm => params.minHitsToConfirm;

  @override
  void setFrameBudgets({
    required int trackBuffer,
    required int minHitsToConfirm,
  }) {
    params = params.copyWith(
      trackBuffer: trackBuffer,
      minHitsToConfirm: minHitsToConfirm,
    );
  }

  @override
  Map<String, dynamic> effectiveParamsJson() => {
    'algorithm': algorithmName,
    ...params.toJson(),
  };

  /// Resets the tracker for a new session (ids start again at 1).
  @override
  void reset() {
    _tracks.clear();
    _nextId = 1;
    totalConfirmed = 0;
    _lastFrameTs = 0;
    _frameDtS = 0;
    clearEvents();
  }

  /// Elapsed seconds since the previous processed frame (this frame's
  /// prediction/coasting horizon in [timeAwareMotion] mode). Capped so a
  /// stale velocity can't extrapolate a track across the whole frame after
  /// a long pause.
  double _frameDtS = 0;

  /// Where [t] is expected this frame: the legacy per-frame shift, or the
  /// dt-scaled shift when [timeAwareMotion] is on.
  Rect _predictedOf(Track t) =>
      timeAwareMotion ? t.predictedBoxAfter(_frameDtS) : t.predictedBox;

  /// Drops every track currently in the "lost" state (keeps confirmed and
  /// tentative ones). Needed by the motion gate: while the gate keeps the
  /// detector asleep no frames reach [update], so lost tracks cannot age out
  /// through [ByteTrackParams.trackBuffer]. The session screen calls this when
  /// the gate wakes after sleeping longer than the occlusion tolerance, so a
  /// newly arriving insect can never be re-linked to (and miscounted as) one
  /// that left before the gate closed.
  @override
  void expireLostTracks() {
    for (final t in _tracks) {
      if (t.state == TrackState.lost) {
        // Stamped with the LAST processed frame: no frames arrive while the
        // motion gate sleeps, so that frame is the last moment the track
        // existed. The log line's own time_ms carries the wake moment.
        emitTrackEvent(
          TrackEventKind.removed,
          t,
          _lastFrameTs,
          framesMissed: t.timeSinceUpdate,
          reason: 'gate_expired',
        );
      }
    }
    _tracks.removeWhere((t) => t.state == TrackState.lost);
  }

  /// Advance the tracker by one frame.
  ///
  /// [detections] are this frame's ROI-filtered boxes; [timestampMs] is the
  /// frame's wall-clock time. Returns the list of confirmed tracks after the
  /// update (stable ids, latest boxes).
  @override
  List<Track> update(List<Detection> detections, int timestampMs) {
    // Association compares detections against each track's *predicted* box
    // (its last box shifted by its velocity); the last actual box is kept until
    // a match updates it, so velocity stays a true frame-to-frame measurement.

    // Time base for the time-aware variant: how long since the last frame.
    _frameDtS = (_lastFrameTs > 0 && timestampMs > _lastFrameTs)
        ? ((timestampMs - _lastFrameTs) / 1000.0).clamp(0.0, _maxPredictSeconds)
        : 0.0;

    // Split detections into high- and low-confidence pools.
    final high = <Detection>[];
    final low = <Detection>[];
    for (final d in detections) {
      (d.confidence >= params.highThresh ? high : low).add(d);
    }

    final unmatchedTracks = List<Track>.from(_tracks);

    // Step 2: first association — all tracks vs high-confidence detections.
    final remainingHigh = _associate(
      unmatchedTracks,
      high,
      params.matchThresh,
      timestampMs,
    );

    // Step 3: second association — leftover tracks vs low-confidence dets.
    final remainingLow = _associate(
      unmatchedTracks,
      low,
      params.lowMatchThresh,
      timestampMs,
    );

    // Step 3b: distance-association fallback. The IoU passes compare against the
    // velocity-*predicted* box, which overshoots for a near-stationary insect at
    // low frame rate and drops the overlap below threshold — splitting one insect
    // into many ids. Here we re-link an already-real (confirmed/lost) track to a
    // nearby detection by CENTRE DISTANCE from its last *observed* position, so the
    // overshoot no longer matters. High-confidence leftovers that get consumed here
    // must not also spawn a new track, so we feed `remainingHigh` through it.
    final spawnable = _associateFallback(
      unmatchedTracks,
      remainingHigh,
      timestampMs,
    );
    // Low-confidence leftovers can also revive a track, but never spawn one.
    _associateFallback(unmatchedTracks, remainingLow, timestampMs);

    // Step 4: age out unmatched tracks; drop those past the buffer.
    final survivors = <Track>[];
    for (final t in _tracks) {
      if (unmatchedTracks.contains(t)) {
        // Report a confirmed track's first unmatched frame BEFORE the box
        // starts coasting, so the event carries the last observed box.
        if (t.state == TrackState.confirmed) {
          emitTrackEvent(TrackEventKind.lost, t, timestampMs);
        }
        t.timeSinceUpdate += 1;
        // Keep coasting the box along the last known velocity so prediction
        // continues to track the insect through a multi-frame occlusion.
        t.box = _predictedOf(t);
        if (t.state == TrackState.confirmed) {
          t.state = TrackState.lost;
        }
        if (t.timeSinceUpdate <= params.trackBuffer &&
            t.state != TrackState.tentative) {
          survivors.add(t);
        } else if (t.state == TrackState.lost) {
          // Aged past the occlusion tolerance: this visit is over for good.
          emitTrackEvent(
            TrackEventKind.removed,
            t,
            timestampMs,
            framesMissed: t.timeSinceUpdate,
            reason: 'aged_out',
          );
        }
        // Tentative tracks that miss a frame are discarded immediately
        // (they were never confirmed as a real insect — no event either).
      } else {
        survivors.add(t);
      }
    }
    _tracks
      ..clear()
      ..addAll(survivors);

    // Step 5: spawn new tracks from high-confidence detections that matched no
    // existing track (after IoU *and* distance association).
    for (final d in spawnable) {
      _tracks.add(
        Track(
          id: _nextId++,
          box: d.box,
          confidence: d.confidence,
          classIndex: d.classIndex,
          className: d.className,
          firstSeenMs: timestampMs,
          lastSeenMs: timestampMs,
        ),
      );
    }

    _lastFrameTs = timestampMs;
    return confirmedTracks;
  }

  /// Greedily matches [tracks] (the ones still unmatched, mutated in place by
  /// removal) to [dets] when IoU >= [minIou]. Returns the detections that found
  /// no track.
  List<Detection> _associate(
    List<Track> tracks,
    List<Detection> dets,
    double minIou,
    int timestampMs,
  ) {
    if (tracks.isEmpty || dets.isEmpty) return List<Detection>.from(dets);

    // Build every viable (track, detection) pair with its IoU, then take them
    // in descending IoU order, skipping any whose track or detection is already
    // claimed. Simple and correct for small counts.
    final pairs = <_Pair>[];
    for (var ti = 0; ti < tracks.length; ti++) {
      for (var di = 0; di < dets.length; di++) {
        final score = iou(_predictedOf(tracks[ti]), dets[di].box);
        if (score >= minIou) pairs.add(_Pair(ti, di, score));
      }
    }
    pairs.sort((a, b) => b.score.compareTo(a.score));

    final claimedTracks = <int>{};
    final claimedDets = <int>{};
    for (final p in pairs) {
      if (claimedTracks.contains(p.ti) || claimedDets.contains(p.di)) continue;
      claimedTracks.add(p.ti);
      claimedDets.add(p.di);
      _applyMatch(tracks[p.ti], dets[p.di], timestampMs);
    }

    // Remove matched tracks from the unmatched list (highest index first so the
    // earlier indices stay valid during removal).
    final matchedTrackIndices = claimedTracks.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final idx in matchedTrackIndices) {
      tracks.removeAt(idx);
    }

    final leftover = <Detection>[];
    for (var di = 0; di < dets.length; di++) {
      if (!claimedDets.contains(di)) leftover.add(dets[di]);
    }
    return leftover;
  }

  /// Fallback association: re-link still-unmatched **real** tracks
  /// (confirmed or lost — never tentative) to a leftover detection near the
  /// track's last observed position — scored per [fallbackMode] (centre
  /// distance, or buffered IoU since round 107). Greedy by best score.
  /// Mutates [tracks] (removes matched) and returns the detections that
  /// found no track (candidates to spawn new tracks).
  List<Detection> _associateFallback(
    List<Track> tracks,
    List<Detection> dets,
    int timestampMs,
  ) {
    if (tracks.isEmpty || dets.isEmpty) return List<Detection>.from(dets);

    final pairs = <_Pair>[];
    for (var ti = 0; ti < tracks.length; ti++) {
      final t = tracks[ti];
      if (t.state == TrackState.tentative) continue; // only revive real tracks
      for (var di = 0; di < dets.length; di++) {
        final score = _fallbackScore(t, dets[di]);
        if (score != null) pairs.add(_Pair(ti, di, score));
      }
    }
    // Highest score first: negated distances (closest first) or buffered
    // IoU (most overlap first), depending on the mode — see [_fallbackScore].
    pairs.sort((a, b) => b.score.compareTo(a.score));

    final claimedTracks = <int>{};
    final claimedDets = <int>{};
    for (final p in pairs) {
      if (claimedTracks.contains(p.ti) || claimedDets.contains(p.di)) continue;
      claimedTracks.add(p.ti);
      claimedDets.add(p.di);
      _applyMatch(tracks[p.ti], dets[p.di], timestampMs);
    }

    final matchedTrackIndices = claimedTracks.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final idx in matchedTrackIndices) {
      tracks.removeAt(idx);
    }

    final leftover = <Detection>[];
    for (var di = 0; di < dets.length; di++) {
      if (!claimedDets.contains(di)) leftover.add(dets[di]);
    }
    return leftover;
  }

  /// Scores one (track, detection) pair for the fallback pass, or null when
  /// the pair is outside the gate. Higher score = better match in the shared
  /// greedy loop (distance scores are negated so "closer" sorts first).
  double? _fallbackScore(Track t, Detection d) {
    switch (fallbackMode) {
      case FallbackMode.distance:
        final dist = (d.box.center - t.lastObservedCenter).distance;
        final gate = (distanceGateFactor * _diagonal(d.box)).clamp(
          _minDistGate,
          _maxDistGate,
        );
        return dist <= gate ? -dist : null;
      case FallbackMode.bufferedIou:
        // Anchor at the last OBSERVED position (not the coasted box) at the
        // track's current box size, then compare enlarged boxes.
        final anchor = Rect.fromCenter(
          center: t.lastObservedCenter,
          width: t.box.width,
          height: t.box.height,
        );
        final score = iou(
          _bufferedWithFloor(anchor),
          _bufferedWithFloor(d.box),
        );
        return score >= _minFallbackBiou ? score : null;
    }
  }

  /// A box enlarged per side by a fraction of its own size, never less than
  /// the absolute reach floor (the tiny-box guarantee — see round 106).
  static Rect _bufferedWithFloor(Rect r) {
    final bw = r.width * _fallbackBufferScale;
    final bh = r.height * _fallbackBufferScale;
    return Rect.fromLTRB(
      r.left - (bw > _minFallbackReach ? bw : _minFallbackReach),
      r.top - (bh > _minFallbackReach ? bh : _minFallbackReach),
      r.right + (bw > _minFallbackReach ? bw : _minFallbackReach),
      r.bottom + (bh > _minFallbackReach ? bh : _minFallbackReach),
    );
  }

  void _applyMatch(Track t, Detection d, int timestampMs) {
    // Pre-match values for the lifecycle events below: a "recovered" event
    // must carry when the track was REALLY last observed and how many frames
    // it missed, which the match is about to overwrite.
    final prevLastSeenMs = t.lastSeenMs;
    final missedFrames = t.timeSinceUpdate;
    // Update velocity from the centre shift before overwriting the box.
    final newCenter = d.box.center;
    final s = params.velocitySmoothing;
    if (timeAwareMotion) {
      // Units/second, measured from the last true observation over real
      // elapsed time — immune to the frame rate wandering between frames.
      final dtS = (timestampMs - t.lastSeenMs) / 1000.0;
      if (dtS > 0) {
        final instVx = (newCenter.dx - t.lastObservedCenter.dx) / dtS;
        final instVy = (newCenter.dy - t.lastObservedCenter.dy) / dtS;
        t.vx = s * instVx + (1 - s) * t.vx;
        t.vy = s * instVy + (1 - s) * t.vy;
      }
    } else {
      // Legacy: units/frame, measured against the (possibly coasted) box.
      final oldCenter = t.box.center;
      final instVx = newCenter.dx - oldCenter.dx;
      final instVy = newCenter.dy - oldCenter.dy;
      t.vx = s * instVx + (1 - s) * t.vx;
      t.vy = s * instVy + (1 - s) * t.vy;
    }

    t.box = d.box;
    t.lastObservedCenter = newCenter; // true last position (not coasted)
    t.confidence = d.confidence;
    t.classIndex = d.classIndex;
    t.className = d.className;
    t.lastSeenMs = timestampMs;
    t.hits += 1;
    t.timeSinceUpdate = 0;
    if (t.state == TrackState.tentative && t.hits >= params.minHitsToConfirm) {
      t.state = TrackState.confirmed;
      totalConfirmed += 1; // first time this id is confirmed
      emitTrackEvent(TrackEventKind.created, t, timestampMs);
    } else if (t.state == TrackState.lost) {
      t.state = TrackState.confirmed; // re-activation; already counted
      emitTrackEvent(
        TrackEventKind.recovered,
        t,
        timestampMs,
        lastSeenMs: prevLastSeenMs,
        framesMissed: missedFrames,
      );
    }
  }
}

class _Pair {
  final int ti;
  final int di;
  final double score;
  const _Pair(this.ti, this.di, this.score);
}
