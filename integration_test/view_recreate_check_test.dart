// FaunaPulse (round 244): on-device check that the camera screen's native settings survive a new
// camera view.
//
// The camera view is built anew when the analysis stream size changes (its key): when the screen
// picks the stream size by itself (round 109, while the user has not chosen one) or when the user
// changes it in Settings. Before round 244 the new view kept only the model and the thresholds:
// no ROI crop, no motion gate, no camera frame-rate cap, and not in time-lapse mode.
//
// Each session starts from a stream size the phone's own pick changes (START_STREAM, default
// 640x480, the choice left automatic), waits for the new view before recording, and records 30 s:
//  A. live AI with a motion gate nothing can wake (as in live_video_check_test.dart D): the
//     detector must sleep;
//  B. time-lapse video bursts: the clip must keep about 15 fps, with no detector results.
// The phone's saved settings are restored afterwards. logcat shows "YOLOView created" twice per
// session when the view was built anew.
// Run:  flutter test integration_test/view_recreate_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'skip_before_record_sheet.dart';

const _folder = 'view_recreate_check';
const _startStream = String.fromEnvironment('START_STREAM', defaultValue: '640x480');
// --dart-define=START_LENS=0.6: a saved non-main lens; logcat "setLens" must show it applied on
// both views of a session (round 245).
const _startLens = String.fromEnvironment('START_LENS');
const _seconds = 30;

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native settings survive a new camera view on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    await skipBeforeRecordSheet(); // round 298
    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions');
    sessions.createSync(recursive: true); // a fresh install has none yet
    final wh = _startStream.split('x').map(int.parse).toList();

    final recButton = find.byWidgetPredicate(
      (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 72, height: 72),
    );

    Future<List<Map<String, dynamic>>> record(String label, SessionConfig config) async {
      final before = sessions.listSync().map((e) => e.path).toSet();
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: CameraSessionScreen(initialConfig: config)),
      );
      // The stream pick waits for the camera probes; recording blocks it.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')).evaluate().isNotEmpty) await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')).first);
      }
      Directory? dir;
      for (var i = 0; i < 30 && dir == null; i++) {
        if (find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')).evaluate().isNotEmpty) await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')).first);
        await tester.tap(recButton.first, warnIfMissed: false);
        await tester.pump(const Duration(seconds: 1));
        final added = sessions.listSync().whereType<Directory>().where((d) => !before.contains(d.path)).toList();
        if (added.isNotEmpty) dir = added.single;
      }
      expect(dir, isNotNull, reason: 'recording $label did not start');
      final start = DateTime.now();
      while (DateTime.now().difference(start).inSeconds < _seconds) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(recButton.first, warnIfMissed: false);
      final log = File('${dir!.path}/session.jsonl');
      for (var i = 0; i < 40 && !log.readAsStringSync().contains('"end_of_session"'); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      final recs = [for (final l in log.readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
      final fps = recs.where((r) => r['type'] == 'fps').toList();
      final streams = {for (final r in fps) '${r['analysis_w']}x${r['analysis_h']}'};
      _log('SESSION $label: ${fps.length} fps records, analysis streams $streams, '
          '${fps.where((r) => r['gate_idle'] == true).length} with the detector asleep, '
          '${fps.where((r) => (r['detector_fps'] as num? ?? 0) > 0).length} with detector results');
      return recs;
    }

    final start = saved.copyWith(
      streamWidth: wh[0],
      streamHeight: wh[1],
      streamResolutionExplicit: false,
      selectedLensZoom: _startLens.isEmpty ? null : double.parse(_startLens),
      scheduleEnabled: false,
      sessionMinutes: 60,
      folderName: _folder,
    );

    // A. Live AI, a gate nothing can wake.
    final arthropod = File('${(await getApplicationSupportDirectory()).path}/models/arthropod_yolov11_float16.tflite');
    final a = await record(
      'A',
      start.copyWith(
        captureTrigger: CaptureTrigger.detector,
        liveAiVideo: false,
        motionGateEnabled: true,
        motionGatePixelDelta: 255,
        confidenceThreshold: 0.99,
        modelPath: arthropod.existsSync() ? arthropod.path : null,
      ),
    );
    final aFps = a.where((r) => r['type'] == 'fps').toList();

    // B. Time-lapse video bursts: 10 s every 25 s, so 30 s holds a whole first burst.
    final b = await record(
      'B',
      start.copyWith(
        captureTrigger: CaptureTrigger.timelapse,
        timeLapseSaveAs: TimeLapseSaveAs.video,
        timeLapseVideoFps: 15,
        durationSeconds: 10,
        timeLapseGapSeconds: 15,
        timeLapseCameraSleep: false,
        timeLapseTorch: false,
      ),
    );
    final clips = b.where((r) => r['type'] == 'video_clip').toList();
    for (final c in clips) {
      _log('CLIP B burst ${c['burst']}: ${c['frame_count']} frames, ${c['duration_ms']} ms, ${c['fps_mean']} fps, '
          '${c['end_reason']}');
    }

    expect(aFps.where((r) => r['gate_idle'] == true), isNotEmpty, reason: 'A: the gate should have slept');
    expect(clips, isNotEmpty, reason: 'B: no clip');
    expect(clips.first['fps_mean'] as num, greaterThan(12), reason: 'B: the first burst should keep ~15 fps');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
