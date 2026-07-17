// Tests for FrameProcessor — the per-frame mapping/tracking core extracted
// from the camera screen in round 73 (review B6a), which made two previously
// untestable behaviours testable (review B8):
//
//  * detection mapping: ROI-normalized boxes are mapped back onto the frame
//    (or full-frame boxes filtered by ROI centre on the fallback path) and
//    strictly confined to the ROI;
//  * the motion-gate wake rule: waking after a sleep longer than the
//    occlusion tolerance must expire the tracker's "lost" tracks, so a new
//    insect can never inherit (and extend) the visit of one that left before
//    the gate closed.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/models/track.dart';
import 'package:fauna_pulse/fauna_pulse/session/frame_processor.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';

/// One native detection as the platform channel delivers it.
Map<String, dynamic> det({
  double left = 0,
  double top = 0,
  double right = 1,
  double bottom = 1,
  double confidence = 0.9,
}) => {
  'classIndex': 0,
  'className': 'bee',
  'confidence': confidence,
  'normalizedBox': {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  },
};

/// One native stream event (analysis frame 1280×960 unless overridden).
Map<String, dynamic> event({
  required List<Map<String, dynamic>> detections,
  bool roiActive = true,
  int? timestamp,
  int? frameSensorMs,
}) => {
  'detections': detections,
  'roiActive': roiActive,
  'timestamp': ?timestamp,
  'frameSensorMs': ?frameSensorMs,
};

/// A tracker that confirms on the 2nd matched frame, with a buffer long
/// enough that tracks never age out by themselves during a test.
ByteTracker tracker() => ByteTracker(
  params: const ByteTrackParams(minHitsToConfirm: 2, trackBuffer: 1000),
);

