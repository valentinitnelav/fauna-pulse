// Round 313 (owner: "I didn't really check other ByteTrack user inputs and see
// if they really get updated and take effect on the tracker"). Each test here
// changes ONE setting a user can change and shows that the tracker's result
// changes with it, then that every stored value reaches the tracker the
// camera, the video screen and the photo screen build. Together with
// settings_fields_test.dart (every control stores what was typed) this covers
// "set on the screen -> stored -> used".

import 'dart:ui';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/models/track.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart' show VideoAnalysisPrefs;
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker_replay.dart';
import 'package:flutter_test/flutter_test.dart';

Detection det(Rect box, [double conf = 0.9]) => Detection(box: box, confidence: conf, classIndex: 0, className: 'bee');

Rect boxAt(double x, [double side = 0.10]) => Rect.fromLTWH(x, 0.40, side, side);

/// Runs [frames] (one list of boxes per frame, 100 ms apart) and returns how
/// many track IDs were confirmed.
int trackIds(InsectTracker t, List<List<Detection>> frames) {
  for (var f = 0; f < frames.length; f++) {
    t.update(frames[f], 1000 + f * 100);
  }
  return t.totalConfirmed;
}

/// A newcomer that moves 0.05 per frame: consecutive boxes overlap with an
/// IoU of 1/3.
List<List<Detection>> mover({int frames = 6, double conf = 0.9}) => [
  for (var f = 0; f < frames; f++) [det(boxAt(0.20 + f * 0.05), conf)],
];

