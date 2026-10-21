// Stress test (2026-10-20, races): "Find animals in videos". Start marks the
// screen busy only after the chosen model has been saved to the phone's
// settings (an await). A second tap on Start in that moment starts a second
// run on the same session (two detectors writing one video_detections.jsonl).
//
// Start saves 14 settings one after another; each write here takes 3 ms (on
// a phone each is a round trip to Android's settings store), so the screen
// stays tappable for about 40 ms. The YOLO plugin's channel is a stand-in
// that records every call.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The settings store with a delay (only for this test).
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

/// Keeps values in memory; every write takes [delay].
class _SlowStore extends SharedPreferencesStorePlatform {
  final _data = <String, Object>{};
  final Duration delay;
  _SlowStore(this.delay);

  @override
  Future<bool> clear() async => (_data..clear()).isEmpty;

  @override
  Future<Map<String, Object>> getAll() async => Map.of(_data);

  @override
  Future<bool> remove(String key) async {
    await Future<void>.delayed(delay);
    _data.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await Future<void>.delayed(delay);
    _data[key] = value;
    return true;
  }
}

Future<void> _pumpUntil(WidgetTester tester, Finder ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
    if (ready.evaluate().isNotEmpty) break;
  }
  expect(ready, findsWidgets, reason: 'content never appeared: $ready');
}

/// Leaves the screen and lets the slow settings writes finish.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  late List<String> yoloCalls;

  setUp(() {
    VideoPlayerPlatform.instance = FakeVideoPlayer();
    wakelockPlusPlatformInstance = FakeWakelock();
    yoloCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(yoloChannel, (call) async {
      yoloCalls.add(call.method);
      // No real model here: the run stops with an error after this.
      throw PlatformException(code: 'TEST', message: 'no model in tests');
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(yoloChannel, null);
  });

  Directory session(Directory tmp) {
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
    return dir;
  }

  Future<Finder> open(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = _SlowStore(const Duration(milliseconds: 3));
    store._data['flutter.find_also_identify'] = false;
    SharedPreferencesStorePlatform.instance = store;
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tmp = Directory.systemTemp.createTempSync('video_double_tap');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final dir = session(tmp);
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
    await _pumpUntil(tester, find.text('Area to analyze'));
    await tester.scrollUntilVisible(start, 200, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    return start;
  }

  /// Lets a started run reach the plugin (and fail there, no model).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  group('stress: video analysis Start double tap', () {
    testWidgets('one tap on Start starts one run (reference)', (tester) async {
      final start = await open(tester);
      final before = yoloCalls.length;
      await tester.tap(start);
      await settle(tester);
      final run = yoloCalls.sublist(before);
      // ignore: avoid_print
      print('plugin calls of one run: $run');
      expect(run, isNotEmpty, reason: 'the run reached the plugin');
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets(
      'two quick taps on Start start only one run',
      (tester) async {
        final start = await open(tester);
        // The calls of one run, measured first in the same way.
        final before = yoloCalls.length;
        await tester.tap(start);
        await tester.pump(const Duration(milliseconds: 10));
        await tester.tap(start, warnIfMissed: false);
        await settle(tester);
        final calls = yoloCalls.sublist(before);
        // ignore: avoid_print
        print('plugin calls after a double tap: $calls');
        final first = calls.isEmpty ? '' : calls.first;
        expect(calls.where((m) => m == first).length, 1, reason: 'each run starts with "$first"; calls: $calls');
        await _close(tester);
      },
    );

    testWidgets(
      'leaving the screen while Start saves the settings starts nothing and throws nothing',
      (tester) async {
        final start = await open(tester);
        final before = yoloCalls.length;
        await tester.tap(start);
        await tester.pump(const Duration(milliseconds: 10));
        // The phone's Back button: the screen goes away.
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        expect(yoloCalls.sublist(before), isEmpty, reason: 'no run without its screen');
        expect(tester.takeException(), isNull);
      },
    );
  });
}
