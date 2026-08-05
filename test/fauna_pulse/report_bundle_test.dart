// Tests for the round-191 problem-report bundle: the diagnostic-file
// samplers (what is kept vs. the measured flood/noise lines) and the single
// shareable zip.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/report_bundle.dart';

void main() {
  group('line filters', () {
    test('session events: flood record types dropped, everything else kept', () {
      expect(keepSessionEventLine('{"type":"detections","tracks":[]}'), false);
      expect(keepSessionEventLine('{"type":"track_event","event":"lost"}'), false);
      expect(keepSessionEventLine('{"type":"raw_detections"}'), false);
      expect(keepSessionEventLine('{"type":"capture","jpeg":"a.jpg"}'), false);
      expect(keepSessionEventLine('{"type":"gt_capture"}'), false);
      expect(keepSessionEventLine('{"type":"motion_capture"}'), false);
      expect(keepSessionEventLine('{"type":"timelapse_capture"}'), false);
      // Legacy per-track records (≤ r68) are flood too.
      expect(keepSessionEventLine('{"type":"detection","track_id":7}'), false);

      expect(keepSessionEventLine('{"type":"start_of_session"}'), true);
      expect(keepSessionEventLine('{"type":"end_of_session"}'), true);
      expect(keepSessionEventLine('{"type":"fps","fps":9.0}'), true);
      expect(keepSessionEventLine('{"type":"app_error","message":"x"}'), true);
      expect(keepSessionEventLine('{"type":"motion_gate","idle":true}'), true);
      // Unknown/future record types must never be silently dropped.
      expect(keepSessionEventLine('{"type":"some_future_record"}'), true);
    });

    test('logcat: the measured noise floods dropped, real lines kept', () {
      expect(
        keepLogcatLine(
          '08-04 21:51:00.204 E/FrameEvents(10670): '
          'updateAcquireFence: Did not find frame.',
        ),
        false,
      );
      expect(
        keepLogcatLine(
          '08-04 21:51:00.255 I/flutter (10670): PERF camera=15.0 '
          'detector=10.1 pipeline=10.1',
        ),
        false,
      );
      expect(
        keepLogcatLine(
          '08-04 21:51:06.415 I/YOLOView(10670): FRAMEPERF deliveredFps=15.0',
        ),
        false,
      );
      expect(
        keepLogcatLine(
          '08-04 21:51:06.4 I/YOLOView(10670): Camera fps cap: requested=15',
        ),
        true,
      );
    });

    test('post detections: per-photo records dropped, run summaries kept', () {
      expect(keepPostDetectionLine('{"type":"post_detection","jpeg":"a"}'), false);
      expect(keepPostDetectionLine('{"type":"post_start","model":"m"}'), true);
      expect(keepPostDetectionLine('{"type":"post_end","elapsed_ms":5}'), true);
      expect(keepPostDetectionLine('{"type":"post_cleanup"}'), true);
    });
  });

  group('sampleFilteredFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('report_sample'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File write(List<String> lines) =>
        File('${tmp.path}/f.txt')..writeAsStringSync(lines.join('\n'));

    test('keeps head + tail of the FILTERED lines with a marker', () async {
      // 40 kept lines interleaved with noise; head 10 + tail 10 → 20 omitted.
      final lines = <String>[];
      for (var i = 0; i < 40; i++) {
        lines.add('keep $i');
        lines.add('NOISE');
      }
      final out = await sampleFilteredFile(
        write(lines),
        keep: (l) => !l.contains('NOISE'),
        head: 10,
        tail: 10,
      );
      final outLines = out.split('\n');
      expect(outLines, hasLength(21));
      expect(outLines.first, 'keep 0');
      expect(outLines[9], 'keep 9');
      expect(outLines[10], '… 20 lines omitted …');
      expect(outLines.last, 'keep 39');
    });

    test('short input: no marker; map applied; blanks dropped', () async {
      final out = await sampleFilteredFile(
        write(['a', '', 'b']),
        keep: (_) => true,
        map: (l) => l.toUpperCase(),
      );
      expect(out, 'A\nB');
    });

    test('missing file yields empty string', () async {
      final out = await sampleFilteredFile(
        File('${tmp.path}/nope.txt'),
        keep: (_) => true,
      );
      expect(out, '');
    });

    test('caps overlong lines', () async {
      final out = await sampleFilteredFile(
        write(['x' * 5000]),
        keep: (_) => true,
      );
      expect(out.length, lessThan(2100));
      expect(out, endsWith('…[truncated]'));
    });
  });

  group('collectSessionExtras', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('report_extras'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('samples the files that exist, redacts location, skips missing', () async {
      File('${tmp.path}/session.jsonl').writeAsStringSync([
        '{"type":"start_of_session","time_ms":1,"location":{"lat":47.5,'
            '"lon":9.1,"accuracy_m":9.0,"fix_time_ms":1,"source":"gps"},'
            '"model_path":"m"}',
        '{"type":"detections","tracks":[]}',
        '{"type":"fps","fps":9.0}',
        '{"type":"end_of_session","ended_normally":true}',
      ].join('\n'));
      File('${tmp.path}/logcat_start.txt').writeAsStringSync([
        'E/FrameEvents: updateAcquireFence: Did not find frame.',
        'I/YOLOView: Camera fps cap: requested=15 applied=[15, 15]',
      ].join('\n'));
      // No logcat_end.txt, no post_detections.jsonl — both skipped.

      final extras = await collectSessionExtras(tmp);
      expect(extras.map((e) => e.name), [
        'session_events_sample.jsonl.txt',
        'logcat_start_sample.txt',
      ]);
      final events = extras[0].content;
      expect(events, contains('"type":"start_of_session"'));
      expect(events, contains('"type":"fps"'));
      expect(events, isNot(contains('"type":"detections"')));
      // Location redacted (protected sites, r126 rule for report samples).
      expect(events, isNot(contains('47.5')));
      expect(events, contains('"location":"[redacted]"'));
      final logcat = extras[1].content;
      expect(logcat, contains('Camera fps cap'));
      expect(logcat, isNot(contains('updateAcquireFence')));
    });
  });

  group('writeReportZip', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('report_zip'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('bundles txt + screenshots + extras; readable back', () async {
      final txt = File('${tmp.path}/report_x.txt')
        ..writeAsStringSync('the report');
      final shot = File('${tmp.path}/report_x_screenshot1.png')
        ..writeAsBytesSync([1, 2, 3]);
      final zip = await writeReportZip(
        File('${tmp.path}/report_x.zip'),
        reportTxt: txt,
        screenshots: [shot],
        extras: [(name: 'logcat_start_sample.txt', content: 'lines')],
      );
      expect(zip, isNotNull);
      final archive = ZipDecoder().decodeBytes(zip!.readAsBytesSync());
      expect(archive.files.map((f) => f.name).toList(), [
        'report_x.txt',
        'report_x_screenshot1.png',
        'logcat_start_sample.txt',
      ]);
      expect(
        String.fromCharCodes(archive.files.first.content as List<int>),
        'the report',
      );
    });
  });
}
