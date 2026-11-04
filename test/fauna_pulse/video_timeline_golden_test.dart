// Round 350 (perf review H3): the Video tab's timeline readers and the
// run-sample parser stream their files instead of loading them whole. This
// test pins their results on a rich synthetic session (edge cases included)
// to a golden file written by the readers before the rewrite, so the results
// stay the same to the last digit.
//
// To write the golden again (only when a reader's rules change on purpose):
//   flutter test test/fauna_pulse/video_timeline_golden_test.dart --dart-define=WRITE_GOLDEN=true

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:fauna_pulse/fauna_pulse/logging/track_source.dart' show postTracksFileName;
import 'package:fauna_pulse/fauna_pulse/postprocess/video_box_timeline.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_run_samples.dart';
import 'package:flutter_test/flutter_test.dart';

const _write = bool.fromEnvironment('WRITE_GOLDEN');
const _goldenPath = 'test/fauna_pulse/fixtures/video_timeline_golden.json';
const _t0 = 1790000000000;

String _j(Map<String, dynamic> m) => jsonEncode(m);

Map<String, double> _roiBox(Random r) {
  final l = r.nextDouble() * 0.7, t = r.nextDouble() * 0.7;
  return {'left': l, 'top': t, 'right': l + 0.1 + r.nextDouble() * 0.2, 'bottom': t + 0.1 + r.nextDouble() * 0.2};
}

