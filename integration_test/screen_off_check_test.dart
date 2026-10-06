// FaunaPulse (round 292): on-device check that a recording keeps its camera while the app is
// hidden (screen off, power button, Home). Before round 292 the camera stopped with the screen;
// round 290 made time-lapse skip photos then, and round 292 keeps the camera running instead.
//
//  T. Time-lapse photos, one per second, no break: photos must keep coming while hidden (no gap
//     over 3 s, no timelapse_skipped, no two photos with the same bytes).
//  D. Live detection with the phone's saved detection model (skipped without one), motion
//     gate off: the camera must not go silent while hidden (no watchdog app_error).
//  P. Time-lapse with the camera off between bursts: the camera parks, and wakes for the
//     next burst while hidden; that burst's photos must all be taken.
//  S. A scheduled run whose 2-minute window opens while the app is hidden: the window must
//     record (the camera starts from the background) and end normally.
//  O. "Screen off by itself after" 1 min (round 293): no touch for 75 s, then the black
//     power-save screen must be up (about 60 s after the last touch) and the app must no
//     longer hold the screen on; one tap brings it back. Prints SCREEN_IDLE_START and
//     KEEP_CHECK, where the runner may read `adb shell dumpsys window windows` (no
//     KEEP_SCREEN_ON flag on the FaunaPulse window after the let-go).
//
// Each part prints "HOME_NOW <part> <seconds>". Whoever runs the check then sends the app to
// the background, which hides it the same way the power button does, and brings it back after
// that many seconds:
//   adb -s <serial> shell input keyevent KEYCODE_HOME
//   adb -s <serial> shell monkey -p com.faunapulse.app -c android.intent.category.LAUNCHER 1
// (Home instead of the power button: a phone with a PIN would stay locked.) While hidden,
// `adb logcat -s YOLOView` keeps showing FRAMEPERF lines. Problems print as PROBLEM lines.
// --dart-define=PARTS=TP runs only those parts. The phone's saved settings are restored afterwards;
// the sessions stay in screen_off_check*.
// Run:  flutter test integration_test/screen_off_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fauna_pulse/fauna_pulse/models/schedule_window.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'skip_before_record_sheet.dart';

