// FaunaPulse — the common face of the app's frame-association trackers.
//
// "Frame association" (= tracking) links each insect's detections across
// consecutive frames into one visit with a stable track id. The app ships two
// interchangeable algorithms behind this interface (round 105):
//
//   * ByteTrack-style (`byte_track.dart`) — the field-tested default. Matches
//     by box overlap (IoU) against a velocity-predicted box, in two confidence
//     passes, with a distance fallback.
//   * C-BIoU-style (`c_biou_track.dart`) — an experimental alternative that
//     "buffers" (enlarges) the boxes before comparing them, in two widening
//     passes, so fast or erratic movement between frames still overlaps.
//
// The camera screen builds one of them per session from the settings and the
// frame processor only ever sees this interface, so adding/evaluating another
// association algorithm never touches the per-frame pipeline again.

import '../models/track.dart';

/// Which association algorithm a session uses. Persisted by name in
/// [SessionConfig] ('bytetrack' is the default and the fallback for configs
/// saved before this choice existed).
enum TrackerAlgorithm { bytetrack, cbiou }

/// What every tracker must provide to the per-frame pipeline and the UI.
abstract class InsectTracker {
  /// Advance by one processed frame: [detections] are the ROI-filtered boxes,
  /// [timestampMs] the frame's wall-clock time. Returns the confirmed tracks.
  List<Track> update(List<Detection> detections, int timestampMs);

  /// Resets all state for a new session (ids start again at 1).
  void reset();

  /// Drops every "lost" track immediately (motion-gate wake after a sleep
  /// longer than the occlusion tolerance — see the byte_track.dart original).
  void expireLostTracks();

  /// All currently confirmed tracks (the ones worth showing/logging).
  List<Track> get confirmedTracks;

  /// Count of distinct track ids that ever reached "confirmed" this session —
  /// the number of visits actually counted.
  int get totalConfirmed;

  /// The frame-count buffers currently in effect. The user sets these in
  /// SECONDS (occlusion tolerance / min visit length); the camera screen
  /// converts them to frames against the live detector FPS about once a
  /// second and pushes them through [setFrameBudgets].
  int get trackBuffer;
  int get minHitsToConfirm;

  /// Applies freshly FPS-derived frame budgets (see [trackBuffer]).
  void setFrameBudgets({required int trackBuffer, required int minHitsToConfirm});

  /// The [TrackerAlgorithm] name, for logs and the settings round-trip.
  String get algorithmName;

  /// The effective (live) parameters as logged into the session's start
  /// record — always includes an `algorithm` key so post-processing can tell
  /// which tracker produced a session's ids.
  Map<String, dynamic> effectiveParamsJson();
}
