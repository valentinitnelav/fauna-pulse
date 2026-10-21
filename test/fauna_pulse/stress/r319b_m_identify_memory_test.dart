// Round 319, part 2 (phone test PB2, steps b and b2): on the 3.6 GB Redmi, "Also identify them"
// started the BioCLIP 2 load in the background (under the analysis service) and Android's
// low-memory killer ended the app 3 s into the load, both times; the same model started with the
// app in front ran to the end. Owner's decision (2026-10-21): before such a load while the app
// is not in front, check the free memory; when the model does not fit, do not load, give the
// service up, show an "Animals found" notification and start the identification by itself when
// the app comes to the front.
//
// The plugin's answer to 'embedderMemory' is faked with the numbers of the phone test. Only
// channel names are used here (no new Dart names), so this file also runs against the code
// before the fix, where it fails: the model loads in the background at once.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show roiPhotoFileName;
import 'package:fauna_pulse/fauna_pulse/identification/identification_run.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/photo_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/screens/analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_results_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/services/analysis_keepalive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../video_screens_test.dart' show postTracks;
import '../video_test_fakes.dart';

final _s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': _s0, ...m});

Uint8List _jpeg(int r, int g, int b) {
  final im = img.Image(width: 320, height: 320, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

const _kb = 1024;

/// PB2 step b: 3.6 GB Redmi, BioCLIP 2 fp16 (0.61 GB) on the CPU, at the hand-over to the
/// identification (11:15:12): MemAvailable 1,083,708 kB. availMem (MemFree + Cached) is larger.
Map<String, Object> _redmi() => {
      'fileBytes': 609000000,
      'needBytes': (609000000 * 2.15).round(),
      'onGpu': false,
      'availMem': 1400000 * _kb,
      'threshold': 226 * 1024 * _kb,
      'totalMem': 3800000000,
      'lowMemory': false,
      'memAvailable': 1083708 * _kb,
    };

/// A phone with plenty free (an 8 GB phone with 3.5 GB free).
Map<String, Object> _roomy() => {
      ..._redmi(),
      'availMem': 3600000 * _kb,
      'totalMem': 7400000000,
      'memAvailable': 3500000 * _kb,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  const keepAliveChannel = MethodChannel('faunapulse/keepalive');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
  late Directory tmp;
  late List<String> calls;
  late List<String> keepCalls;
  late Map<String, Object>? memory;
  late bool reminderFails;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319b_m_memory');
    IdentificationRun.resetForTest();
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    wakelockPlusPlatformInstance = FakeWakelock();
    PackageInfo.setMockInitialValues(appName: 'FaunaPulse', packageName: 'test', version: '0.0.0', buildNumber: '1', buildSignature: '');
    SharedPreferences.setMockInitialValues({
      'identify_model': 'test-model.tflite',
      'identify_pack': 'tiny_pack.fpack',
      'find_also_identify': true,
    });
    AnalysisKeepAlive.resetForTest();
    AnalysisKeepAlive.debugIsAndroid = true;
    keepCalls = [];
    reminderFails = false;
    messenger.setMockMethodCallHandler(keepAliveChannel, (call) async {
      switch (call.method) {
        case 'startAnalysis':
          keepCalls.add('start ${(call.arguments as Map)['title']}');
        case 'stopAnalysis':
          keepCalls.add('stop');
        case 'showIdentifyReminder':
          final a = call.arguments as Map;
          keepCalls.add('reminder ${a['title']} | ${a['text']}');
          // Android 13+ without the notification permission (the native side answers false).
          if (reminderFails) throw PlatformException(code: 'denied', message: 'no permission');
        default:
          keepCalls.add(call.method);
      }
      return true;
    });
    memory = _redmi();
    calls = [];
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'embedderMemory':
          return memory;
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

  /// A time-lapse session (a photo every 0.2 s for 4 s), every photo analyzed, one insect from
  /// 1 s to 3 s with its track ID found (as r319_l4_identify_background_test).
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
    final jpeg = _jpeg(200, 60, 40);
    for (final t in times) {
      File('${frames.path}/${name(t)}').writeAsBytesSync(jpeg);
    }
    await tester.runAsync(() => PhotoTracker.run(dir, const SessionConfig()));
    return dir;
  }

  Future<void> settle(WidgetTester tester, [int rounds = 30]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done, String what, {int rounds = 300}) async {
    for (var i = 0; i < rounds && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: 'never happened: $what; plugin calls: $calls; keepalive: $keepCalls');
  }

  void toBackground(WidgetTester tester) {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void toForeground(WidgetTester tester) {
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  /// The identify_start record of the run (in the embeddings log of the session).
  Map<String, dynamic> identifyStart(Directory dir) {
    final f = Directory('${dir.path}/identification')
        .listSync()
        .whereType<File>()
        .firstWhere((f) => f.path.split('/').last.startsWith('embeddings_') && f.path.endsWith('.jsonl'));
    return f
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .firstWhere((r) => r['type'] == 'identify_start');
  }

  const reminder =
      'reminder Animals found | Open FaunaPulse to identify them. The phone has too little free memory to do it '
      'in the background. If it does not start, use "Identify organisms" in the session\'s ⋮ menu on the '
      'Sessions screen.';

  testWidgets('in the background, too little free memory: no load, the service goes, a notification; '
      'the app in front: it starts by itself and the notification goes', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = await photoSession(tester);
    toForeground(tester);
    final find0 = AnalysisKeepAlive.acquire(title: kFindPhotosKeepAliveTitle); // tap on Start
    await pumpUntil(tester, () => keepCalls.isNotEmpty, 'the Find hold is sent');
    toBackground(tester); // Home during the Find job
    final run = IdentificationRun.autoStart(dir); // the Find job ends: the hand-over
    find0.release();
    await pumpUntil(tester, () => keepCalls.contains(reminder), 'the notification is asked for');
    await settle(tester);
    expect(calls, contains('embedderMemory'));
    expect(calls, isNot(contains('embedderLoad')), reason: 'the model must not load in the background');
    expect(run.finished, isFalse, reason: 'the run waits for the app');
    // The service is given up while the run waits (the stop and the notification go out on
    // their own ways, in either order).
    expect(keepCalls.take(2), ['start $kFindPhotosKeepAliveTitle', 'start $kIdentifyKeepAliveTitle']);
    expect(keepCalls.skip(2), unorderedEquals(['stop', reminder]));
    expect(AnalysisKeepAlive.activeHolds, 0);
    expect(IdentificationRun.of(dir), same(run), reason: 'a page opened now shows the waiting run');

    toForeground(tester); // the tap on the notification
    await pumpUntil(tester, () => run.finished, 'the run starts and ends once the app is in front');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
    expect(run.result?.embedded, greaterThan(0));
    expect(keepCalls.sublist(4), ['cancelIdentifyReminder', 'start $kIdentifyKeepAliveTitle', 'stop']);
    final check = identifyStart(dir)['memory_check'] as Map<String, dynamic>;
    expect(check['decision'], 'wait_for_app');
    expect(check['need_mb'], 1248); // 2.15 x 0.61 GB
    expect(check['free_mb'], 1058); // MemAvailable, the smaller of the two
    expect(check['on_gpu'], false);
    expect(check, contains('waited_s'));
  });

  testWidgets('in the background, enough free memory: it loads at once, no notification', (tester) async {
    final dir = await photoSession(tester);
    memory = _roomy();
    toBackground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
    expect(calls.indexOf('embedderMemory'), lessThan(calls.indexOf('embedderLoad')));
    expect(keepCalls.where((c) => c.startsWith('reminder') || c == 'cancelIdentifyReminder'), isEmpty);
    expect(keepCalls, ['start $kIdentifyKeepAliveTitle', 'stop']);
    expect((identifyStart(dir)['memory_check'] as Map)['decision'], 'load');
    toForeground(tester);
  });

  testWidgets('the app in front: no memory check, it loads at once', (tester) async {
    final dir = await photoSession(tester);
    toForeground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(calls, isNot(contains('embedderMemory')));
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
    expect(keepCalls, ['start $kIdentifyKeepAliveTitle', 'stop']);
    expect(identifyStart(dir), isNot(contains('memory_check')));
  });

  testWidgets('the notification cannot be shown (no permission): no crash, it still starts once in front',
      (tester) async {
    final dir = await photoSession(tester);
    reminderFails = true;
    toBackground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => keepCalls.contains(reminder), 'the notification is asked for');
    await settle(tester);
    expect(calls, isNot(contains('embedderLoad')));
    toForeground(tester);
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(run.failure, isNull);
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
  });

  testWidgets('the memory cannot be read: it goes on as before', (tester) async {
    final dir = await photoSession(tester);
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'embedderMemory':
          throw PlatformException(code: 'embedder_memory_error', message: 'x');
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
      }
      return null;
    });
    toBackground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
    toForeground(tester);
  });

  testWidgets('stopped while waiting: nothing loads, the notification goes', (tester) async {
    final dir = await photoSession(tester);
    toBackground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => keepCalls.contains(reminder), 'the notification is asked for');
    run.cancel();
    await pumpUntil(tester, () => run.finished, 'the run ends');
    await settle(tester, 10);
    expect(calls, isNot(contains('embedderLoad')));
    expect(keepCalls, contains('cancelIdentifyReminder'));
    expect(IdentificationRun.of(dir), isNull);
    expect(AnalysisKeepAlive.activeHolds, 0);
    toForeground(tester);
  });

  testWidgets('"Find animals in photos" in the background: waits; in front the Identify page shows the run '
      'and opens the results', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = await photoSession(tester);
    toForeground(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          initialSessionPath: dir.path,
          sessionsDir: dir.parent,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    final button = find.text('Identify the animals found');
    await pumpUntil(tester, () => find.textContaining('Salvia').evaluate().isNotEmpty, 'the session');
    await settle(tester, 10);
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    toBackground(tester);
    await tester.pump();
    await tester.tap(button);
    await pumpUntil(tester, () => keepCalls.contains(reminder), 'the notification is asked for');
    await settle(tester);
    expect(calls, isNot(contains('embedderLoad')));
    expect(find.byType(IdentificationScreen), findsNothing, reason: 'no frame in the background');

    toForeground(tester);
    await pumpUntil(tester, () => find.byType(IdentificationResultsScreen).evaluate().isNotEmpty, 'the results open');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1), reason: 'one run only: $calls');
    expect(keepCalls, contains('cancelIdentifyReminder'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('"Find animals in videos" in the background: waits; in front the Identify page shows the run '
      'and opens the results', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    VideoPlayerPlatform.instance = FakeVideoPlayer();
    await photoSession(tester); // for the models only
    // One clip analyzed with the screen's settings and its track IDs found, two kept frames of
    // track ID 1 saved (as r319_l4_identify_background_test).
    final dir = Directory('${tmp.path}/sessions/Echium');
    Directory('${dir.path}/videos').createSync(recursive: true);
    File('${dir.path}/videos/a.mp4').writeAsStringSync('video');
    File('${dir.path}/session.jsonl').writeAsStringSync([
      '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}',
      '{"type":"video_clip","time_ms":1000,"file":"videos/a.mp4","duration_ms":30000,"width":640,"height":480}',
      '{"type":"end_of_session","time_ms":31000,"ended_normally":true}',
    ].join('\n'));
    final settings = const VideoRunConfig(
      modelPath: 'test_model',
      modelName: 'test_model.tflite',
      confidence: 0.25,
      iou: 0.7,
      useGpu: true,
      roi: [0.5, 0.5, 0.75],
    ).identity;
    File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      [jsonEncode({'type': 'video_run_start', 'settings': settings}), '{"type":"video_clip_done","clip":"a.mp4"}'].join('\n'),
    );
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    final jpeg = _jpeg(40, 160, 60);
    final kept = ['vid_a_000001000.jpg', 'vid_a_000002000.jpg'];
    for (final k in kept) {
      File('${frames.path}/$k').writeAsBytesSync(jpeg);
    }
    final lines = postTracks(['a.mp4'], trackIds: 1).split('\n');
    File('${dir.path}/post_tracks.jsonl').writeAsStringSync([
      lines.first,
      for (final (i, k) in kept.indexed)
        jsonEncode({
          'type': 'detections',
          'time_ms': 2000 + i * 1000,
          'tracks': [
            {
              'track_id': 1,
              'confidence': 0.9,
              'box_in_roi': {'left': 0.2, 'top': 0.2, 'right': 0.7, 'bottom': 0.7},
              'jpeg': k,
            },
          ],
        }),
      lines.last,
    ].join('\n'));
    toForeground(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: dir.path,
          sessionsDir: dir.parent,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    final button = find.text('Identify the animals found');
    await pumpUntil(tester, () => find.text('Area to analyze').evaluate().isNotEmpty, 'the screen');
    await settle(tester, 10);
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    toBackground(tester);
    await tester.pump();
    await tester.tap(button);
    await pumpUntil(tester, () => keepCalls.contains(reminder), 'the notification is asked for');
    await settle(tester);
    expect(calls, isNot(contains('embedderLoad')));
    expect(keepCalls, contains('stop'), reason: 'the service is given up');

    toForeground(tester);
    await pumpUntil(tester, () => find.byType(IdentificationResultsScreen).evaluate().isNotEmpty, 'the results open');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1), reason: 'one run only: $calls');
    expect(keepCalls, contains('cancelIdentifyReminder'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