void main() {
  group('ByteTrack: each setting changes the result', () {
    ByteTracker bt(ByteTrackParams p) => ByteTracker(params: p);

    test('New-track confidence: boxes below it never start a track ID', () {
      final faint = [for (var f = 0; f < 6; f++) [det(boxAt(0.4), 0.4)]];
      expect(trackIds(bt(const ByteTrackParams(highThresh: 0.5, minHitsToConfirm: 3)), faint), 0);
      expect(trackIds(bt(const ByteTrackParams(highThresh: 0.3, minHitsToConfirm: 3)), faint), 1);
    });

    test('Match overlap: a high value misses a newcomer that moves', () {
      expect(trackIds(bt(const ByteTrackParams(matchThresh: 0.1, minHitsToConfirm: 3)), mover()), 1);
      expect(trackIds(bt(const ByteTrackParams(matchThresh: 0.6, minHitsToConfirm: 3)), mover()), 0);
    });

    test('Low-score association: decides whether faint boxes continue a new track', () {
      // One strong box, then faint ones that move (IoU 1/3).
      final frames = [
        [det(boxAt(0.20))],
        for (var f = 1; f < 5; f++) [det(boxAt(0.20 + f * 0.05), 0.3)],
      ];
      // Round 313 audit (D2): faint boxes can confirm a new track here, unlike
      // the original ByteTrack; noted for the annotated-video tuning.
      expect(trackIds(bt(const ByteTrackParams(lowMatchThresh: 0.1, minHitsToConfirm: 3)), frames), 1);
      expect(trackIds(bt(const ByteTrackParams(lowMatchThresh: 0.6, minHitsToConfirm: 3)), frames), 0);
    });

    test('Velocity smoothing: how much the newest motion counts', () {
      double vxAfterJump(double s) {
        final t = bt(ByteTrackParams(velocitySmoothing: s, minHitsToConfirm: 2));
        List<Track> tracks = const [];
        // Steady 0.01 per frame, then one step of 0.04.
        for (final (f, x) in [(0, 0.40), (1, 0.41), (2, 0.42), (3, 0.43), (4, 0.47)]) {
          tracks = t.update([det(boxAt(x))], 1000 + f * 100);
        }
        return tracks.single.vx;
      }

      expect(vxAfterJump(0.9), greaterThan(vxAfterJump(0.1) + 0.01));
    });

    test('Occlusion tolerance (track buffer): a longer one keeps the track ID through a gap', () {
      final frames = [
        for (var f = 0; f < 4; f++) [det(boxAt(0.4))],
        for (var f = 0; f < 4; f++) <Detection>[],
        for (var f = 0; f < 4; f++) [det(boxAt(0.4))],
      ];
      expect(trackIds(bt(const ByteTrackParams(trackBuffer: 2, minHitsToConfirm: 2)), frames), 2);
      expect(trackIds(bt(const ByteTrackParams(trackBuffer: 10, minHitsToConfirm: 2)), frames), 1);
    });

    test('Minimum track length (min hits): a short blip is dropped', () {
      final blip = [for (var f = 0; f < 3; f++) [det(boxAt(0.4))]];
      expect(trackIds(bt(const ByteTrackParams(minHitsToConfirm: 2)), blip), 1);
      expect(trackIds(bt(const ByteTrackParams(minHitsToConfirm: 4)), blip), 0);
    });

    test('a budget of 1 works like 2, so the screens show at least 2 (r313)', () {
      final one = [[det(boxAt(0.4))]];
      final two = [[det(boxAt(0.4))], [det(boxAt(0.4))]];
      expect(trackIds(bt(const ByteTrackParams(minHitsToConfirm: 1)), one), 0);
      expect(trackIds(bt(const ByteTrackParams(minHitsToConfirm: 1)), two), 1);
      expect(trackIds(bt(const ByteTrackParams(minHitsToConfirm: 2)), two), 1);
      expect(const SessionConfig(minHitsSeconds: 0).minHitsFramesFor(15), kMinDetectionsInARow);
    });
  });

  group('C-BIoU: each setting changes the result', () {
    CBiouTracker cb(CBiouParams p) => CBiouTracker(params: p);

    /// A small fast newcomer: 0.05 wide, 0.08 per frame, so consecutive boxes
    /// never overlap without the search margin.
    final jumper = [for (var f = 0; f < 6; f++) [det(boxAt(0.10 + f * 0.08, 0.05))]];

    test('New-track confidence', () {
      final faint = [for (var f = 0; f < 6; f++) [det(boxAt(0.4), 0.4)]];
      expect(trackIds(cb(const CBiouParams(highThresh: 0.5, minHitsToConfirm: 3)), faint), 0);
      expect(trackIds(cb(const CBiouParams(highThresh: 0.3, minHitsToConfirm: 3)), faint), 1);
    });

    test('Search margins: pass 1, and pass 2 for what pass 1 missed', () {
      expect(trackIds(cb(const CBiouParams(bufferScale1: 0.05, bufferScale2: 0.05, minHitsToConfirm: 3)), jumper), 0);
      expect(trackIds(cb(const CBiouParams(bufferScale1: 1.0, bufferScale2: 1.0, minHitsToConfirm: 3)), jumper), 1);
      expect(trackIds(cb(const CBiouParams(bufferScale1: 0.05, bufferScale2: 1.5, minHitsToConfirm: 3)), jumper), 1,
          reason: 'pass 2 alone links the jumps');
      expect(trackIds(cb(const CBiouParams(bufferScale1: 1.0, bufferScale2: 0.05, minHitsToConfirm: 3)), jumper), 1,
          reason: 'pass 2 is used as pass 1 when smaller (the stored value stays as typed)');
    });

    test('Occlusion tolerance and minimum track length', () {
      final gap = [
        for (var f = 0; f < 4; f++) [det(boxAt(0.4))],
        for (var f = 0; f < 4; f++) <Detection>[],
        for (var f = 0; f < 4; f++) [det(boxAt(0.4))],
      ];
      expect(trackIds(cb(const CBiouParams(trackBuffer: 2, minHitsToConfirm: 2)), gap), 2);
      expect(trackIds(cb(const CBiouParams(trackBuffer: 10, minHitsToConfirm: 2)), gap), 1);
      final blip = [for (var f = 0; f < 3; f++) [det(boxAt(0.4))]];
      expect(trackIds(cb(const CBiouParams(minHitsToConfirm: 2)), blip), 1);
      expect(trackIds(cb(const CBiouParams(minHitsToConfirm: 4)), blip), 0);
    });
  });

  group('every stored value reaches the tracker that is built', () {
    const byte = ByteTrackParams(highThresh: 0.61, matchThresh: 0.22, lowMatchThresh: 0.33, velocitySmoothing: 0.44);
    const cbiou = CBiouParams(bufferScale1: 0.21, bufferScale2: 0.71, highThresh: 0.62);
    Map<String, dynamic> user(Map<String, dynamic> j) => {...j}
      ..remove('trackBuffer')
      ..remove('minHitsToConfirm')
      ..remove('algorithm');

    test('the camera and photos: SessionConfig.buildTracker', () {
      // Confidence 0.6 above New-track 0.61 minus 0.10: no floor is applied
      // any more (round 313), the stored value is used.
      const c = SessionConfig(
        confidenceThreshold: 0.6,
        occlusionSeconds: 2.0,
        minHitsSeconds: 0.4,
        trackerParams: byte,
        cbiouParams: cbiou,
      );
      final b = c.buildTracker(10);
      expect(user(b.effectiveParamsJson()), byte.toJson()..remove('trackBuffer')..remove('minHitsToConfirm'));
      expect([b.trackBuffer, b.minHitsToConfirm], [20, 4]);
      final cb = c.copyWith(trackerAlgorithm: TrackerAlgorithm.cbiou).buildTracker(10);
      expect(user(cb.effectiveParamsJson()), cbiou.toJson()..remove('trackBuffer')..remove('minHitsToConfirm'));
      expect([cb.trackBuffer, cb.minHitsToConfirm], [20, 4]);
    });

    test('videos: VideoAnalysisPrefs.trackerConfig, with no floor from the confidence', () {
      final p = VideoAnalysisPrefs(
        confidence: 0.55,
        occlusionSeconds: 1.5,
        minVisitSeconds: 0.6,
        trackerParams: byte,
        cbiouParams: cbiou,
      );
      final b = p.trackerConfig(const SessionConfig()).buildTracker(5);
      expect(user(b.effectiveParamsJson()), byte.toJson()..remove('trackBuffer')..remove('minHitsToConfirm'));
      expect([b.trackBuffer, b.minHitsToConfirm], [8, 3]); // 1.5 s and 0.6 s at 5 frames per second
      expect(p.newTrackConfidence, 0.61);
      p.trackerAlgorithm = TrackerAlgorithm.cbiou;
      final cb = p.trackerConfig(const SessionConfig()).buildTracker(5);
      expect(user(cb.effectiveParamsJson()), cbiou.toJson()..remove('trackBuffer')..remove('minHitsToConfirm'));
      expect(p.newTrackConfidence, 0.62);
    });
  });

  group('the replay that videos and photos are tracked with (r313)', () {
    /// One insect in every frame of a 29.97 fps clip analyzed at 5 frames per
    /// second: gaps of 200, 201 and 167 ms, as the phone's frame picker gives.
    List<ReplayFrame> steadyInsect(int seconds) {
      final frames = <ReplayFrame>[];
      var ts = 1000000;
      for (var i = 0; i < seconds * 5; i++) {
        frames.add(ReplayFrame(timestampMs: ts, detections: [det(boxAt(0.4))]));
        ts += i % 5 == 4 ? 167 : (i.isEven ? 200 : 201);
      }
      return frames;
    }

    test('an occlusion tolerance at or below the frame gap no longer wipes every track', () {
      for (final occlusion in [0.2, 0.3]) {
        final r = replayTracker(
          tracker: SessionConfig(occlusionSeconds: occlusion, minHitsSeconds: 1.0).buildTracker(5),
          frames: steadyInsect(20),
          occlusionSeconds: occlusion,
          minHitsSeconds: 1.0,
          initialFps: 5,
          adaptFps: false,
        );
        expect(r.visits, 1, reason: 'one insect seen for 20 s (occlusion $occlusion s); before round 313: 0 or ~20');
      }
    });

    test('a real pause (motion gate sleep, a burst break) still ends the track IDs', () {
      final frames = [
        ...steadyInsect(3),
        for (final f in steadyInsect(3))
          ReplayFrame(timestampMs: f.timestampMs + 60000, detections: f.detections),
      ];
      final r = replayTracker(
        tracker: const SessionConfig(occlusionSeconds: 3.0, minHitsSeconds: 0.4).buildTracker(5),
        frames: frames,
        occlusionSeconds: 3.0,
        minHitsSeconds: 0.4,
        initialFps: 5,
        adaptFps: false,
      );
      expect(r.visits, 2);
    });
  });
}
