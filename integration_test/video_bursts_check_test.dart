// FaunaPulse (round 238): on-device check of time-lapse video bursts
// (Settings → Setup → "Save bursts as": Video).
//
// Runs the real camera screen with the phone's own saved settings, changed
// only to: time-lapse, video bursts of 10 s every 25 s (15 s break), 15
// frames per second, no camera sleep, no torch, no schedule, folder
// "video_burst_check". The phone's saved settings are restored afterwards.
// The recorded session stays on the phone (Sessions screen) for a look and
// for `adb pull`; delete it there when done.
// Run:  flutter test integration_test/video_bursts_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.
//
// Steps:
//  - start recording; the chip reads "TIME-LAPSE VIDEO: RECORDING" in a burst
//    (SHOT) and "NEXT BURST" in the break;
//  - stop inside the third burst: three clips, the last one ended by the stop;
//  - each clip: its `video_clip` record, the file's own size, length, frame
//    count and frame rate (read back through the decoder), frames skipped;
//  - one frame of the first clip saved as a JPEG, to compare by eye with the
//    recording screenshot (upright, the same view as the ROI square);
//  - battery temperature before and after.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _folder = 'video_burst_check';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('record time-lapse video bursts on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    final saved = await SessionConfig.load();
    addTearDown(saved.save);
    final config = saved.copyWith(
      captureTrigger: CaptureTrigger.timelapse,
      timeLapseSaveAs: TimeLapseSaveAs.video,
      timeLapseVideoFps: 15,
      durationSeconds: 10,
      timeLapseGapSeconds: 15,
      timeLapseCameraSleep: false,
      timeLapseTorch: false,
      scheduleEnabled: false,
      sessionMinutes: 60,
      folderName: _folder,
    );
    _log('CONFIG camera cap ${config.cameraFpsCap}, saved side ${config.targetRoiSavedPx}, '
        'stream ${config.streamWidth}x${config.streamHeight}');

    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions');
    sessions.createSync(recursive: true); // a fresh install has none yet
    final before = sessions.existsSync() ? sessions.listSync().map((e) => e.path).toSet() : <String>{};
    final t0 = await DeviceThermal.read();

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 3));
    }

    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: CameraSessionScreen(initialConfig: config)));
    await tester.pump(const Duration(seconds: 3));

    // The record button: a 72-px white ring around the red dot (square while
    // recording). It is inert until the camera finished calibrating.
    final recButton = find.byWidgetPredicate(
      (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 72, height: 72),
    );
    _log('REC BUTTONS ${recButton.evaluate().length}');
    Directory? dir;
    for (var i = 0; i < 30 && dir == null; i++) {
      if (find.text('Not now').evaluate().isNotEmpty) await tester.tap(find.text('Not now'));
      await tester.tap(recButton.first, warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      final added = sessions.listSync().whereType<Directory>().where((d) => !before.contains(d.path)).toList();
      if (added.isNotEmpty) dir = added.single;
    }
    expect(dir, isNotNull, reason: 'recording did not start');
    final startMs = DateTime.now().millisecondsSinceEpoch;
    _log('RECORDING ${dir!.path}');

    Future<void> until(int sinceStartMs) async {
      while (DateTime.now().millisecondsSinceEpoch - startMs < sinceStartMs) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    await until(5000);
    expect(find.text('VIDEO: RECORDING'), findsOneWidget);
    await shot('video_bursts_recording');
    await until(18000);
    expect(find.textContaining('NEXT BURST'), findsOneWidget);
    // Stop in the middle of the third burst (50 to 60 s).
    await until(55000);
    await tester.tap(recButton.first, warnIfMissed: false);
    final stopMs = DateTime.now().millisecondsSinceEpoch;
    final log = File('${dir.path}/session.jsonl');
    for (var i = 0; i < 30 && !log.readAsStringSync().contains('"end_of_session"'); i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    _log('STOPPED in ${DateTime.now().millisecondsSinceEpoch - stopMs} ms');
    await tester.pump(const Duration(seconds: 2));
    await shot('video_bursts_after_stop');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    final t1 = await DeviceThermal.read();

    // The records.
    final records = [for (final l in log.readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
    final starts = records.where((r) => r['type'] == 'timelapse_video_start').toList();
    final clips = records.where((r) => r['type'] == 'video_clip').toList();
    final skipped = records.where((r) => r['type'] == 'video_skipped').toList();
    for (final s in skipped) {
      _log('SKIPPED $s');
    }
    final start = records.first;
    _log('START not applicable: ${start['config_not_applicable']}');
    expect(start['config']['timeLapseSaveAs'], 'video');
    expect((start['config_not_applicable'] as List), contains('stepSeconds'));
    expect(starts, hasLength(3));
    expect(clips, hasLength(3));
    expect(clips.map((c) => c['burst']), [0, 1, 2]);
    expect(clips.last['end_reason'], 'session_end');
    expect(clips.first['end_reason'], 'burst_end');
    expect(Directory('${dir.path}/roi_frames').listSync(), isEmpty, reason: 'video bursts save no photos');

    // Each clip, read back from the file.
    var totalBytes = 0;
    var totalMs = 0;
    for (final c in clips) {
      final path = '${dir.path}/${c['file']}';
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: path);
      final info = await VideoFrameSource.info(path);
      totalBytes += f.lengthSync();
      totalMs += info.durationMs ?? 0;
      _log('CLIP burst ${c['burst']} (${c['end_reason']}): record ${c['frame_count']} frames, '
          '${c['frames_skipped']} skipped, ${c['duration_ms']} ms, ${c['fps_mean']} fps, '
          '${(c['size_bytes'] as num) / 1e6} MB, crop ${c['crop_ms_mean']} ms, draw ${c['draw_ms_mean']} ms, '
          '${c['encoder']} ${c['bitrate']} bit/s | file: ${info.width}x${info.height} rot ${info.rotation} '
          '${info.mime}, ${info.frameCount} frames, ${info.durationMs} ms, mean ${info.meanFps} fps, '
          'start ${DateTime.fromMillisecondsSinceEpoch(c['start_epoch_ms'] as int).toIso8601String()} '
          '(${c['start_time_source']})');
      expect(info.width, c['width']);
      expect(info.height, c['height']);
      expect(info.rotation, 0);
      expect(info.frameCount, c['frame_count']);
      expect(info.unsupportedReason, isNull);
    }
    // Full bursts: 10 s at 15 fps. The first may start up to 3 s late: on a fresh install
    // the camera switches to a larger stream just after the recording starts (Samsung, r243).
    expect(clips[0]['duration_ms'] as int, inInclusiveRange(7000, 11000));
    expect(clips[1]['duration_ms'] as int, inInclusiveRange(9000, 11000));
    expect(clips[1]['frame_count'] as int, greaterThan(120));
    // Clip start times follow the burst plan: 25 s apart.
    final s0 = clips[0]['start_epoch_ms'] as int;
    final s1 = clips[1]['start_epoch_ms'] as int;
    final s2 = clips[2]['start_epoch_ms'] as int;
    _log('STARTS ${s1 - s0} ms and ${s2 - s1} ms apart; first ${s0 - startMs} ms after the tap');
    expect(s1 - s0, inInclusiveRange(24000, 26000));
    expect(s2 - s1, inInclusiveRange(24000, 26000));

    // One frame of the first clip as a JPEG.
    final first = '${dir.path}/${clips.first['file']}';
    final side = clips.first['width'] as int;
    final jpg = '${dir.path}/check_frame.jpg';
    await VideoFrameSource.openFrames(first, roiPx: [0, 0, side, side]);
    // Times inside the file start at 0 (the muxer counts from the first frame).
    final r = await VideoFrameSource.saveFrames(ptsUs: [5000000], paths: [jpg]);
    await VideoFrameSource.close();
    final jpgBytes = File(jpg).existsSync() ? File(jpg).lengthSync() : 0;
    // A dark scene gives a small file; the picture itself is checked by eye (adb pull
    // check_frame.jpg and compare with the "recording" screenshot: upright, same view).
    _log('FRAME saved ${r.processed}, ${jpgBytes ~/ 1024} KB: ${dir.path}/check_frame.jpg');
    expect(jpgBytes, greaterThan(1000));

    final perHour = totalMs > 0 ? totalBytes / totalMs * 3600000 : 0;
    _log('STORAGE ${totalBytes / 1e6} MB for ${totalMs / 1000} s: ${perHour / 1e9} GB per recorded hour');
    _log('THERMAL battery ${t0.batteryTempC} -> ${t1.batteryTempC} °C');
    for (final t in records.where((r) => r['type'] == 'fps').take(80)) {
      _log('FPS ${t['time_ms'] - startMs}: ${t['delivered_fps'] ?? t['camera_fps'] ?? t}');
    }
  });
}
