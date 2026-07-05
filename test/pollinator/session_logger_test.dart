// Tests for the append-only JSONL session logger, including the crash case
// where the end_of_session line never gets written.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pollinator_monitor/pollinator/logging/session_logger.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('pollinator_log'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('writes valid JSONL with type and timestamps', () {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logStart({'session_id': 'abc', 'battery_percent': 88});
    logger.logDetection({'track_id': 1, 'confidence': 0.9});
    logger.logEnd({'ended_normally': true});
    logger.close();

    final lines = file.readAsLinesSync();
    expect(lines, hasLength(3));

    final records = lines.map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
    expect(records[0]['type'], 'start_of_session');
    expect(records[1]['type'], 'detection');
    expect(records[2]['type'], 'end_of_session');
    expect(records[2]['ended_normally'], true);

    for (final r in records) {
      expect(r['time_ms'], isA<int>());
      expect(r['time_iso'], isA<String>());
    }
  });

  test('a crash (no end record) is detectable', () {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logStart({'session_id': 'abc'});
    logger.logDetection({'track_id': 1});
    // Simulate a crash: close the handle without writing end_of_session.
    logger.close();

    final records = file
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    expect(records.any((r) => r['type'] == 'end_of_session'), isFalse);
    // The already-written lines are intact and parseable.
    expect(records, hasLength(2));
  });

  test('logCapture writes a capture record with its timing fields', () {
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
    logger.close();

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

  test('enriched fps record round-trips the diagnostic fields', () {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logFps({'fps': 9.6, 'inf_ms': 64.8, 'engine': 'CPU'});
    logger.close();

    final rec = jsonDecode(file.readAsLinesSync().single) as Map<String, dynamic>;
    expect(rec['type'], 'fps');
    expect(rec['fps'], 9.6);
    expect(rec['inf_ms'], 64.8);
    expect(rec['engine'], 'CPU');
  });

  test('a failed write never throws, notifies once, and can recover', () {
    final file = File('${tmp.path}/session.jsonl');
    final logger = SessionLogger(file)..open();
    logger.logStart({'session_id': 'abc'});

    // Simulate the disk filling up mid-session (B1): every append now fails.
    final errors = <Object>[];
    logger.onWriteError = errors.add;
    logger.debugInjectWriteError = const FileSystemException('disk full');

    // The per-frame path must survive this without throwing…
    logger.logDetection({'track_id': 1});
    logger.logDetection({'track_id': 2});
    logger.flushNow();

    // …notify exactly once, and count every dropped line.
    expect(errors, hasLength(1));
    expect(logger.hasWriteError, isTrue);
    expect(logger.writeFailures, 2);

    // Storage freed up again: logging simply resumes.
    logger.debugInjectWriteError = null;
    logger.logEnd({'ended_normally': true});
    logger.close();

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

  test('onWriteError may itself log (banner path) without recursing', () {
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
    logger.logDetection({'track_id': 1});
    expect(calls, 1);
    logger.close();
  });

  test('isoWithOffset has millisecond precision and an offset', () {
    final s = isoWithOffset(DateTime(2026, 6, 13, 19, 3, 12, 123));
    expect(s, contains('2026-06-13T19:03:12.123'));
    expect(RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(s), isTrue);
  });
}
