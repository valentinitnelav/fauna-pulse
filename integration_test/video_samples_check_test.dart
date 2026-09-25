// FaunaPulse (round 232): on-device check of the phone samples written while
// the AI runs on videos (temperature, power, speed), their graphs and
// phone_during_analysis.csv.
//
// Uses one of the owner's clips already pushed for video_decode_check_test.dart
// (see its header), in video_check/videos/, by default the 47.8 MB recording:
// --dart-define=SAMPLES_CLIP=VID_20260924_155954.mp4
// Run:  flutter test integration_test/video_samples_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Model: as in video_review_check_test.dart (--dart-define=REVIEW_MODEL=...).
// Screenshots: "SHOT <name>" lines, grabbed as in video_review_check_test.dart.
//
// Steps, as a user would take them:
//  - the clip is analysed at every frame (30 per second, the screen's
//    highest), so the runs last long enough for a few samples;
//  - run 1 (measure every 5 s) is stopped after 6 s;
//  - run 2 (Continue) with the pause limit 1 °C below the battery's
//    temperature now: a real cooling pause from the first reading, stopped
//    after PAUSE_S seconds (cooling 3 °C would take much longer);
//  - run 3 (Continue, measure every 10 s) finishes the clip;
//  - checks the records: a sample every 5 / 10 s also while paused, the three
//    records of one sample share their time, and run 3's mean detector ms per
//    frame matches its video_clip_done;
//  - Find visits, Share results: the zip holds phone_during_analysis.csv;
//  - the summary's Graphs tab (SHOT graphs_*).
// The session and a copy of the CSV stay in video_samples_check/ for `adb pull`.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_run_samples.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

const _clip = String.fromEnvironment('SAMPLES_CLIP', defaultValue: 'VID_20260924_155954.mp4');
const _model = String.fromEnvironment('REVIEW_MODEL', defaultValue: 'arthropod_yolov11_float16.tflite');
const _pauseS = int.fromEnvironment('PAUSE_S', defaultValue: 45);

// ignore: avoid_print
void _log(String s) => print(s);

Future<String> _modelPath() async {
  if (_model.isEmpty) return kLocalYolo26ModelPath;
  final f = File('${(await ModelCatalog.modelsDir()).path}/$_model');
  expect(f.existsSync(), isTrue, reason: 'import $_model in the app first');
  return f.path;
}

