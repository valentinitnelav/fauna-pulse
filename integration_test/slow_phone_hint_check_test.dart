// FaunaPulse (round 278): on-device check of the hint for phones too slow for
// live detection (fewer than 5 pictures per second, perf/slow_phone_hint.dart),
// through the real camera screen in live detection. Preview only: nothing is
// recorded.
//
//  A. flat-bug s at 1024 px on the main processor (slow): the hint appears.
//  B. flat-bug n at 640 px on the graphics chip (fast): no hint in 45 s.
//  C. The slow model again, the screen closed 4 times at slightly different
//     moments: closing while a picture is still being checked (1.5 s each)
//     crashed the app before round 278 (the model was freed under it).
//
// Both files must be on the phone (Download & import models). The phone's
// saved settings are restored afterwards; "Don't show again" must not be set.
// Run:  flutter test integration_test/slow_phone_hint_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in models_screen_check_test.dart.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/perf/slow_phone_hint.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the slow-phone hint on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kHideSlowPhoneHintPrefKey), isNot(true), reason: '"Don\'t show again" was chosen');
    final dir = await ModelCatalog.modelsDir();

    /// Opens the camera with [model] for up to [wait]; true when the hint
    /// appeared.
    Future<bool> run(String label, String model, {required bool gpu, required Duration wait}) async {
      final file = File('${dir.path}/$model');
      expect(file.existsSync(), isTrue, reason: '$model is not on the phone');
      final config = saved.copyWith(modelPath: file.path, useGpu: gpu, captureTrigger: CaptureTrigger.detector);
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: CameraSessionScreen(initialConfig: config)),
      );
      final watch = Stopwatch()..start();
      var seen = false;
      while (watch.elapsed < wait && !seen) {
        await tester.pump(const Duration(milliseconds: 500));
        // The setup tips and other questions at the start: close them as is.
        for (final b in ['Got it', 'Not now']) {
          if (find.text(b).evaluate().isNotEmpty) await tester.tap(find.text(b).first);
        }
        seen = find.byType(SlowPhoneBanner).evaluate().isNotEmpty;
      }
      _log('$label: ${seen ? 'HINT after ${watch.elapsed.inSeconds} s' : 'no hint in ${watch.elapsed.inSeconds} s'}');
      if (seen) {
        await tester.pump(const Duration(milliseconds: 500));
        _log('SHOT slow_hint');
        await tester.pump(const Duration(seconds: 4));
        await tester.tap(find.text('OK'));
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(SlowPhoneBanner), findsNothing, reason: 'OK closes it');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      return seen;
    }

    expect(
      await run('A flat-bug s 1024 on the main processor', 'flatbug-s_1024_fp16.tflite', gpu: false, wait: const Duration(seconds: 120)),
      isTrue,
    );
    expect(
      await run('B flat-bug n 640 on the graphics chip', 'flatbug-n_640_fp16.tflite', gpu: true, wait: const Duration(seconds: 45)),
      isFalse,
    );
    for (var i = 0; i < 4; i++) {
      final config = saved.copyWith(
        modelPath: '${dir.path}/flatbug-s_1024_fp16.tflite',
        useGpu: false,
        captureTrigger: CaptureTrigger.detector,
      );
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: CameraSessionScreen(initialConfig: config)),
      );
      final watch = Stopwatch()..start();
      while (watch.elapsed < Duration(milliseconds: 20000 + i * 400)) {
        await tester.pump(const Duration(milliseconds: 100));
        for (final b in ['Got it', 'Not now', 'OK']) {
          if (find.text(b).evaluate().isNotEmpty) await tester.tap(find.text(b).first);
        }
      }
      _log('C close ${i + 1} after ${watch.elapsed.inMilliseconds} ms');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }
    _log('C the app is still running');
    expect(prefs.getBool(kHideSlowPhoneHintPrefKey), isNot(true), reason: 'OK does not hide it for good');
  });
}
