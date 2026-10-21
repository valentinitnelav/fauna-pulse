// Stress run, step P2: seeded mutation fuzzing of the session log readers
// (SessionLogIndex.parseFile and scanPastSessions). Rule: no hang, no huge
// allocation, and only a clear error type (FormatException / a documented
// result); never an uncaught TypeError or RangeError that would crash a
// screen. A case that shows a real bug is kept and marked skip: 'BUG: ...'.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fuzz_helpers.dart';
import 'session_fixture.dart';

void main() {
  late Directory tmp;
  late Uint8List valid;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fuzz_log_index');
    final f = await writeValidSession(Directory('${tmp.path}/valid'));
    valid = f.readAsBytesSync();
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<SessionLogIndex> parse(List<int> bytes, {String name = 'f'}) {
    final f = File('${tmp.path}/$name.jsonl')..writeAsBytesSync(bytes);
    return SessionLogIndex.parseFile(f.path);
  }

  test('the valid fixture parses (sanity)', () async {
    final index = await parse(valid);
    expect(index.startRecord, isNotNull);
    expect(index.trackSpans, isNotEmpty);
    expect(index.photoOrder, isNotEmpty);
  });

  group('SessionLogIndex.parseFile', () {
    test('byte-level damage: no hang, no crash, always a result', () async {
      final rnd = Random(20261020);
      final report = FuzzReport();
      for (final (name, bytes) in byteMutants(valid, rnd)) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          await parse(bytes);
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.slowest, lessThan(const Duration(seconds: 5)), reason: '$report');
      expect(report.clean, isTrue, reason: '$report');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('wrong JSON types in one field: a clear result, not a TypeError', () async {
      final rnd = Random(77);
      final lines = const LineSplitter().convert(utf8.decode(valid));
      final report = FuzzReport();
      for (final (name, mutated) in typeMutants(lines, rnd, count: 400)) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          await parse(utf8.encode('${mutated.join('\n')}\n'));
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    },
        timeout: const Timeout(Duration(seconds: 60)));
  });

  group('scanPastSessions', () {
    late Directory root;
    setUp(() => root = Directory('${tmp.path}/sessions')..createSync());

    Future<void> intact(String name, int startMs) async {
      await writeValidSession(Directory('${root.path}/$name'), startMs: startMs);
    }

    test('byte-level damage to one session never hides the others', () async {
      final rnd = Random(4242);
      await intact('a_intact_old', 1600000000000);
      await intact('z_intact_new', 1800000000000);
      final report = FuzzReport();
      var n = 0;
      for (final (name, bytes) in byteMutants(valid, rnd, perKind: 8)) {
        final d = Directory('${root.path}/m_damaged')..createSync();
        File('${d.path}/session.jsonl').writeAsBytesSync(bytes);
        final sw = Stopwatch()..start();
        Object? err;
        try {
          final found = await scanPastSessions(root: root);
          final names = found.map((s) => s.name).toSet();
          if (!names.containsAll({'a_intact_old', 'z_intact_new'})) {
            err = StateError('intact sessions missing from the list: $names');
          }
          if (!names.contains('m_damaged')) {
            // A folder with a session.jsonl must be listed, even when the log is empty or cut.
            err ??= StateError('the damaged session itself is missing from the list');
          }
          for (final s in found) {
            // These values feed the Sessions screen directly.
            if (s.sizeBytes < 0) err ??= StateError('negative size');
          }
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
        n++;
      }
      expect(n, greaterThan(50));
      expect(report.clean, isTrue, reason: '$report');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('the start record with a wrong type or out-of-range time_ms keeps the other sessions listed', () async {
      await intact('a_intact_old', 1600000000000);
      await intact('z_intact_new', 1800000000000);
      final report = FuzzReport();
      const starts = [
        '"time_ms":"1700000000000"',
        '"time_ms":[]',
        '"time_ms":{}',
        '"time_ms":true',
        '"time_ms":1e999',
        '"time_ms":99999999999999999999',
        '"time_ms":1e20',
        '"time_ms":-99999999999999999',
        '"time_ms":8640000000000001',
        '"time_ms":null',
      ];
      for (final t in starts) {
        final d = Directory('${root.path}/m_bad_start')..createSync();
        File('${d.path}/session.jsonl').writeAsStringSync(
          '{"type":"start_of_session",$t,"config":{}}\n'
          '{"type":"end_of_session","time_ms":1700000100000,"ended_normally":true}\n',
        );
        Object? err;
        final sw = Stopwatch()..start();
        try {
          final names = (await scanPastSessions(root: root)).map((s) => s.name).toSet();
          if (!names.containsAll({'a_intact_old', 'z_intact_new', 'm_bad_start'})) {
            err = StateError('sessions missing from the list: $names');
          }
        } catch (e) {
          err = e;
        }
        report.add('start record $t', err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('the end record with a wrong type only loses the duration', () async {
      await intact('a_intact_old', 1600000000000);
      final d = Directory('${root.path}/b_bad_end')..createSync();
      File('${d.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":1700000000000,"config":{}}\n'
        '{"type":"end_of_session","time_ms":"soon","ended_normally":"yes"}\n',
      );
      await intact('z_intact_new', 1800000000000);
      final names = (await scanPastSessions(root: root)).map((s) => s.name).toList();
      expect(names, ['z_intact_new', 'b_bad_end', 'a_intact_old']);
    });

    test('a session folder with an unreadable (directory) session.jsonl does not stop the scan', () async {
      await intact('a_intact_old', 1600000000000);
      Directory('${root.path}/b_dir_log/session.jsonl').createSync(recursive: true);
      await intact('z_intact_new', 1800000000000);
      final names = (await scanPastSessions(root: root)).map((s) => s.name).toSet();
      expect(names, containsAll({'a_intact_old', 'z_intact_new'}));
    });

    test('a missing root and an empty root give an empty list', () async {
      expect(await scanPastSessions(root: Directory('${tmp.path}/nowhere')), isEmpty);
      expect(await scanPastSessions(root: root), isEmpty);
    });
  });
}
