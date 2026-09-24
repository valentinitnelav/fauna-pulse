import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoChunk, VideoFrameBoxes, VideoInfo;

/// Fake decoder: each clip has frames every 100 ms; a chunk is 3 frames.
class FakeBackend implements VideoBackend {
  final Map<String, int> frameCounts;
  final Set<String> unsupported;
  final opens = <String, int>{};
  List<int> _pts = const [];
  var _i = 0;

  FakeBackend(this.frameCounts, {this.unsupported = const {}});

  String _name(String path) => path.split('/').last;

  @override
  Future<VideoInfo> info(String path) async => VideoInfo(
    durationMs: frameCounts[_name(path)]! * 100,
    firstPtsUs: 0,
    frameCount: frameCounts[_name(path)]!,
    creationEpochMs: 5000000,
    unsupportedReason: unsupported.contains(_name(path)) ? 'This video is 10-bit / HDR.' : null,
  );

  @override
  Future<void> open(String path, VideoRunConfig config, {required int startPtsUs}) async {
    opens[_name(path)] = startPtsUs;
    _pts = [for (var i = 0; i < frameCounts[_name(path)]!; i++) i * 100000].where((p) => p >= startPtsUs).toList();
    _i = 0;
  }

  @override
  Future<VideoChunk> next() async {
    final end = (_i + 3).clamp(0, _pts.length);
    final frames = [
      for (var k = _i; k < end; k++)
        VideoFrameBoxes(_pts[k], _pts[k] ~/ 100000, [
          [0.1, 0.2, 0.3, 0.4, 0.9, 0],
        ]),
    ];
    _i = end;
    return VideoChunk(frames: frames, done: _i >= _pts.length, decoded: frames.length, names: const ['insect']);
  }

  @override
  Future<void> close() async {}
}

const config = VideoRunConfig(modelPath: 'm.tflite', modelName: 'M', confidence: 0.25, iou: 0.5, useGpu: false, analysisFps: 10);

List<Map<String, dynamic>> records(Directory dir) => File('${dir.path}/${VideoDetector.outputFileName}')
    .readAsLinesSync()
    .map((l) => (jsonDecode(l) as Map).cast<String, dynamic>())
    .toList();

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('video_detector_test');
    Directory('${dir.path}/videos').createSync();
    for (final n in ['a.mp4', 'b.MOV', 'notes.txt']) {
      File('${dir.path}/videos/$n').writeAsStringSync('x');
    }
  });
  tearDown(() => dir.deleteSync(recursive: true));

  VideoDetector detector(FakeBackend b, {double temp = 30}) =>
      VideoDetector(backend: b, thermal: () async => ThermalReading(batteryTempC: temp), pausePoll: Duration.zero);

  test('writes raw_detections per frame, timed from the logged clip start', () async {
    File('${dir.path}/session.jsonl').writeAsStringSync(
      '${jsonEncode({'type': 'video_clip', 'file': 'videos/a.mp4', 'start_epoch_ms': 1000000})}\n',
    );
    final result = await detector(FakeBackend({'a.mp4': 5, 'b.MOV': 2})).run(dir, config: config);

    expect(result.clipsDone, 2);
    expect(result.framesAnalysed, 7);
    final recs = records(dir);
    expect(recs.first['type'], 'video_run_start');
    expect(recs.first['settings']['analysis_fps'], 10);
    final raws = recs.where((r) => r['type'] == 'raw_detections').toList();
    expect(raws.first['frame_ms'], 1000000);
    expect(raws[1]['frame_ms'], 1000100);
    expect(raws[1]['frame'], 1);
    expect(raws.first['boxes'], [
      [0.1, 0.2, 0.3, 0.4, 0.9, 0],
    ]);
    final starts = recs.where((r) => r['type'] == 'video_clip_start').toList();
    expect(starts.map((r) => r['start_time_source']), ['session_log', 'metadata']);
    // The stored time is when filming stopped: the start is 0.2 s before it.
    expect(starts[1]['start_epoch_ms'], 5000000 - 200);
    expect(recs.where((r) => r['type'] == 'video_clip_done').map((r) => r['class_names']), everyElement(['insect']));
    expect(recs.last['type'], 'video_run_end');
    expect(recs.last['ended_normally'], isTrue);
  });

  test('a cancelled run resumes after the last analysed frame and skips finished clips', () async {
    var chunks = 0;
    final first = await detector(FakeBackend({'a.mp4': 2, 'b.MOV': 8})).run(
      dir,
      config: config,
      onProgress: (_) => chunks++,
      isCancelled: () => chunks >= 2, // a.mp4 in one chunk, b.MOV one chunk
    );
    expect(first.cancelled, isTrue);
    expect(first.clipsDone, 1);

    final backend = FakeBackend({'a.mp4': 2, 'b.MOV': 8});
    final second = await detector(backend).run(dir, config: config);
    expect(second.cancelled, isFalse);
    expect(backend.opens.keys, ['b.MOV']);
    expect(backend.opens['b.MOV'], 200000 + config.minIntervalUs);
    final bPts = records(dir).where((r) => r['type'] == 'raw_detections' && r['clip'] == 'b.MOV').map((r) => r['pts_us']);
    expect(bPts, [for (var i = 0; i < 8; i++) i * 100000]);
  });

  test('other settings need startOver, which replaces the file', () async {
    await detector(FakeBackend({'a.mp4': 2, 'b.MOV': 2})).run(dir, config: config);
    const changed = VideoRunConfig(modelPath: 'm.tflite', modelName: 'M', confidence: 0.4, iou: 0.5, useGpu: false, analysisFps: 10);
    expect(
      () => detector(FakeBackend({'a.mp4': 2, 'b.MOV': 2})).run(dir, config: changed),
      throwsA(isA<VideoSettingsChanged>()),
    );
    await detector(FakeBackend({'a.mp4': 2, 'b.MOV': 2})).run(dir, config: changed, startOver: true);
    final recs = records(dir);
    expect(recs.where((r) => r['type'] == 'video_run_start'), hasLength(1));
    expect(recs.first['started_over'], isTrue);
    expect(recs.where((r) => r['type'] == 'raw_detections'), hasLength(4));
  });

  test('an unreadable clip is logged and retried next run; the others finish', () async {
    final result = await detector(FakeBackend({'a.mp4': 2, 'b.MOV': 2}, unsupported: {'a.mp4'})).run(dir, config: config);
    expect(result.clipsFailed, 1);
    expect(result.clipsDone, 1);
    final err = records(dir).firstWhere((r) => r['type'] == 'video_clip_error');
    expect(err['clip'], 'a.mp4');
    expect(err['error'], contains('10-bit'));

    final backend = FakeBackend({'a.mp4': 2, 'b.MOV': 2});
    await detector(backend).run(dir, config: config);
    expect(backend.opens.keys, ['a.mp4']);
  });

  test('a warm phone pauses with a plain-language note, then continues', () async {
    var reads = 0;
    final notes = <String>[];
    final d = VideoDetector(
      backend: FakeBackend({'a.mp4': 2, 'b.MOV': 2}),
      thermal: () async => ThermalReading(batteryTempC: ++reads <= 2 ? 45 : 30),
      pausePoll: Duration.zero,
    );
    final result = await d.run(dir, config: config, onProgress: (p) => notes.add(p.note));
    expect(result.thermalPauses, 1);
    expect(result.framesAnalysed, 4);
    expect(notes.first, contains('Phone warm'));
    expect(records(dir).last['thermal_pauses'], 1);
  });
}
