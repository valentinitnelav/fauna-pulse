// Tests for the Video tab's box timeline (round 231): which boxes show at a
// player position, tracked vs detector boxes, the analysed area, and visits
// found on an earlier analysis. Fixture lines have the shape VideoDetector
// and VideoTracker write.

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_box_timeline.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': 111, ...m});

String _runStart({List<double>? roi}) => _rec('video_run_start', {
  'settings': {'model': 'm.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 10, 'roi': roi, 'max_side_px': 0},
});

/// One box `[l, t, r, b, conf, cls]` (frame-normalized).
List<num> _box(double x, {int cls = 0}) => [x, 0.40, x + 0.05, 0.48, 0.9, cls];

/// One `raw_detections` record per analysed frame at the given times (ms
/// after the clip's first frame, whose time stamp is [firstPtsUs]).
List<String> _clip(
  String name, {
  required Iterable<int> times,
  int firstPtsUs = 0,
  List<num>? Function(int t)? boxAt,
  bool done = true,
  List<int>? roiPx,
}) => [
  _rec('video_clip_start', {'clip': name, 'start_epoch_ms': 1000000, 'width': 1920, 'height': 1080}),
  for (final t in times)
    _rec('raw_detections', {
      'frame_ms': 1000000 + t,
      'clip': name,
      'pts_us': firstPtsUs + t * 1000,
      'frame': t * 30 ~/ 1000,
      'boxes': [?boxAt?.call(t)],
    }),
  if (done)
    _rec('video_clip_done', {
      'clip': name,
      'frame_width': 1920,
      'frame_height': 1080,
      'roi_px': roiPx ?? [0, 0, 1920, 1080],
      'class_names': ['bee', 'fly'],
    }),
];

Iterable<int> _every100(int fromMs, int toMs) sync* {
  for (var t = fromMs; t <= toMs; t += 100) {
    yield t;
  }
}

Directory _session(List<String> lines) {
  final dir = Directory.systemTemp.createTempSync('video_box_timeline_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync('${lines.join('\n')}\n');
  return dir;
}

void main() {
  test('a frame\'s boxes stay until the next frame, at most 1.5 steps', () {
    final t = VideoBoxTimeline.parse([
      _runStart(),
      // Frames every 100 ms up to 1 s, a gap, then 2.0 to 2.2 s.
      ..._clip('a.mp4', times: [..._every100(0, 1000), ..._every100(2000, 2200)], boxAt: (t) => _box(t / 10000)),
    ], const []);
    final c = t.clips['a.mp4']!;
    expect(c.holdMs, 150);
    expect(c.analysedFrames, 14);
    expect(c.rawAt(0).single.box.left, 0);
    expect(c.rawAt(190).single.box.left, closeTo(0.01, 1e-9)); // frame 100 ms
    expect(c.rawAt(1150).single.box.left, closeTo(0.1, 1e-9)); // 1.5 steps after 1 s
    expect(c.rawAt(1151), isEmpty, reason: 'gap: no old boxes');
    expect(c.rawAt(2000).single.box.left, closeTo(0.2, 1e-9));
    expect(c.rawAt(2400), isEmpty, reason: 'unanalysed tail');
    expect(c.lastAnalysedMs, 2200);
  });

  test('positions are the video time stamps, a late first frame included', () {
    // The test phone clip starts with a 50.3 ms empty edit: its first frame
    // plays at 50 ms, and the player's position counts from 0.
    final c = VideoBoxTimeline.parse([
      _runStart(),
      ..._clip('a.mp4', times: _every100(0, 500), firstPtsUs: 50300, boxAt: (t) => _box(0.5)),
    ], const []).clips['a.mp4']!;
    expect(c.rawAt(49), isEmpty);
    expect(c.rawAt(50), hasLength(1));
    expect(c.rawAt(700), hasLength(1)); // last frame 550 ms + 150 ms
    expect(c.rawAt(701), isEmpty);
  });

  test('class names come from the analysis, boxes stay within their clip', () {
    final t = VideoBoxTimeline.parse([
      _runStart(),
      ..._clip('a.mp4', times: _every100(0, 300), boxAt: (t) => _box(0.1, cls: 1)),
      ..._clip('b.mp4', times: _every100(0, 300), done: false),
    ], const []);
    expect(t.clips['a.mp4']!.rawAt(100).single.className, 'fly');
    expect(t.clips['b.mp4']!.rawAt(100), isEmpty);
    expect(t.clips['b.mp4']!.done, isFalse);
    expect(t.hasVisits, isFalse);
    expect(t.clips.containsKey('c.mp4'), isFalse);
  });

  test('analysed area: from the analysis, else the settings, none for the whole frame', () {
    final t = VideoBoxTimeline.parse([
      _runStart(roi: [0.5, 0.5, 0.5]),
      ..._clip('a.mp4', times: [0], roiPx: [480, 0, 1080, 1080]),
      ..._clip('b.mp4', times: [0], done: false),
      ..._clip('c.mp4', times: [0]),
    ], const []);
    final a = t.clips['a.mp4']!.areaFor(16 / 9)!;
    expect(a.left, closeTo(0.25, 1e-9));
    expect(a.width, closeTo(0.5625, 1e-9));
    expect(a.height, closeTo(1, 1e-9));
    // Not finished: the settings' square (half the width, centred).
    final b = t.clips['b.mp4']!.areaFor(16 / 9)!;
    expect(b.left, closeTo(0.25, 1e-9));
    expect(b.right, closeTo(0.75, 1e-9));
    expect(b.center.dy, closeTo(0.5, 1e-9));
    expect(b.height, closeTo(0.5 * 16 / 9, 1e-9));
    expect(t.clips['c.mp4']!.areaFor(16 / 9), isNull);
  });

  test('visits from Find visits sit on the detector\'s boxes, with their numbers', () async {
    // The analysed square is the middle 1080 px: tracked boxes are stored
    // relative to it and must come back in whole-frame coordinates.
    final dir = _session([
      _runStart(roi: [0.5, 0.5, 0.5625]),
      ..._clip(
        'a.mp4',
        times: _every100(0, 4000),
        roiPx: [420, 0, 1080, 1080],
        boxAt: (t) => t >= 1000 && t <= 3000 ? _box(0.4) : null,
      ),
    ]);
    await VideoTracker.run(dir, const SessionConfig());
    final t = VideoBoxTimeline.readSync(dir.path);
    expect(t.hasVisits, isTrue);
    expect(t.visitsStale, isFalse);
    final c = t.clips['a.mp4']!;
    expect(c.tracked, isTrue);
    final v = c.visits.single;
    expect(v.className, 'bee');
    expect(v.startMs, greaterThanOrEqualTo(1000));
    expect(v.endMs, greaterThanOrEqualTo(3000));
    final box = c.trackedAt(2000).single;
    expect(box.trackId, v.trackId);
    expect(box.box.left, closeTo(0.4, 0.01));
    expect(box.box.top, closeTo(0.4, 0.01));
    expect(box.box.right, closeTo(0.45, 0.01));
    expect(c.trackedAt(500), isEmpty);
    expect(c.rawAt(2000).single.trackId, isNull);
  });

  test('visits found on an earlier analysis are not shown', () async {
    final lines = [
      _runStart(),
      ..._clip('a.mp4', times: _every100(0, 2000), boxAt: (t) => _box(0.4)),
    ];
    final dir = _session(lines);
    await VideoTracker.run(dir, const SessionConfig());
    // Analysed again (start over): a new run time.
    File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      '${[lines.first.replaceFirst('"time_ms":111', '"time_ms":222'), ...lines.skip(1)].join('\n')}\n',
    );
    final t = VideoBoxTimeline.readSync(dir.path);
    expect(t.visitsStale, isTrue);
    expect(t.hasVisits, isFalse);
    expect(t.clips['a.mp4']!.trackedAt(1000), isEmpty);
    expect(t.clips['a.mp4']!.visits, isEmpty);
    expect(t.clips['a.mp4']!.rawAt(1000), hasLength(1));
  });

  test('a torn last line and a missing file are harmless', () {
    final dir = _session([_runStart(), ..._clip('a.mp4', times: [0, 100]), '{"type":"raw_detec']);
    final t = VideoBoxTimeline.readSync(dir.path);
    expect(t.clips['a.mp4']!.analysedFrames, 2);
    expect(VideoBoxTimeline.readSync('${dir.path}/nothing').clips, isEmpty);
  });

  test('a clip analysed only in part keeps its boxes but no visits', () async {
    final dir = _session([
      _runStart(),
      ..._clip('a.mp4', times: _every100(0, 2000), boxAt: (t) => _box(0.4)),
      ..._clip('b.mp4', times: _every100(0, 1000), boxAt: (t) => _box(0.2), done: false),
    ]);
    await VideoTracker.run(dir, const SessionConfig());
    final t = VideoBoxTimeline.readSync(dir.path);
    expect(t.clips['a.mp4']!.tracked, isTrue);
    expect(t.clips['b.mp4']!.tracked, isFalse);
    expect(t.clips['b.mp4']!.rawAt(500).single.box, const Rect.fromLTRB(0.2, 0.4, 0.25, 0.48));
  });
}
