// FaunaPulse (round 237): on-device check of "Find visits" in the photos of a
// time-lapse session (photo_tracker.dart).
//
// No field session is touched: the check builds its own time-lapse session in
// photo_visits_check/ from the owner's test clip (VID_20260924_155954.mp4,
// already pushed for video_decode_check_test.dart, see its header): a square
// of the picture saved every 0.2 s as photos, in two bursts 60 s apart, with
// the session.jsonl records a time-lapse session writes.
// Run:  flutter test integration_test/photo_visits_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Model: as in video_review_check_test.dart (--dart-define=REVIEW_MODEL=...).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.
//
// Steps:
//  - the photos run through the detector as on "Run AI on photos";
//  - "Find visits" there, through the real screen (SHOT): visits found, the
//    photo step and burst time in post_tracks.jsonl;
//  - identification plans its crops per visit;
//  - the summary: the visit count "found afterwards in the photos" and a
//    photo of a visit with its number (SHOT).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show roiPhotoFileName;
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/logging/track_source.dart';
import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/post_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _clip = 'VID_20260924_155954.mp4';
const _model = String.fromEnvironment('REVIEW_MODEL', defaultValue: 'arthropod_yolov11_float16.tflite');
const _stepMs = 200;

// ignore: avoid_print
void _log(String s) => print(s);

Future<String> _modelPath() async {
  if (_model.isEmpty) return kLocalYolo26ModelPath;
  final f = File('${(await ModelCatalog.modelsDir()).path}/$_model');
  expect(f.existsSync(), isTrue, reason: 'import $_model in the app first');
  return f.path;
}

