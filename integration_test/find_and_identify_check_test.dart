// FaunaPulse (round 274): on-device check of "Also identify them": one Start
// from a video, or from photos, to the identification results.
//
// Uses a copy of a real clip: by default the owner's bumblebee video in the
// bumblebee-2 session (only read), or --dart-define=CLIP=<path inside the
// app's external files folder>. Everything is made in find_identify_check/.
// Detector: --dart-define=DETECTOR=<file in the app's detection models>
// (default insectdct-v8-s_1024_fp16.tflite). Identification:
// --dart-define=ID_MODEL=<file in identification/models> (default the
// insectDCT classifier, with its class list; fast on the GPU).
// Run:  flutter test integration_test/find_and_identify_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.
// It saves the identification choice and the switch as the remembered ones:
// copy the app's settings before and put them back after (see the test
// device notes).
//
// Steps:
//  - videos: the switch is on with the model and list under it;
//    "Analyze 1 clip and identify" (SHOT) runs the detector, the track IDs
//    and kept frames, then Identify organisms starts by itself and the
//    results open (SHOT);
//  - photos: a time-lapse session made from the same clip; "Analyze N
//    photos and identify" ends on the results too (SHOT).

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_choice.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/screens/analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_choice_fields.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_results_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'check_sessions.dart';

const _clip = String.fromEnvironment('CLIP', defaultValue: 'sessions/bumblebee-2/videos/Bumblebees__720p__h264_.mp4');
const _detector = String.fromEnvironment('DETECTOR', defaultValue: 'insectdct-v8-s_1024_fp16.tflite');
const _idModel = String.fromEnvironment('ID_MODEL', defaultValue: 'insectdct-cls-v7_eff2s_fp16.tflite');

// ignore: avoid_print
void _log(String s) => print(s);

/// The newest identification summary of [dir]: track IDs and the answer of
/// each, for the log.
String _summaryLine(Directory dir) {
  final summaries = IdentificationPaths(dir).existingSummaries();
  if (summaries.isEmpty) return 'no summary';
  final s = jsonDecode(summaries.first.readAsStringSync()) as Map<String, dynamic>;
  final tracks = (s['tracks'] as List? ?? const []).cast<Map<String, dynamic>>();
  return '${summaries.first.path.split('/').last}: ${tracks.length} track IDs';
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('one Start from finding to naming on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    final ext = (await getExternalStorageDirectory())!.path;
    final src = File('$ext/$_clip');
    expect(src.existsSync(), isTrue, reason: 'no clip at ${src.path}');
    final detector = File('${(await ModelCatalog.modelsDir()).path}/$_detector');
    expect(detector.existsSync(), isTrue, reason: 'import $_detector in the app first');
    final models = [ModelEntry(id: detector.path, name: _detector, source: ModelSource.imported)];
    final choice = await IdentificationChoice.load(modelName: _idModel);
    expect(choice.model?.path.split('/').last, _idModel, reason: 'import $_idModel in the app first');
    expect(choice.ready, isTrue, reason: 'no name list for $_idModel');
    _log('CHOICE ${choice.model!.path.split('/').last} + ${choice.pack!.path.split('/').last}');
    await AlsoIdentify.save(true);

    final out = Directory('$ext/find_identify_check');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final cache = Directory('${out.path}/cache')..createSync(recursive: true);
    final sessions = Directory('${out.path}/sessions')..createSync();

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

    // 1. Videos: a copy imported as its own session.
    final name = src.path.split('/').last;
    final info = await VideoFrameSource.info(src.path);
    final copy = src.copySync('${cache.path}/$name');
    final video = await importVideos(
      sessionsDir: sessions,
      sessionName: 'identify check video',
      clips: [
        ImportClip(
          path: copy.path,
          name: name,
          sizeBytes: copy.lengthSync(),
          info: info,
          guess: guessClipStart(
            fileName: name,
            storedMs: info.creationEpochMs,
            durationMs: info.durationMs,
            fileModifiedMs: src.lastModifiedSync().millisecondsSinceEpoch,
          ),
        ),
      ],
      startExtras: {'build_mode': 'debug'},
    );
    _log('VIDEO ${info.width}x${info.height}, ${info.durationMs} ms');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VideoAnalysisScreen(
          initialSessionPath: video.path,
          sessionsDir: sessions,
          models: models,
          identificationChoice: choice,
        ),
      ),
    );
    await waitFor(find.text('Also identify them'));
    final start = find.text('Analyze 1 clip and identify');
    await tester.scrollUntilVisible(start, 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Also identify them'));
    await shot('find_identify_video_start');
    await tester.scrollUntilVisible(start, 300, scrollable: find.byType(Scrollable).first);
    final began = DateTime.now();
    await tester.tap(start);
    await waitFor(find.byType(IdentificationResultsScreen), seconds: 900);
    _log('VIDEO RESULTS after ${DateTime.now().difference(began).inSeconds} s; '
        '${_summaryLine(video)}; detections ${File('${video.path}/${VideoDetector.outputFileName}').existsSync()}');
    await shot('find_identify_video_results');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));

    // 2. Photos: a time-lapse session made from the same clip.
    final (:dir, :photos, :side) = await timeLapseSessionFromClip(src, sessions, 'identify check photos');
    _log('PHOTOS $photos of ${side}px');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: AnalysisScreen(
          initialSessionPath: dir.path,
          sessionsDir: sessions,
          models: models,
          identificationChoice: await IdentificationChoice.load(modelName: _idModel),
        ),
      ),
    );
    await waitFor(find.text('Also identify them'));
    final startPhotos = find.text('Analyze $photos photos and identify');
    await tester.scrollUntilVisible(startPhotos, 300, scrollable: find.byType(Scrollable).first);
    await shot('find_identify_photos_start');
    final began2 = DateTime.now();
    await tester.tap(startPhotos);
    await waitFor(find.byType(IdentificationResultsScreen), seconds: 900);
    _log('PHOTO RESULTS after ${DateTime.now().difference(began2).inSeconds} s; ${_summaryLine(dir)}');
    await shot('find_identify_photos_results');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
