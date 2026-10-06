// FaunaPulse (round 295): on-device check of the high-res photo path (the full photo goes to
// Dart, the app's native crop channel cuts the ROI square). Records a time-lapse with
// photo source "High-res" (one photo every 2 s, no break) for 24 s, then checks every `capture`
// record: path still, the file exists and is a square of `saved_px`, timing logged. Prints
// the median total and grab times. Problems print as PROBLEM lines. The phone's saved settings
// are restored afterwards; the session stays in high_res_check*.
// --dart-define=TARGET=512 sets the saved side (default: the phone's saved setting).
// Run:  flutter test integration_test/high_res_photos_check_test.dart -d <serial> --no-uninstall

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _target = int.fromEnvironment('TARGET');

// ignore: avoid_print
void _log(String s) => print(s);

double _median(List<num> v) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  return s[s.length ~/ 2].toDouble();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('high-res photos are cut to the ROI and saved', (tester) async {
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

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: CameraSessionScreen(
          initialConfig: saved.copyWith(
            scheduleEnabled: false,
            sessionMinutes: 60,
            folderName: 'high_res_check',
            captureTrigger: CaptureTrigger.timelapse,
            timeLapseSaveAs: TimeLapseSaveAs.photos,
            captureMode: RoiCaptureMode.highRes,
            targetRoiSavedPx: _target > 0 ? _target : null,
            stepSeconds: 2,
            durationSeconds: 600,
            timeLapseGapSeconds: 0,
            timeLapseTorch: false,
          ),
        ),
      ),
    );
    await pumpFor(const Duration(seconds: 4));
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
    await pumpFor(const Duration(seconds: 24));
    await tester.tap(recButton.first, warnIfMissed: false);
    final log = File('${dir.path}/session.jsonl');
    for (var i = 0; i < 40 && !log.readAsStringSync().contains('"end_of_session"'); i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await pumpFor(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));

    final recs = [
      for (final l in log.readAsLinesSync())
        if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
    ];
    for (final e in recs.where((r) => r['type'] == 'app_error')) {
      problem('app_error ${e['source']}: ${e['message']}');
    }
    final caps = recs.where((r) => r['type'] == 'capture').toList();
    final paths = <String, int>{};
    for (final c in caps) {
      paths['${c['path']}'] = (paths['${c['path']}'] ?? 0) + 1;
      final f = File('${dir.path}/roi_frames/${c['file']}');
      if (!f.existsSync()) {
        problem('missing ${c['file']}');
        continue;
      }
      final im = img.decodeJpg(f.readAsBytesSync());
      if (im == null || im.width != im.height || im.width != c['saved_px']) {
        problem('${c['file']}: ${im?.width}x${im?.height}, logged saved_px ${c['saved_px']}');
      }
    }
    _log('CAPTURES ${caps.length} by path $paths; saved_px ${caps.map((c) => c['saved_px']).toSet()}');
    _log('TIMING median total_ms ${_median([for (final c in caps) c['total_ms'] as num])}, '
        'grab_ms ${_median([for (final c in caps) if (c['grab_ms'] != null) c['grab_ms'] as num])}, '
        'content_lag_ms ${_median([for (final c in caps) if (c['content_lag_ms'] != null) c['content_lag_ms'] as num])}');
    if (caps.length < 8) problem('only ${caps.length} photos in 24 s at a 2 s step');
    if ((paths['still'] ?? 0) == 0) problem('no high-res (still) photo');
    _log(problems.isEmpty ? 'CHECK PASSED' : 'CHECK FAILED: ${problems.length} problems');
    expect(problems, isEmpty);
  });
}
