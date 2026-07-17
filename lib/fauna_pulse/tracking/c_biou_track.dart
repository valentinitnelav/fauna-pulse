// FaunaPulse — a C-BIoU-style multi-object tracker (round 105).
//
// C-BIoU = "Cascaded Buffered IoU" (Yang et al., WACV 2023: "Hard to Track
// Objects with Irregular Motions and Similar Appearances? Make It Easier by
// Buffering the Matching Space"). The idea, in plain language:
//
//   Plain IoU matching fails when an insect moves so far between two frames
//   that its old and new boxes barely overlap — exactly what happens with
//   small, darting insects at the low/irregular frame rates of this app
//   (2–20 FPS). Instead of trying to *predict* the motion precisely (the
//   fragile part of the ByteTrack-style tracker at low FPS), C-BIoU simply
//   ENLARGES ("buffers") both boxes by a fraction of their own size before
//   comparing them, so a fast mover still overlaps its own track. Matching
//   runs as a cascade: a first pass with a small buffer (strict, keeps
//   nearby insects apart), then a second pass with a larger buffer that
//   catches the big jumps the first pass missed.
//
// Shared semantics with the ByteTrack-style tracker (byte_track.dart), so the
// user-facing meaning of a "visit" never depends on the algorithm choice:
//   * detections below [CBiouParams.highThresh] may keep an existing id alive
//     but never START a new one (same "faint band" rule as ByteTrack);
//   * a track must be matched [minHitsToConfirm] frames to become a confirmed
//     visit, and survives [trackBuffer] unmatched frames before it is dropped
//     (both frame counts are re-derived live from the user's seconds).

import 'dart:ui';

import '../models/track.dart';
import 'tracker.dart';

/// Tunable C-BIoU parameters, surfaced in Settings → AI → Visit tracking.
class CBiouParams {
  /// First-pass buffer: each box is enlarged by this fraction of its own
  /// width/height ON EACH SIDE before the overlap test. 0.3 (the paper's
  /// default) turns a 10-px box into a 16-px box. Small = strict.
  final double bufferScale1;

  /// Second-pass buffer for the tracks/detections the first pass could not
  /// match — larger, to catch big between-frame jumps. Must be ≥ pass 1.
  final double bufferScale2;

  /// Score at/above which a detection may START a new track id. Weaker
  /// detections (down to the model's Confidence threshold) can only keep an
  /// existing id alive — same rule as the ByteTrack-style tracker.
  final double highThresh;

  /// How many consecutive un-matched frames a track survives before it is
  /// dropped ("occlusion tolerance"). FPS-derived at runtime.
  final int trackBuffer;

  /// How many matched frames before a tentative track becomes confirmed.
  /// FPS-derived at runtime.
  final int minHitsToConfirm;

  const CBiouParams({
    this.bufferScale1 = 0.3,
    this.bufferScale2 = 0.5,
    this.highThresh = 0.5,
    this.trackBuffer = 30,
    this.minHitsToConfirm = 3,
  });

  CBiouParams copyWith({
    double? bufferScale1,
    double? bufferScale2,
    double? highThresh,
    int? trackBuffer,
    int? minHitsToConfirm,
  }) => CBiouParams(
    bufferScale1: bufferScale1 ?? this.bufferScale1,
    bufferScale2: bufferScale2 ?? this.bufferScale2,
    highThresh: highThresh ?? this.highThresh,
    trackBuffer: trackBuffer ?? this.trackBuffer,
    minHitsToConfirm: minHitsToConfirm ?? this.minHitsToConfirm,
  );

  Map<String, dynamic> toJson() => {
    'bufferScale1': bufferScale1,
    'bufferScale2': bufferScale2,
    'highThresh': highThresh,
    'trackBuffer': trackBuffer,
    'minHitsToConfirm': minHitsToConfirm,
  };

  factory CBiouParams.fromJson(Map<String, dynamic> j) => CBiouParams(
    bufferScale1: (j['bufferScale1'] as num?)?.toDouble() ?? 0.3,
    bufferScale2: (j['bufferScale2'] as num?)?.toDouble() ?? 0.5,
    highThresh: (j['highThresh'] as num?)?.toDouble() ?? 0.5,
    trackBuffer: (j['trackBuffer'] as num?)?.toInt() ?? 30,
    minHitsToConfirm: (j['minHitsToConfirm'] as num?)?.toInt() ?? 3,
  );
}

