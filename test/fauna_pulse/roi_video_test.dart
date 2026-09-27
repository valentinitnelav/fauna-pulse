// Tests for time-lapse video bursts (round 238, capture/roi_video.dart): the
// storage estimate, the clip names, the burst edges the screen ticks on, and
// TimeLapseVideoClips against a fake native writer with a real session log.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/capture/roi_video.dart';
import 'package:fauna_pulse/fauna_pulse/capture/time_lapse_plan.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_logger.dart';
import 'package:fauna_pulse/fauna_pulse/models/schedule_window.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for RoiVideoWriter: records the calls, answers like it.
class _FakeWriter {
  final starts = <(String, int, int)>[];
  final stops = <String>[];
  Map<String, dynamic>? startAnswer = {'sidePx': 1024, 'bitrate': 3932160, 'encoder': 'c2.fake.avc'};
  int frames = 150;

  Future<Map<String, dynamic>?> start(String path, int side, int fps) async {
    starts.add((path, side, fps));
    return startAnswer;
  }

  Future<Map<String, dynamic>?> stop(String reason) async {
    stops.add(reason);
    return {
      'frames': frames,
      'skipped': 2,
      'firstEpochMs': 1790000000123.4,
      'firstPtsUs': 5000,
      'durationMs': 10000.0,
      'bytes': 4900000,
      'bitrate': 3932160,
      'encoder': 'c2.fake.avc',
      'cropMsMean': 4.567,
      'drawMsMean': 1.234,
      'flushed': true,
      'reason': reason,
      'error': null,
    };
  }
}