/// session.jsonl of a live-AI session with clips: records inside and outside
/// the clips, repeated time stamps, `created` events before and after their
/// frame, wrong-typed fields, blank, `\r\n` and torn lines, a bare UTF-8 lead
/// byte, and the word "detections" inside other records.
List<String> _liveLog() {
  final r = Random(1);
  final lines = <String>[
    _j({
      'type': 'start_of_session',
      'time_ms': _t0,
      'config': {'liveAiVideo': true, 'fieldNotes': 'Blüte, Ähre; count the "detections" by hand'},
    }),
    '',
    _j({'type': 'track_event', 'time_ms': _t0 + 100, 'event': 'created', 'track_id': 1, 'frame_ms': _t0 + 1030, 'hits': 3, 'first_seen_ms': _t0 + 700}),
    _j({'type': 'track_event', 'time_ms': _t0 + 100, 'event': 'created', 'track_id': 2, 'frame_ms': '${_t0 + 2030}', 'hits': 3, 'first_seen_ms': _t0 + 1700}),
    _j({'type': 'track_event', 'time_ms': _t0 + 100, 'event': 'created', 'track_id': 3, 'frame_ms': _t0 + 3030, 'hits': 3}),
    _j({'type': 'track_event', 'time_ms': _t0 + 100, 'event': 'lost', 'track_id': 1, 'frame_ms': _t0 + 9030, 'first_seen_ms': _t0 + 700}),
    _j({'type': 'app_error', 'time_ms': _t0 + 200, 'message': 'no "detections" for 10 s'}),
  ];
  List<Map<String, dynamic>> tracks(int t, List<int> ids, {bool coasted = false, bool noBox = false, Object conf = 0.5}) => [
    for (final id in ids)
      {
        'track_id': id,
        'class_index': id % 3,
        'class_name': ['bee', 'hoverfly', 'Blüte'][id % 3],
        'confidence': conf is num ? (conf + id / 100) : conf,
        if (!noBox) 'box_in_roi': _roiBox(r),
        if (coasted) 'coasted': true,
      },
  ];
  Map<String, dynamic> det(int t, List<int> ids, {bool sensor = true, Object? trackList, bool coasted = false, bool noBox = false, Object conf = 0.5}) => {
    'type': 'detections',
    'time_ms': t + 40,
    'frame_ms': t + 30,
    if (sensor) 'frame_sensor_ms': t,
    'tracks': trackList ?? tracks(t, ids, coasted: coasted, noBox: noBox, conf: conf),
  };
  // Clip a: 0..30 s; clip b: 30.5..60.5 s; a clip with no duration (dropped);
  // clip c: 100..115 s, in a subfolder name.
  for (var ms = 0; ms <= 120000; ms += 100 + r.nextInt(400)) {
    final t = _t0 + ms;
    final ids = [for (var i = 0; i < 1 + r.nextInt(3); i++) 1 + r.nextInt(6)];
    lines.add(_j(det(t, ids, sensor: r.nextInt(10) > 0, coasted: r.nextInt(8) == 0)));
    if (r.nextInt(12) == 0) lines.add(_j(det(t, [9], conf: 0.9))); // the same frame again: the last record wins
    if (r.nextInt(25) == 0) lines.add(_j(det(t + 10, [7], trackList: 'none')));
    if (r.nextInt(25) == 0) lines.add(_j(det(t + 20, [8], noBox: true)));
    if (r.nextInt(30) == 0) lines.add(_j(det(t + 30, [5], conf: 'high')));
    if (ms == 1000) lines.add(_j({'type': 'track_event', 'time_ms': t + 35, 'event': 'created', 'track_id': 4, 'frame_ms': t + 30, 'hits': 3, 'first_seen_ms': t - 400}));
    if (ms == 1000) lines.add(_j({'type': 'track_event', 'time_ms': t + 36, 'event': 'created', 'track_id': 4, 'frame_ms': t + 30, 'hits': 3, 'first_seen_ms': t - 900}));
    if (ms == 31000) lines.add(_j({'type': 'track_event', 'time_ms': t + 35, 'event': 'created', 'track_id': 5, 'frame_ms': t + 30, 'hits': 3, 'first_seen_ms': t - 2000}));
  }
  lines.addAll([
    _j({'type': 'video_clip', 'time_ms': _t0 + 30000, 'file': 'videos/a.mp4', 'start_epoch_ms': _t0, 'duration_ms': 30000}),
    _j({'type': 'video_clip', 'time_ms': _t0 + 60500, 'file': 'videos/b.mp4', 'start_epoch_ms': _t0 + 30500, 'duration_ms': 30000}),
    _j({'type': 'video_clip', 'time_ms': _t0 + 90000, 'file': 'videos/no_duration.mp4', 'start_epoch_ms': _t0 + 61000}),
    _j({'type': 'video_clip', 'time_ms': _t0 + 115000, 'file': 'videos/sub/c.mp4', 'start_epoch_ms': _t0 + 100000, 'duration_ms': 15000}),
    _j({'type': 'video_clip', 'time_ms': _t0 + 115000, 'file': 42, 'start_epoch_ms': _t0 + 100000, 'duration_ms': 15000}),
    'not json at all',
    _j({'type': 'end_of_session', 'time_ms': _t0 + 120000, 'ended_normally': true}),
    '{"type":"detections","time_ms":${_t0 + 5000},"frame_sensor_ms":${_t0 + 5000},"tracks":[{"track_id":1,"box_in', // torn
  ]);
  return lines;
}

/// The file bytes: `\n` lines, one `\r\n` line, one line ending in a bare
/// UTF-8 lead byte.
List<int> _liveBytes() {
  final lines = _liveLog();
  final out = <int>[];
  for (var i = 0; i < lines.length; i++) {
    out.addAll(utf8.encode(lines[i]));
    if (i == 2) out.add(0xC3); // a torn multi-byte letter
    out.addAll(i == 5 ? [0x0D, 0x0A] : [0x0A]);
  }
  return out;
}