/// A rectangle enlarged by [scale] × its own width/height on each side —
/// C-BIoU's "buffered" box. scale 0 returns the box unchanged.
Rect bufferedRect(Rect r, double scale) => Rect.fromLTRB(
  r.left - r.width * scale,
  r.top - r.height * scale,
  r.right + r.width * scale,
  r.bottom + r.height * scale,
);

/// Buffered IoU: plain IoU of the two boxes after both are enlarged by
/// [scale]. Two boxes that don't touch can still score > 0 when their
/// buffered versions overlap — that's the whole point.
double biou(Rect a, Rect b, double scale) {
  final ba = bufferedRect(a, scale);
  final bb = bufferedRect(b, scale);
  final interLeft = ba.left > bb.left ? ba.left : bb.left;
  final interTop = ba.top > bb.top ? ba.top : bb.top;
  final interRight = ba.right < bb.right ? ba.right : bb.right;
  final interBottom = ba.bottom < bb.bottom ? ba.bottom : bb.bottom;
  final interW = interRight - interLeft;
  final interH = interBottom - interTop;
  if (interW <= 0 || interH <= 0) return 0;
  final interArea = interW * interH;
  final union = ba.width * ba.height + bb.width * bb.height - interArea;
  if (union <= 0) return 0;
  return interArea / union;
}

/// The C-BIoU-style tracker. Call [update] once per processed frame.
class CBiouTracker with TrackEventBuffer implements InsectTracker {
  CBiouParams params;

  /// Minimum buffered overlap to accept a match. A small fixed floor (not
  /// user-exposed): the greedy matcher already prefers the best pair, and the
  /// user's real tuning knob is the buffer size itself. The floor only stops
  /// a corner-grazing sliver of buffered overlap from linking two unrelated
  /// insects when nothing better exists.
  static const double _minBiou = 0.05;

  /// Weight of the newest frame-to-frame motion in the velocity estimate
  /// (stand-in for the paper's "simple average motion" — deliberately NOT the
  /// tracker's accuracy lever; the buffered matching is designed to absorb
  /// prediction error, which is why this stays a constant here while the
  /// ByteTrack-style tracker must expose it).
  static const double _motionSmoothing = 0.5;

  /// Round-107 evaluation variant, mirroring [ByteTracker.timeAwareMotion]:
  /// velocity read as normalized units per SECOND instead of per frame.
  final bool timeAwareMotion;

  /// Prediction horizon cap for the time-aware variant (see ByteTracker).
  static const double _maxPredictSeconds = 2.0;

  final List<Track> _tracks = [];
  int _nextId = 1;
  int _lastFrameTs = 0;
  double _frameDtS = 0;

  @override
  int totalConfirmed = 0;

  CBiouTracker({this.params = const CBiouParams(), this.timeAwareMotion = false});

  Rect _predictedOf(Track t) =>
      timeAwareMotion ? t.predictedBoxAfter(_frameDtS) : t.predictedBox;

  @override
  List<Track> get confirmedTracks =>
      _tracks.where((t) => t.state == TrackState.confirmed).toList();

  @override
  String get algorithmName => TrackerAlgorithm.cbiou.name;

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

  @override
  void reset() {
    _tracks.clear();
    _nextId = 1;
    totalConfirmed = 0;
    _lastFrameTs = 0;
    _frameDtS = 0;
    clearEvents();
  }

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

