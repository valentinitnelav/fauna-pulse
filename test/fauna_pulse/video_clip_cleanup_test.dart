// Tests for deleting a session's videos to free storage (round 236,
// clip_cleanup.dart): which clips have no visit, what a deletion writes, and
// that the visits and kept frames survive it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/clip_cleanup.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_frame_keeper.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';

final s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': 111, ...m});

/// One analysed clip starting [startMs] after [s0], 10 s at 10 fps, with a
/// resting insect whenever [insectAt] says so.
List<String> _clip(String name, {int startMs = 0, int durationMs = 10000, bool Function(int t)? insectAt}) => [
  _rec('video_clip_start', {'clip': name, 'start_epoch_ms': s0 + startMs, 'width': 1920, 'height': 1080}),
  for (var t = 0; t <= durationMs; t += 100)
    _rec('raw_detections', {
      'frame_ms': s0 + startMs + t,
      'clip': name,
      'pts_us': t * 1000,
      'frame': t * 3 ~/ 100,
      'boxes': [
        if (insectAt?.call(t) ?? false) [0.4, 0.4, 0.45, 0.48, 0.9, 0],
      ],
    }),
  _rec('video_clip_done', {
    'clip': name,
    'frame_width': 1920,
    'frame_height': 1080,
    'roi_px': [420, 0, 1080, 1080],
    'class_names': ['bee'],
  }),
];

/// A session with the given detections and a small file per clip in
/// videos/ (their sizes differ, so byte counts can be told apart).
Directory _session(List<String> detections, Map<String, int> clipBytes) {
  final dir = Directory.systemTemp.createTempSync('video_clip_cleanup_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final runStart = _rec('video_run_start', {
    'settings': {'model': 'm.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 10, 'roi': null},
  });
  File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync('${[runStart, ...detections].join('\n')}\n');
  File('${dir.path}/session.jsonl').writeAsStringSync(
    '${jsonEncode({'type': 'start_of_session', 'time_ms': s0, 'file_token': 'abc', 'source': 'imported_video'})}\n'
    '${jsonEncode({'type': 'end_of_session', 'time_ms': s0 + 60000, 'ended_normally': true})}\n',
  );
  Directory('${dir.path}/videos').createSync();
  for (final e in clipBytes.entries) {
    File('${dir.path}/videos/${e.key}').writeAsBytesSync(List.filled(e.value, 0));
  }
  return dir;
}

const _keep = KeepFramesSettings(stepSeconds: 1, durationSeconds: 10);

void main() {
  const config = SessionConfig();

  test('the clips without any visit, and all clips', () async {
    final dir = _session(
      [
        ..._clip('a.mp4', insectAt: (t) => t >= 2000 && t <= 5000),
        ..._clip('b.mp4', startMs: 60000),
        ..._clip('c.mp4', startMs: 120000, insectAt: (t) => t == 5000), // one frame: too short for a visit
      ],
      {'a.mp4': 100, 'b.mp4': 200, 'c.mp4': 300, 'd.mp4': 400}, // d: not analysed
    );
    // Before "Find visits" nothing counts as without visits.
    expect((await ClipCleanup.planWithoutVisits(dir)).isEmpty, isTrue);

    await VideoTracker.run(dir, config);
    final none = await ClipCleanup.planWithoutVisits(dir);
    expect(none.mode, ClipCleanup.modeWithoutVisits);
    expect(none.deleteNames, ['b.mp4', 'c.mp4']); // d was never followed by Find visits
    expect(none.deleteBytes, 500);

    final all = await ClipCleanup.planAll(dir);
    expect(all.deleteNames, ['a.mp4', 'b.mp4', 'c.mp4', 'd.mp4']);
    expect(all.deleteBytes, 1000);
  });

  test('a visit running on into the next clip keeps that clip', () async {
    // Back to back: b starts where a ends, the insect sits across the cut.
    final dir = _session(
      [
        ..._clip('a.mp4', insectAt: (t) => t >= 8000),
        ..._clip('b.mp4', startMs: 10100, insectAt: (t) => t <= 1000),
        ..._clip('c.mp4', startMs: 60000),
      ],
      {'a.mp4': 1, 'b.mp4': 1, 'c.mp4': 1},
    );
    final r = await VideoTracker.run(dir, config);
    expect(r.visits, 1);
    expect((await ClipCleanup.planWithoutVisits(dir)).deleteNames, ['c.mp4']);
  });

  test('deleting writes a record; visits and kept frames stay', () async {
    final dir = _session(
      [
        ..._clip('a.mp4', insectAt: (t) => t >= 2000 && t <= 5000),
        ..._clip('b.mp4', startMs: 60000),
      ],
      {'a.mp4': 100, 'b.mp4': 200},
    );
    final before = await VideoTracker.run(dir, config, keep: _keep);
    final kept = await VideoTracker.readKeptFrames(dir);
    expect(kept, isNotEmpty);
    for (final k in kept) {
      File('${dir.path}/${VideoTracker.framesDirName}/${k.file}')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('saved');
    }
    final runId = (await VideoTracker.readSummary(dir))!.runId;

    final none = await ClipCleanup.planWithoutVisits(dir);
    expect(await ClipCleanup.run(dir, none), 1);
    expect(File('${dir.path}/videos/b.mp4').existsSync(), isFalse);
    expect(File('${dir.path}/videos/a.mp4').existsSync(), isTrue);

    expect(await ClipCleanup.run(dir, await ClipCleanup.planAll(dir)), 1);
    expect(VideoDetector.clipsOf(dir), isEmpty);

    // Two records after the session's end, in order.
    final records = [
      for (final l in File('${dir.path}/session.jsonl').readAsLinesSync())
        if (l.contains('"video_cleanup"')) (jsonDecode(l) as Map).cast<String, dynamic>(),
    ];
    expect([for (final r in records) r['mode']], ['without_visits', 'all']);
    expect([for (final r in records) r['clips']], [
      ['b.mp4'],
      ['a.mp4'],
    ]);
    expect([for (final r in records) r['freed_bytes']], [200, 100]);
    expect(records.first['visits_run_id'], runId);
    expect(records.first['time_iso'], isA<String>());
    final lines = File('${dir.path}/session.jsonl').readAsLinesSync();
    expect(lines[1], contains('"end_of_session"'));
    expect((await ClipCleanup.deletedClips(dir)).keys, unorderedEquals(['a.mp4', 'b.mp4']));

    // "Find visits" still runs from the saved boxes, even keeping frames by
    // another rule: the frames of the deleted clip stay on disk, and the
    // ones it can't make count as having no video.
    final again = await VideoTracker.run(dir, config, keep: const KeepFramesSettings(stepSeconds: 2, durationSeconds: 10));
    expect(again.visits, before.visits);
    for (final k in kept) {
      expect(File('${dir.path}/${VideoTracker.framesDirName}/${k.file}').readAsStringSync(), 'saved');
    }
    final status = await VideoFrameKeeper.status(dir);
    expect(status.remaining, 0);
    expect(status.saved + status.noVideo, status.total);
    expect((await ClipCleanup.planAll(dir)).isEmpty, isTrue);
  });
}