void main() {
  const roi = Roi.defaultRoi; // centred square, 45% of frame width
  const aspect = 1280 / 960;
  final roiRect = roi.normalizedRect(aspect);

  FrameResult run(FrameProcessor fp, Map<String, dynamic> data) => fp.process(
    data: data,
    roi: roi,
    width: 1280,
    height: 960,
    fallbackAspect: aspect,
  );

  group('FrameProcessor.process', () {
    test('maps ROI-normalized boxes back onto the frame when the native ROI '
        'crop is active', () {
      final fp = FrameProcessor(tracker: tracker());
      // A box spanning the whole ROI crop (0..1) must land exactly on the
      // ROI rectangle in frame coordinates.
      run(fp, event(detections: [det()], timestamp: 1000));
      final result = run(fp, event(detections: [det()], timestamp: 1100));
      expect(result.tracks, hasLength(1)); // confirmed on 2nd matched frame
      final box = result.tracks.single.box;
      expect(box.left, closeTo(roiRect.left, 1e-9));
      expect(box.top, closeTo(roiRect.top, 1e-9));
      expect(box.right, closeTo(roiRect.right, 1e-9));
      expect(box.bottom, closeTo(roiRect.bottom, 1e-9));
      expect(result.roiRect, roiRect);
      expect(result.timestampMs, 1100);
    });

    test('r114: the sensor-exposure frame stamp is parsed when present and '
        'null when the native side omits it (odd HALs)', () {
      final fp = FrameProcessor(tracker: tracker());
      final withStamp = run(
        fp,
        event(detections: [det()], timestamp: 1100, frameSensorMs: 1040),
      );
      expect(withStamp.frameSensorMs, 1040);
      final without = run(fp, event(detections: [det()], timestamp: 1200));
      expect(without.frameSensorMs, isNull);
    });

    test('exposes the mapped pre-tracking detections (round 105: what the '
        'raw-detections evaluation log records)', () {
      final fp = FrameProcessor(tracker: tracker());
      final result = run(
        fp,
        event(detections: [det(confidence: 0.7)], timestamp: 1000),
      );
      // First frame: the track is still tentative (no confirmed tracks yet)
      // but the detection itself must already be exposed, in FRAME space.
      expect(result.tracks, isEmpty);
      expect(result.detections, hasLength(1));
      expect(result.detections.single.confidence, closeTo(0.7, 1e-9));
      expect(result.detections.single.box.left, closeTo(roiRect.left, 1e-9));
      expect(result.detections.single.box.right, closeTo(roiRect.right, 1e-9));
    });

    test('half-ROI box maps to the matching half of the ROI rectangle', () {
      final fp = FrameProcessor(tracker: tracker());
      final d = det(left: 0, top: 0, right: 0.5, bottom: 0.5);
      run(fp, event(detections: [d], timestamp: 1000));
      final result = run(fp, event(detections: [d], timestamp: 1100));
      final box = result.tracks.single.box;
      expect(box.left, closeTo(roiRect.left, 1e-9));
      expect(box.right, closeTo(roiRect.left + roiRect.width / 2, 1e-9));
      expect(box.bottom, closeTo(roiRect.top + roiRect.height / 2, 1e-9));
    });

    test('without the native ROI crop, full-frame detections are filtered by '
        'ROI centre and clamped to the ROI', () {
      final fp = FrameProcessor(tracker: tracker());
      // Centre (0.05, 0.05) lies outside the ROI → dropped, never a track.
      final outside = det(left: 0, top: 0, right: 0.1, bottom: 0.1);
      // Full-frame box centred inside the ROI → kept, clamped to the ROI.
      final inside = det();
      for (final ts in [1000, 1100, 1200]) {
        final result = run(
          fp,
          event(detections: [outside, inside], roiActive: false, timestamp: ts),
        );
        if (ts >= 1100) {
          expect(result.tracks, hasLength(1));
          expect(result.tracks.single.box, roiRect);
        }
      }
    });

    test('falls back to its clock when the event carries no timestamp', () {
      var now = 42000;
      final fp = FrameProcessor(tracker: tracker(), clock: () => now);
      final result = run(fp, event(detections: []));
      expect(result.timestampMs, 42000);
      now = 43000;
      expect(run(fp, event(detections: [])).timestampMs, 43000);
    });

    test('drains the tracker lifecycle events into FrameResult (round 116)',
        () {
      final fp = FrameProcessor(tracker: tracker());
      // 1st frame: tentative — no events. 2nd: confirmed — one "created".
      // 3rd (empty): one "lost". Each drain leaves the buffer empty, so an
      // event surfaces on exactly one FrameResult (one log line each).
      expect(run(fp, event(detections: [det()], timestamp: 1000)).events,
          isEmpty);
      final confirmed = run(fp, event(detections: [det()], timestamp: 1100));
      expect(confirmed.events.map((e) => e.kind), [TrackEventKind.created]);
      final lost = run(fp, event(detections: [], timestamp: 1200));
      expect(lost.events.map((e) => e.kind), [TrackEventKind.lost]);
      expect(lost.events.single.trackId, confirmed.events.single.trackId);
    });
  });

  group('FrameProcessor.setGateIdle', () {
    // Builds a processor whose tracker holds one LOST confirmed track (an
    // insect that was being followed and then vanished just before the gate
    // closed), with a fake clock the test can advance.
    (FrameProcessor, int Function(), void Function(int)) lostTrackSetup() {
      var now = 100000;
      final t = tracker();
      final fp = FrameProcessor(tracker: t, clock: () => now);
      const d = Detection(
        box: Rect.fromLTRB(0.4, 0.4, 0.6, 0.6),
        confidence: 0.9,
        classIndex: 0,
        className: 'bee',
      );
      t.update(const [d], now); // tentative
      now += 100;
      expect(t.update(const [d], now), hasLength(1)); // confirmed, id 1
      now += 100;
      expect(t.update(const [], now), isEmpty); // unmatched → lost
      return (fp, () => now, (v) => now = v);
    }

    const d = Detection(
      box: Rect.fromLTRB(0.4, 0.4, 0.6, 0.6),
      confidence: 0.9,
      classIndex: 0,
      className: 'bee',
    );

    test('waking after sleeping LONGER than the occlusion tolerance expires '
        'lost tracks — a returning insect gets a fresh id', () {
      final (fp, nowFn, setNow) = lostTrackSetup();
      final idle = fp.setGateIdle(true, occlusionSeconds: 3.0);
      expect(idle, isNotNull);
      expect(idle!.idle, isTrue);
      expect(fp.gateIdle, isTrue);

      setNow(nowFn() + 10000); // asleep 10 s > 3 s tolerance
      final wake = fp.setGateIdle(false, occlusionSeconds: 3.0);
      expect(wake, isNotNull);
      expect(wake!.expiredLostTracks, isTrue);
      expect(wake.idleSeconds, closeTo(10.0, 1e-9));

      // An identical detection arriving now must build a NEW track id, not
      // revive the expired one.
      setNow(nowFn() + 100);
      fp.tracker.update(const [d], nowFn());
      setNow(nowFn() + 100);
      final tracks = fp.tracker.update(const [d], nowFn());
      expect(tracks.single.id, 2);
    });

    test('waking WITHIN the occlusion tolerance keeps lost tracks revivable — '
        'same insect, same id', () {
      final (fp, nowFn, setNow) = lostTrackSetup();
      fp.setGateIdle(true, occlusionSeconds: 3.0);
      setNow(nowFn() + 1000); // asleep 1 s < 3 s tolerance
      final wake = fp.setGateIdle(false, occlusionSeconds: 3.0);
      expect(wake!.expiredLostTracks, isFalse);
      expect(wake.idleSeconds, closeTo(1.0, 1e-9));

      // The lost track is re-linked on the next detection: id preserved.
      setNow(nowFn() + 100);
      final tracks = fp.tracker.update(const [d], nowFn());
      expect(tracks.single.id, 1);
    });

    test('reporting the state it is already in is a no-op', () {
      final fp = FrameProcessor(tracker: tracker(), clock: () => 0);
      expect(fp.setGateIdle(false, occlusionSeconds: 3.0), isNull);
      expect(fp.setGateIdle(true, occlusionSeconds: 3.0), isNotNull);
      expect(fp.setGateIdle(true, occlusionSeconds: 3.0), isNull);
    });

    test('forceGateAwake clears the idle flag without wake bookkeeping', () {
      var now = 5000;
      final t = tracker();
      final fp = FrameProcessor(tracker: t, clock: () => now);
      fp.setGateIdle(true, occlusionSeconds: 3.0);
      now += 60000;
      fp.forceGateAwake(); // user disabled the gate: no transition, no expiry
      expect(fp.gateIdle, isFalse);
      expect(fp.setGateIdle(false, occlusionSeconds: 3.0), isNull);
    });
  });

  group('FrameProcessor.updatePipelineFps', () {
    test('smooths the callback rate; first call establishes the baseline', () {
      final fp = FrameProcessor(tracker: tracker());
      expect(fp.updatePipelineFps(1000), 0); // no previous callback yet
      expect(fp.updatePipelineFps(1100), closeTo(10.0, 1e-9)); // 100 ms gap
      // EMA: 0.1 × instant + 0.9 × previous.
      expect(fp.updatePipelineFps(1150), closeTo(0.1 * 20 + 0.9 * 10, 1e-9));
      expect(fp.pipelineFpsEma, closeTo(11.0, 1e-9));
    });

    test('a long pause (gate sleep) is skipped, not blended in (round 85)', () {
      final fp = FrameProcessor(tracker: tracker());
      // Establish a steady ~10 fps rhythm.
      var now = 1000;
      fp.updatePipelineFps(now);
      for (var i = 0; i < 50; i++) {
        now += 100;
        fp.updatePipelineFps(now);
      }
      final steady = fp.pipelineFpsEma;
      expect(steady, closeTo(10.0, 0.01));
      // 30 s gate sleep: the resume callback must NOT dip the estimate
      // (blending 1/30 fps into the EMA would report ~9 fps for no reason).
      now += 30000;
      expect(fp.updatePipelineFps(now), closeTo(steady, 1e-9));
      // …and the estimator keeps tracking normally afterwards.
      now += 100;
      expect(
        fp.updatePipelineFps(now),
        closeTo(0.1 * 10 + 0.9 * steady, 1e-9),
      );
    });

    test('slow-but-steady rhythms below the 2 s floor still blend', () {
      final fp = FrameProcessor(tracker: tracker());
      // A 1 fps inference cap produces legitimate 1 s gaps — those are the
      // real rate, not pauses, and must keep feeding the EMA.
      var now = 1000;
      fp.updatePipelineFps(now);
      for (var i = 0; i < 60; i++) {
        now += 1000;
        fp.updatePipelineFps(now);
      }
      expect(fp.pipelineFpsEma, closeTo(1.0, 0.01));
    });
  });
}
