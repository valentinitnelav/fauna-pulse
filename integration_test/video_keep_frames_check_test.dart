// FaunaPulse (round 234): on-device check of the frames kept of each visit
// found in videos.
//
// Uses the owner's test clips (VID*) already pushed for
// video_decode_check_test.dart (see its header), in video_check/videos/.
// Run:  flutter test integration_test/video_keep_frames_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Model: as in video_review_check_test.dart (--dart-define=REVIEW_MODEL=...).
// Identification: the BioCLIP model and a label pack imported in the app
// (--dart-define=KEEP_PACK=<file>.fpack, default the first one found); the
// identification steps are left out when there is none.
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
//
// Steps:
//  - imports copies of the clips, analyses them as the screen does (15
//    frames per second, whole picture) and finds the visits keeping a frame
//    every 1 s for up to 10 s; the count must stay within
//    visits × (1 + 10 / 1) and every visit must have a frame;
//  - saves them with the phone's decoder: every file there, the size of the
//    analysed area, and a few saved again directly must come back at exactly
//    the wanted time stamp with the same bytes;
//  - stops a save half way and continues it: same files;
//  - finds the visits again every 2 s: the frames no longer kept are gone,
//    the others untouched;
//  - identification on the kept frames; after finding the visits again the
//    next run starts over under the new visit numbers;
//  - the summary's Video tab: the kept frames under the player, "Show in
//    video" moves the player to the frame (SHOT).
// The session stays in video_keep_frames_check/ for `adb pull`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_frame_keeper.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/video_review_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:video_player/video_player.dart';

const _model = String.fromEnvironment('REVIEW_MODEL', defaultValue: 'arthropod_yolov11_float16.tflite');
const _pack = String.fromEnvironment('KEEP_PACK');

// ignore: avoid_print
void _log(String s) => print(s);

Future<String> _modelPath() async {
  if (_model.isEmpty) return kLocalYolo26ModelPath;
  final f = File('${(await ModelCatalog.modelsDir()).path}/$_model');
  expect(f.existsSync(), isTrue, reason: 'import $_model in the app first');
  return f.path;
}

