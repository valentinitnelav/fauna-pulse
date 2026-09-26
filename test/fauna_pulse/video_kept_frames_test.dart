// Tests for the frames kept of each visit found in videos (round 234):
// which frames "Find visits" keeps (the live photo rule), their records in
// post_tracks.jsonl, which files a new run may take over or delete, saving
// them (VideoFrameKeeper, fake decoder), and how the log index and
// identification read them.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show roiPhotoFileName;
import 'package:fauna_pulse/fauna_pulse/identification/crop_worker.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_frame_keeper.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show SavedFramesChunk, SavedVideoFrame;

final s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': 111, ...m});

/// One box `[l, t, r, b, conf, cls]` of a resting insect at [x].
List<num> _box(double x) => [x, 0.40, x + 0.05, 0.48, 0.9, 0];

/// video_detections.jsonl of one clip analysed at 10 fps.
List<String> _clip(
  String name, {
  int durationMs = 20000,
  required List<List<num>> Function(int t) boxesAt,
  List<int>? roiPx,
}) => [
  _rec('video_run_start', {
    'settings': {'model': 'm.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 10, 'roi': null},
  }),
  _rec('video_clip_start', {'clip': name, 'start_epoch_ms': s0, 'width': 1920, 'height': 1080}),
  for (var t = 0; t <= durationMs; t += 100)
    _rec('raw_detections', {'frame_ms': s0 + t, 'clip': name, 'pts_us': t * 1000, 'frame': t * 3 ~/ 100, 'boxes': boxesAt(t)}),
  _rec('video_clip_done', {
    'clip': name,
    'frame_width': 1920,
    'frame_height': 1080,
    'roi_px': roiPx ?? [420, 0, 1080, 1080],
    'class_names': ['bee'],
  }),
];

/// A session with [lines] as its detections and an (empty) video [clip].
Directory _session(List<String> lines, {String clip = 'a.mp4', bool video = true}) {
  final dir = Directory.systemTemp.createTempSync('video_kept_frames_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync('${lines.join('\n')}\n');
  // An imported-video session: no live tracker, the session's name token.
  File('${dir.path}/session.jsonl').writeAsStringSync(
    '${jsonEncode({
      'type': 'start_of_session',
      'time_ms': s0,
      'file_token': 'abc123',
      'config': {'captureTrigger': 'none'},
    })}\n',
  );
  if (video) {
    Directory('${dir.path}/videos').createSync();
    File('${dir.path}/videos/$clip').writeAsStringSync('not really a video');
  }
  return dir;
}

List<Map<String, dynamic>> _records(Directory d, [String? type]) => [
  for (final l in File('${d.path}/${VideoTracker.outputFileName}').readAsLinesSync())
    if (type == null || (jsonDecode(l) as Map)['type'] == type) (jsonDecode(l) as Map).cast<String, dynamic>(),
];

File _frame(Directory d, String name) => File('${d.path}/${VideoTracker.framesDirName}/$name');

/// Two insects sitting for the whole 20 s clip.
List<List<num>> _twoInsects(int t) => [_box(0.2), _box(0.6)];

const _keep = KeepFramesSettings(stepSeconds: 1, durationSeconds: 10);

/// Writes a small file for every frame asked for, as the phone's decoder
/// would; [perCall] limits how many one call deals with.
class _FakeBackend implements FrameSaveBackend {
  final int perCall;
  final bool stall;
  final opened = <String>[];
  final asked = <int>[];
  var closed = 0;
  _FakeBackend({this.perCall = 1000, this.stall = false});

  @override
  Future<void> open(String path, List<int> roiPx) async => opened.add(path.split('/').last);