/// video_detections.jsonl: two runs, clips with and without a done record,
/// damaged boxes, a clip without class names.
List<String> _detectionsLog() {
  final r = Random(2);
  Map<String, dynamic> rec(String type, int t, Map<String, dynamic> m) => {'type': type, 'time_ms': t, ...m};
  final lines = <String>[
    _j(rec('video_run_start', _t0, {'settings': {'model': 'm.tflite', 'analysis_fps': 10, 'roi': [0.5, 0.5, 0.6], 'max_side_px': 0}, 'sample_s': 10})),
  ];
  for (final (name, frames, done, names) in [('a.mp4', 120, true, ['bee', 'fly']), ('b.mp4', 60, true, <String>[]), ('c.mp4', 30, false, ['bee', 'fly'])]) {
    lines.add(_j(rec('video_clip_start', _t0 + 1000, {'clip': name, 'start_epoch_ms': _t0, 'width': 1920, 'height': 1080})));
    for (var i = 0; i < frames; i++) {
      final boxes = <Object>[
        for (var b = 0; b < r.nextInt(3); b++) [r.nextDouble() * 0.8, r.nextDouble() * 0.8, 0.85, 0.9, 0.3 + r.nextDouble() * 0.6, r.nextInt(3)],
        if (r.nextInt(20) == 0) [0.1, 0.1, 0.2],
        if (r.nextInt(20) == 0) [0.1, 0.1, 0.2, 0.2, 'high', 0],
      ];
      lines.add(_j(rec('raw_detections', _t0 + 1000 + i * 100, {'clip': name, 'pts_us': i * 100000 + (i % 7 == 0 ? 500 : 0), 'frame': i * 3, 'boxes': boxes})));
      if (i % 20 == 5) lines.add(_j(rec('thermal', _t0 + 1000 + i * 100, {'clip': name, 'battery_temp_c': 30 + i / 10, 'thermal_headroom': 0.5, 'thermal_status': 'none', 'mem_total_bytes': 8000000000, 'mem_free_bytes': 3000000000 - i * 1000000, 'app_memory_bytes': 500000000, 'app_cpu_cores': 1.5})));
      if (i % 20 == 5) lines.add(_j(rec('power', _t0 + 1000 + i * 100, {'power_w': 2.5, 'battery_current_ua': -700000, 'battery_voltage_mv': 3900, 'charge_counter_uah': 3000000 - i * 100, 'is_charging': false, 'is_plugged': i > 100})));
      if (i % 20 == 5) lines.add(_j(rec('analysis_speed', _t0 + 1000 + i * 100, {'clip': name, 'frames_per_s': 9.5, 'frames': 50, 'decode_ms': 12.5, 'convert_ms': 3.0, 'detect_ms': 80.0})));
      if (i == 40) lines.add(_j(rec('video_thermal_pause', _t0 + 1000 + i * 100, {})));
      if (i == 50) lines.add(_j(rec('video_thermal_resume', _t0 + 1000 + i * 100, {})));
    }
    if (done) {
      lines.add(_j(rec('video_clip_done', _t0 + 2000 + frames * 100, {'clip': name, 'frame_width': 1920, 'frame_height': 1080, 'roi_px': name == 'b.mp4' ? [0, 0, 1920, 1080] : [480, 120, 960, 960], 'class_names': names})));
    }
  }
  lines.add(_j(rec('video_run_start', _t0 + 3600000, {'settings': {'model': 'm.tflite', 'analysis_fps': 10, 'roi': null, 'max_side_px': 0}, 'sample_s': 5})));
  lines.add(_j(rec('thermal', _t0 + 3600000 + 500, {'battery_temp_c': 33.0, 'thermal_headroom': 0.4, 'thermal_status': 'light'})));
  lines.add(_j(rec('video_thermal_pause', _t0 + 3600000 + 600, {})));
  lines.add(_j(rec('thermal', _t0 + 3600000 + 5500, {'battery_temp_c': 'warm'})));
  lines.add('{"type":"raw_detections","time_ms":${_t0 + 3600000 + 6000},"clip":"c.mp4","pts_us":1000,"bo'); // torn
  return lines;
}

