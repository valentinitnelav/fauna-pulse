// Tests for RoiCaptureScheduler.evaluate() — the stateful photo cadence
// (review item B8). This is the logic that decides HOW PHOTOS LAND ON DISK:
// first photo immediately when a track appears, then one per step for up to
// the per-track duration, one SHARED photo when several tracks are due at the
// same instant, and window bookkeeping that must survive momentary "lost"
// blips without double-photographing a returning track id.
//
// evaluate() is synchronous and touches no camera or disk, so these tests
// drive it with hand-built tracks and fake clocks only. The capture() side
// (grab + crop + write) is exercised only for its busy flag, with a capture
// function that never resolves until the test says so.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pollinator_monitor/pollinator/capture/roi_capture.dart';
import 'package:pollinator_monitor/pollinator/models/roi.dart';
import 'package:pollinator_monitor/pollinator/models/session_config.dart';
import 'package:pollinator_monitor/pollinator/models/track.dart';

/// A minimal confirmed track; only [Track.id] matters to the scheduler.
Track track(int id) => Track(
  id: id,
  box: const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6),
  confidence: 0.9,
  classIndex: 0,
  className: 'bee',
  firstSeenMs: 0,
  lastSeenMs: 0,
);

RoiCaptureScheduler scheduler({
  int stepMs = 1000,
  int durationMs = 5000,
  Future<Uint8List?> Function()? fastCapture,
}) => RoiCaptureScheduler(
  framesDir: Directory('${Directory.systemTemp.path}/roi_scheduler_test'),
  sessionId: 'S',
  stepMs: stepMs,
  durationMs: durationMs,
  mode: RoiCaptureMode.fast,
  targetPx: 640,
  fastCaptureFn: fastCapture ?? () async => null,
  stillCaptureFn: () async => null,
  roiProvider: () => Roi.defaultRoi,
  streamDims: () => (1280, 960),
  stillDims: () => (0, 0),
);

void main() {
  group('RoiCaptureScheduler.evaluate', () {
    test('first sight of a track takes a photo immediately, with a '
        'deterministic session-stamped file name', () {
      final s = scheduler();
      final pending = s.evaluate([track(1)], 10000);
      expect(pending, isNotNull);
      expect(pending!.fileName, 'roi_S_10000.jpg');
      expect(pending.trackIds, [1]);
      expect(pending.capturedAtMs, 10000);
    });

    test('respects the step interval between photos of the same track', () {
      final s = scheduler(stepMs: 1000);
      expect(s.evaluate([track(1)], 10000), isNotNull); // first photo
      // Not due again until a full step has passed.
      expect(s.evaluate([track(1)], 10400), isNull);
      expect(s.evaluate([track(1)], 10999), isNull);
      expect(s.evaluate([track(1)], 11000), isNotNull);
      // The step counts from the LAST photo, not from track start.
      expect(s.evaluate([track(1)], 11900), isNull);
      expect(s.evaluate([track(1)], 12000), isNotNull);
    });

    test('stops photographing a track once its duration window is over', () {
      final s = scheduler(stepMs: 1000, durationMs: 3000);
      expect(s.evaluate([track(1)], 10000), isNotNull);
      expect(s.evaluate([track(1)], 11000), isNotNull);
      expect(s.evaluate([track(1)], 12000), isNotNull);
      expect(s.evaluate([track(1)], 13000), isNotNull); // 3000 ms, not yet >
      // Past the window: the track may stay on the flower for hours, but its
      // time-lapse is complete.
      expect(s.evaluate([track(1)], 14000), isNull);
      expect(s.evaluate([track(1)], 60000), isNull);
    });

    test('concurrent due tracks share ONE photo, logged for both ids', () {
      final s = scheduler();
      final pending = s.evaluate([track(1), track(2)], 10000);
      expect(pending, isNotNull);
      expect(pending!.trackIds, [1, 2]);
      // Both were marked as photographed by the shared image: neither is due
      // again before the step elapses.
      expect(s.evaluate([track(1), track(2)], 10500), isNull);
    });

    test('a track that starts later still gets its own full window', () {
      final s = scheduler(stepMs: 1000, durationMs: 2000);
      expect(s.evaluate([track(1)], 10000)!.trackIds, [1]);
      // Track 1's window ends after 12000; track 2 appears at 13000 while
      // track 1 is still present but expired → photo is for track 2 only.
      expect(s.evaluate([track(1)], 11000), isNotNull);
      expect(s.evaluate([track(1)], 12000), isNotNull);
      expect(s.evaluate([track(1)], 13000), isNull);
      final p = s.evaluate([track(1), track(2)], 13500);
      expect(p, isNotNull);
      expect(p!.trackIds, [2]);
    });

    test('a momentary lost blip does NOT reset an expired window '
        '(no double-photographing when the same id returns)', () {
      final s = scheduler(stepMs: 1000, durationMs: 2000);
      expect(s.evaluate([track(1)], 10000), isNotNull);
      expect(s.evaluate([track(1)], 11000), isNotNull);
      expect(s.evaluate([track(1)], 12000), isNotNull); // window complete
      // Track vanishes briefly (occlusion) and returns within the duration:
      // the window must be remembered, so no fresh "first photo" fires.
      expect(s.evaluate([], 12500), isNull);
      expect(s.evaluate([track(1)], 13000), isNull);
      expect(s.evaluate([track(1)], 20000), isNull);
    });

    test('forgets a window only after the id has been GONE for longer than '
        'the duration (safe because the tracker never reuses ids)', () {
      final s = scheduler(stepMs: 1000, durationMs: 2000);
      expect(s.evaluate([track(1)], 10000), isNotNull);
      // Gone at 10500; cleanup needs absence > durationMs since last seen.
      expect(s.evaluate([], 11000), isNull); // gone 500 ms → window kept
      expect(s.evaluate([], 13000), isNull); // gone 2500 ms → window dropped
      // If the same id ever came back now it would be treated as brand new
      // (immediate photo). Real track ids are never reused, so this only
      // documents the cleanup boundary.
      expect(s.evaluate([track(1)], 13500), isNotNull);
    });

    test('returns null while a previous capture is still in flight', () async {
      final gate = Completer<Uint8List?>();
      final s = scheduler(fastCapture: () => gate.future);
      final pending = s.evaluate([track(1)], 10000)!;
      final inFlight = s.capture(pending); // do not await: keeps busy set
      // A due photo is skipped rather than queued while busy — track 2 would
      // otherwise pile up grabs faster than the phone can save them.
      expect(s.evaluate([track(1), track(2)], 11000), isNull);
      gate.complete(null); // grab "fails": capture returns without writing
      await inFlight;
      // Busy cleared: scheduling works again.
      expect(s.evaluate([track(1), track(2)], 12000), isNotNull);
    });
  });
}
