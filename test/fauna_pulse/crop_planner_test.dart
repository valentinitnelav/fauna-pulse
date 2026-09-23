// Tests for crop planning (round 208): boxes → crop tasks from the session
// log index, the _live companion preference, post-hoc fallback, sampling.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/crop_planner.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';

const _log = '''
{"type":"start_of_session","time_ms":1000,"config":{}}
{"type":"detections","time_ms":2000,"tracks":[{"track_id":1,"confidence":0.8,"box_in_roi":{"left":0.1,"top":0.1,"right":0.3,"bottom":0.4},"jpeg":"roi_a_2026-07-14_120000_000.jpg"}]}
{"type":"capture","time_ms":2100,"file":"roi_a_2026-07-14_120000_000.jpg","captured_at_ms":2000,"path":"fast","saved_px":1024}
{"type":"detections","time_ms":3000,"tracks":[{"track_id":1,"confidence":0.9,"box_in_roi":{"left":0.2,"top":0.1,"right":0.5,"bottom":0.4},"jpeg":"roi_a_2026-07-14_120001_000.jpg"},{"track_id":2,"confidence":0.7,"box_in_roi":{"left":0.6,"top":0.6,"right":0.7,"bottom":0.7}}]}
{"type":"capture","time_ms":3100,"file":"roi_a_2026-07-14_120001_000.jpg","captured_at_ms":3000,"path":"still","saved_px":2000,"live_jpeg":"roi_a_2026-07-14_120001_000_live.jpg","live_saved_px":900}
{"type":"end_of_session","time_ms":4000,"ended_normally":true}
''';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('crop_planner_test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('planFromIndex yields one task per (photo, track) and prefers the live companion', () async {
    final log = File('${tmp.path}/session.jsonl')..writeAsStringSync(_log);
    final index = await SessionLogIndex.parseFile(log.path);
    final tasks = planFromIndex(index, fileExists: (n) => n.endsWith('_live.jpg'));
    expect(tasks.length, 3);
    expect(tasks[0].trackId, 1);
    expect(tasks[0].boxSource, 'trigger');
    expect(tasks[0].source, 'roi_a_2026-07-14_120000_000.jpg');
    expect(tasks[0].detConf, closeTo(0.8, 1e-9));
    // Second photo has a live companion: both its tracks use it.
    expect(tasks[1].source, 'roi_a_2026-07-14_120001_000_live.jpg');
    expect(tasks[1].boxSource, 'live');
    expect(tasks[1].photo, 'roi_a_2026-07-14_120001_000.jpg');
    expect(tasks[2].trackId, 2);
    expect(tasks[2].left, closeTo(0.6, 1e-9));
    expect(tasks[0].key, isNot(tasks[1].key));
  });

  test('planFromPostDetections keeps the last record per photo, no track ids', () {
    const jsonl = '''
{"type":"post_start"}
{"type":"post_detection","jpeg":"b.jpg","captured_at_ms":5,"boxes":[{"class_name":"insect","conf":0.5,"box":[0.1,0.1,0.2,0.2]}]}
{"type":"post_detection","jpeg":"b.jpg","captured_at_ms":5,"boxes":[{"class_name":"insect","conf":0.6,"box":[0.3,0.3,0.5,0.5]}]}
{"type":"post_detection","jpeg":"a.jpg","captured_at_ms":4,"boxes":[]}
{"type":"post_detection","jpeg":"c.jpg","captured_at
''';
    final tasks = planFromPostDetections(jsonl);
    expect(tasks.length, 1);
    expect(tasks.single.trackId, isNull);
    expect(tasks.single.detConf, closeTo(0.6, 1e-9));
    expect(tasks.single.boxSource, 'post');
    expect(tasks.single.captureMs, 5);
  });

  test('sampleTracks keeps the largest boxes per track, in original order', () {
    CropTask t(int id, double size, String src) => CropTask(
      source: src,
      photo: src,
      boxSource: 'trigger',
      trackId: id,
      left: 0,
      top: 0,
      right: size,
      bottom: size,
      detConf: 1,
      captureMs: null,
    );
    final tasks = [t(1, 0.1, 'p1'), t(1, 0.5, 'p2'), t(1, 0.3, 'p3'), t(2, 0.2, 'p4')];
    final kept = sampleTracks(tasks, 2);
    expect(kept.map((e) => e.source).toList(), ['p2', 'p3', 'p4']);
    expect(sampleTracks(tasks, 0).length, 4);
  });
}
