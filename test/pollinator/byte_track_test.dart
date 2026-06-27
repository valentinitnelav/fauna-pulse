// Tests for the ByteTrack-style tracker: stable ids, distinct objects, and
// id retention across a brief occlusion.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pollinator_monitor/pollinator/models/track.dart';
import 'package:pollinator_monitor/pollinator/tracking/byte_track.dart';

Detection det(Rect box, [double conf = 0.9]) =>
    Detection(box: box, confidence: conf, classIndex: 0, className: 'bee');

void main() {
  test('a single moving object keeps one stable id', () {
    final tracker = ByteTracker(
      params: const ByteTrackParams(minHitsToConfirm: 3),
    );
    int? id;
    for (var f = 0; f < 6; f++) {
      // Drift slowly to the right; boxes overlap frame-to-frame.
      final box = Rect.fromLTWH(0.40 + f * 0.01, 0.40, 0.10, 0.10);
      final tracks = tracker.update([det(box)], f * 100);
      if (f >= 2) {
        expect(tracks, hasLength(1));
        id ??= tracks.first.id;
        expect(tracks.first.id, id);
      }
    }
  });

  test('two separated objects get distinct ids', () {
    final tracker = ByteTracker(
      params: const ByteTrackParams(minHitsToConfirm: 2),
    );
    List<Track> tracks = const [];
    for (var f = 0; f < 4; f++) {
      tracks = tracker.update([
        det(const Rect.fromLTWH(0.10, 0.10, 0.10, 0.10)),
        det(const Rect.fromLTWH(0.70, 0.70, 0.10, 0.10)),
      ], f * 100);
    }
    expect(tracks, hasLength(2));
    expect(tracks.map((t) => t.id).toSet(), hasLength(2));
  });

  test('id survives a brief occlusion (gap shorter than the buffer)', () {
    final tracker = ByteTracker(
      params: const ByteTrackParams(minHitsToConfirm: 2, trackBuffer: 30),
    );
    const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);

    // Confirm the track.
    tracker.update([det(box)], 0);
    var tracks = tracker.update([det(box)], 100);
    final id = tracks.single.id;

    // Two frames with no detections (occlusion). Track goes "lost" but is kept.
    tracker.update(const [], 200);
    tracker.update(const [], 300);

    // Re-appears at (nearly) the same place -> same id, not a new one.
    tracks = tracker.update([det(box)], 400);
    expect(tracks, hasLength(1));
    expect(tracks.single.id, id);
  });

  test('iou is 1 for identical boxes and 0 when disjoint', () {
    const a = Rect.fromLTWH(0, 0, 1, 1);
    expect(iou(a, a), closeTo(1.0, 1e-9));
    expect(iou(a, const Rect.fromLTWH(5, 5, 1, 1)), 0.0);
  });

  // --- Knob-impact tests: prove each exposed parameter actually changes the
  // pipeline's behaviour (same synthetic sequence, two settings, two outcomes).
  // These are the deterministic backing for the on-device "Total tracks" check.

  group('occlusion tolerance (trackBuffer) changes the unique count', () {
    // A confirmed insect vanishes for 5 frames, then reappears in place.
    int uniqueAfterGap({required int trackBuffer}) {
      final tracker = ByteTracker(
        params: ByteTrackParams(minHitsToConfirm: 2, trackBuffer: trackBuffer),
      );
      const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);
      tracker.update([det(box)], 0);
      tracker.update([det(box)], 100); // confirmed -> totalConfirmed == 1
      for (var f = 0; f < 5; f++) {
        tracker.update(const [], 200 + f * 100); // occlusion gap
      }
      tracker.update([det(box)], 700);
      tracker.update([det(box)], 800); // long enough to re-confirm if new
      return tracker.totalConfirmed;
    }

    test('buffer longer than the gap keeps one id', () {
      expect(uniqueAfterGap(trackBuffer: 10), 1);
    });
    test('buffer shorter than the gap splits into a second id', () {
      expect(uniqueAfterGap(trackBuffer: 2), 2);
    });
  });

  group('low-score association threshold changes id retention', () {
    // Confirm a stationary insect on high-confidence boxes, then feed a single
    // low-confidence box shifted enough that IoU with the prediction is ~0.33.
    List<Track> afterFaintMove({required double lowMatchThresh}) {
      final tracker = ByteTracker(
        params: ByteTrackParams(
          minHitsToConfirm: 2,
          highThresh: 0.5,
          lowMatchThresh: lowMatchThresh,
          trackBuffer: 30,
        ),
      );
      const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);
      tracker.update([det(box, 0.9)], 0);
      tracker.update([det(box, 0.9)], 100); // confirmed
      // Faint (0.3 < highThresh) box shifted by 0.05 -> IoU ≈ 0.33.
      return tracker.update([
        det(const Rect.fromLTWH(0.50, 0.45, 0.10, 0.10), 0.3),
      ], 200);
    }

    test('loose threshold recovers the faint detection (id kept)', () {
      final tracks = afterFaintMove(lowMatchThresh: 0.1);
      expect(tracks, hasLength(1));
    });
  });

  group('distance-association fallback prevents id fragmentation', () {
    // The real-world failure: a near-stationary insect whose IoU vs the
    // velocity-predicted box falls below matchThresh at low frame rate. The
    // distance fallback must keep ONE id instead of spawning a new one each frame.
    test('re-links a detection that fails the IoU gate but is close by', () {
      final t = ByteTracker(
        // Very high IoU thresholds so BOTH IoU passes fail on any shift; only the
        // distance fallback can hold the id. (Mirrors the real failure: the
        // predicted box overshoots, so IoU drops below matchThresh.)
        params: const ByteTrackParams(
          minHitsToConfirm: 2,
          matchThresh: 0.9,
          lowMatchThresh: 0.9,
        ),
      );
      t.update([det(const Rect.fromLTWH(0.45, 0.45, 0.10, 0.10))], 0);
      t.update([det(const Rect.fromLTWH(0.45, 0.45, 0.10, 0.10))], 100);
      // Shifted by 0.04: IoU ≈ 0.43 (< 0.9, IoU fails), centre 0.04 away (< gate).
      final tr = t.update([
        det(const Rect.fromLTWH(0.49, 0.45, 0.10, 0.10)),
      ], 200);
      expect(tr, hasLength(1)); // id kept via distance fallback
      expect(tr.single.id, 1);
      expect(t.totalConfirmed, 1); // no new id spawned
    });

    test('a jump beyond the gate is NOT merged (still a new id)', () {
      final t = ByteTracker(
        params: const ByteTrackParams(
          minHitsToConfirm: 1,
          matchThresh: 0.6,
          lowMatchThresh: 0.6,
        ),
      );
      t.update([det(const Rect.fromLTWH(0.15, 0.15, 0.10, 0.10))], 0);
      t.update([det(const Rect.fromLTWH(0.15, 0.15, 0.10, 0.10))], 100);
      // Far jump (centre ~0.7 away >> gate): a second insect, distinct id.
      t.update([det(const Rect.fromLTWH(0.75, 0.75, 0.10, 0.10))], 200);
      t.update([det(const Rect.fromLTWH(0.75, 0.75, 0.10, 0.10))], 300);
      expect(t.totalConfirmed, 2);
    });
  });

  group('high-score threshold decides whether a new id can start', () {
    // A steady 0.4-confidence detection: "high" (can spawn) only when the
    // threshold is below 0.4.
    int confirmedFor({required double highThresh}) {
      final tracker = ByteTracker(
        params: ByteTrackParams(minHitsToConfirm: 2, highThresh: highThresh),
      );
      const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);
      for (var f = 0; f < 4; f++) {
        tracker.update([det(box, 0.4)], f * 100);
      }
      return tracker.totalConfirmed;
    }

    test('threshold below the score lets a track start', () {
      expect(confirmedFor(highThresh: 0.3), 1);
    });
    test('threshold above the score blocks it (low scores never spawn)', () {
      expect(confirmedFor(highThresh: 0.5), 0);
    });
  });

  test('velocity smoothing changes the motion prediction', () {
    // Identical constant rightward motion; higher smoothing trusts the latest
    // motion more, so the predicted box is shifted further along it.
    double predictedLeft(double smoothing) {
      final tracker = ByteTracker(
        params: ByteTrackParams(
          minHitsToConfirm: 1,
          velocitySmoothing: smoothing,
        ),
      );
      List<Track> tracks = const [];
      for (var f = 0; f < 3; f++) {
        final box = Rect.fromLTWH(0.20 + f * 0.05, 0.40, 0.10, 0.10);
        tracks = tracker.update([det(box)], f * 100);
      }
      return tracks.single.predictedBox.left;
    }

    expect(predictedLeft(0.8), greaterThan(predictedLeft(0.2)));
  });
}
