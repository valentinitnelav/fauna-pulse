// Tests for offline tracking of analysed videos (round 228): synthetic
// video_detections.jsonl files in, visits / post_tracks.jsonl / visits.csv /
// MOT files out. The fixture lines have the shape VideoDetector writes.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_logger.dart' show isoWithOffset;
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/track_export.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';

final s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': 111, ...m});

String _runStart({double fps = 10}) => _rec('video_run_start', {
  'settings': {'model': 'm.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': fps, 'roi': null, 'max_side_px': 0},
});

/// One box `[l, t, r, b, conf, cls]` (frame-normalized) of a resting insect.
List<num> _box(double x, {int cls = 0}) => [x, 0.40, x + 0.05, 0.48, 0.9, cls];

/// The records of one clip: start, one `raw_detections` per analysed frame
/// (every [stepMs] of a 30 fps video), and `video_clip_done` if [done].
List<String> _clip(
  String name, {
  required int startMs,
  int durationMs = 10000,
  int stepMs = 100,
  List<num>? Function(int t)? boxAt,
  bool done = true,
  List<int>? roiPx,
}) => [
  _rec('video_clip_start', {'clip': name, 'start_epoch_ms': startMs, 'width': 1920, 'height': 1080}),
  for (var t = 0; t <= durationMs; t += stepMs)
    _rec('raw_detections', {
      'frame_ms': startMs + t,
      'clip': name,
      'pts_us': t * 1000,
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

Directory _session(List<String> lines) {
  final dir = Directory.systemTemp.createTempSync('video_tracker_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync('${lines.join('\n')}\n');
  return dir;
}

List<Map<String, dynamic>> _records(Directory d) => [
  for (final l in File('${d.path}/${VideoTracker.outputFileName}').readAsLinesSync())
    (jsonDecode(l) as Map).cast<String, dynamic>(),
];

/// visits.csv rows without the header, split into cells (no quoted cells here).
List<List<String>> _visits(Directory d) => [
  for (final l in File('${d.path}/${TrackExport.visitsFileName}').readAsLinesSync().skip(1)) l.split(','),
];

List<String> _mot(Directory d, String name) => File('${d.path}/mot/$name').readAsLinesSync();

String _iso(int ms) => isoWithOffset(DateTime.fromMillisecondsSinceEpoch(ms));

void main() {
  const config = SessionConfig(); // occlusion 3 s, minimum visit 0.2 s

  group('VideoTracker.run', () {
    test('one insect gives one visit, and every file is written', () async {
      final lines = [
        _runStart(),
        ..._clip(
          'a.mp4',
          startMs: s0,
          boxAt: (t) => t >= 2000 && t <= 5000 ? _box(0.40) : null,
          roiPx: [420, 0, 1080, 1080], // a square in the middle of the frame
        ),
      ];
      lines.insert(30, lines[30]); // a line written twice must count once
      final dir = _session(lines);

      final result = await VideoTracker.run(dir, config);
      expect(result.visits, 1);
      expect(result.clipsTracked, 1);
      expect(result.clipsLeftOut, 0);
      expect(result.frames, 101);

      final rows = _visits(dir);
      expect(rows, hasLength(1));
      final mot = _mot(dir, 'a.txt');
      expect(rows.single, [
        '1',
        'a.mp4',
        _iso(s0 + 2000),
        '2.000',
        '5.000',
        '3.000',
        '${mot.length}',
        '0.900',
        'bee',
      ]);
      // From confirmation (0.2 s = 2 frames at 10 fps) to the last sighting.
      expect(mot.length, inInclusiveRange(28, 31));
      final m = mot.first.split(',');
      expect(int.parse(m[0]), greaterThanOrEqualTo(2000 * 30 ~/ 1000 + 1)); // frames count from 1
      expect(m[1], '1');
      expect(double.parse(m[2]), closeTo(768, 1)); // 0.40 * 1920
      expect(double.parse(m[3]), closeTo(432, 1)); // 0.40 * 1080
      expect(double.parse(m[4]), closeTo(96, 1));
      expect(double.parse(m[5]), closeTo(86.4, 1));
      expect(m.sublist(6), ['0.9000', '-1', '-1', '-1']);

      final recs = _records(dir);
      expect(recs.first['type'], 'post_track_start');
      expect(recs.first['detections_run_ms'], 111);
      expect(recs.first['clips'], ['a.mp4']);
      expect(recs.first['clips_left_out'], isEmpty);
      expect(recs.first['tracker']['algorithm'], config.trackerAlgorithm.name);
      expect(recs.last['type'], 'post_track_end');
      expect(recs.last['visits'], 1);
      expect(recs.last['frames'], 101);

      // Shaped like a live session log, stamped with the frame's own time.
      final dets = recs.where((r) => r['type'] == 'detections').toList();
      expect(dets, hasLength(mot.length));
      for (final r in dets) {
        expect(r['time_ms'], r['frame_ms']);
        expect(r['clip'], 'a.mp4');
        expect(r['pts_us'], ((r['frame_ms'] as int) - s0) * 1000);
      }
      final track = (dets.first['tracks'] as List).single as Map;
      expect(track['track_id'], 1);
      expect(track['class_name'], 'bee');
      // Box relative to the analysed square, as live sessions log it.
      expect(track['box_in_roi']['left'], closeTo((0.40 - 420 / 1920) / (1080 / 1920), 1e-3));
      expect(track['box_in_roi']['top'], closeTo(0.40, 1e-3));
      final created = recs.where((r) => r['type'] == 'track_event' && r['event'] == 'created');
      expect(created.map((r) => r['track_id']), [1]);
      expect(created.single['clip'], 'a.mp4');

      expect(dir.listSync(recursive: true).where((e) => e.path.endsWith('.tmp')), isEmpty);

      final summary = await VideoTracker.readSummary(dir);
      expect(summary, isNotNull);
      expect(summary!.visits, 1);
      expect(summary.clips, ['a.mp4']);
      expect(summary.detectionsRunMs, 111);
      expect(summary.occlusionSeconds, 3.0);
      expect(summary.minHitsSeconds, 0.2);
      expect(summary.algorithm, config.trackerAlgorithm.name);
    });

    test('a gap longer than the occlusion tolerance makes two visits', () async {
      final dir = _session([
        _runStart(),
        ..._clip(
          'a.mp4',
          startMs: s0,
          boxAt: (t) => t >= 1000 && t <= 3000
              ? _box(0.40)
              : t >= 8000
              ? _box(0.40, cls: 1)
              : null,
        ),
      ]);
      final result = await VideoTracker.run(dir, config);
      expect(result.visits, 2);
      final rows = _visits(dir);
      expect(rows.map((r) => r[0]), ['1', '2']);
      expect(rows.map((r) => r[3]), ['1.000', '8.000']);
      expect(rows.map((r) => r[8]), ['bee', 'fly']); // names from video_clip_done
    });

    test('a gap shorter than the occlusion tolerance keeps one visit (both trackers)', () async {
      for (final alg in TrackerAlgorithm.values) {
        final dir = _session([
          _runStart(),
          ..._clip(
            'a.mp4',
            startMs: s0,
            boxAt: (t) => (t >= 1000 && t <= 3000) || (t >= 4000 && t <= 6000) ? _box(0.40) : null,
          ),
        ]);
        final result = await VideoTracker.run(dir, SessionConfig(trackerAlgorithm: alg));
        expect(result.visits, 1, reason: alg.name);
        expect(_visits(dir).single[4], '6.000', reason: alg.name);
      }
    });

    test('clips recorded back to back share one tracker', () async {
      final dir = _session([
        _runStart(),
        ..._clip('a.mp4', startMs: s0, durationMs: 5000, boxAt: (t) => t >= 3000 ? _box(0.40) : null),
        ..._clip('b.mp4', startMs: s0 + 5100, durationMs: 5000, boxAt: (t) => t <= 2000 ? _box(0.40) : null),
      ]);
      final result = await VideoTracker.run(dir, config);
      expect(result.visits, 1);
      final row = _visits(dir).single;
      // The visit keeps the clock of the clip it began in.
      expect(row.sublist(1, 2), ['a.mp4']);
      expect(row[3], '3.000');
      expect(row[4], '7.100');
      expect(_records(dir).first['clips_continuing_previous'], ['b.mp4']);
      final b = _mot(dir, 'b.txt');
      expect(b.first, startsWith('1,1,')); // b's own frame numbers, same id
      expect(_mot(dir, 'a.txt').every((l) => l.split(',')[1] == '1'), isTrue);
    });

    test('overlapping or far apart clips start afresh, ids stay unique', () async {
      final dir = _session([
        _runStart(),
        ..._clip('a.mp4', startMs: s0, durationMs: 5000, boxAt: (_) => _box(0.40)),
        ..._clip('b.mp4', startMs: s0 + 2000, durationMs: 5000, boxAt: (_) => _box(0.40)), // overlaps a
        ..._clip('c.mp4', startMs: s0 + 60000, durationMs: 5000, boxAt: (_) => _box(0.40)), // a minute later
      ]);
      final result = await VideoTracker.run(dir, config);
      expect(result.visits, 3);
      expect(_visits(dir).map((r) => '${r[0]} ${r[1]} ${r[3]}'), ['1 a.mp4 0.000', '2 b.mp4 0.000', '3 c.mp4 0.000']);
      expect(_records(dir).first['clips_continuing_previous'], isEmpty);
      // Filmed time counts the overlap of a and b once: 7 s + 5 s.
      expect(_records(dir).first['observed_ms'], 12000);
    });

    test('2 analysed frames per second still follow one insect', () async {
      final dir = _session([
        _runStart(fps: 2),
        ..._clip('a.mp4', startMs: s0, stepMs: 500, boxAt: (t) => t >= 2000 && t <= 8000 ? _box(0.40) : null),
      ]);
      final result = await VideoTracker.run(dir, config);
      expect(result.visits, 1);
      final row = _visits(dir).single;
      expect(row[3], '2.000');
      expect(row[4], '8.000');
      expect(int.parse(row[6]), greaterThanOrEqualTo(12));
    });

    test('clips whose analysis did not finish are left out', () async {
      final dir = _session([
        _runStart(),
        ..._clip('a.mp4', startMs: s0, boxAt: (_) => _box(0.40)),
        ..._clip('b.mp4', startMs: s0 + 20000, boxAt: (_) => _box(0.40), done: false),
      ]);
      final result = await VideoTracker.run(dir, config);
      expect(result.clipsTracked, 1);
      expect(result.clipsLeftOut, 1);
      expect(result.visits, 1);
      final start = _records(dir).first;
      expect(start['clips'], ['a.mp4']);
      expect(start['clips_left_out'], ['b.mp4']);
      expect(Directory('${dir.path}/mot').listSync().map((e) => e.uri.pathSegments.last), ['a.txt']);
    });

    test('nothing to track: no analysis yet, or no finished clip', () async {
      final empty = _session([]);
      File('${empty.path}/${VideoDetector.outputFileName}').deleteSync();
      await expectLater(VideoTracker.run(empty, config), throwsStateError);
      final unfinished = _session([_runStart(), ..._clip('a.mp4', startMs: s0, done: false)]);
      await expectLater(VideoTracker.run(unfinished, config), throwsStateError);
      expect(File('${unfinished.path}/${VideoTracker.outputFileName}').existsSync(), isFalse);
    });

    test('a re-run with other settings replaces the previous results', () async {
      final dir = _session([
        _runStart(),
        ..._clip(
          'a.mp4',
          startMs: s0,
          boxAt: (t) => (t >= 1000 && t <= 3000) || (t >= 4000 && t <= 6000) ? _box(0.40) : null,
        ),
      ]);
      Directory('${dir.path}/mot').createSync();
      File('${dir.path}/mot/old.txt').writeAsStringSync('1,1,0,0,1,1,1,-1,-1,-1\n');
      expect((await VideoTracker.run(dir, config)).visits, 1);
      expect(File('${dir.path}/mot/old.txt').existsSync(), isFalse);

      final strict = config.copyWith(occlusionSeconds: 0.5); // the 1 s gap now splits the visit
      expect((await VideoTracker.run(dir, strict)).visits, 2);
      expect(_visits(dir), hasLength(2));
      expect((await VideoTracker.readSummary(dir))!.occlusionSeconds, 0.5);
    });

    test('a failed run leaves the previous results in place', () async {
      final dir = _session([
        _runStart(),
        ..._clip('a.mp4', startMs: s0, boxAt: (_) => _box(0.40)),
      ]);
      await VideoTracker.run(dir, config);
      final before = File('${dir.path}/${VideoTracker.outputFileName}').readAsStringSync();
      // A folder in the way of the temporary file makes writing fail.
      Directory('${dir.path}/${VideoTracker.outputFileName}.tmp').createSync();
      await expectLater(VideoTracker.run(dir, config), throwsA(anything));
      expect(File('${dir.path}/${VideoTracker.outputFileName}').readAsStringSync(), before);
    });

    test('readSummary: null for a missing or unfinished file', () async {
      final dir = _session([]);
      expect(await VideoTracker.readSummary(dir), isNull);
      File('${dir.path}/${VideoTracker.outputFileName}').writeAsStringSync(
        '${_rec('post_track_start', {'clips': <String>[]})}\n${_rec('detections', {})}\n',
      );
      expect(await VideoTracker.readSummary(dir), isNull);
    });

    test('writeResultsZip packs the results and the logs they came from', () async {
      final dir = _session([
        _runStart(),
        ..._clip('a.mp4', startMs: s0, boxAt: (_) => _box(0.40)),
      ]);
      File('${dir.path}/session.jsonl').writeAsStringSync('{"type":"start_of_session"}\n');
      await VideoTracker.run(dir, config);
      final zipPath = '${dir.path}/results.zip';
      expect(await VideoTracker.writeResultsZip(dir.path, zipPath), zipPath);
      final names = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync()).files.map((f) => f.name);
      expect(names, [
        'visits.csv',
        'post_tracks.jsonl',
        'video_detections.jsonl',
        'session.jsonl',
        'mot/a.txt',
      ]);
    });
  });

  group('TrackExport', () {
    test('visits.csv: sorted by id, times from the clip start, quoted cells', () {
      final a = VideoVisit(trackId: 2, clip: 'b, 2.mp4', clipStartMs: s0, firstSeenMs: s0 + 1500)
        ..lastSeenMs = s0 + 4250
        ..addFrame(0.8, 'fly')
        ..addFrame(0.6, 'bee')
        ..addFrame(0.7, 'fly');
      final b = VideoVisit(trackId: 1, clip: 'a.mp4', clipStartMs: s0, firstSeenMs: s0 + 250)
        ..lastSeenMs = s0 + 1000
        ..addFrame(0.9, 'bee');
      expect(
        TrackExport.visitsCsv([a, b]),
        'track_id,clip,start_time,start_s,end_s,duration_s,n_frames,mean_conf,class\n'
        '1,a.mp4,${_iso(s0 + 250)},0.250,1.000,0.750,1,0.900,bee\n'
        '2,"b, 2.mp4",${_iso(s0 + 1500)},1.500,4.250,2.750,3,0.700,fly\n',
      );
    });

    test('a class tie goes to the class seen first', () {
      final v = VideoVisit(trackId: 1, clip: 'a.mp4', clipStartMs: 0, firstSeenMs: 0)
        ..addFrame(0.5, 'bee')
        ..addFrame(0.5, 'fly');
      expect(v.className, 'bee');
      expect(VideoVisit(trackId: 1, clip: 'a.mp4', clipStartMs: 0, firstSeenMs: 0).className, '');
    });

    test('MOT text: sorted by frame then id, MOTChallenge columns', () {
      expect(
        TrackExport.motText([
          (frame: 3, id: 2, x: 10.0, y: 20.5, w: 30.25, h: 40.0, conf: 0.5),
          (frame: 3, id: 1, x: 1.0, y: 2.0, w: 3.0, h: 4.0, conf: 0.91234),
          (frame: 1, id: 2, x: 0.0, y: 0.0, w: 5.0, h: 5.0, conf: 1.0),
        ]),
        '1,2,0.00,0.00,5.00,5.00,1.0000,-1,-1,-1\n'
        '3,1,1.00,2.00,3.00,4.00,0.9123,-1,-1,-1\n'
        '3,2,10.00,20.50,30.25,40.00,0.5000,-1,-1,-1\n',
      );
    });

    test('MOT file names: the clip name without extension, unless two clips share it', () {
      expect(TrackExport.motFileNames(['a.mp4', 'a.mov', 'b.mp4', 'noext']), {
        'a.mp4': 'a.mp4.txt',
        'a.mov': 'a.mov.txt',
        'b.mp4': 'b.txt',
        'noext': 'noext.txt',
      });
    });
  });
}
