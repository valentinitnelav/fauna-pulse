// Stress run, step P2: seeded mutation fuzzing of the readers of the video
// analysis files: VideoResume.parse, VideoBoxTimeline.parse / readSync /
// readLiveSync, VideoRunSamples.parse / parseFile, VideoDetector.clipRecordsFromLog
// and VideoDetector.isReadableVideo. Rule: no hang, no huge allocation, only a
// clear error type; never an uncaught TypeError / RangeError. A case that
// shows a real bug is kept and marked skip: 'BUG: ...'.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/logging/track_source.dart' show postTracksFileName;
import 'package:fauna_pulse/fauna_pulse/postprocess/video_box_timeline.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_run_samples.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoChunk, VideoFrameBoxes, VideoInfo;

import 'fuzz_helpers.dart';
import 'session_fixture.dart';

/// Fake decoder: every clip has frames every 100 ms; a chunk is 3 frames.
class _Backend implements VideoBackend {
  final Map<String, int> frameCounts;
  List<int> _pts = const [];
  var _i = 0;
  _Backend(this.frameCounts);

  String _name(String path) => path.split('/').last;

  @override
  Future<VideoInfo> info(String path) async =>
      VideoInfo(durationMs: frameCounts[_name(path)]! * 100, firstPtsUs: 0, frameCount: frameCounts[_name(path)]!, creationEpochMs: 5000000);

  @override
  Future<void> open(String path, VideoRunConfig config, {required int startPtsUs}) async {
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
          [0.5, 0.5, 0.6, 0.6, 0.8, 1],
        ]),
    ];
    _i = end;
    return VideoChunk(
      frames: frames,
      done: _i >= _pts.length,
      decoded: frames.length,
      names: const ['bee', 'fly'],
      decodeMs: 3.0 * frames.length,
      convertMs: 1.5 * frames.length,
      inferMs: 20.0 * frames.length,
    );
  }

  @override
  Future<void> close() async {}
}

const _config = VideoRunConfig(
  modelPath: 'models/m.tflite',
  modelName: 'M',
  confidence: 0.25,
  iou: 0.5,
  useGpu: false,
  analysisFps: 10,
  roi: [0.5, 0.5, 0.8],
);

List<String> _lines(List<int> bytes) => const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));

