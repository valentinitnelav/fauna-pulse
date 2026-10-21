// Round 319 (stress test 2026-10-20, items 2 and 5): Identify was killed 22 s after Home, and
// "Find animals in videos" / "in photos" ran unprotected too: no screen asked Android to keep the
// app alive. Now each run holds the analysis foreground service (AnalysisKeepAlive over the
// faunapulse/keepalive channel) from the tap on Start to the end of the run; a Find run hands over
// to "Also identify them" without a stop in between.
//
// The channel is a stand-in that records every call; AnalysisKeepAlive.debugIsAndroid makes the
// laptop act as a phone.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/identification_run.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/logging/app_error_hooks.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/screens/analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/services/analysis_keepalive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

const _identifyLog = '''
{"type":"start_of_session","time_ms":1000,"config":{},"device":{"model":"TestPhone"}}
{"type":"detections","time_ms":2000,"tracks":[{"track_id":1,"confidence":0.9,"box_in_roi":{"left":0.1,"top":0.1,"right":0.9,"bottom":0.9},"jpeg":"roi_t_2026-07-14_120000_000.jpg"}]}
{"type":"detections","time_ms":3000,"tracks":[{"track_id":2,"confidence":0.7,"box_in_roi":{"left":0.1,"top":0.1,"right":0.9,"bottom":0.9},"jpeg":"roi_t_2026-07-14_120001_000.jpg"}]}
{"type":"end_of_session","time_ms":4000,"ended_normally":true}
''';

