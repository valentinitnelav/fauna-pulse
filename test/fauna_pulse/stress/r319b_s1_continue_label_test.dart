// Round 319 part 2 (S1b, phone test PB1 L2c): a run stopped inside the first clip
// (storage full, Stop, a heat pause left with Back) is continued by the main button,
// and the messages say "press Continue" / "Continue picks up from there", but the
// button read "Analyze 3 clips": it said Continue only once a whole clip was finished.
//
// The YOLO plugin's channels are stand-ins, as in r319_l2_video_screen_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

const _yolo = MethodChannel('yolo_single_image_channel');
const _thermal = MethodChannel('faunapulse/thermal');

Future<void> _pumpUntil(WidgetTester tester, Finder ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
    if (ready.evaluate().isNotEmpty) break;
  }
  expect(ready, findsWidgets, reason: 'never appeared: $ready');
}

void main() {
  final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 64, height: 48)));
  var nextPts = 0;

  Future<Object?> instance(MethodCall call) async {
    switch (call.method) {
      case 'loadModel':
        return true;
      case 'videoInfo':
        return {'durationMs': 300000, 'width': 640, 'height': 480, 'frameCount': 9000, 'firstPtsUs': 0};
      case 'videoThumbnail':
        return jpeg;
      case 'videoOpen':
        nextPts = 0;
        return null;
      case 'videoNext':
        sleep(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final pts = nextPts;
        nextPts += 200000;
        return {
          'frames': [
            {'pts': pts, 'frame': pts ~/ 33333, 'boxes': <Object>[]},
          ],
          'done': false,
          'decoded': 6,
          'frameWidth': 640,
          'frameHeight': 480,
          'names': ['insect'],
        };
    }
    return null;
  }

  setUp(() {
    VideoPlayerPlatform.instance = FakeVideoPlayer();
    wakelockPlusPlatformInstance = FakeWakelock();
    DeviceThermal.resetForTesting();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_yolo, (call) async {
      if (call.method == 'createInstance') {
        final id = (call.arguments as Map)['instanceId'] as String;
        messenger.setMockMethodCallHandler(MethodChannel('yolo_single_image_channel_$id'), instance);
        return null;
      }
      if (call.method == 'inspectModel') return {'task': 'detect'};
      return instance(call);
    });
    messenger.setMockMethodCallHandler(_thermal, (call) async => {'batteryTempC': 30.0});
  });
  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_yolo, null);
    messenger.setMockMethodCallHandler(_thermal, null);
    DeviceThermal.resetForTesting();
  });

  /// [clips] imported clips of 5 min each.
  Directory session(Directory tmp, List<String> clips) {
    final dir = Directory('${tmp.path}/Echium');
    Directory('${dir.path}/videos').createSync(recursive: true);
    for (final c in clips) {
      File('${dir.path}/videos/$c').writeAsStringSync('video');
    }
    File('${dir.path}/session.jsonl').writeAsStringSync(
      [
        '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}',
        for (final c in clips)
          jsonEncode({'type': 'video_clip', 'time_ms': 1000, 'file': 'videos/$c', 'duration_ms': 300000, 'width': 640, 'height': 480}),
        '{"type":"end_of_session","time_ms":31000,"ended_normally":true}',
      ].join('\n'),
    );
    return dir;
  }

  Future<Directory> open(WidgetTester tester, List<String> clips) async {
    SharedPreferences.setMockInitialValues({'find_also_identify': false});
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tmp = Directory.systemTemp.createTempSync('r319b_s1_continue');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final dir = session(tmp, clips);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: dir.path,
          sessionsDir: tmp,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Area to analyze'));
    return dir;
  }

  Future<void> tapButton(WidgetTester tester, Finder button) async {
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    await tester.tap(button);
  }

  /// Starts with [label], stops inside the first clip, and waits for the run to end.
  Future<void> runAndStop(WidgetTester tester, String label) async {
    await tapButton(tester, find.text(label));
    await _pumpUntil(tester, find.textContaining('ms per frame'));
    await tapButton(tester, find.text('Stop'));
    await _pumpUntil(tester, find.byType(SnackBar));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('stopped inside the first of 3 clips: the button says Continue, as the message', (tester) async {
    final dir = await open(tester, ['a.mp4', 'b.mp4', 'c.mp4']);
    await runAndStop(tester, 'Analyze 3 clips');
    expect(find.textContaining('Continue picks up from there.'), findsOneWidget);
    // Nothing finished, but boxes of the first clip are saved: Continue goes on from them.
    final lines = File('${dir.path}/${VideoDetector.outputFileName}').readAsLinesSync();
    expect(lines.where((l) => l.contains('"video_clip_done"')), isEmpty);
    expect(lines.where((l) => l.contains('"raw_detections"')), isNotEmpty);
    await _pumpUntil(tester, find.text('Continue (3 of 3 clips left)'));
    expect(find.text('Analyze 3 clips'), findsNothing);

    // Continue goes on inside the first clip, not from its start.
    final before = lines.where((l) => l.contains('"raw_detections"')).length;
    await runAndStop(tester, 'Continue (3 of 3 clips left)');
    final starts = File('${dir.path}/${VideoDetector.outputFileName}')
        .readAsLinesSync()
        .where((l) => l.contains('"video_clip_start"'))
        .map((l) => jsonDecode(l) as Map)
        .toList();
    expect(starts.last['resume_from_pts_us'], isNotNull);
    expect(before, greaterThan(0));
    await close(tester);
  });

  testWidgets('one clip: the button says Continue', (tester) async {
    await open(tester, ['a.mp4']);
    await runAndStop(tester, 'Analyze 1 clip');
    await _pumpUntil(tester, find.text('Continue'));
    expect(find.text('Analyze 1 clip'), findsNothing);
    await close(tester);
  });
}