void main() {
  late Directory dir;
  late List<String> detLines;
  late List<String> trackLines;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('fuzz_video_files');
    Directory('${dir.path}/videos').createSync();
    for (final n in ['a.mp4', 'b.mov']) {
      File('${dir.path}/videos/$n').writeAsStringSync('x');
    }
    File('${dir.path}/session.jsonl').writeAsStringSync(
      '${jsonEncode({'type': 'video_clip', 'file': 'videos/a.mp4', 'start_epoch_ms': 1000000, 'duration_ms': 500})}\n',
    );
    final detector = VideoDetector(backend: _Backend({'a.mp4': 6, 'b.mov': 4}), thermal: () async => const ThermalReading(batteryTempC: 31), pausePoll: Duration.zero);
    await detector.run(dir, config: _config);
    final out = File('${dir.path}/${VideoDetector.outputFileName}');
    detLines = out.readAsLinesSync();
    // A cooling pause, as a phone writes it, so the samples reader meets every record type.
    final start = jsonDecode(detLines.first) as Map<String, dynamic>;
    final t0 = start['time_ms'] as int;
    detLines.insertAll(2, [
      jsonEncode({'type': 'video_thermal_pause', 'time_ms': t0 + 5}),
      jsonEncode({'type': 'video_thermal_resume', 'time_ms': t0 + 9}),
    ]);
    out.writeAsStringSync('${detLines.join('\n')}\n');
    final tracks = [
      jsonEncode({'type': 'post_track_start', 'time_ms': t0 + 100, 'detections_run_ms': t0, 'clips': ['a.mp4'], 'observed_ms': 600}),
      jsonEncode({'type': 'track_event', 'event': 'created', 'track_id': 1, 'frame_ms': 1000100, 'first_seen_ms': 1000000, 'time_ms': t0 + 101}),
      for (var i = 0; i < 6; i++)
        jsonEncode({
          'type': 'detections',
          'time_ms': t0 + 102 + i,
          'clip': 'a.mp4',
          'pts_us': i * 100000,
          'frame_ms': 1000000 + i * 100,
          'tracks': [
            {'track_id': 1, 'class_name': 'bee', 'confidence': 0.9, 'coasted': i == 3, 'box_in_roi': {'left': 0.1, 'top': 0.2, 'right': 0.3, 'bottom': 0.4}},
          ],
        }),
    ];
    trackLines = tracks;
    File('${dir.path}/$postTracksFileName').writeAsStringSync('${tracks.join('\n')}\n');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the valid fixtures read (sanity)', () {
    final resume = VideoResume.parse(detLines);
    expect(resume.doneClips, {'a.mp4', 'b.mov'});
    expect(resume.settings?['model'], 'models/m.tflite');
    final timeline = VideoBoxTimeline.parse(detLines, trackLines);
    expect(timeline.clips.keys, containsAll(['a.mp4', 'b.mov']));
    expect(timeline.hasVisits, isTrue, reason: 'the tracks file belongs to this run');
    final samples = VideoRunSamples.parse(detLines);
    expect(samples.runs, 1);
    expect(samples.pauses, isNotEmpty);
  });

  group('VideoResume.parse', () {
    test('byte-level damage: no crash (lines read as the safe readers do)', () {
      final report = FuzzReport();
      final bytes = Uint8List.fromList(utf8.encode('${detLines.join('\n')}\n'));
      for (final (name, b) in byteMutants(bytes, Random(1))) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          VideoResume.parse(_lines(b));
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('wrong JSON types in one field: no crash, the rest is still read', () {
      final report = FuzzReport();
      for (final (name, lines) in typeMutants(detLines, Random(2), count: 400)) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          VideoResume.parse(lines);
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });
  });

  group('the strict UTF-8 readers of the analysis files', () {
    test('a half-written last line cut inside a multi-byte letter: the run can still continue', () async {
      // A clip with a non-ASCII name (e.g. "Bienen_über_Blüte.mp4"): the app is killed while
      // writing a raw_detections line, so the file ends inside the two bytes of "ü".
      final out = File('${dir.path}/${VideoDetector.outputFileName}');
      final bytes = BytesBuilder()
        ..add(out.readAsBytesSync())
        ..add(utf8.encode('{"type":"raw_detections","time_ms":9,"clip":"über'))
        ..add([0xC3]);
      out.writeAsBytesSync(bytes.toBytes());
      final detector = VideoDetector(backend: _Backend({'a.mp4': 6, 'b.mov': 4}), thermal: () async => const ThermalReading(batteryTempC: 31), pausePoll: Duration.zero);
      final result = await detector.run(dir, config: _config);
      expect(result.cancelled, isFalse);
    });

    test('clipRecordsFromLog on a session.jsonl that ends inside a multi-byte letter', () async {
      final log = File('${dir.path}/session.jsonl');
      final bytes = BytesBuilder()
        ..add(log.readAsBytesSync())
        ..add(utf8.encode('{"type":"note","text":"Zürich'))
        ..add([0xC3]);
      log.writeAsBytesSync(bytes.toBytes());
      final records = await VideoDetector.clipRecordsFromLog(dir);
      expect(records.keys, ['a.mp4']);
    });
  });

  group('VideoBoxTimeline', () {
    test('parse: byte-level damage to either file', () {
      final report = FuzzReport();
      final detBytes = Uint8List.fromList(utf8.encode('${detLines.join('\n')}\n'));
      final trBytes = Uint8List.fromList(utf8.encode('${trackLines.join('\n')}\n'));
      final rnd = Random(3);
      for (final (name, b) in byteMutants(detBytes, rnd, perKind: 15)) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          VideoBoxTimeline.parse(_lines(b), trackLines);
        } catch (e) {
          err = e;
        }
        report.add('detections: $name', err, sw.elapsed);
      }
      for (final (name, b) in byteMutants(trBytes, rnd, perKind: 15)) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          VideoBoxTimeline.parse(detLines, _lines(b));
        } catch (e) {
          err = e;
        }
        report.add('tracks: $name', err, sw.elapsed);
      }
      expect(report.slowest, lessThan(const Duration(seconds: 5)), reason: '$report');
      expect(report.clean, isTrue, reason: '$report');
    });

    test('parse: wrong JSON types in one field of a box, clip name or track', () {
      final report = FuzzReport();
      for (final (name, lines) in typeMutants(detLines, Random(4), count: 300)) {
        Object? err;
        final sw = Stopwatch()..start();
        try {
          VideoBoxTimeline.parse(lines, trackLines);
        } catch (e) {
          err = e;
        }
        report.add('detections: $name', err, sw.elapsed);
      }
      for (final (name, lines) in typeMutants(trackLines, Random(5), count: 300)) {
        Object? err;
        final sw = Stopwatch()..start();
        try {
          VideoBoxTimeline.parse(detLines, lines);
        } catch (e) {
          err = e;
        }
        report.add('tracks: $name', err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('readSync on files with invalid UTF-8 and damaged lines reads what it can', () {
      final out = File('${dir.path}/${VideoDetector.outputFileName}');
      final bytes = out.readAsBytesSync();
      final damaged = Uint8List.fromList([...bytes, 0xFF, 0xC3, 10, ...utf8.encode('{"type":"raw_detections","clip":"a.mp4","pts_us":5,"boxes":[[1,2')]);
      out.writeAsBytesSync(damaged);
      final t = VideoBoxTimeline.readSync(dir.path);
      expect(t.clips.keys, containsAll(['a.mp4', 'b.mov']));
    });

    test('readLiveSync: damaged session.jsonl', () async {
      final report = FuzzReport();
      final log = await writeValidSession(Directory('${dir.path}/live'));
      final bytes = log.readAsBytesSync();
      for (final (name, b) in byteMutants(bytes, Random(6), perKind: 15)) {
        File('${dir.path}/live/session.jsonl').writeAsBytesSync(b);
        final sw = Stopwatch()..start();
        Object? err;
        try {
          VideoBoxTimeline.readLiveSync('${dir.path}/live');
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('readLiveSync: wrong JSON types in one field', () async {
      final report = FuzzReport();
      final log = await writeValidSession(Directory('${dir.path}/live2'));
      final lines = log.readAsLinesSync();
      for (final (name, mutated) in typeMutants(lines, Random(7), count: 300)) {
        File('${dir.path}/live2/session.jsonl').writeAsStringSync('${mutated.join('\n')}\n');
        final sw = Stopwatch()..start();
        Object? err;
        try {
          VideoBoxTimeline.readLiveSync('${dir.path}/live2');
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });
  });

  group('VideoRunSamples', () {
    test('parseFile: byte-level damage gives samples or null, never an error', () async {
      final report = FuzzReport();
      final bytes = Uint8List.fromList(utf8.encode('${detLines.join('\n')}\n'));
      var i = 0;
      for (final (name, b) in byteMutants(bytes, Random(8))) {
        final f = File('${dir.path}/samples_${i++ % 3}.jsonl')..writeAsBytesSync(b);
        final sw = Stopwatch()..start();
        Object? err;
        try {
          await VideoRunSamples.parseFile(f.path);
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('parse: wrong JSON types in one field still gives the other samples', () {
      final report = FuzzReport();
      for (final (name, lines) in typeMutants(detLines, Random(9), count: 400)) {
        Object? err;
        final sw = Stopwatch()..start();
        try {
          VideoRunSamples.parse(lines);
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('parse: a raw_detections line with a huge time stamp and time_ms above 64 bits', () {
      final s = VideoRunSamples.parse([
        '{"type":"video_run_start","time_ms":1000,"sample_s":10}',
        '{"type":"raw_detections","time_ms":99999999999999999999999,"clip":"a"}',
        '{"type":"thermal","time_ms":2000,"battery_temp_c":30}',
      ]);
      expect(s.runs, 1);
    });
  });

  group('VideoDetector.isReadableVideo', () {
    test('random MP4-like headers: always terminates with true or false', () {
      final rnd = Random(10);
      final f = File('${dir.path}/videos/fuzz.mp4');
      final sw = Stopwatch()..start();
      for (var i = 0; i < 300; i++) {
        final n = rnd.nextInt(200);
        final b = Uint8List.fromList([
          for (var k = 0; k < n; k++) rnd.nextInt(256),
        ]);
        if (n >= 8 && rnd.nextBool()) {
          b.setRange(4, 8, 'ftyp'.codeUnits);
          if (n >= 16 && rnd.nextBool()) {
            // A box of random size right after it, sometimes a 64-bit size or zero.
            b.setRange(8, 12, [0, 0, 0, [0, 1, 8, 255][rnd.nextInt(4)]]);
          }
        }
        f.writeAsBytesSync(b);
        expect(VideoDetector.isReadableVideo(f), isA<bool>());
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });
}
