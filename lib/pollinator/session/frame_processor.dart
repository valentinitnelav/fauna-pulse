// Pollinator Monitor — per-frame detection mapping + tracking, extracted from
// the camera screen (round 73, review item B6a).
//
// A "plain class" in Flutter terms: no widgets, no timers, no platform calls —
// it only transforms one native stream event into tracks. That makes the core
// per-frame logic unit-testable (review item B8), which a 2,800-line screen
// State object never was. The camera screen keeps everything UI: notifiers,
// banners, setState, and the once-a-second housekeeping.

import 'dart:ui';

import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../models/roi.dart';
import '../models/track.dart';
import '../tracking/byte_track.dart';

/// What [FrameProcessor.process] hands back for one stream event: the
/// confirmed tracks after this frame plus the values the screen needs for
/// logging and the overlay.
class FrameResult {
  /// The ROI as a frame-normalized rectangle at this frame's aspect ratio —
  /// the reference frame the logged `box_in_roi` coordinates use.
  final Rect roiRect;

  /// Confirmed tracks after feeding this frame's detections to the tracker.
  final List<Track> tracks;

  /// Dart-side tracker cost for this frame (milliseconds), for the PERF log.
  final double trackMs;

  /// Frame timestamp (ms since epoch; the native one when the event carried
  /// it, the wall clock otherwise).
  final int timestampMs;

  const FrameResult({
    required this.roiRect,
    required this.tracks,
    required this.trackMs,
    required this.timestampMs,
  });
}

/// Reported by [FrameProcessor.setGateIdle] when the motion-gate state
/// actually changed (`null` = no change). Carries what the screen needs to
/// log the transition.
class GateChange {
  /// The new state (true = detector asleep).
  final bool idle;

  /// How long the gate had been idle, in seconds. Only meaningful on a wake
  /// transition; 0 when going idle.
  final double idleSeconds;

  /// True when the gate woke after sleeping longer than the tracker's
  /// occlusion tolerance, so the tracker's "lost" tracks were expired — an
  /// insect arriving now can never inherit the id of one that left before
  /// the gate closed (which would silently inflate visit durations).
  final bool expiredLostTracks;

  const GateChange({
    required this.idle,
    required this.idleSeconds,
    required this.expiredLostTracks,
  });
}

/// Owns the per-frame pipeline state that isn't UI: motion-gate idle state,
/// the pipeline-FPS estimate, and the detection→track transformation.
class FrameProcessor {
  FrameProcessor({required this.tracker, int Function()? clock})
    : _clock = clock ?? _wallClockMs;

  /// The tracker fed by [process]. Owned here but still reachable by the
  /// screen, which resets it per session and re-derives its params live.
  final ByteTracker tracker;

  /// Millisecond wall clock, injectable so tests can fake long gate sleeps.
  final int Function() _clock;
  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// Motion-gate state mirrored from the native side. While the gate is idle
  /// the detector is deliberately asleep (no results), so the UI must show
  /// "idle" instead of a scary 0-FPS state.
  bool get gateIdle => _gateIdle;
  bool _gateIdle = false;
  int _gateIdleSinceMs = 0;

  /// Smoothed rate at which the app fully handles inferred frames (the frame
  /// callback runs ROI mapping + tracking + overlay update).
  double get pipelineFpsEma => _pipelineFpsEma;
  double _pipelineFpsEma = 0;
  int _lastCallbackMs = 0;

  /// Updates the pipeline-FPS estimate for a frame callback arriving at
  /// [nowMs] and returns the new smoothed value.
  double updatePipelineFps(int nowMs) {
    if (_lastCallbackMs > 0) {
      final dt = nowMs - _lastCallbackMs;
      if (dt > 0) {
        final inst = 1000.0 / dt;
        _pipelineFpsEma = _pipelineFpsEma == 0
            ? inst
            : 0.1 * inst + 0.9 * _pipelineFpsEma;
      }
    }
    _lastCallbackMs = nowMs;
    return _pipelineFpsEma;
  }

