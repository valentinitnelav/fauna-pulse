// FaunaPulse — tracking data types.
//
// "Tracking" = following one insect from frame to frame and giving it a stable
// number (a "track id") so that the same bee seen in 30 consecutive frames is
// counted as ONE visit, not 30. The visitation rate (our scientific output)
// comes directly from how many distinct track ids appear and how long each one
// lasts.

import 'dart:ui';

/// One detector output for a single frame, already filtered to the ROI.
/// [box] is the normalized bounding box (edges in 0..1 of the frame).
class Detection {
  final Rect box;
  final double confidence;
  final int classIndex;
  final String className;

  const Detection({
    required this.box,
    required this.confidence,
    required this.classIndex,
    required this.className,
  });
}

/// The lifecycle state of a track.
enum TrackState {
  /// Newly created from a single detection; not yet confirmed as a real visit.
  tentative,

  /// Seen in enough frames to be treated as a genuine insect.
  confirmed,

  /// Temporarily unmatched (e.g. brief occlusion); kept alive for a while in
  /// case the insect reappears, so its id is not lost.
  lost,
}

/// A tracked insect with a stable id that persists across frames.
class Track {
  /// Stable identifier, unique within a session.
  final int id;

  /// Most recent normalized bounding box (edges 0..1 of the frame).
  Rect box;

  /// Centre of the last box that was actually *matched to a detection* (not the
  /// velocity-coasted [box], which drifts while the track is unmatched). Used by
  /// the tracker's distance-association fallback so a near-stationary insect is
  /// re-linked to its existing id even when its predicted box has overshot.
  Offset lastObservedCenter;

  /// Most recent detection confidence (0..1).
  double confidence;

  /// Most recent class index and human-readable name.
  int classIndex;
  String className;

  /// Per-frame velocity of the box centre, in normalized units per frame.
  /// Used to predict where the insect will be in the next frame, which helps
  /// re-match it after a missed detection.
  double vx;
  double vy;

  /// Wall-clock timestamps (milliseconds since epoch) of first and last match.
  final int firstSeenMs;
  int lastSeenMs;

  /// Number of frames in which this track was matched to a detection.
  int hits;

  /// Number of consecutive frames since the last match (0 when just matched).
  int timeSinceUpdate;

  TrackState state;

  Track({
    required this.id,
    required Rect box,
    required this.confidence,
    required this.classIndex,
    required this.className,
    required this.firstSeenMs,
    required this.lastSeenMs,
    Offset? lastObservedCenter,
    this.vx = 0,
    this.vy = 0,
    this.hits = 1,
    this.timeSinceUpdate = 0,
    this.state = TrackState.tentative,
  }) : box = box,
       lastObservedCenter = lastObservedCenter ?? box.center;

  /// The predicted box for the next frame, shifting the current box by the
  /// estimated velocity. Used during association.
  Rect get predictedBox => box.shift(Offset(vx, vy));

  /// The predicted box after [dtSeconds], reading [vx]/[vy] as normalized
  /// units PER SECOND (round 107 time-aware motion variant). The plain
  /// [predictedBox] getter above keeps the legacy per-frame reading — which
  /// interpretation applies is the tracker's choice, not the track's.
  Rect predictedBoxAfter(double dtSeconds) =>
      box.shift(Offset(vx * dtSeconds, vy * dtSeconds));

  /// How long (milliseconds) this track has been alive, first to last match.
  int get durationMs => lastSeenMs - firstSeenMs;
}

/// The lifecycle transitions a tracker reports (round 116).
enum TrackEventKind {
  /// The track was matched enough frames to become a confirmed visit.
  created,

  /// A confirmed track's first unmatched frame (occlusion, missed detection,
  /// or the insect left) — kept buffered in case it reappears.
  lost,

  /// A lost track was matched to a detection again (same id, same visit).
  recovered,

  /// The track was dropped for good: it aged past the occlusion tolerance, or
  /// a motion-gate wake expired it.
  removed,
}

/// One lifecycle transition of a [Track], reported by the tracker so the
/// session log can say explicitly when a visit started, briefly vanished,
/// came back, or ended (round 116).
///
/// Why explicit events: the log's `detections` records only carry tracks that
/// were matched to a real detection in that frame (unmatched tracks go
/// [TrackState.lost], which the trackers do not return). A track id simply
/// disappearing from those records is therefore ambiguous — briefly occluded,
/// gone for good, or no frames analyzed at all (a high-res photo grab pauses
/// the analysis stream). These events remove the guesswork from
/// post-processing that stitches fragmented ids or times visits.
class TrackEvent {
  final TrackEventKind kind;

  /// The [Track.id] this transition belongs to.
  final int trackId;

  /// Frame timestamp (ms since epoch) of the frame the transition happened
  /// on. For gate-expiry removals — no frames arrive while the motion gate
  /// sleeps — this is the last processed frame before the sleep.
  final int atMs;

  /// The track's box at the transition, frame-normalized. For "lost" this is
  /// the last observed box, captured before coasting starts.
  final Rect box;

  /// Matched-frame count at the transition (see [Track.hits]).
  final int hits;

  /// When the track's first (still tentative) detection was seen — the real
  /// visit start, which predates the "created" event by the confirmation lag.
  final int firstSeenMs;

  /// The last real observation. For "recovered" this is the moment BEFORE the
  /// gap (the match itself already stamped the new time on the track), so
  /// `atMs - lastSeenMs` is the gap the id survived.
  final int lastSeenMs;

  /// Unmatched frames at the transition (recovered/removed; 0 elsewhere).
  final int framesMissed;

  /// Why a track was removed: 'aged_out' | 'gate_expired'. Null otherwise.
  final String? reason;

  const TrackEvent({
    required this.kind,
    required this.trackId,
    required this.atMs,
    required this.box,
    required this.hits,
    required this.firstSeenMs,
    required this.lastSeenMs,
    this.framesMissed = 0,
    this.reason,
  });
}
