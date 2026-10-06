// FaunaPulse (round 290): on-device check that time-lapse photos are never copies of an old
// frame when the camera stops without the app asking (power button, another app). Before this
// round each photo was cut from the last frame in memory, so a stopped camera gave many copies
// of one old frame.
//
// The check records time-lapse photos (one per second, no break), prints HOME_NOW after 8 s and
// keeps the recording running. Whoever runs it then sends the app to the background, which stops
// the camera the same way the power button does, and brings it back about 20 s later:
//   adb -s <serial> shell input keyevent KEYCODE_HOME
//   adb -s <serial> shell monkey -p com.faunapulse.app -c android.intent.category.LAUNCHER 1
// (Home instead of the power button: a phone with a PIN would stay locked.) Expected: one
// timelapse_skipped record (reason app_hidden), a gap of at least 15 s without photo times,
// photos again after the gap, no refused photo (roi_capture app_error) and no two photos with
// the same bytes. Problems print as PROBLEM lines.
// The phone's saved settings are restored afterwards; the session stays in camera_stop_check*.
// Run:  flutter test integration_test/camera_stop_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('time-lapse photos wait while the camera is stopped', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions');
    sessions.createSync(recursive: true);
    final problems = <String>[];
    void problem(String what) {
      problems.add(what);
      _log('PROBLEM $what');
    }

    Set<String> sessionDirs() => sessions.listSync().whereType<Directory>().map((d) => d.path).toSet();
    final recButton = find.byWidgetPredicate(
      (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 72, height: 72),
    );
    final closeButton = find.descendant(of: find.byType(AlertDialog), matching: find.text('Close'));
    Future<void> pumpFor(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 500));
        if (closeButton.evaluate().isNotEmpty) await tester.tap(closeButton.first);
      }
    }

    final config = saved.copyWith(
      scheduleEnabled: false,
      sessionMinutes: 60,
      folderName: 'camera_stop_check',
      captureTrigger: CaptureTrigger.timelapse,
      timeLapseSaveAs: TimeLapseSaveAs.photos,
      captureMode: RoiCaptureMode.fast,
      stepSeconds: 1,
      durationSeconds: 600,
      timeLapseGapSeconds: 0,
      timeLapseCameraSleep: false,
      timeLapseTorch: false,
    );
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: CameraSessionScreen(initialConfig: config)),
    );
    await pumpFor(const Duration(seconds: 3));

    final before = sessionDirs();
    Directory? dir;
    for (var i = 0; i < 30 && dir == null; i++) {
      if (closeButton.evaluate().isNotEmpty) await tester.tap(closeButton.first);
      await tester.tap(recButton.first, warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      final added = sessionDirs().difference(before);
      if (added.isNotEmpty) dir = Directory(added.single);
    }
    expect(dir, isNotNull, reason: 'recording did not start');
    _log('RECORDING ${dir!.path.split('/').last}');
    await pumpFor(const Duration(seconds: 8));
    _log('HOME_NOW');
    // In the background no frames are drawn, so this wait may also last until the app is back.
    await pumpFor(const Duration(seconds: 25));
    // Back in front: give the camera time to deliver again, then stop.
    await pumpFor(const Duration(seconds: 10));
    await tester.tap(recButton.first, warnIfMissed: false);
    final log = File('${dir.path}/session.jsonl');
    for (var i = 0; i < 40 && !log.readAsStringSync().contains('"end_of_session"'); i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await pumpFor(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));

    final recs = [
      for (final l in log.readAsLinesSync())
        if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
    ];
    if (!recs.any((r) => r['type'] == 'end_of_session' && r['ended_normally'] == true)) {
      problem('no normal end_of_session');
    }
    for (final e in recs.where((r) => r['type'] == 'app_error')) {
      _log('APP_ERROR ${e['source']}: ${e['message']}'); // the watchdog is expected here
      if (e['source'] == 'roi_capture') problem('a photo was refused: ${e['message']}');
    }
    final skipped = recs.where((r) => r['type'] == 'timelapse_skipped').toList();
    _log('SKIPPED ${[for (final s in skipped) '${s['reason']}/${s['silent_ms']}'].join(' ')}');
    if (skipped.length != 1 || skipped.single['reason'] != 'app_hidden') {
      problem('expected one timelapse_skipped record with reason app_hidden');
    }

    final shots = [for (final r in recs.where((r) => r['type'] == 'timelapse_capture')) r['captured_at_ms'] as int];
    var gapMs = 0;
    var gapEnd = 0;
    for (var i = 1; i < shots.length; i++) {
      if (shots[i] - shots[i - 1] > gapMs) {
        gapMs = shots[i] - shots[i - 1];
        gapEnd = i;
      }
    }
    _log('PHOTOS ${shots.length}; longest gap $gapMs ms; photos after it ${shots.length - gapEnd}');
    if (gapMs < 15000) problem('no gap of 15 s or more in the photo times (longest $gapMs ms)');
    if (shots.length - gapEnd < 3) problem('photos did not resume after the camera came back');

    final frames = Directory('${dir.path}/roi_frames');
    final files = frames.existsSync() ? frames.listSync().whereType<File>().toList() : <File>[];
    final byDigest = <String, List<String>>{};
    for (final f in files) {
      byDigest.putIfAbsent(md5.convert(f.readAsBytesSync()).toString(), () => []).add(f.path.split('/').last);
    }
    final copies = byDigest.values.where((names) => names.length > 1).toList();
    _log('FILES ${files.length}; identical groups ${copies.length}');
    if (copies.isNotEmpty) problem('identical photos: ${copies.take(3).toList()}');

    _log(problems.isEmpty ? 'CHECK PASSED' : 'CHECK FAILED: ${problems.length} problems');
    expect(problems, isEmpty);
  });
}