String _rec(String type, int ms, Map<String, dynamic> m) =>
    jsonEncode({'type': type, 'time_ms': ms, 'time_iso': DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String(), ...m});

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('find track IDs in photos on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    // Screen on for the whole check: once the display sleeps, no frame is
    // drawn and the screen steps below wait for ever.
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    // 1. A time-lapse session made from the clip.
    final ext = (await getExternalStorageDirectory())!.path;
    final src = File('$ext/video_check/videos/$_clip');
    expect(src.existsSync(), isTrue, reason: 'push $_clip to $ext/video_check/videos first');
    final out = Directory('$ext/photo_visits_check');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final sessions = Directory('${out.path}/sessions')..createSync(recursive: true);
    final dir = Directory('${sessions.path}/photo check')..createSync();
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    final info = await VideoFrameSource.info(src.path);
    final upW = info.rotation % 180 == 0 ? info.width : info.height;
    final upH = info.rotation % 180 == 0 ? info.height : info.width;
    final side = min2(upW, upH);
    final roi = [(upW - side) ~/ 2, (upH - side) ~/ 2, side, side];
    final t0 = DateTime(2026, 9, 26, 12).millisecondsSinceEpoch;
    // Two 15-s bursts of the clip, the second shown 60 s later.
    final pts = [for (var t = 0; t < (info.durationMs ?? 30000) - 300; t += _stepMs) t];
    int wallOf(int t) => t0 + t + (t >= 15000 ? 60000 : 0);
    final names = [for (final t in pts) roiPhotoFileName(wallOf(t), 'chk')];
    await VideoFrameSource.openFrames(src.path, roiPx: roi);
    var done = 0;
    while (done < pts.length) {
      final chunk = await VideoFrameSource.saveFrames(
        ptsUs: [for (final t in pts.skip(done)) t * 1000],
        paths: [for (final n in names.skip(done)) '${frames.path}/$n'],
      );
      expect(chunk.processed, greaterThan(0));
      done += chunk.processed;
    }
    await VideoFrameSource.close();
    File('${dir.path}/session.jsonl').writeAsStringSync(
      '${[
        _rec('start_of_session', t0, {
          'file_token': 'chk',
          'config': {'captureTrigger': 'timelapse', 'stepSeconds': _stepMs / 1000, 'durationSeconds': 15.0},
        }),
        for (var i = 0; i < pts.length; i++) ...[
          _rec('timelapse_capture', wallOf(pts[i]), {'jpeg': names[i], 'captured_at_ms': wallOf(pts[i])}),
          _rec('capture', wallOf(pts[i]), {'file': names[i], 'captured_at_ms': wallOf(pts[i]), 'saved_px': side}),
        ],
        _rec('end_of_session', wallOf(pts.last) + 1000, {'ended_normally': true}),
      ].join('\n')}\n',
    );
    _log('SESSION ${pts.length} photos of ${side}px, every $_stepMs ms in two bursts');

    // 2. The detector over the photos.
    final model = await _modelPath();
    final yolo = YOLO(modelPath: model, useGpu: true);
    expect(await yolo.loadModel(), isTrue);
    final run = await PostDetector(
      predict: (Uint8List bytes) =>
          yolo.predict(bytes, confidenceThreshold: 0.25, iouThreshold: 0.7, includeAnnotatedImage: false),
    ).run(
      dir,
      config: PostRunConfig(modelPath: model, modelName: model.split('/').last, confidence: 0.25, iou: 0.7, useGpu: true),
    );
    await yolo.dispose();
    _log('ANALYSED ${run.processed} photos, ${run.failed} failed, in ${run.elapsed.inSeconds} s');
    expect(run.failed, 0);

    Future<void> waitFor(Finder f, {int seconds = 20}) async {
      for (var i = 0; i < seconds * 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (f.evaluate().isNotEmpty) return;
      }
      fail('not found: $f');
    }

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 4));
    }

    // 3. "Find visits" on the real screen.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: AnalysisScreen(initialSessionPath: dir.path, sessionsDir: sessions),
      ),
    );
    await waitFor(find.textContaining('photo check'));
    await tester.pump(const Duration(seconds: 1));
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Find track IDs'), 300, scrollable: list);
    await tester.tap(find.text('Find track IDs'));
    await waitFor(find.textContaining('(occlusion tolerance'));
    await tester.pump(const Duration(seconds: 5)); // the snack bar goes
    await tester.scrollUntilVisible(find.text('Find track IDs again'), 300, scrollable: list);
    await tester.ensureVisible(find.text('Track IDs'));
    await shot('photo_visits_screen');
    final summary = (await VideoTracker.readSummary(dir))!;
    final start = (jsonDecode(File('${dir.path}/$postTracksFileName').readAsLinesSync().first) as Map);
    _log('FIND VISITS ${summary.visits} track IDs; source ${start['source']}, photos ${start['photos']}, '
        'step ${start['photo_step_s']} s, observed ${start['observed_ms']} ms');
    expect(summary.visits, greaterThan(0));
    expect(start['source'], 'photos');
    expect(trackSourceOf(dir), TrackSource.afterwards);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));

    // 4. Identification plans per visit.
    final tasks = await IdentificationJob.planSession(dir, maxCropsPerTrack: 10);
    final perTrack = <int?, int>{};
    for (final t in tasks) {
      perTrack[t.trackId] = (perTrack[t.trackId] ?? 0) + 1;
    }
    _log('IDENTIFY PLAN ${tasks.length} crops: $perTrack');
    expect(tasks, isNotEmpty);
    expect(perTrack.keys, everyElement(isNotNull));

    // 5. The summary.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'), initialTabIndex: 1),
      ),
    );
    await waitFor(find.text('${summary.visits} (found afterwards in the photos)'));
    await shot('photo_visits_graphs');
    await tester.tap(find.text('Photos'));
    await tester.pump(const Duration(seconds: 2));
    // Every photo in capture order, so the pager reaches a visit; the
    // viewer's arrows sit below the screen until scrolled into view.
    await tester.tap(find.textContaining('All ('));
    await tester.pump(const Duration(seconds: 1));
    final inVisit = find.textContaining(RegExp(r'in track IDs?$'));
    final pager = find.byIcon(Icons.chevron_right);
    if (pager.evaluate().isNotEmpty) await tester.ensureVisible(pager.first);
    for (var i = 0; i < 160 && inVisit.evaluate().isEmpty && pager.evaluate().isNotEmpty; i++) {
      await tester.tap(pager.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (inVisit.evaluate().isNotEmpty) await tester.ensureVisible(inVisit.first);
    _log('PHOTO ${inVisit.evaluate().isEmpty ? 'no track ID photo in the sample' : 'a photo of a track ID shown'}');
    await shot('photo_visits_photos');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}

int min2(int a, int b) => a < b ? a : b;