List<Map<String, dynamic>> _records(Directory dir) => [
  for (final line in File('${dir.path}/${VideoDetector.outputFileName}').readAsLinesSync())
    if (!line.startsWith('{"type":"raw_detections"')) (jsonDecode(line) as Map).cast<String, dynamic>(),
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone samples while the AI runs on a video', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    // 1. Import a copy of the clip.
    final ext = (await getExternalStorageDirectory())!.path;
    final src = File('$ext/video_check/videos/$_clip');
    expect(src.existsSync(), isTrue, reason: 'push $_clip to $ext/video_check/videos first');
    final out = Directory('$ext/video_samples_check');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final cache = Directory('${out.path}/cache')..createSync(recursive: true);
    final info = await VideoFrameSource.info(src.path);
    final copy = src.copySync('${cache.path}/$_clip');
    final bytes = copy.lengthSync(); // the import moves the copy
    final dir = await importVideos(
      sessionsDir: Directory('${out.path}/sessions')..createSync(),
      sessionName: 'samples check',
      clips: [
        ImportClip(
          path: copy.path,
          name: _clip,
          sizeBytes: bytes,
          info: info,
          guess: guessClipStart(
            fileName: _clip,
            storedMs: info.creationEpochMs,
            durationMs: info.durationMs,
            fileModifiedMs: src.lastModifiedSync().millisecondsSinceEpoch,
          ),
        ),
      ],
      startExtras: {'build_mode': 'debug'},
    );
    _log('CLIP $_clip ${info.width}x${info.height} ${info.durationMs} ms $bytes bytes');

    // 2. Three runs, as the screen starts them (its settings, every frame).
    final model = await _modelPath();
    final yolo = YOLO(modelPath: model, task: YOLOTask.detect, useMultiInstance: true);
    expect(await yolo.loadModel(), isTrue);
    final config = VideoRunConfig(
      modelPath: model,
      modelName: model.split('/').last,
      confidence: 0.25,
      iou: 0.7,
      useGpu: true,
      analysisFps: 30,
    );
    Future<VideoRunResult> run(String name, {required double limitC, required int everyS, Duration? stopAfter}) async {
      final started = DateTime.now();
      final r = await VideoDetector(backend: NativeVideoBackend(yolo.instanceId)).run(
        dir,
        config: config,
        thermalLimitC: limitC,
        sampleEvery: Duration(seconds: everyS),
        isCancelled: stopAfter == null ? null : () => DateTime.now().difference(started) > stopAfter,
      );
      _log('RUN $name limit $limitC °C every $everyS s: ${r.framesAnalysed} frames in ${r.elapsed.inSeconds} s, '
          'pauses ${r.thermalPauses}, cancelled ${r.cancelled}');
      return r;
    }

    _log('THERMAL before ${(await DeviceThermal.read()).toJson()}');
    final r1 = await run('1 (stopped)', limitC: 45, everyS: 5, stopAfter: const Duration(seconds: 6));
    expect(r1.cancelled, isTrue);
    final now = (await DeviceThermal.read()).batteryTempC;
    expect(now, isNotNull, reason: 'the battery temperature is needed to force a pause');
    final r2 = await run('2 (forced pause)', limitC: now! - 1, everyS: 5, stopAfter: const Duration(seconds: _pauseS));
    expect(r2.thermalPauses, 1);
    final r3 = await run('3 (continue)', limitC: 45, everyS: 10);
    expect(r3.clipsDone, 1);
    await yolo.dispose();

    // 3. The records.
    final recs = _records(dir);
    final runs = <List<Map<String, dynamic>>>[];
    for (final r in recs) {
      if (r['type'] == 'video_run_start') runs.add([]);
      runs.last.add(r);
    }
    expect(runs.length, 3);
    for (var i = 0; i < runs.length; i++) {
      final every = runs[i].first['sample_s'] as int;
      final byType = <String, List<int>>{};
      for (final r in runs[i]) {
        (byType[r['type'] as String] ??= []).add(r['time_ms'] as int);
      }
      final thermal = byType['thermal'] ?? [];
      final gaps = [for (var k = 1; k < thermal.length; k++) thermal[k] - thermal[k - 1]];
      _log('RUN ${i + 1} every $every s: ${thermal.length} samples, gaps ms $gaps');
      expect(byType['power'], thermal, reason: 'power at every thermal time');
      expect(thermal, containsAll(byType['analysis_speed'] ?? <int>[]));
      // One chunk's time late at most; the final sample may come early.
      for (final g in gaps) {
        expect(g, lessThan(every * 1000 + 3000));
      }
      for (final r in runs[i].where((r) => r['type'] == 'analysis_speed' || r['type'].toString().startsWith('video_thermal'))) {
        _log('  ${r['type']} ${jsonEncode({...r}..remove('type'))}');
      }
    }

    // Run 3: the samples' detector ms per frame, weighted by frames, against
    // the clip's totals.
    final speed = runs[2].where((r) => r['type'] == 'analysis_speed' && (r['frames'] as int) > 0);
    final done = runs[2].firstWhere((r) => r['type'] == 'video_clip_done');
    final frames = speed.fold<int>(0, (a, r) => a + (r['frames'] as int));
    expect(frames, done['frames_analysed']);
    for (final (k, total) in [('detect_ms', 'infer_ms'), ('decode_ms', 'decode_ms'), ('convert_ms', 'convert_ms')]) {
      final fromSamples = speed.fold<double>(0, (a, r) => a + (r[k] as num) * (r['frames'] as int)) / frames;
      final fromClip = (done[total] as num) / (done['frames_analysed'] as num);
      _log('MEAN $k: samples ${fromSamples.toStringAsFixed(2)} vs video_clip_done ${fromClip.toStringAsFixed(2)} ms per frame');
      expect(fromSamples, closeTo(fromClip, 0.1 + fromClip * 0.01));
    }

    final samples = (await VideoRunSamples.read(File('${dir.path}/${VideoDetector.outputFileName}')))!;
    _log('SAMPLES runs ${samples.runs}, total ${samples.totalMs} ms, running ${samples.runMs} ms, paused '
        '${samples.pausedMs} ms, frames ${samples.frames}, ${samples.meanFramesPerS?.toStringAsFixed(2)} fps, '
        'every ${samples.sampleSeconds}, gap ${samples.runGapMs} ms, pauses ${samples.pauses}');
    expect(samples.runs, 3);
    expect(samples.pauses.length, 1);
    expect(samples.frames, r1.framesAnalysed + r2.framesAnalysed + r3.framesAnalysed);

    // 4. Find visits and Share results.
    final tracks = await VideoTracker.run(dir, const SessionConfig());
    final zipPath = '${out.path}/results.zip';
    expect(await VideoTracker.writeResultsZip(dir.path, zipPath), zipPath);
    final zipped = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync()).findFile(VideoRunSamples.csvFileName);
    expect(zipped, isNotNull);
    final csv = utf8.decode(zipped!.content as List<int>);
    expect(csv, samples.toCsv());
    File('${out.path}/${VideoRunSamples.csvFileName}').writeAsStringSync(csv);
    _log('ZIP visits ${tracks.visits}, ${VideoRunSamples.csvFileName} ${csv.split('\n').length - 2} rows');
    _log('CSV\n$csv');

    // 5. The summary's Graphs tab, extra graphs open (the phone's own
    // choice is put back afterwards).
    final prefs = await SharedPreferences.getInstance();
    final expandedBefore = prefs.getBool('extra_graphs_expanded');
    await prefs.setBool('extra_graphs_expanded', true);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'), initialTabIndex: 1),
      ),
    );
    final title = find.text('While the AI ran on the videos', skipOffstage: false);
    for (var i = 0; i < 200 && title.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(title, findsOneWidget);
    final list = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('While the AI ran on the videos'), 300, scrollable: list);
    final position = tester.state<ScrollableState>(list).position;
    var n = 0;
    Future<void> shot() async {
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT graphs_${n++}');
      await tester.pump(const Duration(seconds: 4));
    }

    position.jumpTo(position.pixels - 40);
    await shot();
    while (position.pixels < position.maxScrollExtent) {
      position.jumpTo((position.pixels + 500).clamp(0, position.maxScrollExtent));
      await shot();
    }
    expect(find.text('Not enough samples.'), findsNothing);
    if (expandedBefore == null) {
      await prefs.remove('extra_graphs_expanded');
    } else {
      await prefs.setBool('extra_graphs_expanded', expandedBefore);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
