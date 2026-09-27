// FaunaPulse (round 231): on-device check of the summary's Video tab.
//
// Uses the owner's test clips (VID*) already pushed for
// video_decode_check_test.dart (see its header), in video_check/videos/.
// Run:  flutter test integration_test/video_review_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Minutes of playback for the temperature check: --dart-define=REVIEW_SOAK_MIN=5
// Model: a file imported in the app (Settings → AI → models), by default the
// owner's pollinator detector: --dart-define=REVIEW_MODEL=arthropod_yolov11_float16.tflite
// (empty = the bundled yolo26, a COCO model that has no insect class).
//
// Screenshots: the test prints "SHOT <name>" and holds the paused picture for
// a few seconds, so a loop on the computer can grab the screen, e.g.
//   flutter test ... | tee run.log &
//   tail -f run.log | grep --line-buffered -o 'SHOT [a-z0-9_]*' | while read _ n; do
//     adb -s <serial> exec-out screencap -p > "$n.png"; done
//
// Steps:
//  - imports copies of the clips, analyses them at 10 frames per second in a
//    centred square and finds the visits;
//  - opens the real summary: the Video tab plays each clip; paused inside a
//    visit, in both views (SHOT: the boxes must sit on the insect);
//  - 4× playback: how long Flutter's frames take while the boxes move;
//  - battery temperature before and after REVIEW_SOAK_MIN minutes of playback;
//  - "Change square and analyse again": while "Run AI on videos" is open the
//    clips are analysed again with another square; back on the tab, the new
//    square and visits show (SHOT).
// The import stays in video_review_check/ for `adb pull`.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_box_timeline.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/video_review_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:video_player/video_player.dart';

const _soakMin = int.fromEnvironment('REVIEW_SOAK_MIN', defaultValue: 5);
const _model = String.fromEnvironment('REVIEW_MODEL', defaultValue: 'arthropod_yolov11_float16.tflite');

// ignore: avoid_print
void _log(String s) => print(s);

String _box(TimelineBox b) =>
    '[${[b.box.left, b.box.top, b.box.right, b.box.bottom].map((v) => v.toStringAsFixed(3)).join(', ')}] '
    '${b.className} ${b.confidence.toStringAsFixed(2)}${b.trackId == null ? '' : ' #${b.trackId}'}';

Future<String> _modelPath() async {
  if (_model.isEmpty) return kLocalYolo26ModelPath;
  final f = File('${(await ModelCatalog.modelsDir()).path}/$_model');
  expect(f.existsSync(), isTrue, reason: 'import $_model in the app first');
  return f.path;
}

