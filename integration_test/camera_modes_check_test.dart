// FaunaPulse (round 245): on-device regression check of the camera screen's recording modes,
// through the real screen and camera, after the native frame path changed for video (rounds 238
// to 244). Each session records for a fixed time and is then checked from its session.jsonl and
// files; every problem found is printed as a "PROBLEM" line and the check fails at the end if
// there were any, so one run shows them all.
//
//  A. Time-lapse photos, camera off between bursts, torch: 5 photos per burst (1 s apart),
//     35-s breaks (the camera parks from 30 s), 90 s: camera parked and woken, torch on and
//     off, every photo on disk.
//  B. Video bursts with the same camera sleep and torch: 10-s clips, 35-s breaks, 100 s.
//  C. Continuous video (no break): 20-s clips back to back, 50 s.
//  D. Motion-only capture: the check blinks the torch every 4 s (through the screen's own
//     camera controller), so even a still scene has motion: photos, no detector.
//  E. Live AI photos. A still scene often has nothing to detect, so by default E only checks
//     that what was tracked was photographed and saved; finding nothing is no failure. It runs
//     with the torch on, confidence 0.02 (the arthropod model when imported), raw boxes logged
//     and the tracker starting tracks from 0.02 (default 0.5), to give weak boxes a chance.
//     With --dart-define=E_SUBJECT=true the phone looks at something its model detects (e.g. a
//     screen playing a video of pollinators, or animals for MegaDetector): E then uses the
//     phone's own model and thresholds and fails when nothing is tracked or photographed.
//  F. A scheduled run with video bursts: a 2-minute window starting at the next minute; the
//     app sleeps until then, records the window as its own session and ends the run.
// --dart-define=MODES=ACF runs only those sessions (default all). The phone's saved settings
// are restored afterwards; the sessions stay in modes_check*. Grant the notification
// permission first (adb shell pm grant com.faunapulse.app android.permission.POST_NOTIFICATIONS):
// a scheduled run asks for it, and the system dialog would stop the check.
// Run:  flutter test integration_test/camera_modes_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/schedule_window.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart' show ByteTrackParams;
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart' show TrackerAlgorithm;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _folder = 'modes_check';
const _modes = String.fromEnvironment('MODES', defaultValue: 'ABCDEF');
const _eSubject = bool.fromEnvironment('E_SUBJECT');

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recording modes on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions');
    sessions.createSync(recursive: true); // a fresh install has none yet
    final problems = <String>[];
    void problem(String label, String what) {
      problems.add('$label: $what');
      _log('PROBLEM $label: $what');
    }

    final recButton = find.byWidgetPredicate(
      (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 72, height: 72),
    );

    Future<void> pumpFor(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')).evaluate().isNotEmpty) await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')).first);
      }
    }

    Set<String> sessionDirs() => sessions.listSync().whereType<Directory>().map((d) => d.path).toSet();

    List<Map<String, dynamic>> readLog(Directory dir) => [
      for (final l in File('${dir.path}/session.jsonl').readAsLinesSync())
        if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
    ];

    Future<void> openScreen(SessionConfig config) async {
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: CameraSessionScreen(initialConfig: config)),
      );
      await pumpFor(const Duration(seconds: 3));
    }

    Future<void> closeScreen() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    /// Starts a manual recording, records [seconds] (calling [during] once a second), stops it
    /// and returns the session folder.
    Future<Directory?> record(String label, SessionConfig config, int seconds,
        {Future<void> Function(int second)? during}) async {
      final before = sessionDirs();
      await openScreen(config);
      Directory? dir;
      for (var i = 0; i < 30 && dir == null; i++) {
        if (find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')).evaluate().isNotEmpty) await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')).first);
        await tester.tap(recButton.first, warnIfMissed: false);
        await tester.pump(const Duration(seconds: 1));
        final added = sessionDirs().difference(before);
        if (added.isNotEmpty) dir = Directory(added.single);
      }
      if (dir == null) {
        problem(label, 'recording did not start');
        await closeScreen();
        return null;
      }
      _log('RECORDING $label ${dir.path.split('/').last} for $seconds s');
      for (var sec = 0; sec < seconds; sec++) {
        await during?.call(sec);
        await pumpFor(const Duration(seconds: 1));
      }
      await tester.tap(recButton.first, warnIfMissed: false);
      final log = File('${dir.path}/session.jsonl');
      for (var i = 0; i < 40 && !log.readAsStringSync().contains('"end_of_session"'); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump(const Duration(seconds: 2));
      await closeScreen();
      return dir;
    }

    /// What every session must have: a normal end, no app errors, fps records.
    void common(String label, List<Map<String, dynamic>> recs) {
      final end = recs.where((r) => r['type'] == 'end_of_session').toList();
      if (end.isEmpty || end.last['ended_normally'] != true) problem(label, 'no normal end_of_session');
      for (final e in recs.where((r) => r['type'] == 'app_error')) {
        problem(label, 'app_error ${e['source']}: ${e['message']}');
      }
      if (!recs.any((r) => r['type'] == 'fps')) problem(label, 'no fps records');
    }

    /// Photos named in [type] records must exist in roi_frames/.
    int photosOnDisk(String label, Directory dir, List<Map<String, dynamic>> recs, String type) {
      final names = [for (final r in recs.where((r) => r['type'] == type)) r['jpeg'] as String];
      final missing = names.where((n) => !File('${dir.path}/roi_frames/$n').existsSync()).toList();
      if (missing.isNotEmpty) problem(label, '${missing.length} of ${names.length} $type photos missing');
      return names.length;
    }

    /// The camera parked between bursts and woke for each, the wake lead (10 s) ahead of the
    /// burst: states in order, no fallback.
    void cameraSleep(String label, List<Map<String, dynamic>> recs, {required int minParks}) {
      final states = [for (final r in recs.where((r) => r['type'] == 'camera_sleep')) '${r['state']}/${r['reason']}'];
      _log('CAMERA $label ${states.join(' ')}');
      final parks = states.where((s) => s.startsWith('parked')).length;
      if (parks < minParks) problem(label, 'camera parked $parks times, expected $minParks');
      if (states.any((s) => s.startsWith('fallback_bound'))) problem(label, 'camera fell back: $states');
      final wakes = [for (final r in recs.where((r) => r['type'] == 'camera_sleep' && r['state'] == 'running')) r['wake_ms']];
      final leads = [
        for (final r in recs.where((r) => r['type'] == 'camera_sleep' && r['state'] == 'warming'))
          (r['next_burst_at_ms'] as int) - (r['time_ms'] as int),
      ];
      _log('WAKE $label took ms: $wakes; issued ms before the burst: $leads');
      if (leads.any((l) => l < 9000)) problem(label, 'the camera woke late: $leads ms before the bursts, expected 10000');
    }

    /// Torch records: lit before a burst and put out, every change applied.
    void torch(String label, List<Map<String, dynamic>> recs) {
      final t = recs.where((r) => r['type'] == 'torch').toList();
      _log('TORCH $label ${[for (final r in t) '${r['on'] == true ? 'on' : 'off'}/${r['success']}/${r['reason']}'].join(' ')}');
      if (!t.any((r) => r['on'] == true && r['success'] == true)) problem(label, 'torch never came on');
      if (!t.any((r) => r['on'] == false && r['success'] == true)) problem(label, 'torch never went off');
      if (t.any((r) => r['success'] != true)) problem(label, 'a torch change failed');
    }

    /// Clips: each read back with its logged frame count; full ones near their length at ~15 fps.
    Future<List<Map<String, dynamic>>> clips(String label, Directory dir, List<Map<String, dynamic>> recs,
        {required int fullMs}) async {
      final out = recs.where((r) => r['type'] == 'video_clip').toList();
      for (final s in recs.where((r) => r['type'] == 'video_skipped')) {
        problem(label, 'video_skipped ${s['reason']}');
      }
      for (final c in out) {
        final info = await VideoFrameSource.info('${dir.path}/${c['file']}');
        _log('CLIP $label burst ${c['burst']} (${c['end_reason']}): ${c['frame_count']} frames, '
            '${c['frames_skipped']} skipped, ${c['duration_ms']} ms, ${c['fps_mean']} fps, '
            '${c['width']} px | file ${info.frameCount} frames, ${info.durationMs} ms');
        if (info.frameCount != c['frame_count']) problem(label, 'clip ${c['burst']}: file has ${info.frameCount} frames');
        if (c['end_reason'] == 'burst_end') {
          if ((c['duration_ms'] as num) < fullMs - 3000 || (c['duration_ms'] as num) > fullMs + 1000) {
            problem(label, 'clip ${c['burst']} lasted ${c['duration_ms']} ms, expected about $fullMs');
          }
          if ((c['fps_mean'] as num) < 13) problem(label, 'clip ${c['burst']} at ${c['fps_mean']} fps');
        }
      }
      return out;
    }

    YOLOViewController camera() => tester.widget<YOLOView>(find.byType(YOLOView)).controller!;
    final arthropod = File('${(await getApplicationSupportDirectory()).path}/models/arthropod_yolov11_float16.tflite');

    final base = saved.copyWith(
      scheduleEnabled: false,
      sessionMinutes: 60,
      folderName: _folder,
      timeLapseTorchLeadSeconds: 5,
      timeLapseWakeLeadSeconds: 10,
    );
    final t0 = await DeviceThermal.read();

    // A. Time-lapse photos, camera sleep, torch.
    if (_modes.contains('A')) {
      final dir = await record(
        'A',
        base.copyWith(
          captureTrigger: CaptureTrigger.timelapse,
          timeLapseSaveAs: TimeLapseSaveAs.photos,
          stepSeconds: 1,
          durationSeconds: 5,
          timeLapseGapSeconds: 35,
          timeLapseCameraSleep: true,
          timeLapseTorch: true,
        ),
        90,
      );
      if (dir != null) {
        final recs = readLog(dir);
        common('A', recs);
        final n = photosOnDisk('A', dir, recs, 'timelapse_capture');
        final perBurst = <int, int>{};
        for (final r in recs.where((r) => r['type'] == 'timelapse_capture')) {
          perBurst[r['burst'] as int] = (perBurst[r['burst'] as int] ?? 0) + 1;
        }
        _log('PHOTOS A $n, per burst $perBurst');
        for (final b in [0, 1]) {
          if ((perBurst[b] ?? 0) < 4) problem('A', 'burst $b has ${perBurst[b] ?? 0} photos, expected 5');
        }
        cameraSleep('A', recs, minParks: 2);
        torch('A', recs);
      }
    }

    // B. Video bursts, camera sleep, torch.
    if (_modes.contains('B')) {
      final dir = await record(
        'B',
        base.copyWith(
          captureTrigger: CaptureTrigger.timelapse,
          timeLapseSaveAs: TimeLapseSaveAs.video,
          timeLapseVideoFps: 15,
          durationSeconds: 10,
          timeLapseGapSeconds: 35,
          timeLapseCameraSleep: true,
          timeLapseTorch: true,
        ),
        100,
      );
      if (dir != null) {
        final recs = readLog(dir);
        common('B', recs);
        final c = await clips('B', dir, recs, fullMs: 10000);
        if (c.where((c) => c['end_reason'] == 'burst_end').length < 2) problem('B', 'fewer than 2 full clips');
        cameraSleep('B', recs, minParks: 2);
        torch('B', recs);
      }
    }

    // C. Continuous video.
    if (_modes.contains('C')) {
      final dir = await record(
        'C',
        base.copyWith(
          captureTrigger: CaptureTrigger.timelapse,
          timeLapseSaveAs: TimeLapseSaveAs.video,
          timeLapseVideoFps: 15,
          durationSeconds: 20,
          timeLapseGapSeconds: 0,
          timeLapseCameraSleep: true,
          timeLapseTorch: false,
        ),
        50,
      );
      if (dir != null) {
        final recs = readLog(dir);
        common('C', recs);
        final c = await clips('C', dir, recs, fullMs: 20000);
        if (c.length < 3) problem('C', '${c.length} clips, expected 3');
        for (var i = 1; i < c.length; i++) {
          final prevEnd = (c[i - 1]['start_epoch_ms'] as int) + (c[i - 1]['duration_ms'] as int);
          final gap = (c[i]['start_epoch_ms'] as int) - prevEnd;
          _log('GAP C between clips ${i - 1} and $i: $gap ms');
          if (gap > 1500) problem('C', 'a $gap-ms hole between clips ${i - 1} and $i');
        }
        if (recs.any((r) => r['type'] == 'camera_sleep' && r['state'] == 'parked')) {
          problem('C', 'the camera parked in a continuous recording');
        }
      }
    }

    // D. Motion-only capture, woken by sensor noise.
    if (_modes.contains('D')) {
      final dir = await record(
        'D',
        base.copyWith(
          captureTrigger: CaptureTrigger.motion,
          stepSeconds: 1,
          durationSeconds: 5,
        ),
        40,
        during: (sec) async {
          if (sec % 4 == 0) await camera().setTorchMode(sec % 8 == 0 && sec < 36);
        },
      );
      if (dir != null) {
        final recs = readLog(dir);
        common('D', recs);
        final n = photosOnDisk('D', dir, recs, 'motion_capture');
        final dets = recs.where((r) => r['type'] == 'detections').length;
        _log('PHOTOS D $n motion photos, $dets detection records');
        if (n == 0) problem('D', 'no motion photos while the torch blinked');
        if (dets > 0) problem('D', 'the detector ran in motion-only mode');
      }
    }

    // E. Live AI photos: a subject in view (E_SUBJECT), or a still scene with weak boxes allowed.
    if (_modes.contains('E')) {
      final live = base.copyWith(
        captureTrigger: CaptureTrigger.detector,
        logRawDetections: true,
        motionGateEnabled: false,
        liveAiVideo: false,
        stepSeconds: 1,
        durationSeconds: 5,
      );
      final dir = await record(
        'E',
        _eSubject
            ? live
            : live.copyWith(
                confidenceThreshold: 0.02,
                modelPath: arthropod.existsSync() ? arthropod.path : null,
                trackerAlgorithm: TrackerAlgorithm.bytetrack,
                trackerParams: const ByteTrackParams(highThresh: 0.02),
              ),
        40,
        during: _eSubject
            ? null
            : (sec) async {
                if (sec == 0) await camera().setTorchMode(true);
                if (sec == 39) await camera().setTorchMode(false);
              },
      );
      if (dir != null) {
        final recs = readLog(dir);
        common('E', recs);
        final dets = recs.where((r) => r['type'] == 'detections').length;
        final raw = recs.where((r) => r['type'] == 'raw_detections').toList();
        final rawBoxes = raw.fold<int>(0, (n, r) => n + ((r['boxes'] as List?)?.length ?? 0));
        final boxFrames = raw.where((r) => (r['boxes'] as List?)?.isNotEmpty ?? false).length;
        _log('RAW E ${raw.length} records, $rawBoxes boxes on $boxFrames frames');
        final caps = recs.where((r) => r['type'] == 'capture').toList();
        final missing = caps.where((c) => c['file'] is String && !File('${dir.path}/roi_frames/${c['file']}').existsSync());
        final start = recs.first['config'] as Map;
        _log('PHOTOS E ${caps.length} capture records, $dets detection records, '
            'confidence logged ${start['confidenceThreshold']}');
        if (_eSubject) {
          if (dets == 0) problem('E', 'nothing tracked although a subject was in view');
        } else if (dets == 0) {
          // A still scene: nothing, or a few stray boxes, which make no track (3 matching hits
          // are needed; the Xiaomi, round 246: 3 lone boxes in 622 frames).
          _log('NOTE E: nothing tracked, so the photo path was not tested; point the phone at a video of '
              'pollinators or animals and pass E_SUBJECT=true to test it');
        }
        if (dets > 0 && caps.isEmpty) problem('E', 'detections but no photos');
        if (missing.isNotEmpty) problem('E', '${missing.length} photos missing');
      }
    }

    // F. A scheduled run with video bursts.
    if (_modes.contains('F')) {
      final now = DateTime.now();
      final startMin = now.hour * 60 + now.minute + (now.second > 40 ? 2 : 1);
      final window = ScheduleWindow(startMin, startMin + 2);
      final before = sessionDirs();
      await openScreen(
        base.copyWith(
          captureTrigger: CaptureTrigger.timelapse,
          timeLapseSaveAs: TimeLapseSaveAs.video,
          timeLapseVideoFps: 15,
          durationSeconds: 10,
          timeLapseGapSeconds: 35,
          timeLapseCameraSleep: true,
          timeLapseTorch: false,
          scheduleEnabled: true,
          scheduleWindows: [window],
          scheduleDays: 1,
        ),
      );
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
        problem('F', 'the scheduled run did not start');
      } else {
        _log('SCHEDULED F window ${window.label}');
        final complete = find.text('Scheduled run complete');
        final deadline = DateTime.now().add(const Duration(minutes: 5));
        while (complete.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
          await pumpFor(const Duration(seconds: 2));
        }
        if (complete.evaluate().isEmpty) {
          problem('F', 'the run did not end within 5 minutes');
        } else {
          await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Close')));
          await tester.pump(const Duration(seconds: 1));
        }
        final added = sessionDirs().difference(before).toList();
        _log('SESSIONS F ${added.map((p) => p.split('/').last).toList()}');
        if (added.length != 1) problem('F', '${added.length} session folders, expected 1');
        for (final p in added) {
          final dir = Directory(p);
          final recs = readLog(dir);
          common('F', recs);
          final startMs = recs.first['time_ms'] as int;
          final windowStart = DateTime(now.year, now.month, now.day).add(Duration(minutes: startMin));
          _log('WINDOW F recording started ${startMs - windowStart.millisecondsSinceEpoch} ms after the window opened');
          final c = await clips('F', dir, recs, fullMs: 10000);
          if (c.length < 2) problem('F', '${c.length} clips in a 2-minute window');
          cameraSleep('F', recs, minParks: 2);
        }
      }
      await closeScreen();
    }

    final t1 = await DeviceThermal.read();
    _log('THERMAL battery ${t0.batteryTempC} -> ${t1.batteryTempC} °C');
    _log('PROBLEMS ${problems.length}');
    expect(problems, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 30)));
}
