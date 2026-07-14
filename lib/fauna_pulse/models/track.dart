// Pollinator Monitor — tracking data types.
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

  /// How long (milliseconds) this track has been alive, first to last match.
  int get durationMs => lastSeenMs - firstSeenMs;
}
