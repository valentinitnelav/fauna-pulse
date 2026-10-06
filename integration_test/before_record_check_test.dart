// FaunaPulse (round 298): on-device check of the "Before you record" sheet. With the sheet on,
// REC opens it (SHOT before_record), "Change" next to Field notes opens the Field notes page
// and the sheet comes back, Start starts a 6 s time-lapse, and the start record carries
// `phone_state` with FaunaLapse's keys. Screenshots: "SHOT <name>" lines (hold 4 s), e.g.
//   adb -s <serial> exec-out screencap -p > <name>.png
// The phone's saved settings and its sheet choice are restored afterwards; the session stays
// in before_record_check*.
// Run:  flutter test integration_test/before_record_check_test.dart -d <serial> --no-uninstall

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/before_record_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Before you record sheet', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    final prefs = await SharedPreferences.getInstance();
    final sheetBefore = prefs.getBool(kBeforeRecordSheetKey);
    await prefs.setBool(kBeforeRecordSheetKey, true);
    addTearDown(() async {
      if (sheetBefore == null) {
        await prefs.remove(kBeforeRecordSheetKey);
      } else {
        await prefs.setBool(kBeforeRecordSheetKey, sheetBefore);
      }
    });
    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions')..createSync(recursive: true);
    final problems = <String>[];
    void problem(String what) {
      problems.add(what);
      _log('PROBLEM $what');
    }

    Future<void> pumpFor(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 4));
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: CameraSessionScreen(
          initialConfig: saved.copyWith(
            scheduleEnabled: false,
            sessionMinutes: 60,
            folderName: 'before_record_check',
            captureTrigger: CaptureTrigger.timelapse,
            timeLapseSaveAs: TimeLapseSaveAs.photos,
            captureMode: RoiCaptureMode.fast,
            stepSeconds: 1,
            durationSeconds: 10,
            timeLapseGapSeconds: 1800,
          ),
        ),
      ),
    );
    await pumpFor(const Duration(seconds: 6));
    // A setup-tips window may open with the camera screen; close it.
    final close = find.descendant(of: find.byType(AlertDialog), matching: find.text('Close'));
    if (close.evaluate().isNotEmpty) await tester.tap(close.first);
    await pumpFor(const Duration(seconds: 1));
    final recButton = find.byWidgetPredicate(
      (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 72, height: 72),
    );
    await tester.tap(recButton.first);
    await pumpFor(const Duration(seconds: 2));
    if (find.text('Before you record').evaluate().isEmpty) problem('REC did not open the sheet');
    if (find.textContaining('Photos: one every 1 s for 10 s, then 30 min off.').evaluate().isEmpty) {
      problem('the plan sentence is missing');
    }
    await shot('before_record');
    await tester.tap(find.text('Change').first);
    await pumpFor(const Duration(seconds: 2));
    if (find.text('Field notes').evaluate().isEmpty) problem('Change did not open the Field notes page');
    await tester.pageBack();
    await pumpFor(const Duration(seconds: 2));
    if (find.text('Before you record').evaluate().isEmpty) problem('the sheet did not come back');
    final before = sessions.listSync().whereType<Directory>().map((d) => d.path).toSet();
    await tester.tap(find.text('Start'));
    await pumpFor(const Duration(seconds: 3));
    final added = sessions.listSync().whereType<Directory>().map((d) => d.path).toSet().difference(before);
    if (added.length != 1) {
      problem('Start did not start a recording');
    } else {
      await pumpFor(const Duration(seconds: 5));
      await tester.tap(recButton.first, warnIfMissed: false);
      await pumpFor(const Duration(seconds: 4));
      final start = jsonDecode(File('${added.single}/session.jsonl').readAsLinesSync().first) as Map<String, dynamic>;
      final phone = start['phone_state'];
      _log('PHONE_STATE ${jsonEncode(phone)}');
      if (phone is! Map || phone.length != 8 || phone['airplane_mode'] == null) problem('phone_state missing or incomplete');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    _log(problems.isEmpty ? 'CHECK PASSED' : 'CHECK FAILED: ${problems.length} problems');
    expect(problems, isEmpty);
  });
}
