// FaunaPulse (round 236): on-device check of "Free storage" (deleting a
// session's videos once their visits are found).
//
// Uses the owner's test clips (VID*) already pushed for
// video_decode_check_test.dart (see its header), in video_check/videos/.
// They are imported as copies into video_cleanup_check/, so only the copies
// are deleted.
// Run:  flutter test integration_test/video_cleanup_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Model: as in video_review_check_test.dart (--dart-define=REVIEW_MODEL=...).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
//
// Steps:
//  - imports copies of the clips, analyses them (15 frames per second, whole
//    picture), finds the visits keeping frames, saves the frames;
//  - "Run AI on videos": the Free storage section (SHOT), "Delete all …"
//    with its confirmation; the files are gone, the session and its visits
//    stay, the start button says the videos were deleted (SHOT);
//  - "Find visits" again from the saved boxes: the same visits, the kept
//    frames untouched;
//  - the summary's Video tab: the deleted clip says so (SHOT).
// The session stays in video_cleanup_check/ for `adb pull`.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/clip_cleanup.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_frame_keeper.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

const _model = String.fromEnvironment('REVIEW_MODEL', defaultValue: 'arthropod_yolov11_float16.tflite');

// ignore: avoid_print
void _log(String s) => print(s);

Future<String> _modelPath() async {
  if (_model.isEmpty) return kLocalYolo26ModelPath;
  final f = File('${(await ModelCatalog.modelsDir()).path}/$_model');
  expect(f.existsSync(), isTrue, reason: 'import $_model in the app first');
  return f.path;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('free storage on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    // 1. Import copies, analyse, find visits, save the kept frames.
    final ext = (await getExternalStorageDirectory())!.path;
    final clips = VideoDetector.clipsOf(
      Directory('$ext/video_check'),
    ).where((f) => f.path.split('/').last.startsWith('VID')).toList();
    expect(clips, isNotEmpty, reason: 'push the VID* clips to $ext/video_check/videos first');
    final out = Directory('$ext/video_cleanup_check');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final cache = Directory('${out.path}/cache')..createSync(recursive: true);
    final sessions = Directory('${out.path}/sessions')..createSync();
    final toImport = <ImportClip>[];
    for (final f in clips) {
      final name = f.path.split('/').last;
      final info = await VideoFrameSource.info(f.path);
      final copy = f.copySync('${cache.path}/$name');
      toImport.add(
        ImportClip(
          path: copy.path,
          name: name,
          sizeBytes: copy.lengthSync(),
          info: info,
          guess: guessClipStart(
            fileName: name,
            storedMs: info.creationEpochMs,
            durationMs: info.durationMs,
            fileModifiedMs: f.lastModifiedSync().millisecondsSinceEpoch,
          ),
        ),
      );
    }
    final dir = await importVideos(
      sessionsDir: sessions,
      sessionName: 'cleanup check',
      clips: toImport,
      startExtras: {'build_mode': 'debug'},
    );
    final model = await _modelPath();
    final yolo = YOLO(modelPath: model, task: YOLOTask.detect, useMultiInstance: true);
    expect(await yolo.loadModel(), isTrue);
    final run = await VideoDetector(backend: NativeVideoBackend(yolo.instanceId)).run(
      dir,
      config: VideoRunConfig(modelPath: model, modelName: model.split('/').last, confidence: 0.25, iou: 0.7, useGpu: true),
      thermalLimitC: 45,
    );
    await yolo.dispose();
    expect(run.clipsFailed, 0);
    const keep = KeepFramesSettings(stepSeconds: 1, durationSeconds: 10);
    final before = await VideoTracker.run(dir, const SessionConfig(), keep: keep);
    final saved = await const VideoFrameKeeper().run(dir);
    final kept = await VideoTracker.readKeptFrames(dir);
    final framesDir = VideoFrameKeeper.framesDirOf(dir).path;
    final bytesBefore = {for (final k in kept) k.file: File('$framesDir/${k.file}').readAsBytesSync()};
    final none = await ClipCleanup.planWithoutVisits(dir);
    final all = await ClipCleanup.planAll(dir);
    _log('READY ${before.visits} visits in ${before.clipsTracked} clips, ${saved.saved} frames saved; '
        'without visits: ${none.deleteNames} (${none.deleteBytes} B); all: ${all.deleteNames.length} clips, '
        '${all.deleteBytes} B');

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

    // 2. "Run AI on videos": Free storage, delete all.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VideoAnalysisScreen(initialSessionPath: dir.path, sessionsDir: sessions),
      ),
    );
    // The session picker at the top (the rest of the list builds as it scrolls).
    await waitFor(find.textContaining('${all.deleteNames.length} analyzed)'));
    final list = find.byType(Scrollable).first;
    final deleteAll = find.textContaining('Delete all ${all.deleteNames.length} clips, keep the saved frames');
    await tester.scrollUntilVisible(deleteAll, 300, scrollable: list);
    await tester.drag(list, const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 300));
    await shot('cleanup_before');
    await tester.scrollUntilVisible(deleteAll, 300, scrollable: list);
    await tester.tap(deleteAll);
    await waitFor(find.text('Delete all videos?'));
    await shot('cleanup_confirm');
    await tester.tap(find.text('Delete ${all.deleteNames.length}'));
    await waitFor(find.text('All ${all.deleteNames.length} videos were deleted.'));
    await tester.pump(const Duration(seconds: 5)); // the snack bar goes
    await shot('cleanup_after');
    expect(VideoDetector.clipsOf(dir), isEmpty);
    await tester.scrollUntilVisible(find.text('The videos were deleted'), -300, scrollable: list);
    final record = File('${dir.path}/session.jsonl').readAsLinesSync().lastWhere((l) => l.contains('"video_cleanup"'));
    _log('RECORD $record');
    expect((jsonDecode(record) as Map)['freed_bytes'], all.deleteBytes);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));

    // 3. Find visits again from the saved boxes.
    final after = await VideoTracker.run(dir, const SessionConfig(), keep: keep);
    final status = await VideoFrameKeeper.status(dir);
    _log('FIND VISITS AGAIN ${after.visits} visits, kept ${after.keptFrames}; frames saved ${status.saved} of '
        '${status.total}, no video ${status.noVideo}');
    expect(after.visits, before.visits);
    for (final e in bytesBefore.entries) {
      expect(File('$framesDir/${e.key}').readAsBytesSync(), e.value, reason: '${e.key} untouched');
    }
    expect(status.remaining, 0);

    // 4. The summary's Video tab.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl')),
      ),
    );
    await waitFor(find.textContaining('to free storage'));
    await shot('cleanup_video_tab');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
