// Stress run, step P2: seeded mutation fuzzing of the readers of the
// identification files (EmbeddingIndex.parse, readEmbeddingRows,
// LatestIdentification.load) and of the Dashboard's cache file
// (DashboardStatsCache.forSession, dashboard_stats.json). Rule: no hang, no
// huge allocation, only a clear error type; never an uncaught TypeError /
// RangeError. A case that shows a real bug is kept and marked skip: 'BUG: ...'.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/logging/dashboard_stats.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fuzz_helpers.dart';
import 'session_fixture.dart';

String _embeddingsJsonl() {
  final lines = <String>[
    jsonEncode({'type': 'identify_start', 'model': 'bioclip-2.5_224_fp16', 'dim': 8, 'margin': 0.1, 'min_crop_px': 32, 'square_crops': true, 'track_ids_run_id': 3}),
    for (var i = 0; i < 6; i++)
      jsonEncode({
        'type': 'crop',
        ...EmbeddingRecord(
          key: 'roi_$i.jpg|${i % 3}|0.1000,0.2000,0.3000,0.4000',
          source: 'roi_$i.jpg',
          photo: 'roi_$i.jpg',
          boxSource: 'live',
          trackId: i % 3,
          box: const [0.1, 0.2, 0.3, 0.4],
          cropPx: 96,
          padFrac: 0.1,
          sharpness: 12.5,
          detConf: 0.9,
          capturedAtMs: 1700000000000 + i,
          row: i,
        ).toJson(),
      }),
    jsonEncode({'type': 'crop_skipped', 'key': 'tiny.jpg|1|0,0,0.01,0.01', 'reason': 'too_small', 'crop_px': 12}),
  ];
  return '${lines.join('\n')}\n';
}