/// post_tracks.jsonl matching [_detectionsLog] (or not: [runMs]).
List<String> _tracksLog({required int runMs, bool withStart = true}) {
  final r = Random(3);
  final lines = <String>[
    if (withStart) _j({'type': 'post_track_start', 'time_ms': _t0 + 7200000, 'detections_run_ms': runMs, 'clips': ['a.mp4', 'c.mp4', 'd.mp4']}),
    _j({'type': 'track_event', 'event': 'created', 'track_id': 1, 'frame_ms': 1000, 'time_ms': _t0, 'first_seen_ms': 700}),
    _j({'type': 'track_event', 'event': 'created', 'track_id': 2, 'frame_ms': 1000, 'time_ms': _t0, 'first_seen_ms': -200}),
  ];
  for (final (name, frames) in [('a.mp4', 120), ('b.mp4', 60), ('c.mp4', 30), ('d.mp4', 10)]) {
    for (var i = 0; i < frames; i += 1 + r.nextInt(3)) {
      final pts = i * 100000 + (i % 7 == 0 ? 500 : 0);
      lines.add(_j({
        'type': 'detections',
        'time_ms': _t0 + i,
        'clip': name,
        'pts_us': pts,
        'frame_ms': pts ~/ 1000,
        'tracks': [
          for (var k = 0; k < 1 + r.nextInt(2); k++)
            {'track_id': 1 + r.nextInt(4), 'class_name': ['bee', 'fly'][r.nextInt(2)], 'confidence': 0.4 + r.nextDouble() * 0.5, 'box_in_roi': _roiBox(r), if (r.nextInt(6) == 0) 'coasted': true},
        ],
      }));
      if (i == 10) lines.add(_j({'type': 'track_event', 'event': 'created', 'track_id': 3, 'frame_ms': pts ~/ 1000, 'time_ms': _t0, 'first_seen_ms': pts ~/ 1000 - 300}));
    }
  }
  return lines;
}

Object? _rect(Rect? r) => r == null ? null : [r.left, r.top, r.right, r.bottom].map((v) => v.toStringAsFixed(6)).toList();

List<Object?> _box(TimelineBox b) => [..._rect(b.box) as List, b.confidence.toStringAsFixed(6), b.className, b.trackId, b.coasted];

Map<String, dynamic> _dumpTimeline(VideoBoxTimeline t) => {
  'hasVisits': t.hasVisits,
  'visitsStale': t.visitsStale,
  'live': t.live,
  'clips': {
    for (final MapEntry(key: name, value: c) in t.clips.entries)
      name: {
        'done': c.done,
        'width': c.width,
        'height': c.height,
        'analysedArea': _rect(c.analysedArea),
        'settingsRoi': c.settingsRoi,
        'trackedClip': c.tracked,
        'analysedFrames': c.analysedFrames,
        'lastAnalysedMs': c.lastAnalysedMs,
        'holdMs': c.holdMs,
        'rawBoxMs': c.rawBoxMs,
        'trackSpans': [for (final s in c.trackSpans) [s.$1, s.$2]],
        'trackedMs': c.trackedMs,
        'rawSpans': [for (final s in c.rawSpans) [s.$1, s.$2]],
        'areaFor16by9': _rect(c.areaFor(16 / 9)),
        'visits': [for (final v in c.visits) [v.trackId, v.startMs, v.endMs, v.className]],
        // The boxes shown every 250 ms, from the start to past the last frame's hold.
        'raw': {
          for (var ms = 0; ms <= (c.lastAnalysedMs ?? 0) + c.holdMs + 200; ms += 250)
            if (c.rawAt(ms).isNotEmpty) '$ms': [for (final b in c.rawAt(ms)) _box(b)],
        },
        'tracked': {
          for (var ms = 0; ms <= (c.lastAnalysedMs ?? 0) + c.holdMs + 200; ms += 250)
            if (c.trackedAt(ms).isNotEmpty) '$ms': [for (final b in c.trackedAt(ms)) _box(b)],
        },
      },
  },
};

