// Round 319 (stress test round 318, report items 3, 4 and 8): "Find animals
// in videos" at the detector level.
// - A detector model that cannot be loaded (a damaged file) stops the run; the
//   clips are not counted as unreadable (item 3).
// - "ms per frame" counts only the time the detector runs, not heat pauses
//   (item 4).
// - Storage full while the results are written stops the run with a clear
//   result, and Continue does not glue its first record onto a cut last line
//   (item 8).
//
// Storage full is real: the results file is opened on Linux's /dev/full,
// where every write fails with "No space left on device" (errno 28), through
// IOOverrides (File.fromRawPath is not overridden, so the stand-in can still
// reach the real files).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dart:isolate' show RemoteError;

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart' show kModelDamagedAdvice, modelLoadAdvice;
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_frame_keeper.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show SavedFramesChunk, VideoChunk, VideoFrameBoxes, VideoInfo;

/// Fake decoder: every clip has frames every 100 ms; a chunk is 3 frames.
class _Backend implements VideoBackend {
  final Map<String, int> frameCounts;

  /// Thrown by [open] (the plugin compiles the model there, round 319).
  Object? openError;

  /// Called for every chunk, e.g. to move a fake clock on.
  Future<void> Function()? onNext;
  final opens = <String>[];
  List<int> _pts = const [];
  var _i = 0;
  _Backend(this.frameCounts);

  String _name(String path) => path.split('/').last;

  @override
  Future<VideoInfo> info(String path) async =>
      VideoInfo(durationMs: frameCounts[_name(path)]! * 100, firstPtsUs: 0, frameCount: frameCounts[_name(path)]!, creationEpochMs: 5000000);

  @override
  Future<void> open(String path, VideoRunConfig config, {required int startPtsUs}) async {
    opens.add(_name(path));
    if (openError case final e?) throw e;
    _pts = [for (var i = 0; i < frameCounts[_name(path)]!; i++) i * 100000].where((p) => p >= startPtsUs).toList();
    _i = 0;
  }

  @override
  Future<VideoChunk> next() async {
    await onNext?.call();
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

const _config = VideoRunConfig(modelPath: 'm.tflite', modelName: 'M', confidence: 0.25, iou: 0.5, useGpu: false, analysisFps: 10);

File _real(String path) => File.fromRawPath(Uint8List.fromList(utf8.encode(path)));

/// A file whose writes all go to /dev/full; reads see the real (absent) file.
class _FullDiskFile implements File {
  @override
  final String path;
  _FullDiskFile(this.path);

  File get _dev => _real('/dev/full');

  @override
  bool existsSync() => _real(path).existsSync();

  @override
  Future<bool> exists() => _real(path).exists();

  @override
  Stream<List<int>> openRead([int? start, int? end]) => _real(path).openRead(start, end);

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) => _dev.openWrite(mode: FileMode.append, encoding: encoding);

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) => _dev.openSync(mode: FileMode.writeOnlyAppend);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('$invocation');
}

/// A results file on a disk that fills up after [budget] bytes: the write
/// that does not fit is cut where the space ends, as on a phone.
class _FillingFile implements File {
  @override
  final String path;
  final int budget;
  _FillingFile(this.path, this.budget);

  @override
  bool existsSync() => _real(path).existsSync();

  @override
  Stream<List<int>> openRead([int? start, int? end]) => _real(path).openRead(start, end);

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) => _FillingRaf(_real(path).openSync(mode: mode), budget);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('$invocation');
}

class _FillingRaf implements RandomAccessFile {
  final RandomAccessFile _f;
  int _left;
  _FillingRaf(this._f, this._left);

  @override
  void writeStringSync(String string, {Encoding encoding = utf8}) {
    final bytes = encoding.encode(string);
    if (bytes.length <= _left) {
      _f.writeFromSync(bytes);
      _left -= bytes.length;
      return;
    }
    _f.writeFromSync(bytes, 0, _left);
    _left = 0;
    throw FileSystemException('writeFrom failed', _f.path, const OSError('No space left on device', 28));
  }

  @override
  int lengthSync() => _f.lengthSync();
  @override
  void setPositionSync(int position) => _f.setPositionSync(position);
  @override
  int readByteSync() => _f.readByteSync();
  @override
  Uint8List readSync(int count) => _f.readSync(count);
  @override
  void truncateSync(int length) => _f.truncateSync(length);
  @override
  void closeSync() => _f.closeSync();
  @override
  String get path => _f.path;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('$invocation');
}

final class _Filling extends IOOverrides {
  final int budget;
  _Filling(this.budget);
  @override
  File createFile(String path) => path.endsWith(VideoDetector.outputFileName) ? _FillingFile(path, budget) : _real(path);
}

final class _FullDisk extends IOOverrides {
  @override
  File createFile(String path) => path.endsWith(VideoDetector.outputFileName) ? _FullDiskFile(path) : _real(path);
}

/// The phone's frame saver when the storage is full: Android's own text.
class _FullFrameSaver implements FrameSaveBackend {
  final opened = <String>[];

  @override
  Future<void> open(String path, List<int> roiPx) async => opened.add(path.split('/').last);

