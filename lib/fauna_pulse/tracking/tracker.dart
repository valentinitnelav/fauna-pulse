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

  /// Tracks currently held in ANY state (tentative + confirmed + lost) —
  /// the tracker's working-set size, reported by the replay harness as a
  /// memory/cost proxy (round 107).
  int get activeTrackCount;

  /// The frame-count buffers currently in effect. The user sets these in
  /// SECONDS (occlusion tolerance / min visit length); the camera screen
  /// converts them to frames against the live detector FPS about once a
  /// second and pushes them through [setFrameBudgets].
  int get trackBuffer;
  int get minHitsToConfirm;

  /// Applies freshly FPS-derived frame budgets (see [trackBuffer]).
  void setFrameBudgets({
    required int trackBuffer,
    required int minHitsToConfirm,
  });

  /// The [TrackerAlgorithm] name, for logs and the settings round-trip.
  String get algorithmName;

  /// The effective (live) parameters as logged into the session's start
  /// record — always includes an `algorithm` key so post-processing can tell
  /// which tracker produced a session's ids.
  Map<String, dynamic> effectiveParamsJson();

  /// Track-lifecycle transitions accumulated since the last drain (round
  /// 116): created / lost / recovered / removed. The frame processor drains
  /// this once per processed frame and the recorder writes each one as a
  /// `track_event` line. See [TrackEventBuffer].
  List<TrackEvent> drainEvents();
}

/// Shared lifecycle-event buffer for the trackers (round 116). Both mix this
/// in so a `track_event` log line means one thing regardless of the algorithm
/// choice. Events pile up during [InsectTracker.update] (and
/// [InsectTracker.expireLostTracks], which runs between frames on a
/// motion-gate wake) until [drainEvents] hands them to the frame processor.
mixin TrackEventBuffer {
  final List<TrackEvent> _events = [];

  List<TrackEvent> drainEvents() {
    if (_events.isEmpty) return const [];
    final out = List<TrackEvent>.of(_events);
    _events.clear();
    return out;
  }

  /// Forgets buffered events (tracker reset for a new session).
  void clearEvents() => _events.clear();

  /// Builds one event from the track's current fields and buffers it.
  /// [lastSeenMs] overrides the track's value for "recovered": by emission
  /// time the match has already stamped this frame onto the track, but the
  /// event must carry the last observation BEFORE the gap.
  void emitTrackEvent(
    TrackEventKind kind,
    Track t,
    int atMs, {
    int? lastSeenMs,
    int framesMissed = 0,
    String? reason,
  }) {
    _events.add(
      TrackEvent(
        kind: kind,
        trackId: t.id,
        atMs: atMs,
        box: t.box,
        hits: t.hits,
        firstSeenMs: t.firstSeenMs,
        lastSeenMs: lastSeenMs ?? t.lastSeenMs,
        framesMissed: framesMissed,
        reason: reason,
      ),
    );
  }
}
