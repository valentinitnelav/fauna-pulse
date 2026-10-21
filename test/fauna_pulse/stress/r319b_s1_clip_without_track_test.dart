// Round 319 part 2 (S1c, phone test PA3 step c): an insect seen until the end of one
// clip is kept by the tracker into the next clip, where it is removed once its time
// runs out. That removal is the only record of the next clip, which has no box of any
// track ID (the player says "0 track IDs"), but the screen said "Every analyzed clip
// has at least one track ID." and never offered to delete that clip.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/clip_cleanup.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

final s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': 111, ...m});

/// One analyzed clip, 10 s at 10 frames per second, [startMs] after [s0].
List<String> _clip(String name, {int startMs = 0, bool Function(int t)? insectAt}) => [
  _rec('video_clip_start', {'clip': name, 'start_epoch_ms': s0 + startMs, 'width': 1920, 'height': 1080}),
  for (var t = 0; t <= 10000; t += 100)
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

void main() {
  test('a clip where a track ID only ran out of time counts as without track ID', () async {
    final dir = Directory.systemTemp.createTempSync('r319b_s1_clip_without_track');
    addTearDown(() => dir.deleteSync(recursive: true));
    final runStart = _rec('video_run_start', {
      'settings': {'model': 'm.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 10, 'roi': null},
    });
    File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      '${[
        runStart,
        // The insect stays until the end of a.mp4; b.mp4 follows right after, empty.
        ..._clip('a.mp4', insectAt: (t) => t >= 6000),
        ..._clip('b.mp4', startMs: 10100),
      ].join('\n')}\n',
    );
    File('${dir.path}/session.jsonl').writeAsStringSync(
      '${jsonEncode({'type': 'start_of_session', 'time_ms': s0, 'source': 'imported_video'})}\n',
    );
    Directory('${dir.path}/videos').createSync();
    File('${dir.path}/videos/a.mp4').writeAsBytesSync(List.filled(100, 0));
    File('${dir.path}/videos/b.mp4').writeAsBytesSync(List.filled(200, 0));

    await VideoTracker.run(dir, const SessionConfig());

    // As on the phone: in b.mp4 no box of the track ID, only its end (here also the first
    // frame it was missed in, as it was seen until the last frame of a.mp4).
    final inB = [
      for (final l in File('${dir.path}/${VideoTracker.outputFileName}').readAsLinesSync())
        if (jsonDecode(l) case {'clip': 'b.mp4'} && final r) r,
    ];
    expect(inB, isNotEmpty);
    expect(inB.map((r) => r['type']).toSet(), {'track_event'});
    expect(inB.map((r) => r['event']).toSet(), containsAll(['removed']));
    expect(inB.map((r) => r['event']).toSet().difference({'lost', 'removed'}), isEmpty);
    expect((await VideoTracker.readSummary(dir))!.visits, 1);

    final none = await ClipCleanup.planWithoutVisits(dir);
    expect(none.deleteNames, ['b.mp4']);
    expect(none.deleteBytes, 200);
  });
}
