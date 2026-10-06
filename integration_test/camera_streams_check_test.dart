// FaunaPulse (round 294): measures what the photo source changes at the camera. The camera screen
// opens with the phone's saved settings, once with photo source "fast" (no zero-shutter-lag
// buffer since round 294) and once with "auto" (buffer allowed), 45 s each, without recording.
// Each part prints "MEASURE_NOW <part>"; whoever runs the check then reads, for example,
//   adb -s <serial> shell dumpsys media.camera     (the configured streams: sizes and formats)
//   adb -s <serial> shell top -b -n 1              (camera provider, cameraserver, FaunaPulse CPU)
// and compares the two parts. The phone's saved settings are restored afterwards.
// Run:  flutter test integration_test/camera_streams_check_test.dart -d <serial> --no-uninstall

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('camera streams with and without the zero-shutter-lag buffer', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    final closeButton = find.descendant(of: find.byType(AlertDialog), matching: find.text('Close'));
    Future<void> pumpFor(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 500));
        if (closeButton.evaluate().isNotEmpty) await tester.tap(closeButton.first);
      }
    }

    for (final (part, mode) in [('fast', RoiCaptureMode.fast), ('auto', RoiCaptureMode.auto)]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: CameraSessionScreen(initialConfig: saved.copyWith(captureMode: mode, scheduleEnabled: false)),
        ),
      );
      await pumpFor(const Duration(seconds: 12));
      _log('MEASURE_NOW $part');
      await pumpFor(const Duration(seconds: 45));
      await tester.pumpWidget(const SizedBox());
      await pumpFor(const Duration(seconds: 3));
    }
    _log('MEASURE_DONE');
  });
}
