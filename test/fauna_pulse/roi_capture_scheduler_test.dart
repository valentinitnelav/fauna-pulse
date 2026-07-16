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
import 'package:image/image.dart' as img;
import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/models/track.dart';

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
  sessionToken: 'S',
  stepMs: stepMs,
  durationMs: durationMs,
  mode: RoiCaptureMode.fast,
  targetPx: 640,
  fastCaptureFn: fastCapture ?? () async => null,
  highResCaptureFn: () async => null,
  roiProvider: () => Roi.defaultRoi,
  streamDims: () => (1280, 960),
  highResDims: () => (0, 0),
);

void main() {
  group('RoiCaptureScheduler.evaluate', () {
    test('first sight of a track takes a photo immediately, with a '
        'deterministic timestamp+token file name', () {
      final s = scheduler();
      final pending = s.evaluate([track(1)], 10000);
      expect(pending, isNotNull);
      expect(pending!.fileName, roiPhotoFileName(10000, 'S'));
      // Lock the human-readable, sort-stable pattern the gallery export and
      // downstream analysis rely on: the per-session token first (so pooled
      // multi-session folders sort grouped by session), then fixed-width
      // local date, HHmmss, milliseconds.
      expect(
        pending.fileName,
        matches(RegExp(r'^roi_S_\d{4}-\d{2}-\d{2}_\d{6}_\d{3}\.jpg$')),
      );
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

  // Motion-only capture mode: same cadence semantics as a track window, but
  // there is exactly ONE shared window per "motion event" (no tracker runs,
  // so no track ids exist).
  group('RoiCaptureScheduler.evaluateMotion', () {
    test('with an effectively unbounded duration it is a pure periodic clock '
        '(the round-107 ground-truth frame dump configuration)', () {
      // The gt dump reuses the motion window as its clock: huge durationMs
      // means the window never exhausts and never resets, so photos land at
      // exactly the step interval however often the driving timer asks.
      final s = scheduler(stepMs: 5000, durationMs: 1 << 50);
      expect(s.evaluateMotion(0), isNotNull); // first frame immediately
      expect(s.evaluateMotion(1000), isNull); // 1 s tick: not due
      expect(s.evaluateMotion(4999), isNull);
      expect(s.evaluateMotion(5000), isNotNull);
      expect(s.evaluateMotion(9000), isNull);
      // A stretched tick (doze) still lands ONE photo, not a backlog.
      expect(s.evaluateMotion(23000), isNotNull);
      expect(s.evaluateMotion(24000), isNull);
      // Far into a long session the window still hasn't exhausted.
      expect(s.evaluateMotion(3600000), isNotNull);
    });

    test('first motion takes a photo immediately, with no track ids', () {
      final s = scheduler();
      final pending = s.evaluateMotion(10000);
      expect(pending, isNotNull);
      expect(pending!.fileName, roiPhotoFileName(10000, 'S'));
      expect(pending.trackIds, isEmpty);
      expect(pending.capturedAtMs, 10000);
    });

    test('respects the step interval while motion persists', () {
      final s = scheduler(stepMs: 1000);
      expect(s.evaluateMotion(10000), isNotNull); // first photo
      expect(s.evaluateMotion(10400), isNull);
      expect(s.evaluateMotion(10999), isNull);
      expect(s.evaluateMotion(11000), isNotNull);
      // The step counts from the LAST photo, not from motion onset.
      expect(s.evaluateMotion(11900), isNull);
      expect(s.evaluateMotion(12000), isNotNull);
    });

    test('stops once the duration window is over despite continued motion '
        '(wind shaking a flower must not fill the storage)', () {
      final s = scheduler(stepMs: 1000, durationMs: 3000);
      expect(s.evaluateMotion(10000), isNotNull);
      expect(s.evaluateMotion(11000), isNotNull);
      expect(s.evaluateMotion(12000), isNotNull);
      expect(s.evaluateMotion(13000), isNotNull); // 3000 ms, not yet >
      // Motion keeps coming (calls stay within durationMs of each other, so
      // it is all one event): the exhausted window stays exhausted. Only a
      // quiet gap > durationMs would start a new one (next test).
      expect(s.evaluateMotion(14000), isNull);
      expect(s.evaluateMotion(15000), isNull);
      expect(s.evaluateMotion(16000), isNull);
    });

    test('a lull shorter than the duration does NOT restart the window', () {
      final s = scheduler(stepMs: 1000, durationMs: 2000);
      expect(s.evaluateMotion(10000), isNotNull);
      expect(s.evaluateMotion(11000), isNotNull);
      expect(s.evaluateMotion(12000), isNotNull); // window complete
      // Motion pauses and resumes within durationMs of the last event: still
      // the same visit, no fresh "first photo".
      expect(s.evaluateMotion(13500), isNull);
      expect(s.evaluateMotion(14000), isNull);
    });

    test('a quiet gap longer than the duration starts a NEW window '
        '(fresh immediate photo)', () {
      final s = scheduler(stepMs: 1000, durationMs: 2000);
      expect(s.evaluateMotion(10000), isNotNull);
      expect(s.evaluateMotion(12000), isNotNull); // window ends here
      // Nothing moves for > durationMs after the last motion at 12000 —
      // the next motion is a new event.
      expect(s.evaluateMotion(14500), isNotNull);
    });

    test('resetMotionWindow re-arms an exhausted window: the next motion '
        'bursts again immediately (round-96 second-wave field bug)', () {
      final s = scheduler(stepMs: 1000, durationMs: 2000);
      expect(s.evaluateMotion(10000), isNotNull);
      expect(s.evaluateMotion(11000), isNotNull);
      expect(s.evaluateMotion(12000), isNotNull); // window complete
      expect(s.evaluateMotion(13000), isNull); // exhausted
      // The gate goes idle (motion event over), then a SECOND hand-wave
      // arrives well within durationMs of the last awake emission — before
      // this fix the gap rule kept the window and nothing was captured.
      s.resetMotionWindow();
      expect(s.evaluateMotion(13500), isNotNull); // fresh burst, photo now
      expect(s.evaluateMotion(14500), isNotNull); // and its own step cadence
    });

    test('resetMotionWindow mid-window also restarts the burst', () {
      final s = scheduler(stepMs: 1000, durationMs: 5000);
      expect(s.evaluateMotion(10000), isNotNull);
      expect(s.evaluateMotion(10500), isNull); // step not elapsed
      // Only the gate going idle calls this, so a restart here is by
      // definition a new motion event — an immediate photo is correct.
      s.resetMotionWindow();
      expect(s.evaluateMotion(10600), isNotNull);
    });

    test('returns null while a previous capture is still in flight', () async {
      final gate = Completer<Uint8List?>();
      final s = scheduler(fastCapture: () => gate.future);
      final pending = s.evaluateMotion(10000)!;
      final inFlight = s.capture(pending);
      expect(s.evaluateMotion(11000), isNull);
      gate.complete(null);
      await inFlight;
      expect(s.evaluateMotion(12000), isNotNull);
    });

    test('motion window is independent of the per-track windows', () {
      final s = scheduler(stepMs: 1000, durationMs: 5000);
      // A track photo at 10000 must not make the motion window think it
      // already photographed anything (and vice versa).
      expect(s.evaluate([track(1)], 10000), isNotNull);
      expect(s.evaluateMotion(10000), isNotNull);
      expect(s.evaluate([track(1)], 11000), isNotNull);
      expect(s.evaluateMotion(11000), isNotNull);
    });
  });

  group('high-res sync companion (round 108)', () {
    // A real (tiny) JPEG so the Dart fallback crop can decode the "high-res"
    // (the native crop channel has no handler under flutter_test).
    final highResJpeg = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 96, height: 96)),
    );
    final liveCrop = Uint8List.fromList([1, 2, 3, 4]); // written verbatim

    RoiCaptureScheduler highResScheduler(
      Directory dir, {
      bool syncCompanion = true,
      Future<RawHighRes?> Function()? highResFn,
      void Function(CaptureStat)? onStat,
    }) => RoiCaptureScheduler(
      framesDir: dir,
      sessionToken: 'S',
      stepMs: 1000,
      durationMs: 5000,
      mode: RoiCaptureMode.highRes,
      targetPx: 640,
      syncCompanion: syncCompanion,
      fastCaptureFn: () async => liveCrop,
      highResCaptureFn: highResFn ??
          () async => RawHighRes(
            bytes: highResJpeg,
            rotationDegrees: 0,
            isFront: false,
            contentLagMs: 750.0,
            callbackLagMs: 760.0,
          ),
      roiProvider: () => Roi.defaultRoi,
      streamDims: () => (640, 480),
      highResDims: () => (96, 96),
      onStat: onStat,
    );

    test('a high-res-path photo also writes the trigger-moment _live crop and '
        'reports both in the stat', () async {
      final dir = Directory.systemTemp.createTempSync('companion_test');
      CaptureStat? stat;
      final s = highResScheduler(dir, onStat: (v) => stat = v);
      final pending = s.evaluate([track(1)], 10000)!;
      await s.capture(pending);

      final liveName = pending.fileName.replaceFirst('.jpg', '_live.jpg');
      expect(File('${dir.path}/${pending.fileName}').existsSync(), isTrue);
      expect(File('${dir.path}/$liveName').existsSync(), isTrue);
      expect(
        File('${dir.path}/$liveName').readAsBytesSync(),
        equals(liveCrop),
      );
      expect(stat, isNotNull);
      expect(stat!.path, CapturePath.highRes);
      expect(stat!.liveJpeg, liveName);
      expect(stat!.liveBytes, liveCrop.length);
      expect(stat!.contentLagMs, 750.0); // ZSL diagnosis plumbed through
      expect(stat!.grabMs, isNotNull);
      dir.deleteSync(recursive: true);
    });

    test('when the high-res photo fails the companion still lands (and is what '
        'gets reported)', () async {
      final dir = Directory.systemTemp.createTempSync('companion_fail_test');
      CaptureStat? stat;
      final s = highResScheduler(
        dir,
        highResFn: () async => null, // camera refused the photo
        onStat: (v) => stat = v,
      );
      final pending = s.evaluate([track(1)], 10000)!;
      await s.capture(pending);

      final liveName = pending.fileName.replaceFirst('.jpg', '_live.jpg');
      expect(File('${dir.path}/${pending.fileName}').existsSync(), isFalse);
      expect(File('${dir.path}/$liveName').existsSync(), isTrue);
      expect(stat, isNotNull);
      expect(stat!.fileName, liveName);
      expect(stat!.path, CapturePath.fast);
      dir.deleteSync(recursive: true);
    });

    test('disabled companion writes only the high-res photo', () async {
      final dir = Directory.systemTemp.createTempSync('companion_off_test');
      final s = highResScheduler(dir, syncCompanion: false);
      final pending = s.evaluate([track(1)], 10000)!;
      await s.capture(pending);

      final liveName = pending.fileName.replaceFirst('.jpg', '_live.jpg');
      expect(File('${dir.path}/${pending.fileName}').existsSync(), isTrue);
      expect(File('${dir.path}/$liveName').existsSync(), isFalse);
      dir.deleteSync(recursive: true);
    });
  });
}
