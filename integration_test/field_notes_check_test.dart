// FaunaPulse (round 297): on-device check of the Field notes page. Opens the camera screen,
// taps the field-notes button (pin with a pencil), types a site and a plant, records 6 s of
// time-lapse, and checks the session's `field` block (FaunaLapse keys, phone maker filled).
// Screenshots: the check prints "SHOT <name>" and holds the picture 4 s, e.g.
//   adb -s <serial> exec-out screencap -p > <name>.png
// The phone's saved settings and field notes are restored afterwards; the session stays in
// field_notes_check*.
// Run:  flutter test integration_test/field_notes_check_test.dart -d <serial> --no-uninstall

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/field_notes.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:fauna_pulse/fauna_pulse/session/site_photos.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'skip_before_record_sheet.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('field notes page and the field block', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    await skipBeforeRecordSheet(); // round 298
    final prefs = await SharedPreferences.getInstance();
    final notesBefore = prefs.getString(FieldNotes.prefsKey);
    addTearDown(() async {
      if (notesBefore == null) {
        await prefs.remove(FieldNotes.prefsKey);
      } else {
        await prefs.setString(FieldNotes.prefsKey, notesBefore);
      }
    });
    // Round 301: start with own fields of several types (restored afterwards).
    await prefs.setString(
      FieldNotes.prefsKey,
      '{"custom_fields":[{"name":"Observer","type":"text","value":"Check"},'
      '{"name":"Rain","type":"yes_no","value":"no"},'
      '{"name":"Flower stage","type":"choice","value":"Open","choices":["Bud","Open","Wilting"]},'
      '{"name":"Survey day","type":"date","value":"2026-10-06"},'
      '{"name":"Start time","type":"time","value":"06:30"}],'
      '"site_photos_about":"Check site photo","gps_goal_m":8}',
    );
    // Round 302: one site photo waiting for the next Start (removed again if the check fails).
    final waiting = await sitePhotosWaitingDir();
    waiting.createSync(recursive: true);
    final sitePhoto = File('${waiting.path}/${sitePhotoStem(DateTime.now())}.jpg')
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 64)));
    addTearDown(() {
      if (sitePhoto.existsSync()) sitePhoto.deleteSync();
    });
    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions')..createSync(recursive: true);
    final problems = <String>[];
    void problem(String what) {
      problems.add(what);
      _log('PROBLEM $what');
    }

    final closeButton = find.descendant(of: find.byType(AlertDialog), matching: find.text('Close'));
    Future<void> pumpFor(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 500));
        if (closeButton.evaluate().isNotEmpty) await tester.tap(closeButton.first);
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
            folderName: 'field_notes_check',
            captureTrigger: CaptureTrigger.timelapse,
            timeLapseSaveAs: TimeLapseSaveAs.photos,
            captureMode: RoiCaptureMode.fast,
            stepSeconds: 1,
            durationSeconds: 600,
            timeLapseGapSeconds: 0,
          ),
        ),
      ),
    );
    await pumpFor(const Duration(seconds: 6));
    await shot('camera_screen');
    await tester.tap(find.byIcon(Icons.edit_location_alt));
    await pumpFor(const Duration(seconds: 2));
    if (find.text('Field notes').evaluate().isEmpty) problem('the Field notes page did not open');
    await shot('field_notes_top');
    await tester.enterText(find.widgetWithText(TextField, 'Site'), 'Check meadow');
    await tester.enterText(find.widgetWithText(TextField, 'Plant'), 'Knautia arvensis');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFor(const Duration(seconds: 1));
    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await pumpFor(const Duration(seconds: 1));
    await shot('field_notes_bottom');
    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await pumpFor(const Duration(seconds: 1));
    await shot('field_notes_own');
    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await pumpFor(const Duration(seconds: 1));
    await shot('field_notes_site');
    await tester.pageBack();
    await pumpFor(const Duration(seconds: 2));

    final recButton = find.byWidgetPredicate(
      (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 72, height: 72),
    );
    final before = sessions.listSync().whereType<Directory>().map((d) => d.path).toSet();
    Directory? dir;
    for (var i = 0; i < 30 && dir == null; i++) {
      if (closeButton.evaluate().isNotEmpty) await tester.tap(closeButton.first);
      await tester.tap(recButton.first, warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      final added = sessions.listSync().whereType<Directory>().map((d) => d.path).toSet().difference(before);
      if (added.isNotEmpty) dir = Directory(added.single);
    }
    expect(dir, isNotNull, reason: 'recording did not start');
    await pumpFor(const Duration(seconds: 6));
    await tester.tap(recButton.first, warnIfMissed: false);
    await pumpFor(const Duration(seconds: 4));
    final start = jsonDecode(File('${dir!.path}/session.jsonl').readAsLinesSync().first) as Map<String, dynamic>;
    final field = start['field'];
    _log('FIELD ${jsonEncode(field)}');
    if (field is! Map) {
      problem('no field block in the start record');
    } else {
      if (field['site'] != 'Check meadow' || field['plant'] != 'Knautia arvensis') problem('typed values missing');
      if (field['phone_maker'] == null || field['phone_model'] == null) problem('phone maker or model missing');
      if (field.keys.length != 17) problem('${field.keys.length} keys, expected 17');
      final photos = field['site_photos'];
      _log('SITE ${jsonEncode(photos)} about ${field['site_photos_about']} goal ${(field['location'] as Map?)?['uncertainty_goal_m']}');
      if (photos is! List || photos.length != 1 || !File('${dir.path}/site_photos/${photos.single}').existsSync()) {
        problem('site photo not moved into the session');
      }
      if (field['site_photos_about'] != 'Check site photo') problem('site_photos_about missing');
      final after = await FieldNotes.load();
      if (after.values['site_photos_about'] != null) problem('the note about the site photos was not cleared');
      final custom = field['custom'];
      if (custom is! Map || custom['Rain'] != false || custom['Flower stage'] != 'Open' || custom['Start time'] != '06:30') {
        problem('own fields missing in custom: $custom');
      }
    }
    await shot('summary');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    _log(problems.isEmpty ? 'CHECK PASSED' : 'CHECK FAILED: ${problems.length} problems');
    expect(problems, isEmpty);
  });
}