void main() {
  group('storage estimate', () {
    test('bit rate and bytes per hour follow 0.25 bits per pixel', () {
      expect(roiVideoBitrate(1024, 15), 3932160);
      expect(roiVideoBytesPerHour(1024, 15), 3932160 / 8 * 3600 * 1.2);
    });

    test('recorded share of a burst plan', () {
      expect(timeLapseRecordedShare(10, 0), 1);
      expect(timeLapseRecordedShare(10, 30), 0.25);
      expect(timeLapseRecordedShare(0, 30), 0);
    });

    test('planned minutes: session length, or every window on every day', () {
      expect(plannedSessionMinutes(const SessionConfig(sessionMinutes: 90)), 90);
      final c = const SessionConfig().copyWith(
        scheduleEnabled: true,
        scheduleWindows: const [ScheduleWindow(360, 480), ScheduleWindow(900, 960)],
        scheduleDays: 3,
      );
      expect(plannedSessionMinutes(c), (120 + 60) * 3);
    });

    test('the sentence names the size per hour and for the session', () {
      final c = const SessionConfig(sessionMinutes: 60).copyWith(
        captureTrigger: CaptureTrigger.timelapse,
        timeLapseSaveAs: TimeLapseSaveAs.video,
        durationSeconds: 10,
        timeLapseGapSeconds: 30,
      );
      final text = roiVideoStorageEstimate(c);
      // 1024 px (the default saved side), 15 fps, plus 20 %: 2.0 GB (1024-based) per hour.
      expect(text, contains('Up to about 2.0 GB per hour of video (1024px, 15 frames per second'));
      // A quarter of 60 min is recorded: 15 min, about 506 MB.
      expect(text, contains('scene). A 60 min session records about 15 min of video: about 506.3 MB.'));
    });
  });

  test('clip names are the photo names with .mp4', () {
    final ms = DateTime(2026, 9, 27, 14, 5, 9, 42).millisecondsSinceEpoch;
    expect(roiVideoFileName(ms, 'ab12'), 'roi_ab12_2026-09-27_140509_042.mp4');
  });

  group('TimeLapsePlan.nextEdgeDelayMs', () {
    test('bursts: until the burst ends, then until the next one starts', () {
      const plan = TimeLapsePlan(stepMs: 1000, burstMs: 10000, gapMs: 20000);
      expect(plan.nextEdgeDelayMs(0), 10001);
      expect(plan.nextEdgeDelayMs(9999), 2);
      expect(plan.inBurstAt(10001), isFalse);
      expect(plan.nextEdgeDelayMs(10001), 19999);
      expect(plan.nextEdgeDelayMs(30000), 10001);
    });

    test('continuous: until the next clip starts', () {
      const plan = TimeLapsePlan(stepMs: 1000, burstMs: 10000, gapMs: 0);
      expect(plan.nextEdgeDelayMs(3000), 7000);
      expect(plan.nextEdgeDelayMs(10000), 10000);
    });
  });

  group('TimeLapseVideoClips', () {
    late Directory tmp;
    late File logFile;
    late SessionLogger logger;
    late _FakeWriter native;
    var storageLow = false;
    final problems = <String>[];
    var now = DateTime(2026, 9, 27, 12).millisecondsSinceEpoch;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('faunapulse_roi_video');
      logFile = File('${tmp.path}/session.jsonl');
      logger = SessionLogger(logFile)..open();
      native = _FakeWriter();
      storageLow = false;
      problems.clear();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    TimeLapseVideoClips clips() => TimeLapseVideoClips(
      videosDir: Directory('${tmp.path}/videos'),
      fileToken: 'tok1',
      fps: 15,
      sidePx: () => 1024,
      startNative: native.start,
      stopNative: native.stop,
      logger: () => logger,
      storageLow: () => storageLow,
      onProblem: (reason, _) => problems.add(reason),
      now: () => now += 1000,
    );

    Future<List<Map<String, dynamic>>> records() async {
      await logger.close();
      return [for (final l in logFile.readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
    }

    test('one clip per burst: opened once, closed at the burst end and logged like an import', () async {
      final c = clips();
      await c.sync(0);
      await c.sync(0);
      expect(c.recording, isTrue);
      expect(native.starts, hasLength(1));
      expect(native.starts.single.$1, startsWith('${tmp.path}/videos/roi_tok1_2026-09-27_'));
      expect(native.starts.single.$1, endsWith('.mp4'));
      expect(native.starts.single.$3, 15);
      expect(Directory('${tmp.path}/videos').existsSync(), isTrue);
      await c.sync(null);
      expect(c.recording, isFalse);
      expect(native.stops, ['burst_end']);
      expect(c.clips, 1);
      expect(c.bytes, 4900000);

      final r = await records();
      expect(r.map((e) => e['type']), ['timelapse_video_start', 'video_clip']);
      final start = r[0];
      expect(start['burst'], 0);
      expect(start['side_px'], 1024);
      expect(start['fps'], 15);
      expect(start['encoder'], 'c2.fake.avc');
      expect(start.containsKey('requested_side_px'), isFalse);
      final clip = r[1];
      expect(clip['file'], start['file']);
      expect((clip['file'] as String).startsWith('videos/roi_tok1_'), isTrue);
      expect(clip['start_epoch_ms'], 1790000000123);
      expect(clip['start_time_source'], 'camera');
      expect(clip['duration_ms'], 10000);
      expect(clip['size_bytes'], 4900000);
      expect(clip['width'], 1024);
      expect(clip['height'], 1024);
      expect(clip['rotation'], 0);
      expect(clip['frame_count'], 150);
      expect(clip['fps_mean'], 15.0);
      expect(clip['fps_nominal'], 15);
      expect(clip['frames_skipped'], 2);
      expect(clip['burst'], 0);
      expect(clip['end_reason'], 'burst_end');
      expect(clip['crop_ms_mean'], 4.57);
      expect(clip.containsKey('error'), isFalse);
      expect(clip.containsKey('flushed'), isFalse);
    });

    test('a new burst ends the open clip and starts the next (continuous time-lapse)', () async {
      final c = clips();
      await c.sync(1);
      await c.sync(2);
      await c.stop('session_end');
      await c.stop('session_end');
      expect(native.starts, hasLength(2));
      expect(native.stops, ['burst_end', 'session_end']);
      final r = await records();
      expect(r.where((e) => e['type'] == 'video_clip').map((e) => e['burst']), [1, 2]);
      expect(r.last['end_reason'], 'session_end');
    });

    test('a clip the encoder shrank records both sides', () async {
      native.startAnswer = {'sidePx': 960, 'bitrate': 3456000, 'encoder': 'c2.fake.avc'};
      final c = clips();
      await c.sync(0);
      await c.stop('session_end');
      final r = await records();
      expect(r[0]['side_px'], 960);
      expect(r[0]['requested_side_px'], 1024);
      expect(r[1]['width'], 960);
    });

    test('a failed start is logged once and not retried until the next burst', () async {
      native.startAnswer = {'error': 'No video encoder on this phone takes 1024px at 15 fps'};
      final c = clips();
      await c.sync(0);
      await c.sync(0);
      await c.sync(0);
      expect(native.starts, hasLength(1));
      expect(c.recording, isFalse);
      expect(c.problem, 'start_failed');
      native.startAnswer = {'sidePx': 1024, 'bitrate': 1, 'encoder': 'x'};
      await c.sync(1);
      expect(c.recording, isTrue);
      expect(c.problem, isNull);
      await c.stop('session_end');
      expect(problems, ['start_failed']);
      final r = await records();
      expect(r.map((e) => e['type']), ['video_skipped', 'timelapse_video_start', 'video_clip']);
      expect(r[0]['reason'], 'start_failed');
      expect(r[0]['burst'], 0);
      expect(r[0]['message'], contains('No video encoder'));
    });

    test('low storage: no clip, logged once per burst, checked again every tick', () async {
      storageLow = true;
      final c = clips();
      await c.sync(0);
      await c.sync(0);
      expect(native.starts, isEmpty);
      expect(c.problem, 'storage_low');
      storageLow = false;
      await c.sync(0);
      expect(native.starts, hasLength(1));
      await c.stop('session_end');
      final r = await records();
      expect(r.map((e) => e['type']), ['video_skipped', 'timelapse_video_start', 'video_clip']);
      expect(r[0]['reason'], 'storage_low');
      expect(problems, ['storage_low']);
    });

    test('a clip without frames is reported, not listed as a clip', () async {
      native.frames = 0;
      final c = clips();
      await c.sync(0);
      await c.sync(null, endReason: 'camera_paused');
      expect(native.stops, ['camera_paused']);
      expect(c.clips, 0);
      final r = await records();
      expect(r.map((e) => e['type']), ['timelapse_video_start', 'video_skipped']);
      expect(r[1]['reason'], 'no_frames');
      expect(r[1]['file'], r[0]['file']);
    });

    test('stop without an open clip does not call the camera', () async {
      final c = clips();
      await c.stop('session_end');
      await c.sync(null);
      expect(native.starts, isEmpty);
      expect(native.stops, isEmpty);
    });
  });
}
