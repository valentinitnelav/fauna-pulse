// Round 319, part 3 (K1): at the end of an identification the native side closes the model and
// gives the freed memory back to Android ("embedderClose", NativeMemory.giveBack). On the 3.6 GB
// phone Android ended the app 0.17 s after that call once it was a cached app without the
// analysis service. So the service hold must be released only after embedderClose has answered,
// or the app is cached while it still holds the model's memory. Here embedderClose is held back
// and the service must stay until it answers.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show roiPhotoFileName;
import 'package:fauna_pulse/fauna_pulse/identification/identification_run.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/photo_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/services/analysis_keepalive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

final _s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': _s0, ...m});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  const keepAliveChannel = MethodChannel('faunapulse/keepalive');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
  late Directory tmp;
  late List<String> events;
  late Completer<void> closeAnswer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319c_k_close');
    IdentificationRun.resetForTest();
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    wakelockPlusPlatformInstance = FakeWakelock();
    PackageInfo.setMockInitialValues(appName: 'FaunaPulse', packageName: 'test', version: '0.0.0', buildNumber: '1', buildSignature: '');
    SharedPreferences.setMockInitialValues({'identify_model': 'test-model.tflite', 'identify_pack': 'tiny_pack.fpack'});
    AnalysisKeepAlive.resetForTest();
    AnalysisKeepAlive.debugIsAndroid = true;
    events = [];
    closeAnswer = Completer<void>();
    messenger.setMockMethodCallHandler(keepAliveChannel, (call) async {
      events.add(call.method == 'startAnalysis' ? 'service start' : 'service stop');
      return true;
    });
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      switch (call.method) {
        case 'embedderLoad':
          return {'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': pack.dim, 'loadMs': 1.0};
        case 'embedderRun':
          final n = ((call.arguments as Map)['images'] as List).length;
          return {
            'dim': pack.dim,
            'count': n,
            'vectors': Float32List.fromList([for (var i = 0; i < n; i++) ...pack.matrix.sublist(0, pack.dim)]),
            'ms': 1.0,
          };
        case 'embedderClose':
          events.add('close asked');
          await closeAnswer.future; // the native close + give-back still running
          events.add('close answered');
          return null;
      }
      return null;
    });
  });
  tearDown(() {
    AnalysisKeepAlive.debugIsAndroid = null;
    for (final c in [pathChannel, yoloChannel, keepAliveChannel]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A time-lapse session (a photo every 0.2 s for 4 s) with one insect from 1 s to 3 s, tracked.
  Future<Directory> photoSession(WidgetTester tester) async {
    final m = Directory('${tmp.path}/identification/models')..createSync(recursive: true);
    final p = Directory('${tmp.path}/identification/packs')..createSync(recursive: true);
    File('${m.path}/test-model.tflite').writeAsBytesSync([0]);
    File('test/fauna_pulse/fixtures/tiny_pack.fpack').copySync('${p.path}/tiny_pack.fpack');
    final dir = Directory('${tmp.path}/sessions/Salvia')..createSync(recursive: true);
    final times = [for (var t = 0; t < 4000; t += 200) t];
    String name(int t) => roiPhotoFileName(_s0 + t, 'tok');
    File('${dir.path}/session.jsonl').writeAsStringSync('${[
      _rec('start_of_session', {
        'file_token': 'tok',
        'config': {'captureTrigger': 'timelapse', 'stepSeconds': 0.2, 'durationSeconds': 4.0},
      }),
      for (final t in times) ...[
        _rec('timelapse_capture', {'jpeg': name(t), 'captured_at_ms': _s0 + t}),
        _rec('capture', {'file': name(t), 'captured_at_ms': _s0 + t, 'saved_px': 640}),
      ],
      _rec('end_of_session', {'time_ms': _s0 + 5000, 'ended_normally': true}),
    ].join('\n')}\n');
    File('${dir.path}/post_detections.jsonl').writeAsStringSync('${[
      _rec('post_start', {'model': 'm.tflite', 'model_name': 'm', 'confidence': 0.25, 'iou': 0.7}),
      for (final t in times)
        _rec('post_detection', {
          'jpeg': name(t),
          'captured_at_ms': _s0 + t,
          'boxes': [
            if (t >= 1000 && t <= 3000)
              {
                'class_name': 'bee',
                'conf': 0.8,
                'box': [0.3, 0.3, 0.6, 0.6],
              },
          ],
        }),
    ].join('\n')}\n');
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    final im = img.Image(width: 320, height: 320, numChannels: 3);
    img.fill(im, color: img.ColorRgb8(200, 60, 40));
    final jpeg = Uint8List.fromList(img.encodeJpg(im, quality: 90));
    for (final t in times) {
      File('${frames.path}/${name(t)}').writeAsBytesSync(jpeg);
    }
    await tester.runAsync(() => PhotoTracker.run(dir, const SessionConfig()));
    return dir;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done, String what) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: 'never happened: $what; events: $events');
  }

  testWidgets('the analysis service is let go only after the model is closed and its memory given back', (tester) async {
    final dir = await photoSession(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => events.contains('close asked'), 'the run closes the model');
    // While the native side is still closing, the service must stay.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(events, isNot(contains('service stop')), reason: 'events: $events');
    expect(run.finished, isFalse);
    closeAnswer.complete();
    await pumpUntil(tester, () => events.isNotEmpty && events.last == 'service stop', 'the service stops');
    expect(events.indexOf('close answered'), lessThan(events.indexOf('service stop')));
    // The run's end deletes the wait note (lane B) after the release, then counts as finished.
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(AnalysisKeepAlive.activeHolds, 0);
  });
}