Map<String, dynamic> _dumpSamples(VideoRunSamples? s) => s == null
    ? {'null': true}
    : {
        'pauses': [for (final p in s.pauses) [p.$1, p.$2]],
        'totalMs': s.totalMs,
        'runMs': s.runMs,
        'pausedMs': s.pausedMs,
        'runs': s.runs,
        'frames': s.frames,
        'runGapMs': s.runGapMs,
        'sampleSeconds': s.sampleSeconds,
        'meanFramesPerS': s.meanFramesPerS?.toStringAsFixed(6),
        'samples': [
          for (final x in s.samples)
            [x.run, x.epochMs, x.ms, x.clip, x.tempC, x.headroom, x.thermalStatus, x.powerW, x.currentUa, x.voltageMv, x.chargeUah, x.charging, x.plugged, x.framesPerS, x.frames, x.pausedMs, x.decodeMs, x.convertMs, x.detectMs, x.memTotal, x.memFree, x.appMem, x.appCpuCores, x.paused, x.memUsedGb?.toStringAsFixed(6)],
        ],
        'power': [for (final p in s.power) [p.ms, p.currentUa, p.voltageMv, p.chargeUah, p.loggedW, p.isCharging, p.isPlugged]],
      };

void main() {
  test('round 350: the streaming readers give the same timelines and samples as before, to the last digit', () async {
    final tmp = Directory.systemTemp.createTempSync('video_timeline_golden');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final live = Directory('${tmp.path}/live')..createSync();
    File('${live.path}/session.jsonl').writeAsBytesSync(_liveBytes());
    Directory after(String name, int runMs, {bool withStart = true}) {
      final d = Directory('${tmp.path}/$name')..createSync();
      File('${d.path}/${VideoDetector.outputFileName}').writeAsStringSync('${_detectionsLog().join('\n')}\n');
      File('${d.path}/$postTracksFileName').writeAsStringSync('${_tracksLog(runMs: runMs, withStart: withStart).join('\n')}\n');
      return d;
    }
    final fresh = after('fresh', _t0);
    final stale = after('stale', _t0 + 1);
    final noStart = after('no_start', _t0, withStart: false);
    final noTracks = Directory('${tmp.path}/no_tracks')..createSync();
    File('${noTracks.path}/${VideoDetector.outputFileName}').writeAsStringSync('${_detectionsLog().join('\r\n')}\r\n');

    final result = {
      'live': _dumpTimeline(VideoBoxTimeline.readLiveSync(live.path)),
      'liveLoaded': _dumpTimeline(await VideoBoxTimeline.loadLive(live)),
      'fresh': _dumpTimeline(VideoBoxTimeline.readSync(fresh.path)),
      'stale': _dumpTimeline(VideoBoxTimeline.readSync(stale.path)),
      'noStart': _dumpTimeline(VideoBoxTimeline.readSync(noStart.path)),
      'noTracks': _dumpTimeline(VideoBoxTimeline.readSync(noTracks.path)),
      'parsed': _dumpTimeline(VideoBoxTimeline.parse(_detectionsLog(), _tracksLog(runMs: _t0))),
      'missing': _dumpTimeline(VideoBoxTimeline.readSync('${tmp.path}/none')),
      'samples': _dumpSamples(await VideoRunSamples.parseFile('${fresh.path}/${VideoDetector.outputFileName}')),
      'samplesParsed': _dumpSamples(VideoRunSamples.parse(_detectionsLog())),
      'samplesMissing': _dumpSamples(await VideoRunSamples.parseFile('${tmp.path}/none.jsonl')),
    };
    final text = jsonEncode(result);
    final golden = File(_goldenPath);
    if (_write) {
      golden.writeAsStringSync(text);
      return;
    }
    expect(golden.existsSync(), isTrue, reason: 'write it with --dart-define=WRITE_GOLDEN=true');
    expect(text, golden.readAsStringSync());
    // The fixture is rich enough: every clip and every edge case is in it.
    final liveClips = (result['live'] as Map)['clips'] as Map;
    expect(liveClips.keys.toSet(), {'a.mp4', 'b.mp4', 'c.mp4'});
    expect((liveClips['a.mp4'] as Map)['visits'], isNotEmpty);
    expect(((result['fresh'] as Map)['clips'] as Map).keys.toSet(), {'a.mp4', 'b.mp4', 'c.mp4'});
    expect((result['stale'] as Map)['visitsStale'], isTrue);
    expect(((result['samples'] as Map)['samples'] as List).length, greaterThan(5));
  });
}
