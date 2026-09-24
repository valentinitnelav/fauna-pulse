// Round 229: which file holds a session's visits (track_source.dart), and
// SessionLogIndex reading visits found afterwards from post_tracks.jsonl.
// The rule under test: one source per session, never both.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';
import 'package:fauna_pulse/fauna_pulse/logging/track_source.dart';

String _rec(String type, Map<String, dynamic> fields) =>
    jsonEncode({'type': type, ...fields});

String _start({Map<String, dynamic>? config}) => _rec('start_of_session', {
  'time_ms': 1000,
  if (config == null) 'source': 'imported_video',
  'config': ?config,
});

String _detections(int ms, List<int> ids) => _rec('detections', {
  'time_ms': ms,
  'frame_ms': ms,
  'tracks': [
    for (final id in ids)
      {
        'track_id': id,
        'class_name': 'bee',
        'confidence': 0.9,
        'box_in_roi': {'left': 0.1, 'top': 0.1, 'right': 0.2, 'bottom': 0.2},
      },
  ],
});

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('track_source_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File writeLog(List<String> lines) =>
      File('${tmp.path}/session.jsonl')
        ..writeAsStringSync('${lines.join('\n')}\n');

  File writePost(List<String> lines) =>
      File('${tmp.path}/$postTracksFileName')
        ..writeAsStringSync('${lines.join('\n')}\n');

  group('trackSourceOf', () {
    test('no post_tracks.jsonl: live, whatever the session', () {
      writeLog([_start()]);
      expect(trackSourceOf(tmp), TrackSource.live);
      expect(tracksFileOf(tmp).path, '${tmp.path}/session.jsonl');
    });

    test('imported videos with found visits: afterwards', () {
      writeLog([_start()]);
      writePost([_rec('post_track_start', {'time_ms': 1000})]);
      expect(trackSourceOf(tmp), TrackSource.afterwards);
      expect(tracksFileOf(tmp).path, '${tmp.path}/$postTracksFileName');
    });

    test('a live AI session keeps its own visits even with a post file', () {
      writeLog([
        _start(config: {'captureTrigger': 'detector'}),
      ]);
      writePost([_rec('post_track_start', {'time_ms': 1000})]);
      expect(trackSourceOf(tmp), TrackSource.live);
    });

    test('time-lapse and motion sessions have no live visits', () {
      writePost([_rec('post_track_start', {'time_ms': 1000})]);
      for (final trigger in ['timelapse', 'motion']) {
        writeLog([
          _start(config: {'captureTrigger': trigger}),
        ]);
        expect(trackSourceOf(tmp), TrackSource.afterwards, reason: trigger);
      }
      // Before round 97 only the motion-only switch marked a no-AI session.
      writeLog([
        _start(config: {'motionOnlyCapture': true}),
      ]);
      expect(trackSourceOf(tmp), TrackSource.afterwards);
      writeLog([_start(config: <String, dynamic>{})]);
      expect(trackSourceOf(tmp), TrackSource.live);
    });

    test('a missing or unreadable log with a post file: afterwards', () {
      writePost([_rec('post_track_start', {'time_ms': 1000})]);
      expect(trackSourceOf(tmp), TrackSource.afterwards);
      writeLog(['{"type":"start_of_sess']); // cut off mid-write
      expect(trackSourceOf(tmp), TrackSource.afterwards);
    });
  });

  group('SessionLogIndex with visits found afterwards', () {
    test('visits come from post_tracks.jsonl only', () async {
      writeLog([
        _start(),
        _rec('video_clip', {'time_ms': 1000, 'file': 'videos/a.mp4'}),
        // Never written for imported videos; if it were, it must not count.
        _detections(1500, [9]),
        _rec('end_of_session', {'time_ms': 20000, 'ended_normally': true}),
      ]);
      writePost([
        _rec('post_track_start', {
          'time_ms': 1000,
          'observed_ms': 19000,
          'tracker': {'algorithm': 'bytetrack'},
        }),
        _detections(2000, [1]),
        _detections(3000, [1, 2]),
        _rec('track_event', {'time_ms': 3000, 'event': 'lost'}),
        _detections(5000, [2]),
        _rec('post_track_end', {'time_ms': 20000, 'visits': 2}),
      ]);

      final index = await SessionLogIndex.build(File('${tmp.path}/session.jsonl'));
      expect(index.trackSource, TrackSource.afterwards);
      expect(index.trackSpans, {1: (2000, 3000), 2: (3000, 5000)});
      expect(index.startRecord?['source'], 'imported_video');
      expect(index.postTrackStart?['observed_ms'], 19000);
      expect(index.postTrackStart?['tracker'], {'algorithm': 'bytetrack'});
    });

    test('a live AI session reads session.jsonl and ignores the post file', () async {
      writeLog([
        _start(config: {'captureTrigger': 'detector'}),
        _detections(1500, [9]),
      ]);
      writePost([
        _rec('post_track_start', {'time_ms': 1000}),
        _detections(2000, [1]),
      ]);

      final index = await SessionLogIndex.build(File('${tmp.path}/session.jsonl'));
      expect(index.trackSource, TrackSource.live);
      expect(index.trackSpans, {9: (1500, 1500)});
      expect(index.postTrackStart, isNull);
    });
  });
}
