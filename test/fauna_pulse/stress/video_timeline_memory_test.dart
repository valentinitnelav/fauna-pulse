// Round 350 (perf review H3): the Video tab's readers stream their files.
// This test builds a one-hour live-AI log (about 17 MB: a `detections`
// record on every frame at 15 fps, 12 five-minute clips) and a run file of
// the same size, reads them as the Video tab does, and prints the process
// memory peak and the time. The bounds are loose: the point is that the
// peak stays near the size of the result, not several times the file.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fauna_pulse/fauna_pulse/postprocess/video_box_timeline.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_run_samples.dart';
import 'package:flutter_test/flutter_test.dart';

const _t0 = 1793520000000;
const _fps = 15;
const _frames = _fps * 3600;

int _mb(int bytes) => bytes ~/ (1024 * 1024);

/// session.jsonl of a live session with the ROI recorded as video.
Future<void> _writeLiveLog(File f) async {
  final r = Random(7);
  final sink = f.openWrite();
  sink.writeln(jsonEncode({'type': 'start_of_session', 'time_ms': _t0, 'config': {'liveAiVideo': true}}));
  var clipStart = _t0;
  for (var i = 0; i < _frames; i++) {
    final t = _t0 + i * 1000 ~/ _fps;
    if (i % (_fps * 20) == 0) {
      sink.writeln(jsonEncode({'type': 'track_event', 'time_ms': t + 35, 'event': 'created', 'track_id': i ~/ (_fps * 20) + 1, 'frame_ms': t + 30, 'hits': 3, 'first_seen_ms': t - 200}));
    }
    sink.writeln(jsonEncode({
      'type': 'detections',
      'time_ms': t + 40,
      'frame_ms': t + 30,
      'frame_sensor_ms': t,
      'tracks': [
        for (var k = 0; k < 1 + r.nextInt(2); k++)
          {
            'track_id': i ~/ (_fps * 20) + 1 + k,
            'class_index': k,
            'class_name': 'bee',
            'confidence': 0.3 + r.nextDouble() * 0.6,
            'box_in_roi': {'left': 0.1 + k * 0.3, 'top': 0.2, 'right': 0.2 + k * 0.3, 'bottom': 0.3},
          },
      ],
    }));
    if (i % (_fps * 10) == 0) {
      sink.writeln(jsonEncode({'type': 'thermal', 'time_ms': t + 50, 'battery_temp_c': 33.0, 'thermal_headroom': 0.4, 'thermal_status': 'none'}));
    }
    if ((i + 1) % (_fps * 300) == 0) {
      final n = (i + 1) ~/ (_fps * 300);
      sink.writeln(jsonEncode({'type': 'video_clip', 'time_ms': t + 60, 'file': 'videos/clip_$n.mp4', 'start_epoch_ms': clipStart, 'duration_ms': 300000}));
      clipStart = t + 1000 ~/ _fps;
    }
  }
  sink.writeln(jsonEncode({'type': 'end_of_session', 'time_ms': _t0 + 3600100, 'ended_normally': true}));
  await sink.flush();
  await sink.close();
}

/// video_detections.jsonl of one run over the same hour of video.
Future<void> _writeRunFile(File f) async {
  final sink = f.openWrite();
  sink.writeln(jsonEncode({'type': 'video_run_start', 'time_ms': _t0, 'settings': {'roi': null}, 'sample_s': 10}));
  for (var i = 0; i < _frames; i++) {
    final t = _t0 + i * 1000 ~/ _fps;
    sink.writeln(jsonEncode({'type': 'raw_detections', 'time_ms': t, 'clip': 'clip_${i ~/ (_fps * 300) + 1}.mp4', 'pts_us': (i % (_fps * 300)) * 1000000 ~/ _fps, 'frame': i, 'boxes': [[0.1, 0.2, 0.3, 0.4, 0.8, 0], [0.5, 0.5, 0.6, 0.7, 0.6, 1]]}));
    if (i % (_fps * 10) == 0) {
      sink.writeln(jsonEncode({'type': 'thermal', 'time_ms': t, 'battery_temp_c': 33.0, 'thermal_headroom': 0.4, 'thermal_status': 'none', 'clip': 'clip_1.mp4'}));
      sink.writeln(jsonEncode({'type': 'analysis_speed', 'time_ms': t, 'frames_per_s': 14.0, 'frames': 150, 'decode_ms': 10.0, 'convert_ms': 2.0, 'detect_ms': 40.0}));
    }
  }
  await sink.flush();
  await sink.close();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('video_timeline_memory'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a one-hour live log: the reader\'s memory peak stays near the result, not the file times several', () async {
    final log = File('${tmp.path}/session.jsonl');
    await _writeLiveLog(log);
    final fileMb = _mb(log.lengthSync());
    final rssBefore = ProcessInfo.currentRss, maxBefore = ProcessInfo.maxRss;
    final sw = Stopwatch()..start();
    final t = VideoBoxTimeline.readLiveSync(tmp.path);
    sw.stop();
    final peakMb = _mb(max(ProcessInfo.maxRss, ProcessInfo.currentRss) - rssBefore);
    final frames = t.clips.values.fold(0, (n, c) => n + c.analysedFrames);
    // ignore: avoid_print
    print('readLiveSync($fileMb MB, $frames frames in ${t.clips.length} clips): ${sw.elapsedMilliseconds} ms, '
        'process memory peak +$peakMb MB (max before ${_mb(maxBefore)} MB)');
    expect(t.clips, hasLength(12));
    expect(frames, _frames);
    expect(peakMb, lessThan(fileMb * 4), reason: 'the whole file as bytes, string, lines and records would be several times its size');
  });

  test('a one-hour run file: the run samples stream through the parser', () async {
    final f = File('${tmp.path}/${VideoDetector.outputFileName}');
    await _writeRunFile(f);
    final fileMb = _mb(f.lengthSync());
    final rssBefore = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();
    final s = (await VideoRunSamples.parseFile(f.path))!;
    sw.stop();
    final peakMb = _mb(max(ProcessInfo.maxRss, ProcessInfo.currentRss) - rssBefore);
    // ignore: avoid_print
    print('VideoRunSamples.parseFile($fileMb MB, ${s.frames} frames): ${sw.elapsedMilliseconds} ms, process memory peak +$peakMb MB');
    expect(s.frames, _frames);
    expect(s.samples, hasLength(360));
    expect(peakMb, lessThan(fileMb * 2));
  });
}
