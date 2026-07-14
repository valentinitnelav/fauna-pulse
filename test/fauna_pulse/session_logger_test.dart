// Tests for the append-only JSONL session logger, including the crash case
// where the end_of_session line never gets written. The logger queues records
// and writes them asynchronously (round 69), so tests await close()/flushNow()
// before reading the file back.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_logger.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('faunapulse_log'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('writes valid JSONL with type and timestamps', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logStart({'session_id': 'abc', 'battery_percent': 88});
    logger.logDetections([
      {'track_id': 1, 'confidence': 0.9},
    ]);
    logger.logEnd({'ended_normally': true});
    await logger.close();

    final lines = file.readAsLinesSync();
    expect(lines, hasLength(3));

    final records = lines
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    expect(records[0]['type'], 'start_of_session');
    expect(records[1]['type'], 'detections');
    expect(records[2]['type'], 'end_of_session');
    expect(records[2]['ended_normally'], true);

    for (final r in records) {
      expect(r['time_ms'], isA<int>());
      expect(r['time_iso'], isA<String>());
    }
  });

  test('one detections record per frame carries all concurrent tracks', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    // Three insects tracked in the same frame: one line, three entries, and
    // only the photo-covered tracks carry the jpeg filename.
    logger.logDetections([
      {'track_id': 1, 'confidence': 0.9, 'jpeg': 'roi_1.jpg'},
      {'track_id': 2, 'confidence': 0.8, 'jpeg': 'roi_1.jpg'},
      {'track_id': 5, 'confidence': 0.7},
    ]);
    await logger.close();

    final rec =
        jsonDecode(file.readAsLinesSync().single) as Map<String, dynamic>;
    expect(rec['type'], 'detections');
    final tracks = rec['tracks'] as List;
    expect(tracks, hasLength(3));
    expect(tracks[0]['jpeg'], 'roi_1.jpg');
    expect(tracks[2]['track_id'], 5);
    expect((tracks[2] as Map).containsKey('jpeg'), isFalse);
  });

  test('a crash (no end record) is detectable', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logStart({'session_id': 'abc'});
    logger.logDetections([
      {'track_id': 1},
    ]);
    // Simulate a crash: close the handle without writing end_of_session.
    await logger.close();

    final records = file
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    expect(records.any((r) => r['type'] == 'end_of_session'), isFalse);
    // The already-written lines are intact and parseable.
    expect(records, hasLength(2));
  });

  test('logCapture writes a capture record with its timing fields', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logStart({'session_id': 'abc'});
    logger.logCapture({
      'file': 'roi_1_2.jpg',
      'track_ids': [1, 2],
      'total_ms': 12.5,
      'bytes': 34567,
      'full_res': true,
    });
    logger.logEnd({'ended_normally': true});
    await logger.close();

    final records = file
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    final cap = records.firstWhere((r) => r['type'] == 'capture');
    expect(cap['file'], 'roi_1_2.jpg');
    expect(cap['track_ids'], [1, 2]);
    expect(cap['total_ms'], 12.5);
    expect(cap['full_res'], true);
  });

  test('logMotionCapture writes a motion_capture record with the jpeg link '
      'and the motion score that fired it', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logMotionCapture({'jpeg': 'roi_S_10000.jpg', 'motion_score': 0.012});
    await logger.close();

    final rec =
        jsonDecode(file.readAsLinesSync().single) as Map<String, dynamic>;
    expect(rec['type'], 'motion_capture');
    // Keyed `jpeg` on purpose — the same photo-link key detections records
    // use, so postprocessing joins photos identically in both modes.
    expect(rec['jpeg'], 'roi_S_10000.jpg');
    expect(rec['motion_score'], 0.012);
    expect(rec['time_ms'], isA<int>());
    expect(rec['time_iso'], isA<String>());
  });

  test('logTimeLapseCapture writes a timelapse_capture record with the jpeg '
      'link and its burst index', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logTimeLapseCapture({'jpeg': 'roi_S_20000.jpg', 'burst': 3});
    await logger.close();

    final rec =
        jsonDecode(file.readAsLinesSync().single) as Map<String, dynamic>;
    expect(rec['type'], 'timelapse_capture');
    expect(rec['jpeg'], 'roi_S_20000.jpg');
    expect(rec['burst'], 3);
    expect(rec['time_ms'], isA<int>());
  });

  test('enriched fps record round-trips the diagnostic fields', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logFps({'fps': 9.6, 'inf_ms': 64.8, 'engine': 'CPU'});
    await logger.close();

    final rec =
        jsonDecode(file.readAsLinesSync().single) as Map<String, dynamic>;
    expect(rec['type'], 'fps');
    expect(rec['fps'], 9.6);
    expect(rec['inf_ms'], 64.8);
    expect(rec['engine'], 'CPU');
  });

  test('a failed write never throws, notifies once, and can recover', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logStart({'session_id': 'abc'});
    // Make sure the start line is on disk before the "disk fills up".
    await logger.flushNow();

    // Simulate the disk filling up mid-session (B1): every write now fails.
    final errors = <Object>[];
    logger.onWriteError = errors.add;
    logger.debugInjectWriteError = const FileSystemException('disk full');

    // The per-frame path must survive this without throwing…
    logger.logDetections([
      {'track_id': 1},
    ]);
    logger.logDetections([
      {'track_id': 2},
    ]);
    await logger.flushNow();

    // …notify exactly once, and count every dropped line.
    expect(errors, hasLength(1));
    expect(logger.hasWriteError, isTrue);
    expect(logger.writeFailures, 2);

    // Storage freed up again: logging simply resumes.
    logger.debugInjectWriteError = null;
    logger.logEnd({'ended_normally': true});
    await logger.close();

    final records = file
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    // The failed detection lines are lost, but the file stays valid JSONL and
    // the end record still lands.
    expect(records, hasLength(2));
    expect(records.first['type'], 'start_of_session');
    expect(records.last['type'], 'end_of_session');
  });

  test('onWriteError may itself log (banner path) without recursing', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.debugInjectWriteError = const FileSystemException('disk full');
    var calls = 0;
    logger.onWriteError = (_) {
      calls++;
      // The screen's handler writes an app_error line from inside the
      // callback; with the disk still full this must not loop or throw.
      logger.logAppError({'source': 'session_log', 'message': 'log broken'});
    };
    logger.logDetections([
      {'track_id': 1},
    ]);
    await logger.close();
    expect(calls, 1);
  });

  test('logging after close is a silent no-op (late platform events)', () async {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logStart({'session_id': 'abc'});
    logger.logEnd({'ended_normally': true});
    await logger.close();
    // A straggler (late detector error, watchdog tick racing the stop
    // sequence) must not throw or reopen anything.
    logger.logAppError({'source': 'detector', 'message': 'late'});
    await logger.flushNow();
    expect(file.readAsLinesSync(), hasLength(2));
  });

  test('isoWithOffset has millisecond precision and an offset', () {
    final s = isoWithOffset(DateTime(2026, 6, 13, 19, 3, 12, 123));
    expect(s, contains('2026-06-13T19:03:12.123'));
    expect(RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(s), isTrue);
  });
}