Future<void> _analyse(Directory dir, List<double> roi, {bool startOver = false}) async {
  final model = await _modelPath();
  final yolo = YOLO(modelPath: model, task: YOLOTask.detect, useMultiInstance: true);
  expect(await yolo.loadModel(), isTrue);
  final run = await VideoDetector(backend: NativeVideoBackend(yolo.instanceId)).run(
    dir,
    config: VideoRunConfig(
      modelPath: model,
      modelName: model.split('/').last,
      confidence: 0.25,
      iou: 0.7,
      useGpu: true,
      analysisFps: 10,
      roi: roi,
    ),
    startOver: startOver,
  );
  await yolo.dispose();
  expect(run.clipsFailed, 0);
  final tracks = await VideoTracker.run(dir, const SessionConfig());
  _log('ANALYSED ${model.split('/').last} roi=$roi frames=${run.framesAnalysed} in ${run.elapsed.inSeconds} s, visits=${tracks.visits}');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Video tab on this phone', (tester) async {
    // Every frame the engine asks for is drawn, as in the app.
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    // 1. Import and analyse.
    final ext = (await getExternalStorageDirectory())!.path;
    final clips = VideoDetector.clipsOf(
      Directory('$ext/video_check'),
    ).where((f) => f.path.split('/').last.startsWith('VID')).toList();
    expect(clips, isNotEmpty, reason: 'push the VID* clips to $ext/video_check/videos first');
    final out = Directory('$ext/video_review_check');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final cache = Directory('${out.path}/cache')..createSync(recursive: true);
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
      _log('CLIP $name ${info.width}x${info.height} rot=${info.rotation} ${info.durationMs} ms');
    }
    final dir = await importVideos(
      sessionsDir: Directory('${out.path}/sessions')..createSync(),
      sessionName: 'review check',
      clips: toImport,
      startExtras: {'build_mode': 'debug'},
    );
    await _analyse(dir, const [0.5, 0.5, 0.7]);
    var timeline = VideoBoxTimeline.readSync(dir.path);
    for (final e in timeline.clips.entries) {
      _log('TIMELINE ${e.key}: ${e.value.analysedFrames} frames, hold ${e.value.holdMs} ms, '
          'visits ${e.value.visits.map((v) => '#${v.trackId} ${v.startMs}-${v.endMs} ${v.className}').join(', ')}');
    }

    // 2. The summary's Video tab.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl')),
      ),
    );
    // The tab's own list (the first Scrollable is the tab pager).
    final list = find.descendant(of: find.byType(VideoReviewPlayer), matching: find.byType(Scrollable)).first;

    Future<void> waitFor(Finder f, {int seconds = 20}) async {
      for (var i = 0; i < seconds * 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (f.evaluate().isNotEmpty) return;
      }
      fail('not found: $f');
    }

    VideoPlayerValue player() => tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller.value;

    // A tap on the picture lands on the tab's tap handler; the box overlay
    // above the VideoPlayer makes the test's hit check warn, hence no warning.
    Future<void> tapVideo() => tester.tap(find.byType(VideoPlayer), warnIfMissed: false);

    // scrollUntilVisible stops once the row is built (it may still be below
    // the screen's edge); ensureVisible brings it fully on screen.
    Future<void> scrollTo(Finder f, double delta) async {
      await tester.scrollUntilVisible(f, delta, scrollable: list);
      await tester.ensureVisible(f);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> tapTooltip(String t) async {
      await tester.tap(find.byTooltip(t));
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> shot(String name) async {
      await scrollTo(find.byType(VideoPlayer), -300);
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 4));
    }

    Future<void> view(String label) async {
      await scrollTo(find.text(label), 200);
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 300));
    }

    await waitFor(find.text('Video'));
    final names = timeline.clips.keys.toList()..sort();
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      final boxes = timeline.clips[name]!;
      if (i > 0) {
        await tester.scrollUntilVisible(find.byType(DropdownButton<int>), -300, scrollable: list);
        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.textContaining(name).last);
        await tester.pump(const Duration(milliseconds: 500));
      }
      await waitFor(find.byTooltip('Play'));
      final v = player();
      _log('PLAYER $name ${v.size.width.round()}x${v.size.height.round()} aspect '
          '${v.aspectRatio.toStringAsFixed(3)} rot=${v.rotationCorrection} ${v.duration.inMilliseconds} ms');

      // Paused inside the first visit (or on the first frame with a box).
      final visit = boxes.visits.isEmpty ? null : boxes.visits.first;
      if (visit != null) {
        await tapTooltip('Next visit');
        await tapTooltip('Play');
        await tester.pump(Duration(milliseconds: 1000 + (visit.endMs - visit.startMs) ~/ 2));
        await tapTooltip('Pause');
        await tester.pump(const Duration(milliseconds: 600));
        final at = player().position.inMilliseconds;
        _log('PAUSED $name at $at ms (visit #${visit.trackId} ${visit.startMs}-${visit.endMs}): '
            'tracked ${boxes.trackedAt(at).map(_box).join('; ')} | raw ${boxes.rawAt(at).map(_box).join('; ')}');
      } else {
        _log('NO VISIT in $name');
      }
      await shot('${i}_whole');
      if (boxes.areaFor(player().aspectRatio) != null) {
        await view('What the AI saw');
        await shot('${i}_ai');
        await view('Whole frame');
      }

      // 4× playback: Flutter frame times while the boxes move.
      await scrollTo(find.text('4×'), 200);
      await tester.tap(find.text('4×'));
      await tester.pump(const Duration(milliseconds: 200));
      await scrollTo(find.byType(VideoPlayer), -300);
      // From the start, so 5 s at 4× does not run into the clip's end.
      await tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller.seekTo(Duration.zero);
      await tester.pump(const Duration(milliseconds: 500));
      final from = player().position.inMilliseconds;
      final timings = <FrameTiming>[];
      void onTimings(List<FrameTiming> t) => timings.addAll(t);
      SchedulerBinding.instance.addTimingsCallback(onTimings);
      await tapVideo();
      await tester.pump(const Duration(seconds: 5));
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      final to = player().position.inMilliseconds;
      if (player().isPlaying) await tapVideo();
      await tester.pump(const Duration(milliseconds: 300));
      int pct(List<int> us, double p) => us.isEmpty ? 0 : (us..sort())[((us.length - 1) * p).round()];
      final build = [for (final t in timings) t.buildDuration.inMicroseconds];
      final raster = [for (final t in timings) t.rasterDuration.inMicroseconds];
      final slow = timings.where((t) => t.totalSpan.inMicroseconds > 16667).length;
      _log('4x $name: video $from → $to ms in 5 s; ${timings.length} frames, build p50/p90 ${pct(build, .5)}/${pct(build, .9)} us, '
          'raster p50/p90 ${pct(raster, .5)}/${pct(raster, .9)} us, over 16.7 ms: $slow');
      await scrollTo(find.text('1×'), 200);
      await tester.tap(find.text('1×'));
      await tester.pump(const Duration(milliseconds: 200));
    }

    // 3. Battery temperature over a few minutes of playback (1×, looping).
    if (_soakMin > 0) {
      await scrollTo(find.byType(VideoPlayer), -300);
      final t0 = await DeviceThermal.read();
      _log('SOAK start ${t0.toJson()}');
      final end = DateTime.now().add(const Duration(minutes: _soakMin));
      var next = DateTime.now().add(const Duration(minutes: 1));
      var starts = 0, playedS = 0;
      while (DateTime.now().isBefore(end)) {
        if (!player().isPlaying) {
          await tapVideo();
          starts++;
        }
        await tester.pump(const Duration(seconds: 1));
        if (player().isPlaying) playedS++;
        if (DateTime.now().isAfter(next)) {
          next = next.add(const Duration(minutes: 1));
          _log('SOAK ${(await DeviceThermal.read()).toJson()}');
        }
      }
      if (player().isPlaying) await tapVideo();
      _log('SOAK playing $playedS of ${_soakMin * 60} s, started $starts times');
      final t1 = await DeviceThermal.read();
      _log('SOAK end ${t1.toJson()}');
    }

    // 4. Change the square and analyse again, then back to the tab.
    await scrollTo(find.text('Change square and analyse again'), 200);
    await tester.tap(find.text('Change square and analyse again'));
    await waitFor(find.byType(VideoAnalysisScreen));
    await _analyse(dir, const [0.45, 0.4, 0.5], startOver: true);
    timeline = VideoBoxTimeline.readSync(dir.path);
    Navigator.of(tester.element(find.byType(VideoAnalysisScreen))).pop();
    // The list is still scrolled down to the button: the picture may not be built.
    await waitFor(find.byType(VideoPlayer, skipOffstage: false));
    await tester.pump(const Duration(seconds: 1));
    await scrollTo(find.byType(VideoPlayer), -300);
    final shown = timeline.clips[names.last]!;
    _log('AFTER re-analysis ${names.last}: ${shown.visits.length} visits, area ${shown.areaFor(player().aspectRatio)}');
    if (shown.visits.isNotEmpty) {
      expect(find.text('Visits in this clip (${shown.visits.length})', skipOffstage: false), findsOneWidget);
    }
    await shot('after_reanalysis');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
