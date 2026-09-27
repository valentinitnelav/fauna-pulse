// FaunaPulse (round 240): on-device check of "Also record the ROI as video"
// while the live AI runs (video plan 3b).
//
// Runs the real camera screen four times with the phone's own saved AI
// settings (model, engine, rates), each for about 45 s, folder
// "live_video_check": A without video, B with video, C with video and the
// motion gate on, D with video and a gate that cannot see motion (a pixel
// must change by more than 255), so the detector sleeps all session and the
// clip's frames take the video-only path. The phone's saved settings are restored
// afterwards; the sessions stay on the phone (delete them there).
// Run:  flutter test integration_test/live_video_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.
//
// Logged per session: detector and camera frames per second (the `fps`
// records after a 10 s warm-up), battery temperature, and for B and C the
// clip (frames, skipped, length, frame rate, copy and draw ms). SHOT: the
// chip while recording, and the summary's Video tab after the stop.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _folder = 'live_video_check';

// --dart-define=LIVE_CHECK_ONLY=D runs only session D (round 243, Samsung).
const _only = String.fromEnvironment('LIVE_CHECK_ONLY');
// --dart-define=LIVE_D_VIDEO=false: session D without video (does the gate sleep at all?).
const _dVideo = bool.fromEnvironment('LIVE_D_VIDEO', defaultValue: true);
const _seconds = 45;

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live AI with and without ROI video on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions');
    sessions.createSync(recursive: true); // a fresh install has none yet

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 3));
    }

    final recButton = find.byWidgetPredicate(
      (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 72, height: 72),
    );

    Future<Directory> record(String label, SessionConfig config) async {
      final before = sessions.existsSync() ? sessions.listSync().map((e) => e.path).toSet() : <String>{};
      final t0 = await DeviceThermal.read();
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: CameraSessionScreen(initialConfig: config)),
      );
      await tester.pump(const Duration(seconds: 3));
      Directory? dir;
      for (var i = 0; i < 30 && dir == null; i++) {
        if (find.text('Not now').evaluate().isNotEmpty) await tester.tap(find.text('Not now'));
        await tester.tap(recButton.first, warnIfMissed: false);
        await tester.pump(const Duration(seconds: 1));
        final added = sessions.listSync().whereType<Directory>().where((d) => !before.contains(d.path)).toList();
        if (added.isNotEmpty) dir = added.single;
      }
      expect(dir, isNotNull, reason: 'recording $label did not start');
      final start = DateTime.now();
      var shotTaken = !config.liveAiVideo;
      while (DateTime.now().difference(start).inSeconds < _seconds) {
        await tester.pump(const Duration(milliseconds: 500));
        if (!shotTaken && DateTime.now().difference(start).inSeconds >= 20) {
          shotTaken = true;
          await shot('live_${label}_recording');
        }
      }
      await tester.tap(recButton.first, warnIfMissed: false);
      final log = File('${dir!.path}/session.jsonl');
      for (var i = 0; i < 40 && !log.readAsStringSync().contains('"end_of_session"'); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump(const Duration(seconds: 3));
      if (config.liveAiVideo) await shot('live_${label}_summary');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      final t1 = await DeviceThermal.read();

      final recs = [for (final l in log.readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
      final t00 = recs.first['time_ms'] as int;
      double mean(String key) {
        final v = [
          for (final r in recs)
            if (r['type'] == 'fps' && (r['time_ms'] as int) - t00 > 10000 && r[key] is num) (r[key] as num).toDouble(),
        ];
        return v.isEmpty ? double.nan : v.reduce((a, b) => a + b) / v.length;
      }

      _log('SESSION $label: detector ${mean('detector_fps').toStringAsFixed(1)} fps, camera '
          '${mean('camera_fps').toStringAsFixed(1)} fps, inference ${mean('inf_ms').toStringAsFixed(1)} ms, '
          'battery ${t0.batteryTempC} -> ${t1.batteryTempC} °C');
      for (final r in recs.where((r) => r['type'] == 'video_clip' || r['type'] == 'video_skipped')) {
        _log('CLIP $label ${r['type']}: segment ${r['segment']}, ${r['frame_count']} frames, '
            '${r['frames_skipped']} skipped, ${r['duration_ms']} ms, ${r['fps_mean']} fps, '
            '${r['size_bytes']} B, copy ${r['crop_ms_mean']} ms, draw ${r['draw_ms_mean']} ms, '
            '${r['end_reason'] ?? r['reason']}');
      }
      return dir;
    }

    final base = saved.copyWith(
      captureTrigger: CaptureTrigger.detector,
      scheduleEnabled: false,
      sessionMinutes: 60,
      folderName: _folder,
    );
    final runs = <Directory>[];
    if (_only.isEmpty) {
      final a = await record('A', base.copyWith(liveAiVideo: false));
      expect(Directory('${a.path}/videos').existsSync(), isFalse);
      runs.add(await record('B', base.copyWith(liveAiVideo: true, liveAiVideoFps: 15)));
      runs.add(await record('C', base.copyWith(liveAiVideo: true, liveAiVideoFps: 15, motionGateEnabled: true)));
    }
    // D: nothing can wake the gate: no pixel change counts (> 255) and no box counts as a
    // detection (confidence 0.99; any box keeps the gate awake, also classes the tracker
    // ignores, e.g. MegaDetector's person/vehicle on a dark scene: Samsung, round 243). The
    // arthropod model, when imported, finds nothing in a dark scene.
    final arthropod = File('${(await getApplicationSupportDirectory()).path}/models/arthropod_yolov11_float16.tflite');
    final d = await record(
      'D',
      base.copyWith(
        liveAiVideo: _dVideo,
        liveAiVideoFps: 15,
        motionGateEnabled: true,
        motionGatePixelDelta: 255,
        confidenceThreshold: 0.99,
        modelPath: arthropod.existsSync() ? arthropod.path : null,
      ),
    );
    if (_dVideo) runs.add(d);
    final idle = File('${d.path}/session.jsonl').readAsLinesSync().where((l) => l.contains('"gate_idle":true')).length;
    _log('GATE D: $idle fps records with the detector asleep');
    expect(idle, greaterThan(0), reason: 'the gate should have slept');
    for (final dir in runs) {
      final recs = [for (final l in File('${dir.path}/session.jsonl').readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
      expect(recs.where((r) => r['type'] == 'live_video_start'), hasLength(1));
      final clip = recs.singleWhere((r) => r['type'] == 'video_clip');
      expect(clip['segment'], 0);
      expect(clip['end_reason'], 'session_end');
      final info = await VideoFrameSource.info('${dir.path}/${clip['file']}');
      _log('FILE ${dir.path.split('/').last}: ${info.width}x${info.height}, ${info.frameCount} frames, '
          '${info.durationMs} ms, ${info.meanFps} fps');
      expect(info.frameCount, clip['frame_count']);
      // About 15 per second over the whole session, the gate asleep or not.
      expect(clip['fps_mean'] as num, greaterThan(12));
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