  @override
  Future<SavedFramesChunk> save(List<int> ptsUs, List<String> paths) async =>
      throw PlatformException(code: 'video_error', message: 'write failed: ENOSPC (No space left on device)');

  @override
  Future<void> close() async {}
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('r319_l2_video_run');
    Directory('${dir.path}/videos').createSync();
    for (final n in ['a.mp4', 'b.mp4']) {
      File('${dir.path}/videos/$n').writeAsStringSync('x');
    }
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> lines() => File('${dir.path}/${VideoDetector.outputFileName}').readAsLinesSync();
  List<Map<String, dynamic>> records() => [for (final l in lines()) (jsonDecode(l) as Map).cast<String, dynamic>()];

  VideoDetector detector(_Backend b) =>
      VideoDetector(backend: b, thermal: () async => const ThermalReading(batteryTempC: 30), pausePoll: Duration.zero);

  group('item 3: a detector model that cannot be loaded', () {
    test('stops the run; no clip is counted as unreadable', () async {
      final b = _Backend({'a.mp4': 6, 'b.mp4': 4})
        ..openError = PlatformException(code: 'model_error', message: 'Failed to compile model');
      final result = await detector(b).run(dir, config: _config);

      expect(b.opens, ['a.mp4'], reason: 'the second clip would fail the same way');
      expect(result.clipsFailed, 0);
      expect(result.modelFailed, isTrue);
      final recs = records();
      expect(recs.where((r) => r['type'] == 'video_clip_error'), isEmpty);
      expect(recs.singleWhere((r) => r['type'] == 'video_model_error')['clip'], 'a.mp4');
      expect(recs.last['type'], 'video_run_end');
      expect(recs.last['reason'], 'model_error');
    });

    test('a clip error is still a clip error (reference)', () async {
      final b = _Backend({'a.mp4': 6, 'b.mp4': 4})
        ..openError = PlatformException(code: 'video_error', message: 'setDataSource failed: status = 0x80000000');
      final result = await detector(b).run(dir, config: _config);
      expect(b.opens, ['a.mp4', 'b.mp4']);
      expect(result.clipsFailed, 2);
      expect(result.modelFailed, isFalse);
    });
  });

  test('item 23: the camera says what to do instead of the raw error text', () {
    final advice = modelLoadAdvice('/data/files/models/flatbug-n_640_fp16.tflite', 'LiteRtException: Failed to compile model');
    expect(advice, kModelDamagedAdvice);
    expect(advice, isNot(contains('LiteRt')));
    // A known case keeps its own hint.
    expect(modelLoadAdvice('/m/x_qnn.onnx', 'requires onnxruntime-android-qnn'), contains('Snapdragon NPU edition'));
  });