Uint8List _jpeg(int r, int g, int b) {
  final im = img.Image(width: 320, height: 320, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const keepAliveChannel = MethodChannel('faunapulse/keepalive');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> keepCalls;
  late Object? Function(MethodCall) answer;
  late Directory tmp;

  /// The calls as short strings: "start <title>" or "stop".
  List<String> calls() => [
    for (final c in keepCalls)
      c.method == 'startAnalysis' ? 'start ${(c.arguments as Map)['title']}' : c.method == 'stopAnalysis' ? 'stop' : c.method,
  ];

  setUp(() {
    AnalysisKeepAlive.resetForTest();
    AnalysisKeepAlive.debugIsAndroid = true;
    resetAppErrorRateLimitsForTest();
    keepCalls = [];
    answer = (_) => true;
    messenger.setMockMethodCallHandler(keepAliveChannel, (call) async {
      keepCalls.add(call);
      return answer(call);
    });
    tmp = Directory.systemTemp.createTempSync('r319_keepalive');
  });
  tearDown(() {
    AnalysisKeepAlive.debugIsAndroid = null;
    for (final c in [keepAliveChannel, pathChannel, yoloChannel]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('AnalysisKeepAlive: counted holds', () {
    test('one hold starts the service with its words and its release stops it', () async {
      final h = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      expect(calls(), ['start $kIdentifyKeepAliveTitle']);
      expect((keepCalls.single.arguments as Map)['text'], kAnalysisKeepAliveText);
      h.release();
      await AnalysisKeepAlive.settled;
      expect(calls(), ['start $kIdentifyKeepAliveTitle', 'stop']);
      expect(AnalysisKeepAlive.activeHolds, 0);
    });

    test('two jobs keep it until both end; the notification shows the newest job', () async {
      final videos = AnalysisKeepAlive.acquire(title: kFindVideosKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      final identify = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      identify.release();
      await AnalysisKeepAlive.settled;
      expect(calls(), [
        'start $kFindVideosKeepAliveTitle',
        'start $kIdentifyKeepAliveTitle',
        'start $kFindVideosKeepAliveTitle', // back to the job still running, no stop
      ]);
      videos.release();
      await AnalysisKeepAlive.settled;
      expect(calls().last, 'stop');
      expect(calls().where((c) => c == 'stop'), hasLength(1));
    });

    test('a hand-over (new hold, then the old one released) never stops the service', () async {
      final find = AnalysisKeepAlive.acquire(title: kFindPhotosKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      final next = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      find.release();
      await AnalysisKeepAlive.settled;
      expect(calls(), ['start $kFindPhotosKeepAliveTitle', 'start $kIdentifyKeepAliveTitle']);
      next.release();
      await AnalysisKeepAlive.settled;
      expect(calls(), ['start $kFindPhotosKeepAliveTitle', 'start $kIdentifyKeepAliveTitle', 'stop']);
    });

    test('releasing twice stops once and does not count below zero', () async {
      final a = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      a.release();
      a.release();
      await AnalysisKeepAlive.settled;
      final b = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      expect(AnalysisKeepAlive.activeHolds, 1);
      expect(calls(), ['start $kIdentifyKeepAliveTitle', 'stop', 'start $kIdentifyKeepAliveTitle']);
      b.release();
      await AnalysisKeepAlive.settled;
    });

    test('a hold released before its call went out costs no start', () async {
      AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle).release();
      await AnalysisKeepAlive.settled;
      expect(calls(), isEmpty);
    });

    test('a failing channel never throws, and the release still stops', () async {
      answer = (call) => call.method == 'startAnalysis' ? throw PlatformException(code: 'X', message: 'broken') : true;
      final h = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      h.release();
      await AnalysisKeepAlive.settled;
      expect(calls(), ['start $kIdentifyKeepAliveTitle', 'stop']);
    });

    test('a refused start (app in the background) never throws', () async {
      answer = (call) => call.method == 'startAnalysis' ? false : true;
      final h = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      h.release();
      await AnalysisKeepAlive.settled;
      expect(calls(), ['start $kIdentifyKeepAliveTitle', 'stop']);
    });

    test('no native side (MissingPluginException) never throws', () async {
      messenger.setMockMethodCallHandler(keepAliveChannel, null);
      final h = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      h.release();
      await AnalysisKeepAlive.settled;
      expect(AnalysisKeepAlive.activeHolds, 0);
    });

    test('off Android nothing is called', () async {
      AnalysisKeepAlive.debugIsAndroid = false;
      final h = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
      await AnalysisKeepAlive.settled;
      h.release();
      await AnalysisKeepAlive.settled;
      expect(calls(), isEmpty);
    });
  });

  group('the run code holds the service', () {
    Future<void> settle(WidgetTester tester, [int n = 50]) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> pumpUntil(WidgetTester tester, bool Function() done, String what) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue, reason: 'never happened: $what; keepalive calls: ${calls()}');
    }

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    group('Identify', () {
      final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
      late List<String> yolo;

      setUp(() {
        messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
        wakelockPlusPlatformInstance = FakeWakelock();
        PackageInfo.setMockInitialValues(
          appName: 'FaunaPulse',
          packageName: 'test',
          version: '0.0.0',
          buildNumber: '1',
          buildSignature: '',
        );
        yolo = [];
        messenger.setMockMethodCallHandler(yoloChannel, (call) async {
          yolo.add(call.method);
          switch (call.method) {
            case 'embedderLoad':
              return {'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': pack.dim, 'loadMs': 1.0};
            case 'embedderRun':
              final n = ((call.arguments as Map)['images'] as List).length;
              // The service runs while the model embeds.
              yolo.add('keepalive holds: ${AnalysisKeepAlive.activeHolds}');
              return {
                'dim': pack.dim,
                'count': n,
                'vectors': Float32List.fromList([for (var i = 0; i < n; i++) ...pack.matrix.sublist(0, pack.dim)]),
                'ms': 1.0,
              };
          }
          return null;
        });
        SharedPreferences.setMockInitialValues({
          'identify_model': 'test-model.tflite',
          'identify_pack': 'tiny_pack.fpack',
        });
      });

      Directory makeSession({bool photos = true}) {
        final models = Directory('${tmp.path}/identification/models')..createSync(recursive: true);
        final packs = Directory('${tmp.path}/identification/packs')..createSync(recursive: true);
        File('${models.path}/test-model.tflite').writeAsBytesSync([0]);
        File('test/fauna_pulse/fixtures/tiny_pack.fpack').copySync('${packs.path}/tiny_pack.fpack');
        final dir = Directory('${tmp.path}/sessions/meadow')..createSync(recursive: true);
        File('${dir.path}/session.jsonl').writeAsStringSync(_identifyLog);
        final frames = Directory('${dir.path}/roi_frames')..createSync();
        if (photos) {
          File('${frames.path}/roi_t_2026-07-14_120000_000.jpg').writeAsBytesSync(_jpeg(220, 30, 30));
          File('${frames.path}/roi_t_2026-07-14_120001_000.jpg').writeAsBytesSync(_jpeg(30, 30, 220));
        }
        return dir;
      }

      testWidgets('a run starts the service with the Identify words and stops it at its end', (tester) async {
        phone(tester);
        final session = makeSession();
        await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
        await pumpUntil(tester, () => yolo.contains('embedderClose'), 'the run ends');
        await settle(tester, 10);
        expect(yolo, contains('keepalive holds: 1'), reason: 'no hold while the model embeds: $yolo');
        expect(calls(), ['start $kIdentifyKeepAliveTitle', 'stop']);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });

      testWidgets('a Find screen hands over to the identification run: no stop in between', (tester) async {
        phone(tester);
        final session = makeSession();
        final find = AnalysisKeepAlive.acquire(title: kFindVideosKeepAliveTitle);
        await settle(tester, 2); // the hold's call goes out (an await here would wait for a pump)
        // What the Find screens do (round 319, L4b): the run takes its hold, then the Find hold goes.
        IdentificationRun.autoStart(session);
        find.release();
        await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
        await pumpUntil(tester, () => yolo.contains('embedderClose'), 'the run ends');
        await settle(tester, 10);
        expect(AnalysisKeepAlive.activeHolds, 0);
        expect(calls(), ['start $kFindVideosKeepAliveTitle', 'start $kIdentifyKeepAliveTitle', 'stop']);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });

      testWidgets('the handed-over hold is released when there is nothing to identify', (tester) async {
        phone(tester);
        final session = makeSession(photos: false);
        IdentificationRun.autoStart(session);
        await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
        await settle(tester);
        expect(yolo, isNot(contains('embedderLoad')));
        expect(AnalysisKeepAlive.activeHolds, 0, reason: 'the service would run on with nothing to do');
        expect(calls().last, 'stop');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    });

    testWidgets('"Find animals in videos": Start holds the service until the run ends', (tester) async {
      phone(tester);
      VideoPlayerPlatform.instance = FakeVideoPlayer();
      wakelockPlusPlatformInstance = FakeWakelock();
      SharedPreferences.setMockInitialValues({'find_also_identify': false});
      // No real model here: the run stops with an error.
      messenger.setMockMethodCallHandler(yoloChannel, (call) async {
        throw PlatformException(code: 'TEST', message: 'no model in tests');
      });
      final dir = Directory('${tmp.path}/Echium');
      Directory('${dir.path}/videos').createSync(recursive: true);
      File('${dir.path}/videos/a.mp4').writeAsStringSync('video');
      File('${dir.path}/session.jsonl').writeAsStringSync(
        [
          '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}',
          '{"type":"video_clip","time_ms":1000,"file":"videos/a.mp4","duration_ms":30000,"width":640,"height":480}',
          '{"type":"end_of_session","time_ms":31000,"ended_normally":true}',
        ].join('\n'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoAnalysisScreen(
            initialSessionPath: dir.path,
            sessionsDir: tmp,
            models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
          ),
        ),
      );
      final start = find.text('Analyze 1 clip');
      await pumpUntil(tester, () => find.text('Area to analyze').evaluate().isNotEmpty, 'the screen');
      await tester.scrollUntilVisible(start, 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(calls(), isEmpty);
      await tester.tap(start);
      await settle(tester);
      expect(calls(), ['start $kFindVideosKeepAliveTitle', 'stop']);
      expect(AnalysisKeepAlive.activeHolds, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('"Find animals in photos": Start holds the service until the run ends', (tester) async {
      phone(tester);
      wakelockPlusPlatformInstance = FakeWakelock();
      SharedPreferences.setMockInitialValues({'analysis_model': 'test_model', 'find_also_identify': false});
      messenger.setMockMethodCallHandler(yoloChannel, (call) async {
        throw PlatformException(code: 'TEST', message: 'no model in tests');
      });
      final s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;
      String rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': s0, ...m});
      final dir = Directory('${tmp.path}/Salvia')..createSync();
      Directory('${dir.path}/roi_frames').createSync();
      final names = [for (var i = 0; i < 5; i++) 'roi_t_2026-07-01_10000${i}_000.jpg'];
      File('${dir.path}/session.jsonl').writeAsStringSync([
        rec('start_of_session', {
          'file_token': 'tok',
          'config': {'captureTrigger': 'timelapse', 'stepSeconds': 1.0, 'durationSeconds': 5.0},
        }),
        for (final (i, n) in names.indexed) ...[
          rec('timelapse_capture', {'jpeg': n, 'captured_at_ms': s0 + i * 1000}),
          rec('capture', {'file': n, 'captured_at_ms': s0 + i * 1000, 'saved_px': 640}),
        ],
        rec('end_of_session', {'time_ms': s0 + 6000, 'ended_normally': true}),
      ].join('\n'));
      for (final n in names) {
        File('${dir.path}/roi_frames/$n').writeAsBytesSync(_jpeg(100, 120, 90));
      }
      await tester.pumpWidget(
        MaterialApp(
          home: AnalysisScreen(
            initialSessionPath: dir.path,
            sessionsDir: tmp,
            models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
          ),
        ),
      );
      final start = find.textContaining(RegExp(r'^Analyze \d+ photos'));
      await pumpUntil(tester, () => start.evaluate().isNotEmpty, 'the Analyze button');
      await tester.ensureVisible(start);
      await tester.pump();
      expect(calls(), isEmpty);
      await tester.tap(start);
      await settle(tester);
      expect(calls(), ['start $kFindPhotosKeepAliveTitle', 'stop']);
      expect(AnalysisKeepAlive.activeHolds, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
