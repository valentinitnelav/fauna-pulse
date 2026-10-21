// Round 319 (stress test 2026-10-20, report item 5): with "Also identify them" on, a Find screen
// opened "Identify organisms" and that page started the run. A page is built only in a frame,
// and Flutter draws no frames while the app is in the background, so the identification waited
// until the app was shown again (phone: tracking ended in the background, no identification/
// folder until the app came back). Now the Find screen starts the run itself
// (IdentificationRun.autoStart) and the page only shows it.
//
// Background here: the app's lifecycle is set to paused, so the binding schedules no frame and
// tester.pump draws none (SchedulerBinding.framesEnabled is false), as on the phone.

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

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319_identify_bg');
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
    messenger.setMockMethodCallHandler(keepAliveChannel, (call) async {
      keepCalls.add(call.method == 'startAnalysis' ? 'start ${(call.arguments as Map)['title']}' : 'stop');
      return true;
    });
    calls = [];
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      calls.add(call.method);
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

  void models() {
    final m = Directory('${tmp.path}/identification/models')..createSync(recursive: true);
    final p = Directory('${tmp.path}/identification/packs')..createSync(recursive: true);
    File('${m.path}/test-model.tflite').writeAsBytesSync([0]);
    File('test/fauna_pulse/fixtures/tiny_pack.fpack').copySync('${p.path}/tiny_pack.fpack');
  }

  /// A time-lapse session (a photo every 0.2 s for 4 s), every photo analyzed; an insect rests
  /// in the photos from 1 s to 3 s. With [tracked] its track ID is found too.
  Future<Directory> photoSession(WidgetTester tester, {bool tracked = true, bool insect = true}) async {
    models();
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
            if (insect && t >= 1000 && t <= 3000)
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
    if (tracked) await tester.runAsync(() => PhotoTracker.run(dir, const SessionConfig()));
    return dir;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done, String what, {int rounds = 300}) async {
    for (var i = 0; i < rounds && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    if (!done()) {
      // ignore: avoid_print
      print([for (final e in find.byType(Text).evaluate()) (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()].join(' | '));
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

  testWidgets('"Find animals in photos": the identification starts and ends while the app is in the background',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = await photoSession(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          initialSessionPath: dir.path,
          sessionsDir: dir.parent,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    // Every photo is analyzed, so the one button only identifies (the same call as the end of a run).
    final button = find.text('Identify the animals found');
    await pumpUntil(tester, () => find.textContaining('Salvia').evaluate().isNotEmpty, 'the session');
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    toBackground(tester);
    await tester.pump(); // a frame asked for before Home is still drawn
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.tap(button);

    await pumpUntil(tester, () => calls.contains('embedderClose'), 'the identification runs in the background');
    expect(find.byType(IdentificationScreen), findsNothing, reason: 'no frame was drawn, so no page was built');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
    expect(calls, contains('embedderRun'));
    expect(Directory('${dir.path}/identification').listSync().whereType<File>().map((f) => f.path.split('/').last),
        contains(startsWith('summary_')));
    await pumpUntil(tester, () => keepCalls.isNotEmpty && keepCalls.last == 'stop', 'the service stops at the end');
    expect(keepCalls.where((c) => c == 'stop'), hasLength(1), reason: 'no stop between the jobs: $keepCalls');

    // Back on screen: the page shows the finished run and opens its results; nothing runs twice.
    toForeground(tester);
    await pumpUntil(tester, () => find.byType(IdentificationResultsScreen).evaluate().isNotEmpty, 'the results open');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1), reason: 'the page started a second run: $calls');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('"Find animals in videos": the identification starts and ends while the app is in the background',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    VideoPlayerPlatform.instance = FakeVideoPlayer();
    models();
    // One clip analyzed with the screen's settings and its track IDs found, with two kept frames
    // of track ID 1 saved (what identification names).
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
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    toBackground(tester);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.tap(button);

    await pumpUntil(tester, () => calls.contains('embedderClose'), 'the identification runs in the background');
    expect(find.byType(IdentificationScreen), findsNothing, reason: 'no frame was drawn, so no page was built');
    expect(calls.where((c) => c == 'embedderRun'), isNotEmpty);
    expect(Directory('${dir.path}/identification').listSync().whereType<File>().map((f) => f.path.split('/').last),
        contains(startsWith('summary_')));
    toForeground(tester);
    await pumpUntil(tester, () => find.byType(IdentificationResultsScreen).evaluate().isNotEmpty, 'the results open');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1), reason: 'the page started a second run: $calls');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  // Decisions D5 and D7 (round 319): the red line after some failed crops, and the short
  // progress line when the GPU is not used (its reason once, below).
  testWidgets('one failed crop: "1 of N"; GPU not used: short progress line, reason below', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = await photoSession(tester);
    var runs = 0;
    var go = false;
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'embedderLoad':
          return {
            'accelerator': 'CPU',
            'accelerationNote': 'on the GPU blocklist of this phone',
            'inputWidth': 32,
            'inputHeight': 32,
            'dim': pack.dim,
            'loadMs': 1.0,
          };
        case 'embedderRun':
          while (!go) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          if (runs++ == 0) throw PlatformException(code: 'X', message: 'broken');
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
    await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: dir, autoStart: true)));
    await pumpUntil(tester, () => calls.contains('embedderRun'), 'the run reaches the model');
    expect(find.text('Identifying crops on the CPU (GPU not used, see below)…'), findsOneWidget);
    expect(find.textContaining('GPU not used: The GPU failed with this model several times'), findsOneWidget);
    go = true;
    await pumpUntil(tester, () => calls.contains('embedderClose'), 'the run ends');
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final line = find.textContaining('crops could not be identified (the model stopped with an error).');
    await tester.scrollUntilVisible(line, 300, scrollable: find.byType(Scrollable).first);
    final text = (tester.widget<Text>(line)).data!;
    expect(text, matches(RegExp(r'^1 of \d+ crops could not be identified \(the model stopped with an error\)\. '
        r'It is missing from the results\. "Continue / re-run" tries it again\.$')));
    expect(find.byType(IdentificationResultsScreen), findsNothing, reason: 'a run with failed crops stays on the page');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  group('IdentificationRun without any screen', () {
    testWidgets('autoStart runs, holds the service and ends; a page opened later shows it', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = await photoSession(tester);
      final find0 = AnalysisKeepAlive.acquire(title: kFindPhotosKeepAliveTitle);
      await pumpUntil(tester, () => keepCalls.isNotEmpty, 'the Find hold is sent');
      final run = IdentificationRun.autoStart(dir);
      find0.release(); // the Find run's hold goes after the identification took its own
      expect(IdentificationRun.of(dir), same(run));
      await pumpUntil(tester, () => run.finished, 'the run ends');
      expect(run.result, isNotNull);
      expect(run.result!.embedded, greaterThan(0));
      expect(run.failure, isNull);
      expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
      expect(calls.last, 'embedderClose');
      await pumpUntil(tester, () => keepCalls.last == 'stop', 'the service stops');
      expect(keepCalls, ['start $kFindPhotosKeepAliveTitle', 'start $kIdentifyKeepAliveTitle', 'stop']);
      expect(AnalysisKeepAlive.activeHolds, 0);
      // Nobody saw it yet, so it waits for the page, which shows it and starts nothing.
      expect(IdentificationRun.of(dir), same(run));
      await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: dir, autoStart: true)));
      await pumpUntil(tester, () => find.byType(IdentificationResultsScreen).evaluate().isNotEmpty, 'the results open');
      expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
      expect(IdentificationRun.of(dir), isNull, reason: 'shown once');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('autoStart with nothing to identify loads no model and lets the service go', (tester) async {
      final dir = await photoSession(tester, insect: false);
      final run = IdentificationRun.autoStart(dir);
      await pumpUntil(tester, () => run.finished, 'the run ends');
      expect(run.declined, isTrue);
      expect(calls, isNot(contains('embedderLoad')));
      expect(IdentificationRun.of(dir), isNull);
      expect(AnalysisKeepAlive.activeHolds, 0);
      await pumpUntil(tester, () => keepCalls.isEmpty || keepCalls.last == 'stop', 'the service stops');
    });

    testWidgets('a page opened while the run goes on shows it; Back asks, and Stop and leave stops it', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = await photoSession(tester);
      // Each model call waits until the test lets it go.
      var go = false;
      messenger.setMockMethodCallHandler(yoloChannel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'embedderLoad':
            return {'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': pack.dim, 'loadMs': 1.0};
          case 'embedderRun':
            while (!go) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
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
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              IdentificationRun.autoStart(dir);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => IdentificationScreen(sessionDir: dir, autoStart: true)),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await pumpUntil(tester, () => calls.contains('embedderRun'), 'the run reaches the model');
      expect(find.textContaining('Identifying crops on the CPU'), findsOneWidget, reason: 'the page shows the run');
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Identification is still running'), findsOneWidget);
      await tester.tap(find.text('Stop and leave'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(IdentificationScreen), findsNothing);
      final runs = calls.where((c) => c == 'embedderRun').length;
      go = true;
      await pumpUntil(tester, () => calls.contains('embedderClose'), 'the run stops');
      expect(calls.where((c) => c == 'embedderRun').length, runs, reason: 'it went on after Stop and leave: $calls');
      expect(calls.where((c) => c == 'embedderLoad'), hasLength(1), reason: 'the page started its own run: $calls');
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