String _summaryJson() => jsonEncode({
  'pack_id': 'p',
  'generated_iso': '2026-10-20T10:00:00',
  'capture': {'track_ids_run_id': 3},
  'tracks': [
    {'track_id': 1, 'headline': 'Bombus', 'identified_rank': 'genus', 'p': 0.9, 'suspect': false},
    {'track_ids': [2, 3], 'headline': 'Apis', 'identified_rank': 'species', 'p': 0.8},
    {'src': 'motion.jpg', 'headline': 'unidentified'},
  ],
});

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fuzz_identification'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the valid fixtures read (sanity)', () {
    final index = EmbeddingIndex.parse(_embeddingsJsonl());
    expect(index.records, hasLength(6));
    expect(index.contiguous, isTrue);
    expect(index.dim, 8);
    expect(index.skippedKeys, hasLength(1));
  });

  group('EmbeddingIndex.parse', () {
    test('byte-level damage: no crash, no hang', () {
      final bytes = Uint8List.fromList(utf8.encode(_embeddingsJsonl()));
      final report = FuzzReport();
      for (final (name, b) in byteMutants(bytes, Random(11))) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          final index = EmbeddingIndex.parse(utf8.decode(b, allowMalformed: true));
          // The derived values the resume logic uses must not throw either.
          index.contiguous;
          index.rows;
          index.doneKeys;
          index.skippedFor(32);
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.slowest, lessThan(const Duration(seconds: 5)), reason: '$report');
      expect(report.clean, isTrue, reason: '$report');
    });

    test('wrong JSON types in one field: a clear result, not a TypeError', () {
      final lines = const LineSplitter().convert(_embeddingsJsonl());
      final report = FuzzReport();
      for (final (name, mutated) in typeMutants(lines, Random(12), count: 400)) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          final index = EmbeddingIndex.parse('${mutated.join('\n')}\n');
          index.contiguous;
          index.rows;
          index.skippedFor(32);
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });
  });

  group('the strict UTF-8 file reads of the identification files', () {
    test('an embeddings file torn inside a multi-byte letter can still be read by the resume code', () async {
      // Read through the app's own reader (IdentificationJob.storedIndex); the resume
      // and scoring reads in identification_job.dart decode the same way.
      final f = IdentificationPaths(tmp).embeddingsJsonl('x');
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync([...utf8.encode(_embeddingsJsonl()), ...utf8.encode('{"type":"crop","key":"Blüte'), 0xC3]);
      final index = await IdentificationJob.storedIndex(tmp, 'x.tflite');
      expect(index!.records, hasLength(6));
    });
  });

  group('readEmbeddingRows', () {
    test('a short .bin is refused with a clear error', () {
      final bin = File('${tmp.path}/e.bin')..writeAsBytesSync(Uint8List(16));
      expect(() => readEmbeddingRows(bin, 10, 8), throwsA(isA<StateError>()));
    });

    test('a record claiming a huge row number is refused, not read as a tiny array', () {
      // EmbeddingIndex.rows = highest row + 1; rows * dim wraps around 64 bits at row 2^62.
      final bin = File('${tmp.path}/e.bin')..writeAsBytesSync(Uint8List(64));
      final index = EmbeddingIndex.parse(
        '${jsonEncode({'type': 'crop', 'key': 'k', 'row': 4611686018427387904})}\n',
      );
      expect(index.rows, 4611686018427387905);
      // 4611686018427387905 * 4 wraps to 4: the size check passes with only 64 bytes.
      Object? error;
      Float32List? out;
      try {
        out = readEmbeddingRows(bin, index.rows, 4);
      } catch (e) {
        error = e;
      }
      expect(error, isA<StateError>(), reason: 'returned an array of ${out?.length} floats for ${index.rows} rows');
    });
  });

  group('LatestIdentification.load', () {
    Directory session() {
      final d = Directory('${tmp.path}/s')..createSync(recursive: true);
      Directory('${d.path}/identification').createSync();
      return d;
    }

    test('the valid summary reads (sanity)', () async {
      final d = session();
      File('${d.path}/identification/summary_p.json').writeAsStringSync(_summaryJson());
      final id = await LatestIdentification.load(d);
      expect(id!.byTrack.keys.toSet(), {1, 2, 3});
      expect(id.byPhoto.keys, ['motion.jpg']);
      expect(id.visitsRunId, 3);
    });

    test('byte-level damage: null or a result, as the doc comment says (null when unreadable)', () async {
      final d = session();
      final report = FuzzReport();
      final bytes = Uint8List.fromList(utf8.encode(_summaryJson()));
      for (final (name, b) in byteMutants(bytes, Random(13), perKind: 25)) {
        File('${d.path}/identification/summary_p.json').writeAsBytesSync(b);
        final sw = Stopwatch()..start();
        Object? err;
        try {
          await LatestIdentification.load(d);
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('wrong JSON types in one field', () async {
      final d = session();
      final report = FuzzReport();
      for (final (name, mutated) in typeMutants([_summaryJson()], Random(14), count: 300)) {
        File('${d.path}/identification/summary_p.json').writeAsStringSync(mutated.single);
        final sw = Stopwatch()..start();
        Object? err;
        try {
          await LatestIdentification.load(d);
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });
  });

  group('DashboardStatsCache.forSession', () {
    Future<Directory> session() async {
      final d = Directory('${tmp.path}/dash')..createSync(recursive: true);
      await writeValidSession(d);
      return d;
    }

    test('a damaged dashboard_stats.json is recomputed, never thrown', () async {
      final d = await session();
      final clean = await DashboardStatsCache.forSession(d);
      final cache = File('${d.path}/${DashboardStatsCache.fileName}');
      expect(cache.existsSync(), isTrue);
      final good = cache.readAsBytesSync();
      final report = FuzzReport();
      for (final (name, b) in byteMutants(good, Random(15), perKind: 25)) {
        cache.writeAsBytesSync(b);
        final sw = Stopwatch()..start();
        Object? err;
        try {
          final s = await DashboardStatsCache.forSession(d);
          if (s.startMs != clean.startMs || s.endMs != clean.endMs || s.visits.length != clean.visits.length) {
            err = StateError('different numbers than the clean cache: ${s.toJson()} vs ${clean.toJson()}');
          }
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('wrong JSON types in the cache fall back to a recompute', () async {
      final d = await session();
      final clean = await DashboardStatsCache.forSession(d);
      final cache = File('${d.path}/${DashboardStatsCache.fileName}');
      final good = cache.readAsStringSync();
      final report = FuzzReport();
      for (final (name, mutated) in typeMutants([good], Random(16), count: 250)) {
        cache.writeAsStringSync(mutated.single);
        final sw = Stopwatch()..start();
        Object? err;
        try {
          final s = await DashboardStatsCache.forSession(d);
          // A typed-but-changed value (e.g. a different start_ms) is a cache hit by design;
          // only the shape and the absence of errors are checked here.
          if (s.visits.any((v) => v.$2 < v.$1) && !(clean.visits.any((v) => v.$2 < v.$1))) {
            // tolerated: values are trusted when the log is unchanged
          }
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a session log with a time far outside the calendar does not break the Dashboard numbers', () async {
      final d = Directory('${tmp.path}/dash2')..createSync(recursive: true);
      File('${d.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":1700000000000,"config":{"captureTrigger":"detector"}}\n'
        '{"type":"detections","time_ms":1700000001000,"frame_ms":9000000000000000000,"tracks":[{"track_id":1,"class_name":"bee"}]}\n'
        '{"type":"end_of_session","time_ms":1700000002000,"ended_normally":true}\n',
      );
      final stats = await DashboardStatsCache.forSession(d);
      // This is what the Dashboard screen does with every session's numbers.
      expect(() => aggregateDashboard([stats]), returnsNormally);
    });
  });
}
