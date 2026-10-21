// Scale and robustness tests for SessionLogIndex.parseFile (the one streaming
// parse of session.jsonl behind the summary screen and the Dashboard):
// a log with 1,000,000 lines (time and memory), a log with thousands of photos
// close together (the second pass), huge single lines, and valid JSON lines
// with fields of the wrong type. Big files live in a temp folder and are
// deleted at the end.
//
// Tests that show a real bug are kept and marked `skip: 'BUG: ...'` so the
// normal suite stays green. Run them with --run-skipped to see them fail.
// All random numbers come from a seeded Random.

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';

const int kT0 = 1760000000000; // 2025-10-09, an arbitrary start

/// Writes a log of exactly [lines] lines (start record, then a mix of the
/// record types a real session writes). Every [photoEvery] lines a photo is
/// added: a `capture` record with a content moment, and a `detections` line
/// that names the JPEG.
Future<void> writeBigLog(String path, int lines, {int photoEvery = 0, int seed = 1}) async {
  final rng = Random(seed);
  final sink = File(path).openWrite();
  var buf = StringBuffer();
  buf.write('{"type":"start_of_session","time_ms":$kT0,"analysis_frame_width_px":1440,"analysis_frame_height_px":1080,'
      '"roi":{"width_px":416,"height_px":416,"frame_width_px":1440,"frame_height_px":1080},'
      '"config":{"captureTrigger":"detector"}}\n');
  var written = 1, photo = 0;
  var ms = kT0;
  while (written < lines) {
    ms += 100;
    final k = written % 20;
    final trackBase = 1 + written ~/ 400;
    if (photoEvery > 0 && written % photoEvery == 0 && written + 3 < lines) {
      photo++;
      final name = 'roi_$photo.jpg';
      buf.write('{"type":"detections","time_ms":${ms + 30},"frame_ms":$ms,"tracks":[{"track_id":$trackBase,"class_name":"bee",'
          '"confidence":0.9,"box_in_roi":{"left":0.1,"top":0.2,"right":0.3,"bottom":0.4},"jpeg":"$name"}]}\n');
      buf.write('{"type":"capture","time_ms":${ms + 200},"file":"$name","captured_at_ms":${ms + 50},"saved_px":1024,'
          '"content_at_ms":${ms + 40},"content_lag_ms":10}\n');
      buf.write('{"type":"detections","time_ms":${ms + 230},"frame_ms":${ms + 100},"tracks":[{"track_id":$trackBase,"class_name":"bee",'
          '"confidence":0.9,"box_in_roi":{"left":0.1,"top":0.2,"right":0.3,"bottom":0.4}}]}\n');
      written += 3;
      continue;
    }
    if (k < 9) {
      final n = 1 + rng.nextInt(3);
      buf.write('{"type":"detections","time_ms":${ms + 30},"frame_ms":$ms,"tracks":[');
      for (var t = 0; t < n; t++) {
        if (t > 0) buf.write(',');
        buf.write('{"track_id":${trackBase + t},"class_name":"bee","confidence":${(0.5 + rng.nextDouble() * 0.5).toStringAsFixed(3)},'
            '"box_in_roi":{"left":${rng.nextDouble().toStringAsFixed(3)},"top":0.2,"right":0.3,"bottom":0.4}}');
      }
      buf.write(']}\n');
    } else if (k < 13) {
      buf.write('{"type":"fps","time_ms":$ms,"fps":9.0,"pipeline_fps":10.0,"inf_ms":55.0}\n');
    } else if (k < 15) {
      buf.write('{"type":"thermal","time_ms":$ms,"battery_temp_c":37.5,"thermal_headroom":0.6}\n');
    } else if (k == 15) {
      buf.write('{"type":"power","time_ms":$ms,"battery_current_ua":500000,"battery_voltage_mv":3900,'
          '"charge_counter_uah":1200000,"power_w":1.95,"is_charging":false,"is_plugged":true}\n');
    } else if (k < 18) {
      buf.write('{"type":"track_event","time_ms":$ms,"event":"created","track_id":$trackBase,"first_seen_ms":${ms - 300},"hits":3}\n');
    } else {
      buf.write('{"type":"raw_detections","time_ms":$ms,"frame_ms":$ms,"boxes":[[0.1,0.2,0.3,0.4,0.9,0],[0.5,0.5,0.6,0.6,0.7,0]]}\n');
    }
    written++;
    if (written % 20000 == 0) {
      sink.write(buf.toString());
      buf = StringBuffer();
    }
  }
  sink.write(buf.toString());
  await sink.flush();
  await sink.close();
}