const _parts = String.fromEnvironment('PARTS', defaultValue: 'TDPSO');

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a recording keeps its camera while the app is hidden', timeout: const Timeout(Duration(minutes: 20)), (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    await skipBeforeRecordSheet(); // round 298
    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions');
    sessions.createSync(recursive: true);
    final problems = <String>[];
    void problem(String label, String what) {
      problems.add('$label: $what');
      _log('PROBLEM $label: $what');
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

    /// Records with a Home press in the middle (see the header) and returns the session's
    /// records, or null when the recording did not start.
    Future<(Directory, List<Map<String, dynamic>>)?> record(
      String label,
      SessionConfig config, {
      int homeAfterS = 8,
      int hiddenS = 20,
    }) async {
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
      if (dir == null) {
        problem(label, 'recording did not start');
        return null;
      }
      _log('RECORDING $label ${dir.path.split('/').last}');
      await pumpFor(Duration(seconds: homeAfterS));
      _log('HOME_NOW $label $hiddenS');
      // While hidden no frames are drawn, so this wait may last until the app is back.
      await pumpFor(Duration(seconds: hiddenS + 5));
      await pumpFor(const Duration(seconds: 8));
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
        problem(label, 'no normal end_of_session');
      }
      for (final e in recs.where((r) => r['type'] == 'app_error')) {
        problem(label, 'app_error ${e['source']}: ${e['message']}');
      }
      return (dir, recs);
    }

    /// The hidden span from the `screen` records (epoch ms), or null.
    (int, int)? hiddenSpan(String label, List<Map<String, dynamic>> recs) {
      final screen = recs.where((r) => r['type'] == 'screen').toList();
      _log('SCREEN $label ${[for (final r in screen) '${r['state']}@${r['time_ms']}'].join(' ')}');
      final hidden = screen.where((r) => r['state'] == 'hidden').toList();
      final visible = screen.where((r) => r['state'] == 'visible').toList();
      if (hidden.isEmpty || visible.isEmpty) {
        problem(label, 'no screen hidden/visible records (was Home pressed?)');
        return null;
      }
      final from = hidden.first['time_ms'] as int;
      final to = visible.last['time_ms'] as int;
      _log('HIDDEN $label for ${((to - from) / 1000).toStringAsFixed(1)} s');
      if (to - from < 10000) problem(label, 'hidden for only ${to - from} ms');
      return (from, to);
    }

    final base = saved.copyWith(scheduleEnabled: false, sessionMinutes: 60, folderName: 'screen_off_check');

    if (_parts.contains('T')) {
      final out = await record(
        'T',
        base.copyWith(
          captureTrigger: CaptureTrigger.timelapse,
          timeLapseSaveAs: TimeLapseSaveAs.photos,
          captureMode: RoiCaptureMode.fast,
          stepSeconds: 1,
          durationSeconds: 600,
          timeLapseGapSeconds: 0,
          timeLapseTorch: false,
        ),
      );
      if (out != null) {
        final (dir, recs) = out;
        final span = hiddenSpan('T', recs);
        if (recs.any((r) => r['type'] == 'timelapse_skipped')) problem('T', 'photos were skipped');
        final shots = [for (final r in recs.where((r) => r['type'] == 'timelapse_capture')) r['captured_at_ms'] as int];
        var gapMs = 0;
        for (var i = 1; i < shots.length; i++) {
          if (shots[i] - shots[i - 1] > gapMs) gapMs = shots[i] - shots[i - 1];
        }
        final whileHidden = span == null ? 0 : shots.where((t) => t > span.$1 && t < span.$2).length;
        _log('PHOTOS T ${shots.length}; $whileHidden while hidden; longest gap $gapMs ms');
        if (gapMs > 3000) problem('T', 'a gap of $gapMs ms between photos');
        if (span != null && whileHidden < (span.$2 - span.$1) ~/ 1000 - 3) {
          problem('T', 'only $whileHidden photos while hidden');
        }
        final files = Directory('${dir.path}/roi_frames').listSync().whereType<File>().toList();
        final byDigest = <String, List<String>>{};
        for (final f in files) {
          byDigest.putIfAbsent(md5.convert(f.readAsBytesSync()).toString(), () => []).add(f.path.split('/').last);
        }
        final copies = byDigest.values.where((n) => n.length > 1).toList();
        _log('FILES T ${files.length}; identical groups ${copies.length}');
        if (copies.isNotEmpty) problem('T', 'identical photos: ${copies.take(3).toList()}');
        final missing = recs
            .where((r) => r['type'] == 'timelapse_capture')
            .where((r) => !File('${dir.path}/roi_frames/${r['jpeg']}').existsSync())
            .length;
        if (missing > 0) problem('T', '$missing photos named in the log are missing');
      }
    }

    if (_parts.contains('D')) {
      if (saved.modelPath.isEmpty || !File(saved.modelPath).existsSync()) {
        _log('SKIP D: no detection model saved on this phone');
      } else {
        final out = await record(
          'D',
          base.copyWith(captureTrigger: CaptureTrigger.detector, motionGateEnabled: false, liveAiVideo: false),
        );
        if (out != null) {
          final (_, recs) = out;
          hiddenSpan('D', recs);
          _log('FPS D ${[for (final r in recs.where((r) => r['type'] == 'fps')) r['camera_fps']].join(' ')}');
        }
      }
    }

    if (_parts.contains('P')) {
      // Burst 0 at 0-5 s, parked from about 5 s, woken at 30 s (10 s lead), burst 1 at 40-45 s:
      // hidden from 20 s to 50 s covers the wake and the whole burst.
      final out = await record(
        'P',
        base.copyWith(
          captureTrigger: CaptureTrigger.timelapse,
          timeLapseSaveAs: TimeLapseSaveAs.photos,
          captureMode: RoiCaptureMode.fast,
          stepSeconds: 1,
          durationSeconds: 5,
          timeLapseGapSeconds: 35,
          timeLapseCameraSleep: true,
          timeLapseWakeLeadSeconds: 10,
          timeLapseTorch: false,
        ),
        homeAfterS: 20,
        hiddenS: 30,
      );
      if (out != null) {
        final (dir, recs) = out;
        final span = hiddenSpan('P', recs);
        final states = [for (final r in recs.where((r) => r['type'] == 'camera_sleep')) '${r['state']}/${r['reason']}'];
        _log('CAMERA P ${states.join(' ')}');
        if (states.any((s) => s.startsWith('fallback_bound'))) problem('P', 'the camera fell back: $states');
        final wakesHidden = span == null
            ? 0
            : recs
                  .where((r) => r['type'] == 'camera_sleep' && r['state'] == 'running')
                  .where((r) => (r['time_ms'] as int) > span.$1 && (r['time_ms'] as int) < span.$2)
                  .length;
        final perBurst = <int, int>{};
        for (final r in recs.where((r) => r['type'] == 'timelapse_capture')) {
          perBurst[r['burst'] as int] = (perBurst[r['burst'] as int] ?? 0) + 1;
        }
        _log('PHOTOS P per burst $perBurst; wakes while hidden $wakesHidden');
        if (wakesHidden < 1) problem('P', 'no camera wake happened while hidden');
        if ((perBurst[1] ?? 0) < 5) problem('P', 'burst 1 (while hidden) has ${perBurst[1] ?? 0} photos, expected 5');
        final missing = recs
            .where((r) => r['type'] == 'timelapse_capture')
            .where((r) => !File('${dir.path}/roi_frames/${r['jpeg']}').existsSync())
            .length;
        if (missing > 0) problem('P', '$missing photos named in the log are missing');
      }
    }

    if (_parts.contains('S')) {
      final now = DateTime.now();
      final startMin = now.hour * 60 + now.minute + (now.second > 30 ? 2 : 1);
      final windowStart = DateTime(now.year, now.month, now.day).add(Duration(minutes: startMin));
      final before = sessionDirs();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: CameraSessionScreen(
            initialConfig: base.copyWith(
              captureTrigger: CaptureTrigger.timelapse,
              timeLapseSaveAs: TimeLapseSaveAs.photos,
              captureMode: RoiCaptureMode.fast,
              stepSeconds: 1,
              durationSeconds: 5,
              timeLapseGapSeconds: 35,
              timeLapseCameraSleep: true,
              timeLapseTorch: false,
              scheduleEnabled: true,
              scheduleWindows: [ScheduleWindow(startMin, startMin + 2)],
              scheduleDays: 1,
            ),
          ),
        ),
      );
      await pumpFor(const Duration(seconds: 3));
      var started = false;
      for (var i = 0; i < 30 && !started; i++) {
        await tester.tap(recButton.first, warnIfMissed: false);
        await tester.pump(const Duration(seconds: 1));
        if (find.text('Start scheduled run?').evaluate().isNotEmpty) {
          await tester.tap(find.text('Start'));
          started = true;
        }
      }
      if (!started) {
        problem('S', 'the scheduled run did not start');
      } else {
        await pumpFor(const Duration(seconds: 2));
        // Hidden from now until 50 s into the window: the window opens while hidden.
        final hiddenS = windowStart.difference(DateTime.now()).inSeconds + 50;
        _log('SCHEDULED S window at ${windowStart.toIso8601String()}');
        _log('HOME_NOW S $hiddenS');
        // Not pumpFor: it closes every window with a Close button, this one included.
        final complete = find.text('Scheduled run complete');
        final deadline = DateTime.now().add(Duration(seconds: hiddenS + 245));
        while (complete.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        if (complete.evaluate().isEmpty) {
          problem('S', 'no "Scheduled run complete" within 4 minutes after the app came back');
        } else {
          await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')));
          await tester.pump(const Duration(seconds: 1));
        }
        final added = sessionDirs().difference(before).toList();
        _log('SESSIONS S ${added.map((p) => p.split('/').last).toList()}');
        if (added.length != 1) problem('S', '${added.length} session folders, expected 1');
        for (final p in added) {
          final recs = [
            for (final l in File('$p/session.jsonl').readAsLinesSync())
              if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
          ];
          if (!recs.any((r) => r['type'] == 'end_of_session' && r['ended_normally'] == true)) {
            problem('S', 'no normal end_of_session');
          }
          for (final e in recs.where((r) => r['type'] == 'app_error')) {
            problem('S', 'app_error ${e['source']}: ${e['message']}');
          }
          final startMs = recs.first['time_ms'] as int;
          final shots = [for (final r in recs.where((r) => r['type'] == 'timelapse_capture')) r['captured_at_ms'] as int];
          final hiddenUntil = windowStart.millisecondsSinceEpoch + 50000;
          final whileHidden = shots.where((t) => t < hiddenUntil).length;
          _log('WINDOW S started ${startMs - windowStart.millisecondsSinceEpoch} ms after it opened; '
              'photos ${shots.length}, $whileHidden before the app came back');
          if (whileHidden < 5) problem('S', 'only $whileHidden photos while the app was hidden');
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    if (_parts.contains('O')) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: CameraSessionScreen(
            initialConfig: base.copyWith(
              captureTrigger: CaptureTrigger.timelapse,
              timeLapseSaveAs: TimeLapseSaveAs.photos,
              captureMode: RoiCaptureMode.fast,
              stepSeconds: 2,
              durationSeconds: 600,
              timeLapseGapSeconds: 0,
              timeLapseTorch: false,
              screenOffAfterMin: 1,
            ),
          ),
        ),
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
      if (dir == null) {
        problem('O', 'recording did not start');
      } else {
        final lastTouchMs = DateTime.now().millisecondsSinceEpoch;
        _log('SCREEN_IDLE_START');
        // No touch: plain pumps (pumpFor taps Close buttons, which would count as touches).
        final until = DateTime.now().add(const Duration(seconds: 75));
        while (DateTime.now().isBefore(until)) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        _log('KEEP_CHECK');
        await tester.pump(const Duration(seconds: 3));
        // One tap anywhere wakes the screen (the black cover takes it), then stop.
        await tester.tapAt(const Offset(180, 300));
        await pumpFor(const Duration(seconds: 3));
        await tester.tap(recButton.first, warnIfMissed: false);
        final log = File('${dir.path}/session.jsonl');
        for (var i = 0; i < 40 && !log.readAsStringSync().contains('"end_of_session"'); i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        final recs = [
          for (final l in log.readAsLinesSync())
            if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
        ];
        final blackout = [for (final r in recs.where((r) => r['type'] == 'blackout')) '${r['on']}@${((r['time_ms'] as int) - lastTouchMs) ~/ 1000}s'];
        _log('BLACKOUT O $blackout (seconds after the last touch)');
        final on = recs.where((r) => r['type'] == 'blackout' && r['on'] == true).toList();
        if (on.isEmpty) {
          problem('O', 'the screen did not go black');
        } else {
          final afterS = ((on.first['time_ms'] as int) - lastTouchMs) / 1000;
          if (afterS < 58 || afterS > 66) problem('O', 'black after ${afterS.toStringAsFixed(1)} s, expected about 60');
        }
        if (!recs.any((r) => r['type'] == 'blackout' && r['on'] == false)) problem('O', 'the tap did not bring the screen back');
        if (!recs.any((r) => r['type'] == 'end_of_session' && r['ended_normally'] == true)) problem('O', 'no normal end_of_session');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    _log(problems.isEmpty ? 'CHECK PASSED' : 'CHECK FAILED: ${problems.length} problems');
    expect(problems, isEmpty);
  });
}