  group('item 4: ms per frame during and after a heat pause', () {
    test('counts only the time the detector runs', () async {
      // Each chunk (3 frames) takes 30 ms; the pause sleeps 2 x 300 ms. The
      // fake clock moves with the real waits.
      var t = DateTime.utc(2026, 10, 21, 12);
      final temps = [30.0, 45.0, 44.0, 36.0];
      var reads = 0;
      final b = _Backend({'a.mp4': 9, 'b.mp4': 9})
        ..onNext = () async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          t = t.add(const Duration(milliseconds: 30));
        };
      final seen = <({int frames, double ms, bool paused})>[];
      final result = await VideoDetector(
        backend: b,
        thermal: () async => ThermalReading(batteryTempC: reads < temps.length ? temps[reads++] : 30),
        now: () => t,
        sleep: (d) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          t = t.add(const Duration(milliseconds: 300));
        },
      ).run(
        dir,
        config: _config,
        sampleEvery: const Duration(seconds: 1),
        onProgress: (p) => seen.add((frames: p.framesAnalysed, ms: p.msPerFrame, paused: p.note.isNotEmpty)),
      );
      expect(result.thermalPauses, 1);
      expect(seen.where((s) => s.paused), isNotEmpty, reason: 'the pause showed progress');
      for (final s in seen.where((s) => s.frames > 0)) {
        expect(s.ms, closeTo(10, 0.01), reason: 'after ${s.frames} frames${s.paused ? ' (paused)' : ''}');
      }
    });
  });

  group('item 8: storage full while the results are written', () {
    test('the run stops with a storage-full result and throws nothing', () async {
      final b = _Backend({'a.mp4': 6, 'b.mp4': 4});
      final result = await IOOverrides.runWithIOOverrides(() => detector(b).run(dir, config: _config), _FullDisk());
      expect(result.writeError, isNotNull);
      expect(isStorageFullError(result.writeError!), isTrue);
      expect(result.clipsDone, 0, reason: 'nothing could be saved');
      expect(b.opens.length, lessThanOrEqualTo(1), reason: 'the run stops at the first failed write');
    });

    test('storage filling up during a clip: the run stops, Continue goes on with every frame once', () async {
      final first = await IOOverrides.runWithIOOverrides(
        () => detector(_Backend({'a.mp4': 12, 'b.mp4': 4})).run(dir, config: _config),
        _Filling(1500),
      );
      expect(isStorageFullError(first.writeError!), isTrue);
      expect(first.clipsDone, 0);
      expect(first.framesAnalysed, greaterThan(0));
      expect(File('${dir.path}/${VideoDetector.outputFileName}').readAsStringSync(), isNot(endsWith('\n')), reason: 'cut');

      final second = await detector(_Backend({'a.mp4': 12, 'b.mp4': 4})).run(dir, config: _config);
      expect(second.writeError, isNull);
      expect(second.clipsDone, 2);
      final raws = records().where((r) => r['type'] == 'raw_detections').map((r) => '${r['clip']} ${r['pts_us']}').toList();
      expect(raws.toSet().length, raws.length, reason: 'no frame twice');
      expect(raws.length, 16, reason: 'every frame of both clips');
    });

    test('Continue cuts a half-written last line instead of writing onto it', () async {
      final start = jsonEncode({'type': 'video_run_start', 'time_ms': 1, 'settings': _config.identity});
      final raw = jsonEncode({'type': 'raw_detections', 'time_ms': 2, 'frame_ms': 5000000, 'clip': 'a.mp4', 'pts_us': 0, 'frame': 0, 'boxes': []});
      File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync('$start\n$raw\n{"type":"raw_detections","time_ms":3,"cl');
      final b = _Backend({'a.mp4': 6, 'b.mp4': 4});
      final result = await detector(b).run(dir, config: _config);
      expect(result.clipsDone, 2);
      for (final (i, l) in lines().indexed) {
        expect(() => jsonDecode(l), returnsNormally, reason: 'line ${i + 1}: $l');
      }
      expect(lines().take(2), [start, raw], reason: 'the whole records before the cut stay');
    });

    test('a whole last record without its line end is kept', () async {
      final start = jsonEncode({'type': 'video_run_start', 'time_ms': 1, 'settings': _config.identity});
      final done = jsonEncode({'type': 'video_clip_done', 'time_ms': 2, 'clip': 'a.mp4'});
      File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync('$start\n$done');
      final b = _Backend({'a.mp4': 6, 'b.mp4': 4});
      await detector(b).run(dir, config: _config);
      expect(b.opens, ['b.mp4'], reason: 'a.mp4 was finished');
      expect(lines().take(2), [start, done]);
      for (final l in lines()) {
        expect(() => jsonDecode(l), returnsNormally, reason: l);
      }
    });
  });

  group('item 8: the other writers of the run', () {
    test('storage-full errors are told apart from other errors', () {
      expect(isStorageFullError(const FileSystemException('writeFrom failed', '/x', OSError('No space left on device', 28))), isTrue);
      expect(isStorageFullError(PlatformException(code: 'video_error', message: 'write failed: ENOSPC (No space left on device)')), isTrue);
      expect(isStorageFullError(RemoteError('FileSystemException: writeFrom failed (OS Error: No space left on device, errno = 28)', '')), isTrue);
      expect(isStorageFullError(const FileSystemException('Cannot open file', '/x', OSError('Permission denied', 13))), isFalse);
      expect(isStorageFullError(PlatformException(code: 'video_error', message: 'setDataSource failed')), isFalse);
    });

    test('saving the kept frames stops at full storage; the frames are not counted as unreadable', () async {
      String rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': 111, ...m});
      final s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;
      File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync([
        rec('video_run_start', {
          'settings': {'model': 'm.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 10, 'roi': null},
        }),
        for (final (i, clip) in ['a.mp4', 'b.mp4'].indexed) ...[
          rec('video_clip_start', {'clip': clip, 'start_epoch_ms': s0 + i * 60000, 'width': 1920, 'height': 1080}),
          for (var t = 0; t <= 5000; t += 100)
            rec('raw_detections', {
              'frame_ms': s0 + i * 60000 + t,
              'clip': clip,
              'pts_us': t * 1000,
              'frame': t * 3 ~/ 100,
              'boxes': [
                [0.2, 0.40, 0.25, 0.48, 0.9, 0],
              ],
            }),
          rec('video_clip_done', {'clip': clip, 'frame_width': 1920, 'frame_height': 1080, 'roi_px': [420, 0, 1080, 1080], 'class_names': ['bee']}),
        ],
      ].map((l) => '$l\n').join());
      File('${dir.path}/session.jsonl').writeAsStringSync(
        '${jsonEncode({'type': 'start_of_session', 'time_ms': s0, 'file_token': 'abc123', 'config': {'captureTrigger': 'none'}})}\n',
      );
      await VideoTracker.run(dir, const SessionConfig(), keep: const KeepFramesSettings(stepSeconds: 1, durationSeconds: 3));
      final before = await VideoFrameKeeper.status(dir);
      expect(before.remaining, greaterThan(0));

      final saver = _FullFrameSaver();
      final r = await VideoFrameKeeper(backend: saver).run(dir);
      expect(r.storageFull, isTrue);
      expect(r.failed, 0, reason: 'not "could not be read from their video"');
      expect(saver.opened, ['a.mp4'], reason: 'the next clip would fail the same way');
      expect((await VideoFrameKeeper.status(dir)).remaining, before.remaining, reason: 'left for the next run');
    });
  });
}