int lineCount(String path) {
  var n = 0;
  final bytes = File(path).readAsBytesSync();
  for (final b in bytes) {
    if (b == 10) n++;
  }
  return n;
}

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('log_index_scale'));
  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('1,000,000-line log', () {
    test('parseFile: time and memory (with 330 photos, so the second pass runs too)', () async {
      final path = '${tmp.path}/big.jsonl';
      final gen = Stopwatch()..start();
      await writeBigLog(path, 1000000, photoEvery: 3000);
      gen.stop();
      final size = File(path).lengthSync();
      expect(lineCount(path), 1000000);

      final rssBefore = ProcessInfo.currentRss;
      final sw = Stopwatch()..start();
      final index = await SessionLogIndex.parseFile(path);
      sw.stop();
      final rssAfter = ProcessInfo.currentRss;
      final peak = ProcessInfo.maxRss;
      // ignore: avoid_print
      print('1M-line log: ${(size / 1048576).toStringAsFixed(0)} MB, written in ${gen.elapsedMilliseconds} ms; '
          'parseFile ${sw.elapsedMilliseconds} ms; RSS before ${(rssBefore / 1048576).toStringAsFixed(0)} MB, '
          'after ${(rssAfter / 1048576).toStringAsFixed(0)} MB, peak so far ${(peak / 1048576).toStringAsFixed(0)} MB; '
          'track IDs ${index.trackSpans.length}, photos ${index.photos.length}, temps ${index.temps.length}, '
          'fps ${index.fps.length}, power ${index.powerSamples.length}');

      expect(index.startRecord?['time_ms'], kT0);
      expect(index.trackSpans.length, greaterThan(2000));
      expect(index.photos.length, greaterThan(300));
      expect(index.temps.length, greaterThan(90000));
      expect(index.fps.length, greaterThan(190000));
      expect(index.powerSamples.length, greaterThan(40000));
      // Memory: the streaming parse must not hold the file (~170 MB) in memory.
      expect(rssAfter - rssBefore, lessThan(1200 * 1048576));
      expect(sw.elapsedMilliseconds, lessThan(60000));
      File(path).deleteSync();
    });

    test('parseFile: throughput does not drop for a 4 times longer log (no quadratic step)', () async {
      final times = <int, int>{};
      for (final n in [100000, 400000]) {
        final path = '${tmp.path}/t$n.jsonl';
        await writeBigLog(path, n, photoEvery: 2000, seed: 2);
        final sw = Stopwatch()..start();
        await SessionLogIndex.parseFile(path);
        sw.stop();
        times[n] = sw.elapsedMilliseconds;
        File(path).deleteSync();
      }
      // ignore: avoid_print
      print('parseFile ms: 100k lines ${times[100000]}, 400k lines ${times[400000]}');
      // 4 times the lines: allow up to 8 times the time (and a floor for tiny times).
      expect(times[400000]!, lessThan(max(times[100000]!, 200) * 8));
    });
  });

  group('second pass with many photos close together', () {
    test('3000 photos 20 ms apart, 20000 detector frames: stays fast', () async {
      // Pass 2 offers each detector frame to every photo within 1.5 s. Photos
      // are normally more than 1 s apart; here 75 photos fall in one window,
      // so each frame touches 75 photos. This is the worst case for the walk.
      final path = '${tmp.path}/photos.jsonl';
      final b = StringBuffer('{"type":"start_of_session","time_ms":$kT0,"config":{}}\n');
      for (var p = 0; p < 3000; p++) {
        final at = kT0 + 1000 + p * 20;
        b.write('{"type":"capture","time_ms":${at + 100},"file":"roi_$p.jpg","captured_at_ms":$at,"saved_px":512,'
            '"content_at_ms":$at}\n');
      }
      for (var f = 0; f < 20000; f++) {
        final ms = kT0 + 1000 + f * 3;
        b.write('{"type":"detections","time_ms":${ms + 20},"frame_ms":$ms,"tracks":[{"track_id":1,"class_name":"bee",'
            '"confidence":0.9,"box_in_roi":{"left":0.1,"top":0.2,"right":0.3,"bottom":0.4}}]}\n');
      }
      File(path).writeAsStringSync(b.toString());
      final sw = Stopwatch()..start();
      final index = await SessionLogIndex.parseFile(path);
      sw.stop();
      // ignore: avoid_print
      print('3000 close photos x 20000 frames: ${sw.elapsedMilliseconds} ms, '
          'matched ${index.photos.values.where((p) => p.stillMatch != null).length}');
      expect(index.photos.length, 3000);
      expect(sw.elapsedMilliseconds, lessThan(20000));
    });
  });

  group('huge single lines and odd bytes', () {
    test('one 8 MB line of junk, then normal lines: the normal lines are still read', () async {
      final path = '${tmp.path}/junk.jsonl';
      final sink = File(path).openWrite();
      sink.write('{"type":"start_of_session","time_ms":$kT0,"config":{}}\n');
      sink.write('${'x' * 8000000}\n');
      sink.write('{"type":"thermal","time_ms":${kT0 + 1000},"battery_temp_c":30.5}\n');
      await sink.close();
      final sw = Stopwatch()..start();
      final index = await SessionLogIndex.parseFile(path);
      sw.stop();
      expect(index.temps, [(kT0 + 1000, 30.5)]);
      expect(sw.elapsedMilliseconds, lessThan(10000));
    });

    test('a 6 MB JSON line with a 200,000-entry tracks array does not crash', () async {
      final path = '${tmp.path}/wide.jsonl';
      final tracks = [for (var i = 0; i < 200000; i++) '{"track_id":${i % 500},"confidence":0.5}'].join(',');
      File(path).writeAsStringSync(
        '{"type":"start_of_session","time_ms":$kT0,"config":{}}\n'
        '{"type":"detections","time_ms":${kT0 + 1},"frame_ms":${kT0 + 1},"tracks":[$tracks]}\n',
      );
      final index = await SessionLogIndex.parseFile(path);
      expect(index.trackSpans.length, 500);
    });

    test('a deeply nested JSON line (5000 levels) is skipped like a cut line', () async {
      final path = '${tmp.path}/deep.jsonl';
      File(path).writeAsStringSync(
        '{"type":"start_of_session","time_ms":$kT0,"config":{}}\n'
        '${'[' * 5000}${']' * 5000}\n'
        '{"type":"thermal","time_ms":${kT0 + 1000},"battery_temp_c":30.5}\n',
      );
      final index = await SessionLogIndex.parseFile(path);
      expect(index.temps, hasLength(1));
    });

    test('binary junk and a file of 300,000 empty lines', () async {
      final rng = Random(4);
      final a = '${tmp.path}/bin.jsonl';
      File(a).writeAsBytesSync([for (var i = 0; i < 3000000; i++) rng.nextInt(256)]);
      final i1 = await SessionLogIndex.parseFile(a);
      expect(i1.startRecord, isNull);
      final b = '${tmp.path}/empty_lines.jsonl';
      File(b).writeAsStringSync('\n' * 300000);
      final i2 = await SessionLogIndex.parseFile(b);
      expect(i2.trackSpans, isEmpty);
    });

    test('a missing file throws a file error (the caller must handle it)', () async {
      await expectLater(SessionLogIndex.parseFile('${tmp.path}/nope.jsonl'), throwsA(isA<FileSystemException>()));
    });
  });

  group('valid JSON lines with a field of the wrong type', () {
    // One odd line in a good log. The `as num?` / `as String?` casts on log
    // fields throw a TypeError for the wrong type; feed() must skip only that
    // line (before the fix parseFile failed as a whole, and the Dashboard
    // counted the session as "no track IDs").
    const good = '{"type":"start_of_session","time_ms":$kT0,"config":{}}\n'
        '{"type":"detections","time_ms":${kT0 + 100},"frame_ms":${kT0 + 100},"tracks":[{"track_id":1,"confidence":0.9}]}\n';
    final odd = <String, String>{
      'time_ms as text (thermal)': '{"type":"thermal","time_ms":"soon","battery_temp_c":30.5}',
      'time_ms as text (detections)': '{"type":"detections","time_ms":"soon","frame_ms":5,"tracks":[]}',
      'battery_temp_c as text': '{"type":"thermal","time_ms":${kT0 + 5},"battery_temp_c":"hot"}',
      'fps as text': '{"type":"fps","time_ms":${kT0 + 5},"fps":"fast"}',
      'is_charging as text': '{"type":"power","time_ms":${kT0 + 5},"is_charging":"yes"}',
      'jpeg as number': '{"type":"detections","time_ms":${kT0 + 5},"frame_ms":${kT0 + 5},"tracks":[{"track_id":2,"jpeg":7}]}',
      'track_id as text': '{"type":"detections","time_ms":${kT0 + 5},"frame_ms":${kT0 + 5},"tracks":[{"track_id":"7"}]}',
      'box_in_roi left as text': '{"type":"detections","time_ms":${kT0 + 5},"frame_ms":${kT0 + 5},"tracks":[{"track_id":2,"jpeg":"a.jpg","box_in_roi":{"left":"a"}}]}',
      'capture file as number': '{"type":"capture","time_ms":${kT0 + 5},"file":7}',
      'capture saved_px as text': '{"type":"capture","time_ms":${kT0 + 5},"file":"a.jpg","saved_px":"big"}',
      'roi_update saves_px as text': '{"type":"roi_update","time_ms":${kT0 + 5},"saves_px":"big"}',
      'roi_update roi_source as number': '{"type":"roi_update","time_ms":${kT0 + 5},"roi_source":3}',
      'roi width as text': '{"type":"roi_update","time_ms":${kT0 + 5},"roi":{"width_px":"x"}}',
      'track_event first_seen_ms as text': '{"type":"track_event","time_ms":${kT0 + 5},"event":"created","track_id":1,"first_seen_ms":"x"}',
      'type as number': '{"type":5,"time_ms":${kT0 + 5}}',
      'tracks as object': '{"type":"detections","time_ms":${kT0 + 5},"frame_ms":${kT0 + 5},"tracks":{"a":1}}',
      'line is a JSON number': '5',
      'line is a JSON list': '[1,2,3]',
      'line is null': 'null',
    };
    for (final e in odd.entries) {
      test('${e.key}: the rest of the log is still read', () async {
        final path = '${tmp.path}/odd_${e.key.hashCode}.jsonl';
        File(path).writeAsStringSync('$good${e.value}\n{"type":"thermal","time_ms":${kT0 + 9},"battery_temp_c":31.5}\n');
        final index = await SessionLogIndex.parseFile(path);
        expect(index.trackSpans.containsKey(1), isTrue);
        expect(index.temps.map((t) => t.$2), contains(31.5));
      });
    }
  });
}
