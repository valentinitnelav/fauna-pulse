// FaunaPulse (round 247): on-device check of "Test speed" on the Identify organisms screen:
// it counts the crops as it goes (10, "Crop i of 10, about N s left") and then reports the time
// per crop. Uses the session photo_visits_check_test.dart made (run that first) and the phone's
// own identification settings (model, GPU, threads); nothing is written to the session.
// Run:  flutter test integration_test/identify_speed_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Test speed shows its progress on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final dir = Directory('${(await getExternalStorageDirectory())!.path}/photo_visits_check/sessions/photo check');
    expect(dir.existsSync(), isTrue, reason: 'run photo_visits_check_test.dart first');

    Future<void> waitFor(Finder f, {int seconds = 60}) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (f.evaluate().isNotEmpty) return;
      }
      fail('not found: $f');
    }

    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: IdentificationScreen(sessionDir: dir)),
    );
    await waitFor(find.text('Test speed'));
    final list = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      skipOffstage: true,
    ).first;
    await tester.scrollUntilVisible(find.textContaining('times the model on 10'), 200, scrollable: list);
    await tester.pump(const Duration(milliseconds: 300));
    final started = DateTime.now();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Test speed'));
    await waitFor(find.textContaining('Testing speed: '));
    _log('PROGRESS ${(tester.widget<Text>(find.textContaining('Testing speed: ')).data)}');
    await waitFor(find.textContaining('Testing speed: Crop 2 of 10'), seconds: 300);
    await tester.scrollUntilVisible(find.textContaining('Testing speed: '), 100, scrollable: list);
    _log('SHOT identify_speed_progress');
    _log('PROGRESS ${(tester.widget<Text>(find.textContaining('Testing speed: ')).data)}');
    await tester.pump(const Duration(seconds: 3));
    await waitFor(find.textContaining('s per crop on the'), seconds: 600);
    final result = tester.widget<Text>(find.textContaining('s per crop on the')).data;
    _log('RESULT after ${DateTime.now().difference(started).inSeconds} s: $result');
    expect(result, contains('10 crops after a warm-up'));
    expect(find.textContaining('Testing speed: '), findsNothing);
    await tester.scrollUntilVisible(find.textContaining('s per crop on the'), 100, scrollable: list);
    _log('SHOT identify_speed_result');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 15)));
}
