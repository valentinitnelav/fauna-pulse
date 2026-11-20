// Tests for the feedback report: the log sampler (head + tail with an omission marker, long
// lines capped), the persistent crash store (file name / body format, newest-first recall,
// prune-to-max), and the report itself (ID and subject, screenshots, the size cap for email).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
        redact: redactReportLine,
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
        redact: redactReportLine,
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

  group('redactReportLine (rounds 126, 328)', () {
    test('strips the location block from a start record line', () {
      const line =
          '{"type":"start_of_session","location":{"lat":47.5,"lon":8.2,'
          '"accuracy_m":9.0,"fix_time_ms":1,"source":"gps"},"model_path":"m"}';
      final out = redactReportLine(line);
      expect(out, isNot(contains('47.5')));
      expect(out, contains('"location":"[redacted]"'));
      expect(out, contains('"model_path":"m"'));
    });

    test('passes through lines without location or field notes', () {
      const plain = '{"type":"detections","tracks":[]}';
      expect(redactReportLine(plain), plain);
      const other = 'a log line that is not JSON';
      expect(redactReportLine(other), other);
    });

    // Round 328: the report may be posted in public, so the field notes typed at the session
    // start (names, places, free text) go too; numbers and the phone model stay.
    test('removes typed field notes, keeps numbers and the phone model', () {
      final line = jsonEncode({
        'type': 'start_of_session',
        'field': {
          'phone_model': 'SM-M127F',
          'setup_by': 'Ana Example',
          'site': 'Meadow by the mill',
          'plant': 'Geranium sp.',
          'camera_height_m': 1.2,
          'custom': {'Observer': 'Bo', 'Notes': 'nest under the bridge'},
        },
      });
      final out = redactReportLine(line);
      for (final s in ['Ana', 'mill', 'Geranium', 'Bo"', 'bridge']) {
        expect(out, isNot(contains(s)));
      }
      final field = (jsonDecode(out) as Map)['field'] as Map;
      expect(field['setup_by'], '[redacted]');
      expect((field['custom'] as Map).keys, ['Observer', 'Notes']);
      expect(field['camera_height_m'], 1.2);
      expect(field['phone_model'], 'SM-M127F');
    });

    // A FaunaLapse block is copied as it is, so keys this app does not know reach reports too.
    test('unknown field keys, a custom list and positions elsewhere are removed', () {
      final line = jsonEncode({
        'type': 'start_of_session',
        'field': {
          'observer': 'Jane Doe',
          'custom': ['Jane Doe'],
          'camera_height_m': 1.2,
        },
        'faunalapse': {
          'settings': {
            'location': {'latitude': 47.51, 'longitude': 8.27},
          },
        },
      });
      final out = redactReportLine(line);
      expect(out, isNot(contains('Jane')));
      expect(out, isNot(contains('47.51')));
      expect(((jsonDecode(out) as Map)['field'] as Map)['camera_height_m'], 1.2);
    });

    test('a line with a position that cannot be read is left out', () {
      const cut = '{"type":"start_of_session","location":{"lat":47.5,"lon":8.2';
      expect(redactReportLine(cut), isNot(contains('47.5')));
      const cutNotes = '{"type":"start_of_session","field":{"setup_by":"Ana Example"';
      expect(redactReportLine(cutNotes), isNot(contains('Ana')));
    });
  });

  group('the report', () {
    late Directory tmp;
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      PackageInfo.setMockInitialValues(
        appName: 'FaunaPulse',
        packageName: 'com.faunapulse.app',
        version: '0.12.0-beta.1',
        buildNumber: '17',
        buildSignature: '',
      );
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
      // Copies live in error_reports/ (the FileProvider-served folder), share the .txt's
      // name, and keep their extension (these bytes are no picture the app can read).
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
      // The footer names the feedback address first, then the issue tracker.
      final email = txt.indexOf('Please send this file by email to ${ErrorReporter.feedbackEmail}.');
      expect(email, greaterThan(0));
      expect(txt.indexOf('open a GitHub issue'), greaterThan(email));

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

    test('the unsent description is kept as a draft until its report is handed over (round 362)', () async {
      // What the share sheet answers: '' = closed without choosing an app, else the app chosen.
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      var shareAnswer = '';
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(shareChannel, (call) async => shareAnswer);
      addTearDown(() => messenger.setMockMethodCallHandler(shareChannel, null));

      expect(await ErrorReporter.loadDraft(), '');
      await ErrorReporter.saveDraft('It froze after 5 minutes');
      expect(await ErrorReporter.loadDraft(), 'It froze after 5 minutes');
      // The draft is no report: the list of reports does not show it.
      expect(await ErrorReporter.listReports(), isEmpty);

      // Building the report keeps the text: the user may close the report's window to correct it.
      final report = await ErrorReporter.build(trigger: 'test', userDescription: 'It froze after 5 minutes');
      expect(await ErrorReporter.loadDraft(), 'It froze after 5 minutes');
      // A share sheet closed without choosing an app sent nothing.
      expect(await ErrorReporter.share(report, 'It froze'), isFalse);
      expect(await ErrorReporter.loadDraft(), 'It froze after 5 minutes');
      // Handed to an app: sent, the next description starts empty.
      shareAnswer = 'com.example.mail/.Compose';
      expect(await ErrorReporter.share(report, 'It froze'), isTrue);
      expect(await ErrorReporter.loadDraft(), '');

      // The email app: opened = handed over; no email app = nothing sent.
      const diagnostics = MethodChannel('faunapulse/diagnostics');
      var hasEmailApp = false;
      messenger.setMockMethodCallHandler(diagnostics, (call) async => call.method == 'sendEmail' ? hasEmailApp : null);
      addTearDown(() => messenger.setMockMethodCallHandler(diagnostics, null));
      await ErrorReporter.saveDraft('An idea');
      expect(await ErrorReporter.email(report, 'An idea'), isFalse);
      expect(await ErrorReporter.loadDraft(), 'An idea');
      hasEmailApp = true;
      expect(await ErrorReporter.email(report, 'An idea'), isTrue);
      expect(await ErrorReporter.loadDraft(), '');

      await ErrorReporter.saveDraft('   ');
      expect(await ErrorReporter.loadDraft(), '');
    });

    test('no attachments, no session: still one zip (the same kind of file every time)', () async {
      final report = await ErrorReporter.build(trigger: 'test');
      expect(report.attachments, isEmpty);
      expect(report.shareFile.path, endsWith('.zip'));
      expect(report.sizeBytes, report.shareFile.lengthSync(), reason: 'the size of what is sent');
      expect(
        report.file.readAsStringSync(),
        isNot(contains('Attached screenshots')),
      );
      expect(report.messageText(''), "(Attached: one zip file with the app's technical details (${report.humanSize}).)");
    });

    test('report ID and subject: six letters or digits, the version with its build', () async {
      final ids = {for (var i = 0; i < 200; i++) ErrorReporter.newReportId()};
      expect(ids.length, greaterThan(195), reason: 'random');
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[A-HJ-NP-Z2-9]{6}$')), reason: 'no 0, O, 1 or I: $id');
      }
      expect(ErrorReporter.newReportId(Random(1)), ErrorReporter.newReportId(Random(1)));
      expect(ErrorReporter.feedbackSubject('0.12.0-beta.1+17', 'K7QX2M'), 'FaunaPulse feedback 0.12.0-beta.1+17 K7QX2M');

      final report = await ErrorReporter.build(trigger: 'Send feedback (Home)', userDescription: ' Idea: a dark map. ');
      expect(report.appVersion, '0.12.0-beta.1+17');
      expect(report.subject, 'FaunaPulse feedback 0.12.0-beta.1+17 ${report.id}');
      final txt = report.file.readAsLinesSync();
      expect(txt.take(3), ['==== FaunaPulse feedback ====', 'Report ID: ${report.id}', 'Version:   0.12.0-beta.1+17']);
      expect(report.file.path, endsWith('_${report.id}.txt'));
      expect(report.shareFile.path, endsWith('_${report.id}.zip'));
      // The tester's words first, so they can be read on a phone without opening the zip.
      expect(report.messageText(' Idea: a dark map. '), startsWith('Idea: a dark map.\n\n(Attached: one zip file'));
    });

    test('screenshots become JPEGs of 1600 px at most, without their EXIF block', () async {
      final src = Directory('${tmp.path}/picker_cache')..createSync();
      // An Android screenshot: a PNG with a transparency channel, which the picker keeps.
      final png = File('${src.path}/Screenshot_1.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 1080, height: 2400, numChannels: 4)));
      // The picker's scaled copy of a camera photo: it keeps the original name (a JPEG called
      // .heic) and the EXIF block with the position.
      final photo = img.Image(width: 1600, height: 1200);
      photo.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(51, 1);
      final scaled = File('${src.path}/scaled_IMG_2.heic')..writeAsBytesSync(img.encodeJpg(photo));
      expect(img.decodeJpg(scaled.readAsBytesSync())!.exif.gpsIfd.isEmpty, isFalse, reason: 'the test photo has a position');

      final report = await ErrorReporter.build(trigger: 'test', attachmentPaths: [png.path, scaled.path]);
      expect(report.attachments.map((f) => f.uri.pathSegments.last.split('_').last), ['screenshot1.jpg', 'screenshot2.jpg']);
      final converted = img.decodeJpg(report.attachments[0].readAsBytesSync())!;
      expect([converted.width, converted.height], [720, 1600], reason: '1600 px on the long side');
      final again = img.decodeJpg(report.attachments[1].readAsBytesSync())!;
      expect([again.width, again.height], [1600, 1200]);
      expect(again.exif.isEmpty, isTrue, reason: 'no hidden data such as a position');
      expect(report.messageText('x'), contains('one zip file with 2 screenshots and'));
    });

    test('too big for an email: session samples go first, then screenshots from the end', () async {
      final session = Directory('${tmp.path}/sessions/s1')..createSync(recursive: true);
      final log = File('${session.path}/session.jsonl')
        ..writeAsStringSync('{"type":"start_of_session","time_ms":1}\n{"type":"end_of_session"}');
      // 300 lines of 1000 characters: about 0.3 MB of samples.
      File('${session.path}/logcat_start.txt').writeAsStringSync(List.filled(300, 'I/x: ${'a' * 1000}').join('\n'));
      final src = Directory('${tmp.path}/picker_cache')..createSync();
      // Bytes no picture decoder takes (a header of 0xFF), so they go in unchanged.
      final rnd = Random(3);
      final shots = [
        for (var i = 1; i <= 3; i++)
          (File('${src.path}/shot$i.jpg')..writeAsBytesSync([for (var b = 0; b < 200 * 1024; b++) b < 32 ? 0xFF : rnd.nextInt(256)])).path,
      ];
      const mb = 1024 * 1024;

      // Room for everything (1 MB is kept for the .txt).
      var report = await ErrorReporter.build(trigger: 't', sessionLog: log, attachmentPaths: shots, zipLimitBytes: 2 * mb);
      expect(report.leftOut, isNull);
      expect(report.attachments, hasLength(3));
      expect(report.bundledNames, contains('logcat_start_sample.txt'));

      // Room for the screenshots only: the samples go, and the .txt carries a log excerpt.
      report = await ErrorReporter.build(trigger: 't', sessionLog: log, attachmentPaths: shots, zipLimitBytes: mb + 700 * 1024);
      expect(report.attachments, hasLength(3));
      expect(report.bundledNames, isNot(contains('logcat_start_sample.txt')));
      expect(report.leftOut, 'Left out to keep the email below 1 MB: the session files.');
      expect(report.file.readAsStringSync(), contains('-- Session log:'));

      // Room for one screenshot: the last two go too, and their copies are deleted.
      report = await ErrorReporter.build(trigger: 't', sessionLog: log, attachmentPaths: shots, zipLimitBytes: mb + 300 * 1024);
      expect(report.attachments.map((f) => f.path.split('_').last), ['screenshot1.jpg']);
      expect(report.leftOut, 'Left out to keep the email below 1 MB: the session files and 2 screenshots.');
      expect(report.file.readAsStringSync(), contains(report.leftOut));
      expect(report.messageText('x'), endsWith('${report.leftOut})'));
      final names = ZipDecoder().decodeBytes(report.bundleZip!.readAsBytesSync()).files.map((f) => f.name);
      expect(names, hasLength(2), reason: 'the .txt and one screenshot');
      final stem = report.file.path.replaceAll('.txt', '');
      expect(File('${stem}_screenshot2.jpg').existsSync(), isFalse);
    });

    test('files of reports older than 14 days are deleted; the draft stays', () async {
      final dir = Directory('${tmp.path}/error_reports')..createSync();
      final old = File('${dir.path}/report_2026-01-01T10-00-00-000.zip')..writeAsStringSync('x');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 15)));
      final recent = File('${dir.path}/feedback_recent.zip')..writeAsStringSync('x');
      recent.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 13)));
      await ErrorReporter.saveDraft('kept');
      File('${dir.path}/description_draft.md').setLastModifiedSync(DateTime.now().subtract(const Duration(days: 30)));

      await ErrorReporter.build(trigger: 't');
      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
      expect(await ErrorReporter.loadDraft(), 'kept');
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
      expect(names, contains('session_events_sample.jsonl'));
      expect(names, contains('logcat_start_sample.txt'));
      final txt = report.file.readAsStringSync();
      expect(txt, contains('-- Bundled session file samples (2) --'));
      // Round 192 (owner review): with the samples in the zip, the old
      // embedded head+tail log excerpt is gone — the .txt only points at
      // the bundle members.
      expect(txt, contains('-- Session data:'));
      expect(txt, isNot(contains('-- Session log:')));
    });
  });
}