  @override
  List<Track> update(List<Detection> detections, int timestampMs) {
    _frameDtS = (_lastFrameTs > 0 && timestampMs > _lastFrameTs)
        ? ((timestampMs - _lastFrameTs) / 1000.0).clamp(0.0, _maxPredictSeconds)
        : 0.0;
    final unmatchedTracks = List<Track>.from(_tracks);

    // Cascade pass 1 (small buffer, strict): every track vs every detection.
    var remaining = _associate(
      unmatchedTracks,
      detections,
      params.bufferScale1,
      timestampMs,
    );

    // Cascade pass 2 (large buffer): the leftovers only, so a big jump can
    // still be linked — but never at the cost of stealing a pass-1 match.
    // The second buffer never shrinks below the first (that would make the
    // "wider" pass stricter, which is a settings mistake, not a behavior).
    final scale2 = params.bufferScale2 < params.bufferScale1
        ? params.bufferScale1
        : params.bufferScale2;
    remaining = _associate(unmatchedTracks, remaining, scale2, timestampMs);

    // Age out unmatched tracks; drop those past the buffer (same lifecycle as
    // the ByteTrack-style tracker so "occlusion tolerance" means one thing).
    final survivors = <Track>[];
    for (final t in _tracks) {
      if (unmatchedTracks.contains(t)) {
        // Report a confirmed track's first unmatched frame BEFORE the box
        // starts coasting, so the event carries the last observed box.
        if (t.state == TrackState.confirmed) {
          emitTrackEvent(TrackEventKind.lost, t, timestampMs);
        }
        t.timeSinceUpdate += 1;
        // Coast along the last known velocity so a moving insect can still be
        // caught by the buffered match when it reappears.
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
      } else {
        survivors.add(t);
      }
    }
    _tracks
      ..clear()
      ..addAll(survivors);

    // Spawn new tracks — only from strong ("high score") leftovers.
    for (final d in remaining) {
      if (d.confidence < params.highThresh) continue;
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

  /// Greedily matches [tracks] (mutated in place by removal) to [dets] when
  /// the buffered IoU at [scale] is at least [_minBiou]. Returns the
  /// detections that found no track.
  List<Detection> _associate(
    List<Track> tracks,
    List<Detection> dets,
    double scale,
    int timestampMs,
  ) {
    if (tracks.isEmpty || dets.isEmpty) return List<Detection>.from(dets);

    final pairs = <_Pair>[];
    for (var ti = 0; ti < tracks.length; ti++) {
      for (var di = 0; di < dets.length; di++) {
        final score = biou(_predictedOf(tracks[ti]), dets[di].box, scale);
        if (score >= _minBiou) pairs.add(_Pair(ti, di, score));
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

  void _applyMatch(Track t, Detection d, int timestampMs) {
    // Pre-match values for the lifecycle events below: a "recovered" event
    // must carry when the track was REALLY last observed and how many frames
    // it missed, which the match is about to overwrite.
    final prevLastSeenMs = t.lastSeenMs;
    final missedFrames = t.timeSinceUpdate;
    final newCenter = d.box.center;
    if (timeAwareMotion) {
      // Units/second from the last true observation (see ByteTracker).
      final dtS = (timestampMs - t.lastSeenMs) / 1000.0;
      if (dtS > 0) {
        t.vx = _motionSmoothing * ((newCenter.dx - t.lastObservedCenter.dx) / dtS) +
            (1 - _motionSmoothing) * t.vx;
        t.vy = _motionSmoothing * ((newCenter.dy - t.lastObservedCenter.dy) / dtS) +
            (1 - _motionSmoothing) * t.vy;
      }
    } else {
      final oldCenter = t.box.center;
      t.vx = _motionSmoothing * (newCenter.dx - oldCenter.dx) +
          (1 - _motionSmoothing) * t.vx;
      t.vy = _motionSmoothing * (newCenter.dy - oldCenter.dy) +
          (1 - _motionSmoothing) * t.vy;
    }

    t.box = d.box;
    t.lastObservedCenter = newCenter;
    t.confidence = d.confidence;
    t.classIndex = d.classIndex;
    t.className = d.className;
    t.lastSeenMs = timestampMs;
    t.hits += 1;
    t.timeSinceUpdate = 0;
    if (t.state == TrackState.tentative && t.hits >= params.minHitsToConfirm) {
      t.state = TrackState.confirmed;
      totalConfirmed += 1;
      emitTrackEvent(TrackEventKind.created, t, timestampMs);
    } else if (t.state == TrackState.lost) {
      t.state = TrackState.confirmed;
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
