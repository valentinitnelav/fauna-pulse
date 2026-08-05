// Tests for the error-report log sampler (head + tail with an omission
// marker, long lines capped) and the persistent crash store (file name /
// body format, newest-first recall, prune-to-max).

import 'dart:io';

import 'package:archive/archive.dart';
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

  group('boundedHeadTailSample (round 162, perf review E5)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bounded_sample'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File write(String content) =>
        File('${tmp.path}/session.jsonl')..writeAsStringSync(content);

    test('small file matches the whole-file sampler, marker and all', () async {
      final lines = List.generate(500, (i) => 'line $i');
      final f = write('${lines.join('\n')}\n');
      final bounded = await boundedHeadTailSample(f, head: 30, tail: 200);
      expect(bounded, headTailSample(lines, head: 30, tail: 200));
    });

    test('small file applies redaction', () async {
      const loc = '{"type":"start_of_session","location":{"lat":1.0}}';
      final f = write('$loc\nplain\n');
      final out = await boundedHeadTailSample(
        f,
        head: 30,
        tail: 200,
        redact: redactLocation,
      );
      expect(out, contains('[redacted]'));
      expect(out, isNot(contains('"lat"')));
    });

    test('large file reads only head+tail chunks, complete lines only',
        () async {
      // 1000 numbered ~20-byte lines with tiny chunk budgets, so the chunk
      // boundaries are guaranteed to cut lines mid-record.
      final lines =
          List.generate(1000, (i) => 'line ${i.toString().padLeft(6, '0')}');
      final f = write('${lines.join('\n')}\n');
      final out = await boundedHeadTailSample(
        f,
        head: 5,
        tail: 5,
        headBytes: 200,
        tailBytes: 300,
      );
      final outLines = out.split('\n');
      expect(outLines.first, 'line 000000');
      expect(outLines[4], 'line 000004');
      expect(outLines[5], contains('middle omitted'));
      expect(outLines.last, 'line 000999');
      expect(outLines, hasLength(5 + 1 + 5));
      // Every kept line is complete (no partial-line fragments).
      for (final l in [...outLines.take(5), ...outLines.skip(6)]) {
        expect(l, matches(RegExp(r'^line \d{6}$')));
      }
    });

    test('large file redacts retained tail lines', () async {
      final filler = List.generate(200, (i) => 'x' * 50).join('\n');
      const loc = '{"type":"roi_update","location":{"lat":9.9}}';
      final f = write('$filler\n$loc\n');
      final out = await boundedHeadTailSample(
        f,
        head: 2,
        tail: 2,
        headBytes: 128,
        tailBytes: 256,
        redact: redactLocation,
      );
      expect(out, contains('[redacted]'));
      expect(out, isNot(contains('"lat"')));
    });

    test('no trailing newline: final line still sampled', () async {
      final lines = List.generate(300, (i) => 'row $i');
      final f = write(lines.join('\n')); // no trailing \n
      final out = await boundedHeadTailSample(
        f,
        head: 3,
        tail: 3,
        headBytes: 64,
        tailBytes: 128,
      );
      expect(out.split('\n').last, 'row 299');
    });

    test('empty file yields empty sample', () async {
      final f = write('');
      expect(await boundedHeadTailSample(f, head: 30, tail: 200), '');
    });

    test('caps overlong retained lines', () async {
      final f = write('${'y' * 5000}\n');
      final out = await boundedHeadTailSample(f, head: 5, tail: 5);
      expect(out, endsWith('…[truncated]'));
      expect(out.length, lessThan(2100));
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

  group('screenshot attachments (round 190)', () {
    late Directory tmp;
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = Directory.systemTemp.createTempSync('report_attach');
      ErrorReporter.debugDirOverride = tmp;
      CrashStore.debugDirOverride = tmp;
    });
    tearDown(() {
      ErrorReporter.debugDirOverride = null;
      CrashStore.debugDirOverride = null;
      tmp.deleteSync(recursive: true);
    });

    test('build copies picked files next to the .txt and lists them', () async {
      // Two "screenshots" as the photo picker would hand them out (temp
      // copies elsewhere on disk), plus one path that no longer exists —
      // the report must never fail because a screenshot did.
      final src = Directory('${tmp.path}/picker_cache')..createSync();
      final a = File('${src.path}/Screenshot_1.png')
        ..writeAsBytesSync([1, 2, 3]);
      final b = File('${src.path}/photo.jpg')..writeAsBytesSync([4, 5]);

      final report = await ErrorReporter.build(
        trigger: 'test',
        userDescription: 'something broke',
        attachmentPaths: [a.path, '${src.path}/gone.png', b.path],
      );

      expect(report.attachments, hasLength(2));
      // Copies live in error_reports/ (the FileProvider-served folder),
      // share the .txt's stamp, and keep their extension.
      final reportDir = report.file.parent.path;
      expect(reportDir, endsWith('error_reports'));
      expect(report.attachments[0].parent.path, reportDir);
      expect(report.attachments[0].path, endsWith('_screenshot1.png'));
      // Numbering follows the input positions (the missing middle file was
      // skipped), so the second surviving copy is _screenshot3.
      expect(report.attachments[1].path, endsWith('_screenshot3.jpg'));
      expect(report.attachments[0].readAsBytesSync(), [1, 2, 3]);

      final txt = report.file.readAsStringSync();
      expect(txt, contains('-- Attached screenshots (2) --'));
      expect(txt, contains('_screenshot1.png'));
      // The footer suggests the issue tracker, never a direct email.
      expect(txt, contains('Open a GitHub issue'));
      expect(txt, isNot(contains('Send this file to:')));

      // Round 191: anything beyond the bare .txt ships as ONE zip (mixed
      // multi-file shares were dropped whole by WhatsApp — owner test).
      expect(report.bundleZip, isNotNull);
      expect(report.shareFile.path, endsWith('.zip'));
      final names = ZipDecoder()
          .decodeBytes(report.bundleZip!.readAsBytesSync())
          .files
          .map((f) => f.name)
          .toList();
      expect(names, hasLength(3)); // .txt + 2 screenshots
      expect(names.first, endsWith('.txt'));
    });

    test('no attachments, no session: bare txt, no zip', () async {
      final report = await ErrorReporter.build(trigger: 'test');
      expect(report.attachments, isEmpty);
      expect(report.bundleZip, isNull);
      expect(report.shareFile.path, endsWith('.txt'));
      expect(
        report.file.readAsStringSync(),
        isNot(contains('Attached screenshots')),
      );
    });

    test('chosen session: sampled files land in the bundle', () async {
      final session = Directory('${tmp.path}/sessions/s1')
        ..createSync(recursive: true);
      final log = File('${session.path}/session.jsonl')
        ..writeAsStringSync([
          '{"type":"start_of_session","time_ms":1,"model_path":"m"}',
          '{"type":"detections","tracks":[]}',
          '{"type":"end_of_session","ended_normally":true}',
        ].join('\n'));
      File('${session.path}/logcat_start.txt')
          .writeAsStringSync('I/YOLOView: Camera fps cap: requested=15');

      final report = await ErrorReporter.build(trigger: 'test', sessionLog: log);
      expect(report.bundleZip, isNotNull);
      final names = ZipDecoder()
          .decodeBytes(report.bundleZip!.readAsBytesSync())
          .files
          .map((f) => f.name)
          .toList();
      expect(names, contains('session_events_sample.jsonl.txt'));
      expect(names, contains('logcat_start_sample.txt'));
      expect(
        report.file.readAsStringSync(),
        contains('-- Bundled session file samples (2) --'),
      );
    });
  });
}