  @override
  Future<SavedFramesChunk> save(List<int> ptsUs, List<String> paths) async {
    if (stall) return const SavedFramesChunk(saved: [], missing: [], processed: 0);
    final n = ptsUs.length < perCall ? ptsUs.length : perCall;
    for (var i = 0; i < n; i++) {
      File(paths[i]).writeAsStringSync('jpeg ${ptsUs[i]}');
      asked.add(ptsUs[i]);
    }
    return SavedFramesChunk(
      saved: [for (var i = 0; i < n; i++) SavedVideoFrame(i, ptsUs[i], 1080, 1080, 10)],
      missing: const [],
      processed: n,
    );
  }

  @override
  Future<void> close() async => closed++;
}

void main() {
  const config = SessionConfig();

  group('Find visits keeps frames', () {
    test('the first frame of each visit, then one a second for 10 s', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects));
      final result = await VideoTracker.run(dir, config, keep: _keep);
      expect(result.visits, 2);
      // visits × (1 + M/N): the first frame and one at +1 s … +10 s. Both
      // insects are due on the same frames, so each frame is kept once.
      expect(result.keptFrames, 11);

      final start = _records(dir, 'post_track_start').single;
      expect(start['keep_frames'], {'step_seconds': 1.0, 'duration_seconds': 10.0});
      expect(start['file_token'], 'abc123');
      expect(start['run_id'], isA<int>());
      expect(_records(dir, 'post_track_end').single['kept_frames'], 11);

      final captures = _records(dir, 'capture');
      expect(captures, hasLength(11));
      final first = captures.first;
      expect(first['source'], 'video');
      expect(first['clip'], 'a.mp4');
      expect(first['roi_px'], [420, 0, 1080, 1080]);
      expect(first['saved_px'], 1080);
      expect(first['track_ids'], [1, 2]);
      expect(first['file'], roiPhotoFileName(first['captured_at_ms'] as int, 'abc123'));
      final steps = [
        for (var i = 1; i < captures.length; i++) (captures[i]['pts_us'] as int) - (captures[i - 1]['pts_us'] as int),
      ];
      expect(steps, everyElement(1000000));

      // The detections of a kept frame name its file for each visit it was
      // kept for, like a live photo.
      final withJpeg = [
        for (final d in _records(dir, 'detections'))
          for (final t in d['tracks'] as List)
            if ((t as Map)['jpeg'] != null) t,
      ];
      expect(withJpeg, hasLength(22));

      final kept = await VideoTracker.readKeptFrames(dir);
      expect(kept.map((k) => k.file), captures.map((c) => c['file']));
      expect(kept.first.trackIds, [1, 2]);

      final summary = await VideoTracker.readSummary(dir);
      expect(summary!.keep, _keep);
      expect(summary.keptFrames, 11);
      expect(summary.runId, start['run_id']);
    });

    test('a frame wider than tall is saved with its width and height', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects, roiPx: [0, 0, 1920, 1080]));
      await VideoTracker.run(dir, config, keep: _keep);
      final c = _records(dir, 'capture').first;
      expect(c.containsKey('saved_px'), isFalse);
      expect([c['saved_w'], c['saved_h']], [1920, 1080]);
    });

    test('off: no frames, no records', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects));
      final result = await VideoTracker.run(dir, config);
      expect(result.keptFrames, 0);
      expect(_records(dir, 'capture'), isEmpty);
      final start = _records(dir, 'post_track_start').single;
      expect(start['keep_frames'], isNull);
      expect(start.containsKey('file_token'), isFalse);
      expect((await VideoTracker.readSummary(dir))!.keep, isNull);
    });

    test('a file no run kept is never overwritten: the name moves on by 1 ms', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects));
      await VideoTracker.run(dir, config, keep: _keep);
      final firstMs = _records(dir, 'capture').first['captured_at_ms'] as int;
      final taken = roiPhotoFileName(firstMs, 'abc123');
      File('${dir.path}/post_tracks.jsonl').deleteSync();
      _frame(dir, taken)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('a camera photo');

      await VideoTracker.run(dir, config, keep: _keep);
      expect(_records(dir, 'capture').first['file'], roiPhotoFileName(firstMs + 1, 'abc123'));
      expect(_frame(dir, taken).readAsStringSync(), 'a camera photo');
    });

    test('a new run deletes the frames it no longer keeps, unless their video is gone', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects));
      await VideoTracker.run(dir, config, keep: _keep);
      for (final k in await VideoTracker.readKeptFrames(dir)) {
        _frame(dir, k.file)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('saved');
      }
      final before = [for (final k in await VideoTracker.readKeptFrames(dir)) k.file];

      // One every 2 s: the odd seconds go, the rest stay as they are.
      await VideoTracker.run(dir, config, keep: const KeepFramesSettings(stepSeconds: 2, durationSeconds: 10));
      final after = {for (final k in await VideoTracker.readKeptFrames(dir)) k.file};
      expect(after, hasLength(6));
      for (final f in before) {
        expect(_frame(dir, f).existsSync(), after.contains(f), reason: f);
      }

      // Without its video a frame can't be made again: it stays, and a new
      // run doesn't take its name.
      File('${dir.path}/videos/a.mp4').deleteSync();
      await VideoTracker.run(dir, config);
      for (final f in after) {
        expect(_frame(dir, f).readAsStringSync(), 'saved');
      }
    });
  });

  group('VideoFrameKeeper', () {
    test('saves every kept frame once, and a second run has nothing to do', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects));
      await VideoTracker.run(dir, config, keep: _keep);
      expect((await VideoFrameKeeper.status(dir)).remaining, 11);

      final backend = _FakeBackend(perCall: 5);
      final progress = <int>[];
      final r = await VideoFrameKeeper(backend: backend).run(dir, onProgress: (done, total) => progress.add(done));
      expect(r.saved, 11);
      expect(r.failed, 0);
      expect(r.cancelled, isFalse);
      expect(backend.opened, ['a.mp4']);
      expect(backend.closed, 1);
      expect(backend.asked, [for (var s = 0; s <= 10; s++) backend.asked.first + s * 1000000]);
      expect(progress.last, 11);
      final status = await VideoFrameKeeper.status(dir);
      expect([status.total, status.saved, status.remaining], [11, 11, 0]);

      final again = _FakeBackend();
      expect((await VideoFrameKeeper(backend: again).run(dir)).saved, 0);
      expect(again.opened, isEmpty);
    });

    test('Stop keeps what was saved; the next run continues', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects));
      await VideoTracker.run(dir, config, keep: _keep);
      var calls = 0;
      final backend = _FakeBackend(perCall: 4);
      final r = await VideoFrameKeeper(backend: backend).run(dir, isCancelled: () => calls++ >= 2);
      expect(r.cancelled, isTrue);
      expect(r.saved, 4);
      expect(backend.closed, 1);
      expect((await VideoFrameKeeper.status(dir)).saved, 4);

      final rest = _FakeBackend();
      expect((await VideoFrameKeeper(backend: rest).run(dir)).saved, 7);
      expect(rest.asked.first, greaterThan(backend.asked.last));
    });

    test('a missing video or a stuck decoder counts its frames as failed', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects));
      await VideoTracker.run(dir, config, keep: _keep);

      final stuck = _FakeBackend(stall: true);
      final r = await VideoFrameKeeper(backend: stuck).run(dir);
      expect([r.saved, r.failed], [0, 11]);
      expect(stuck.closed, 1);

      File('${dir.path}/videos/a.mp4').deleteSync();
      final status = await VideoFrameKeeper.status(dir);
      expect([status.noVideo, status.remaining], [11, 0]);
      final none = _FakeBackend();
      expect((await VideoFrameKeeper(backend: none).run(dir)).failed, 11);
      expect(none.opened, isEmpty);
    });
  });

  group('readers', () {
    test('the log index shows kept frames as photos of the visits, with clip and moment', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects, roiPx: [0, 0, 1920, 1080]));
      await VideoTracker.run(dir, config, keep: _keep);
      final index = await SessionLogIndex.build(File('${dir.path}/session.jsonl'));
      final kept = await VideoTracker.readKeptFrames(dir);
      final photo = index.photos[kept.first.file]!;
      expect(photo.trackIds, [1, 2]);
      expect(photo.boxes, hasLength(2));
      expect([photo.resW, photo.resH], [1920, 1080]);
      expect(photo.clip, 'a.mp4');
      expect(photo.ptsUs, kept.first.ptsUs);
    });

    test('identification remembers the visits run and starts over after a new one', () async {
      final dir = _session(_clip('a.mp4', boxesAt: _twoInsects));
      Future<void> findVisits() async {
        await Future<void>.delayed(const Duration(milliseconds: 5)); // a new run_id
        await VideoTracker.run(dir, config, keep: _keep);
        final red = img.Image(width: 160, height: 160, numChannels: 3);
        img.fill(red, color: img.ColorRgb8(220, 30, 30));
        final jpeg = img.encodeJpg(red, quality: 90);
        for (final k in await VideoTracker.readKeptFrames(dir)) {
          _frame(dir, k.file)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(jpeg);
        }
      }

      final packFile = File('test/fauna_pulse/fixtures/tiny_pack.fpack');
      final pack = LabelPack.parseBytes(packFile.readAsBytesSync());
      final job = IdentificationJob(
        // Every (red) crop describes pack row 0.
        embed: (rgb) async => [for (final _ in rgb) Float32List.sublistView(pack.matrix, 0, pack.dim)],
        crop: (a) async => cropBatchSync(a),
        thermal: () async => const ThermalReading(batteryTempC: 30),
      );
      const settings = IdentifyRunSettings(
        modelName: 'fake_model.tflite',
        modelId: 'fake',
        packName: 'tiny_pack.fpack',
        inputSize: 32,
        dim: 4,
        accelerator: 'CPU',
        minCropPx: 4,
      );
      Future<(IdentifyResult, int?)> identify() async {
        final r = await job.run(dir, settings: settings, packFile: packFile);
        final summary = jsonDecode(File('${dir.path}/identification/summary_tiny_pack.json').readAsStringSync()) as Map;
        final capture = summary['capture'] as Map;
        expect([capture['photo_step_s'], capture['photo_duration_s']], [1.0, 10.0]);
        return (r, (capture['visits_run_id'] as num?)?.toInt());
      }

      await findVisits();
      final firstRun = (await VideoTracker.readSummary(dir))!.runId;
      var (r, used) = await identify();
      expect(r.error, isNull);
      expect(r.embedded, greaterThan(0));
      expect(used, firstRun);
      final stem = stemOf(settings.modelName);
      final paths = IdentificationPaths(dir);
      expect(EmbeddingIndex.parse(paths.embeddingsJsonl(stem).readAsStringSync()).visitsRunId, firstRun);
      final embedded = r.embedded;

      // Same visits: continued.
      (r, used) = await identify();
      expect([r.resumedDone, r.embedded], [embedded, 0]);

      // Found again: the same pictures, but numbered anew, so every crop is
      // made again under the new numbers.
      await findVisits();
      final secondRun = (await VideoTracker.readSummary(dir))!.runId;
      expect(secondRun, isNot(firstRun));
      (r, used) = await identify();
      expect([r.resumedDone, r.embedded], [0, embedded]);
      expect(used, secondRun);
      expect(EmbeddingIndex.parse(paths.embeddingsJsonl(stem).readAsStringSync()).visitsRunId, secondRun);

      final a = EmbeddingIndex.parse(
        [
          jsonEncode({'type': 'identify_start', 'dim': 4, 'visits_run_id': 17}),
          jsonEncode({'type': 'identify_start', 'dim': 4, 'visits_run_id': 18}),
        ].join('\n'),
      );
      expect(a.visitsRunId, 17);
      expect(EmbeddingIndex.parse(jsonEncode({'type': 'identify_start', 'dim': 4})).visitsRunId, isNull);
    });
  });
}
