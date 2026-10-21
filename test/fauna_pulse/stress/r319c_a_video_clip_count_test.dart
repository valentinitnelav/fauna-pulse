// Round 319 part 3 (A5, phone checks P2X d-S1c and P2R S1c): "Find animals in videos" said
// '8 track IDs in 8 of 8 clips' right above 'Delete 4 clips without any track ID', and the end
// bar 'Found 8 track IDs in 8 clips': it counted every clip the tracker went through. It now
// counts the clips in which a track ID has a box, with the rule of "Delete … clips without any
// track ID" (ClipCleanup.planWithoutVisits): a clip whose only record is a removal has none.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/clip_cleanup.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
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

/// Clips a.mp4 (an insect from 6 s to its end), b.mp4 right after it (only the insect's
/// removal), c.mp4 an hour later (empty) and d.mp4 (an insect from 2 to 5 s).
Directory _session() {
  final dir = Directory.systemTemp.createTempSync('r319c_a_clip_count');
  final runStart = _rec('video_run_start', {
    'settings': {'model': 'm.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 10, 'roi': null},
  });
  File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync(
    '${[
      runStart,
      ..._clip('a.mp4', insectAt: (t) => t >= 6000),
      ..._clip('b.mp4', startMs: 10100),
      ..._clip('c.mp4', startMs: 3600000),
      ..._clip('d.mp4', startMs: 7200000, insectAt: (t) => t >= 2000 && t <= 5000),
    ].join('\n')}\n',
  );
  File('${dir.path}/session.jsonl').writeAsStringSync(
    '${jsonEncode({'type': 'start_of_session', 'time_ms': s0, 'source': 'imported_video'})}\n',
  );
  Directory('${dir.path}/videos').createSync();
  for (final c in ['a', 'b', 'c', 'd']) {
    File('${dir.path}/videos/$c.mp4').writeAsBytesSync(List.filled(100, 0));
  }
  return dir;
}

void main() {
  late Directory dir;
  setUp(() => dir = _session());
  tearDown(() => dir.deleteSync(recursive: true));

  test('the tracker counts the clips with a track ID as "Delete … without any track ID" does', () async {
    final r = await VideoTracker.run(dir, const SessionConfig());
    expect((r.visits, r.clipsTracked), (2, 4));
    final without = await ClipCleanup.planWithoutVisits(dir);
    expect(without.deleteNames, ['b.mp4', 'c.mp4']);
    expect(r.clipsWithTrackIds, r.clipsTracked - without.deleteNames.length);
    expect(r.clipsWithTrackIds, 2);

    final summary = (await VideoTracker.readSummary(dir))!;
    expect(summary.clips, hasLength(4));
    expect(summary.clipsWithTrackIds, 2);
    final end = jsonDecode(File('${dir.path}/${VideoTracker.outputFileName}').readAsLinesSync().last) as Map;
    expect(end['clips_with_track_ids'], 2);

    // The screen's lines: the end bar ('Found …') and the Track IDs part.
    expect('Found ${trackIdsInClips(r.visits, r.clipsWithTrackIds, r.clipsTracked)}.', 'Found 2 track IDs in 2 of 4 clips.');
    expect(trackIdsInClips(summary.visits, summary.clipsWithTrackIds, 4), '2 track IDs in 2 of 4 clips');
  });

  test('results written before this round (no count in post_track_end): counted from the boxes', () async {
    await VideoTracker.run(dir, const SessionConfig());
    final out = File('${dir.path}/${VideoTracker.outputFileName}');
    final lines = out.readAsLinesSync();
    final end = (jsonDecode(lines.last) as Map)..remove('clips_with_track_ids');
    out.writeAsStringSync('${[...lines.take(lines.length - 1), jsonEncode(end)].join('\n')}\n');
    expect((await VideoTracker.readSummary(dir))!.clipsWithTrackIds, 2);
  });

  test('the words: one, several, none', () {
    expect(trackIdsInClips(1, 1, 1), '1 track ID in 1 of 1 clip');
    expect(trackIdsInClips(1, 2, 2), '1 track ID in 2 of 2 clips');
    expect(trackIdsInClips(8, 4, 8), '8 track IDs in 4 of 8 clips');
    expect(trackIdsInClips(0, 0, 8), '0 track IDs in 8 clips');
    expect(trackIdsInClips(0, 0, 1), '0 track IDs in 1 clip');
  });
}