String _ms(Duration d) => '${d.inMilliseconds} ms';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('kept frames on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    // 1. Import, analyse, find visits keeping frames.
    final ext = (await getExternalStorageDirectory())!.path;
    final clips = VideoDetector.clipsOf(
      Directory('$ext/video_check'),
    ).where((f) => f.path.split('/').last.startsWith('VID')).toList();
    expect(clips, isNotEmpty, reason: 'push the VID* clips to $ext/video_check/videos first');
    final out = Directory('$ext/video_keep_frames_check');
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
      sessionName: 'keep frames check',
      clips: toImport,
      startExtras: {'build_mode': 'debug'},
    );
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
      ),
      thermalLimitC: 45,
    );
    await yolo.dispose();
    expect(run.clipsFailed, 0);
    _log('ANALYSED ${run.framesAnalysed} frames in ${run.elapsed.inSeconds} s');

    const every1 = KeepFramesSettings(stepSeconds: 1, durationSeconds: 10);
    var track = await VideoTracker.run(dir, const SessionConfig(), keep: every1);
    var kept = await VideoTracker.readKeptFrames(dir);
    final visitIds = <int>{
      for (final l in File('${dir.path}/${VideoTracker.outputFileName}').readAsLinesSync())
        if (l.startsWith('{"type":"track_event"')) ((jsonDecode(l) as Map)['track_id'] as num).toInt(),
    };
    final withFrame = {for (final k in kept) ...k.trackIds};
    _log('FIND VISITS ${track.visits} visits, ${track.keptFrames} frames kept '
        '(at most ${track.visits * 11}), track ids with a frame ${withFrame.length}, in ${_ms(track.elapsed)}');
    expect(track.visits, greaterThan(0), reason: 'the clips must show an insect');
    expect(kept, hasLength(track.keptFrames));
    expect(track.keptFrames, lessThanOrEqualTo(track.visits * 11));
    expect(withFrame.difference(visitIds), isEmpty);

    // 2. Save them.
    final framesDir = VideoFrameKeeper.framesDirOf(dir).path;
    var r = await const VideoFrameKeeper().run(dir);
    _log('SAVE ${r.saved} saved, ${r.missing} missing, ${r.failed} failed in ${_ms(r.elapsed)} '
        '(${(r.elapsed.inMilliseconds / r.saved).toStringAsFixed(0)} ms per frame)');
    expect([r.saved, r.missing, r.failed, r.cancelled], [kept.length, 0, 0, false]);
    expect((await VideoFrameKeeper.status(dir)).remaining, 0);
    var bytes = 0;
    for (final k in kept) {
      final f = File('$framesDir/${k.file}');
      final data = f.readAsBytesSync();
      bytes += data.length;
      final info = img.JpegDecoder().startDecode(data)!;
      expect([info.width, info.height], [k.roiPx[2], k.roiPx[3]], reason: k.file);
    }
    _log('FILES ${kept.length}, ${(bytes / kept.length / 1024).toStringAsFixed(0)} KB each on average');

    // The wanted moment, exactly: a few again, straight from the decoder.
    final first = kept.first.clip;
    final sample = [for (final k in kept.where((k) => k.clip == first)) k].take(4).toList();
    final again = Directory('${out.path}/again')..createSync();
    await VideoFrameSource.openFrames('${dir.path}/videos/$first', roiPx: sample.first.roiPx);
    final chunk = await VideoFrameSource.saveFrames(
      ptsUs: [for (final k in sample) k.ptsUs],
      paths: [for (final k in sample) '${again.path}/${k.file}'],
    );
    await VideoFrameSource.close();
    expect(chunk.processed, sample.length);
    for (final s in chunk.saved) {
      final k = sample[s.index];
      expect(s.ptsUs, k.ptsUs, reason: 'saved at the wanted time stamp');
      expect(
        File('${again.path}/${k.file}').readAsBytesSync(),
        File('$framesDir/${k.file}').readAsBytesSync(),
        reason: '${k.file}: the same picture',
      );
    }
    _log('EXACT ${chunk.saved.length} frames at their time stamps, same bytes');

    // 3. Stop half way, then continue.
    final before = {for (final k in kept) k.file: File('$framesDir/${k.file}').readAsBytesSync()};
    for (final k in kept) {
      File('$framesDir/${k.file}').deleteSync();
    }
    var progress = 0;
    r = await const VideoFrameKeeper().run(
      dir,
      onProgress: (done, total) => progress = done,
      isCancelled: () => progress >= kept.length ~/ 2,
    );
    final halfSaved = r.saved;
    expect(r.cancelled, halfSaved < kept.length);
    r = await const VideoFrameKeeper().run(dir);
    _log('STOP AND CONTINUE $halfSaved then ${r.saved}');
    expect(halfSaved + r.saved, kept.length);
    for (final k in kept) {
      expect(File('$framesDir/${k.file}').readAsBytesSync(), before[k.file], reason: k.file);
    }

    // 4. Find visits again, a frame every 2 s.
    final mtimes = {for (final k in kept) k.file: File('$framesDir/${k.file}').lastModifiedSync()};
    track = await VideoTracker.run(dir, const SessionConfig(), keep: const KeepFramesSettings(stepSeconds: 2, durationSeconds: 10));
    final kept2 = await VideoTracker.readKeptFrames(dir);
    final names2 = {for (final k in kept2) k.file};
    final onDisk = {for (final f in Directory(framesDir).listSync()) f.path.split('/').last};
    _log('EVERY 2 S ${kept2.length} frames kept (was ${kept.length}); ${onDisk.length} files left');
    expect(kept2.length, lessThan(kept.length));
    expect(onDisk.difference(names2), isEmpty, reason: 'frames no longer kept are deleted');
    for (final f in onDisk) {
      expect(File('$framesDir/$f').lastModifiedSync(), mtimes[f], reason: '$f untouched');
    }
    r = await const VideoFrameKeeper().run(dir);
    _log('SAVE AGAIN ${r.saved} new frames in ${_ms(r.elapsed)}');
    expect((await VideoFrameKeeper.status(dir)).remaining, 0);

    // 5. Identification on the kept frames.
    final models = (await IdentificationAssets.listModels()).where((f) => f.path.contains('bioclip')).toList();
    final packs = await IdentificationAssets.listPacks();
    final pack = packs.where((f) => _pack.isEmpty || f.path.endsWith('/$_pack')).firstOrNull;
    if (models.isEmpty || pack == null) {
      _log('IDENTIFY skipped: no BioCLIP model or pack imported');
    } else {
      final bioclip = models.first;
      final info = await ImageEmbedder.load(bioclip.path, useGpu: true);
      final name = bioclip.path.split('/').last;
      final settings = IdentifyRunSettings(
        modelName: name,
        modelId: stemOf(name),
        packName: pack.path.split('/').last,
        inputSize: info.inputWidth,
        dim: info.dim,
        accelerator: info.accelerator,
      );
      final job = IdentificationJob(
        embed: (List<Uint8List> rgb) async {
          final b = await ImageEmbedder.embed(rgb);
          return [for (var i = 0; i < b.count; i++) Float32List.fromList(b.vector(i))];
        },
      );
      Future<(IdentifyResult, Map)> identify() async {
        final res = await job.run(dir, settings: settings, packFile: pack);
        expect(res.error, isNull);
        final summary = jsonDecode(
          IdentificationPaths(dir).summaryJson(stemOf(pack.path.split('/').last)).readAsStringSync(),
        ) as Map;
        return (res, summary);
      }

      var (res, summary) = await identify();
      final runId = (await VideoTracker.readSummary(dir))!.runId;
      _log('IDENTIFY ${info.accelerator}: ${res.planned} crops planned, ${res.embedded} embedded, '
          '${res.skipped} skipped in ${res.elapsed.inSeconds} s; ${summary['tracks_total']} track ids, '
          'capture ${summary['capture']}');
      for (final t in (summary['tracks'] as List).take(10)) {
        _log('  #${t['track_id']} ${t['headline']} (${t['identified_rank']}) p=${t['p']} crops=${t['n_crops']}');
      }
      expect(res.embedded, greaterThan(0));
      expect((summary['capture'] as Map)['visits_run_id'], runId);
      expect((summary['capture'] as Map)['photo_step_s'], 2.0);

      track = await VideoTracker.run(dir, const SessionConfig(), keep: every1);
      await const VideoFrameKeeper().run(dir);
      (res, summary) = await identify();
      _log('IDENTIFY AFTER FINDING AGAIN: ${res.resumedDone} continued, ${res.embedded} embedded');
      expect(res.resumedDone, 0);
      expect((summary['capture'] as Map)['visits_run_id'], (await VideoTracker.readSummary(dir))!.runId);
      await ImageEmbedder.close();
    }

    // 6. The Video tab.
    kept = await VideoTracker.readKeptFrames(dir);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl')),
      ),
    );
    final list = find.descendant(of: find.byType(VideoReviewPlayer), matching: find.byType(Scrollable)).first;
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

    await waitFor(find.byType(VideoPlayer));
    await tester.scrollUntilVisible(find.text('Kept frames'), 300, scrollable: list);
    await waitFor(find.text('Show in video'));
    final showing = find.textContaining(RegExp(r'^Showing \d+ of \d+ kept frames'));
    await tester.scrollUntilVisible(showing, 200, scrollable: list);
    _log('TAB ${(tester.widget<Text>(showing)).data}');
    expect((tester.widget<Text>(showing)).data, contains('of ${kept.length} kept frames'));
    await tester.scrollUntilVisible(find.text('Show in video').first, 200, scrollable: list);
    await tester.ensureVisible(find.text('Show in video').first);
    await shot('keep_viewer');

    // The viewer's first picture: its info row names the clip and moment.
    final at = find.textContaining(RegExp(r' at \d+:\d\d\.\d$'));
    final inVideo = at.evaluate().isEmpty ? null : (tester.widget<Text>(at.first)).data;
    await tester.tap(find.text('Show in video').first);
    await tester.pump(const Duration(seconds: 1));
    final value = tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller.value;
    _log('SHOW IN VIDEO ${inVideo ?? ''} → player at ${value.position.inMilliseconds} ms, playing ${value.isPlaying}');
    expect(value.isPlaying, isFalse);
    expect(
      kept.map((k) => k.ptsUs ~/ 1000),
      contains(inInclusiveRange(value.position.inMilliseconds - 50, value.position.inMilliseconds + 50)),
      reason: 'the player shows a kept frame\'s moment',
    );
    // (The box overlay covers the VideoPlayer itself for hit tests.)
    expect(find.byTooltip('Play').hitTestable(), findsOneWidget, reason: 'scrolled back to the player');
    await shot('keep_show_in_video');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