  /// Applies a motion-gate state change reported by the native side and —
  /// crucially — expires stale "lost" tracks after a long sleep. While the
  /// gate is idle no frames reach the tracker, so lost tracks cannot age out;
  /// without this, an insect arriving after a long empty period could wrongly
  /// inherit the track id of one that left before the gate closed.
  ///
  /// [occlusionSeconds] is the tracker's re-appearance buffer: a sleep longer
  /// than it means whatever was "lost" back then must not be revivable now.
  /// Returns `null` when the state didn't change.
  GateChange? setGateIdle(bool idle, {required double occlusionSeconds}) {
    if (idle == _gateIdle) return null;
    _gateIdle = idle;
    final nowMs = _clock();
    double idleS = 0;
    var expired = false;
    if (idle) {
      _gateIdleSinceMs = nowMs;
    } else if (_gateIdleSinceMs > 0) {
      idleS = (nowMs - _gateIdleSinceMs) / 1000.0;
      if (idleS > occlusionSeconds) {
        tracker.expireLostTracks();
        expired = true;
      }
    }
    return GateChange(
      idle: idle,
      idleSeconds: idleS,
      expiredLostTracks: expired,
    );
  }

  /// Clears the idle flag without the wake bookkeeping (no expiry, nothing to
  /// log) — used when the user disables the motion gate while it is idle, so
  /// the on-screen indicator resets immediately.
  void forceGateAwake() {
    _gateIdle = false;
  }

  /// Transforms one native stream event into tracks.
  ///
  /// The native side crops inference to the ROI, so detection boxes arrive
  /// normalized to the ROI (0..1 inside it) and are mapped back onto the full
  /// frame here so the tracker and overlay line up with the live preview. If
  /// the ROI crop isn't active (e.g. older native), full-frame detections are
  /// filtered by ROI centre instead. Every box is then confined to the ROI
  /// rectangle and degenerate slivers are dropped, so nothing is ever
  /// tracked, drawn, or logged outside the ROI the user defined.
  ///
  /// [width]/[height] are the analysis-frame dimensions the caller resolved
  /// for this event; [fallbackAspect] is used when they are still unknown.
  FrameResult process({
    required Map<String, dynamic> data,
    required Roi roi,
    required int width,
    required int height,
    required double fallbackAspect,
  }) {
    final ts = (data['timestamp'] as num?)?.toInt() ?? _clock();
    final aspect = (width <= 0 || height <= 0)
        ? fallbackAspect
        : width / height;
    final roiRect = roi.normalizedRect(aspect);
    final roiActive = data['roiActive'] == true;
    Rect roiToFrame(Rect b) => Rect.fromLTRB(
      roiRect.left + b.left * roiRect.width,
      roiRect.top + b.top * roiRect.height,
      roiRect.left + b.right * roiRect.width,
      roiRect.top + b.bottom * roiRect.height,
    );
    // Strictly confine a frame-space box to the ROI rectangle. Detection runs
    // on the ROI crop, so boxes should already be inside it, but native edge
    // overruns (sub-percent over/under 0..1) — or a stray full-frame box in
    // the fallback path — can poke past the boundary.
    Rect clampToRoi(Rect b) => Rect.fromLTRB(
      b.left.clamp(roiRect.left, roiRect.right),
      b.top.clamp(roiRect.top, roiRect.bottom),
      b.right.clamp(roiRect.left, roiRect.right),
      b.bottom.clamp(roiRect.top, roiRect.bottom),
    );

    final dets = <Detection>[];
    final rawList = data['detections'];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final result = YOLOResult.fromMap(raw);
        Rect frameBox;
        if (roiActive) {
          frameBox = roiToFrame(result.normalizedBox);
        } else {
          if (!roi.containsBoxCenter(result.normalizedBox, aspect)) continue;
          frameBox = result.normalizedBox;
        }
        frameBox = clampToRoi(frameBox);
        // Drop anything that clamped to a zero-area sliver (i.e. it was
        // entirely outside the ROI), so a degenerate box never becomes a
        // track.
        if (frameBox.width <= 0 || frameBox.height <= 0) continue;
        dets.add(
          Detection(
            box: frameBox,
            confidence: result.confidence,
            classIndex: result.classIndex,
            className: result.className,
          ),
        );
      }
    }

    final trackSw = Stopwatch()..start();
    final tracks = tracker.update(dets, ts);
    trackSw.stop();

    return FrameResult(
      roiRect: roiRect,
      tracks: tracks,
      trackMs: trackSw.elapsedMicroseconds / 1000.0,
      timestampMs: ts,
    );
  }
}
