// Tests for the error-report log sampler (head + tail with an omission
// marker, long lines capped) and the persistent crash store (file name /
// body format, newest-first recall, prune-to-max).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/crash_store.dart';
import 'package:fauna_pulse/fauna_pulse/logging/error_reporter.dart';

void main() {
  group('headTailSample', () {
    test('short input passes through unchanged', () {
      final lines = List.generate(10, (i) => 'line $i');
      expect(headTailSample(lines, head: 30, tail: 200), lines.join('\n'));
    });

    test('long input keeps head + tail with an omission marker', () {
      final lines = List.generate(500, (i) => 'line $i');
      final out = headTailSample(lines, head: 30, tail: 200).split('\n');
      expect(out, hasLength(30 + 1 + 200));
      expect(out.first, 'line 0');
      expect(out[29], 'line 29');
      expect(out[30], '… 270 lines omitted …');
      expect(out[31], 'line 300');
      expect(out.last, 'line 499');
    });

    test('exactly head+tail lines needs no marker', () {
      final lines = List.generate(230, (i) => 'line $i');
      final out = headTailSample(lines, head: 30, tail: 200);
      expect(out, isNot(contains('omitted')));
      expect(out.split('\n'), hasLength(230));
    });

    test('caps overlong lines', () {
      final long = 'x' * 5000;
      final out = headTailSample([long], head: 30, tail: 200);
      expect(out.length, lessThan(2100));
      expect(out, endsWith('…[truncated]'));
    });

    test('tail 0 keeps only the head (crash-file cap)', () {
      final lines = List.generate(50, (i) => 'line $i');
      final out = headTailSample(lines, head: 20, tail: 0).split('\n');
      expect(out, hasLength(21));
      expect(out.last, '… 30 lines omitted …');
    });
  });

  group('crash file format', () {
    test('file name is a fixed-width local stamp', () {
      expect(
        crashFileName(DateTime(2026, 7, 17, 14, 32, 5)),
        'crash_2026-07-17_143205.txt',
      );
    });

    test('body carries ISO timestamp, source, error and stack', () {
      final body = crashFileBody(
        DateTime(2026, 7, 17, 14, 32, 5, 123),
        'uncaught_async',
        StateError('camera gone'),
        StackTrace.fromString('#0 somewhere\n#1 else\n'),
      );
      expect(body, startsWith('Crash captured: 2026-07-17T14:32:05.123'));
      expect(body, contains('Source: uncaught_async'));
      expect(body, contains('camera gone'));
      expect(body, contains('#1 else'));
    });
  });

  group('CrashStore', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('crash_store_test');
      CrashStore.debugDirOverride = tmp;
      CrashStore.resetForTest();
    });

    tearDown(() {
      CrashStore.debugDirOverride = null;
      tmp.deleteSync(recursive: true);
    });

    test('record writes one file into crashes/', () async {
      final file = await CrashStore.record(
        source: 'flutter_framework',
        error: 'boom',
      );
      expect(file, isNotNull);
      expect(file!.path, contains('/crashes/crash_'));
      expect(await file.readAsString(), contains('Error: boom'));
    });

    test('rate limit: an immediate second record is dropped', () async {
      await CrashStore.record(source: 'a', error: '1');
      final second = await CrashStore.record(source: 'a', error: '2');
      expect(second, isNull);
    });

    test('recent returns newest first and prune keeps maxFiles', () async {
      // Bypass the rate limiter by writing files directly (as the Kotlin
      // handler does), then let one record() run the prune.
      final dir = Directory('${tmp.path}/crashes')..createSync();
      final base = DateTime.now().subtract(const Duration(minutes: 5));
      for (var i = 0; i < 25; i++) {
        File(
          '${dir.path}/${crashFileName(base.add(Duration(seconds: i)))}',
        ).writeAsStringSync('crash $i');
      }
      final recent = await CrashStore.recent(limit: 3);
      expect(recent, hasLength(3));
      expect(
        recent.first.path,
        endsWith(crashFileName(base.add(const Duration(seconds: 24)))),
      );

      await CrashStore.record(source: 'x', error: 'prune trigger');
      final left = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('crash_'))
          .length;
      expect(left, CrashStore.maxFiles);
    });

    test('recent skips files older than the window', () async {
      final dir = Directory('${tmp.path}/crashes')..createSync();
      final old = DateTime.now().subtract(const Duration(days: 30));
      File('${dir.path}/${crashFileName(old)}').writeAsStringSync('old');
      expect(await CrashStore.recent(), isEmpty);
    });
  });

  group('redactLocation (round 126)', () {
    test('strips the location block from a start record line', () {
      const line =
          '{"type":"start_of_session","location":{"lat":47.5,"lon":8.2,'
          '"accuracy_m":9.0,"fix_time_ms":1,"source":"gps"},"model_path":"m"}';
      final out = redactLocation(line);
      expect(out, isNot(contains('47.5')));
      expect(out, contains('"location":"[redacted]"'));
      expect(out, contains('"model_path":"m"'));
    });

    test('passes through lines without location or unparsable ones', () {
      const plain = '{"type":"detections","tracks":[]}';
      expect(redactLocation(plain), plain);
      const broken = 'not json but mentions "location" anyway';
      expect(redactLocation(broken), broken);
    });
  });
}
