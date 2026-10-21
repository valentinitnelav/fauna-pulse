// Scale tests for the session lists and the Dashboard: aggregateDashboard
// over hundreds of synthetic sessions, scanPastSessions over hundreds of
// synthetic session folders (including odd logs), and DashboardStatsCache over
// a few dozen folders (cold and warm). They print their timings so a slow or
// quadratic spot shows up with numbers.
//
// Tests that show a real bug are kept and marked `skip: 'BUG: ...'` so the
// normal suite stays green. Run them with --run-skipped to see them fail.
// All random numbers come from a seeded Random.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/dashboard_stats.dart';
import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';

int localMs(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime(y, m, d, h, min).millisecondsSinceEpoch;

/// [n] synthetic sessions spread over [days] days, each with [visitsEach]
/// track IDs and [identified] identified tracks.
List<SessionDashboardStats> synthSessions(
  int n, {
  int days = 400,
  int visitsEach = 60,
  int identified = 20,
  int seed = 1,
}) {
  final rng = Random(seed);
  const names = ['Apis mellifera', 'Bombus terrestris', 'Eristalis tenax', 'Episyrphus balteatus', 'Vespula vulgaris', 'Lasioglossum', 'no organism', 'unidentified'];
  return [
    for (var i = 0; i < n; i++)
      () {
        final day = rng.nextInt(days);
        final start = localMs(2026, 1, 1, 6 + rng.nextInt(10)) + day * 86400000;
        final visits = [
          for (var v = 0; v < visitsEach; v++)
            (start + v * 40000, start + v * 40000 + 1000 + rng.nextInt(120000)),
        ];
        final tracks = [
          for (var k = 0; k < identified; k++)
            () {
              final name = names[rng.nextInt(names.length)];
              final unnamed = name == 'no organism' || name == 'unidentified';
              return <String, dynamic>{
                'headline': name,
                'identified_rank': unnamed ? null : 'species',
                'ladder': [
                  for (final r in ['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Apis', name]) {'taxon': r},
                ],
                'track_id_count': 1 + rng.nextInt(3) ~/ 2,
                'duration_s': rng.nextDouble() * 100,
              };
            }(),
        ];
        return SessionDashboardStats(
          startMs: start,
          endMs: start + 3600000 * (1 + rng.nextInt(5)),
          aiMode: rng.nextInt(10) != 0,
          visits: visits,
          taxa: SessionTaxa(outdated: rng.nextInt(8) == 0, tracks: tracks, suspect: rng.nextInt(3)),
        );
      }(),
  ];
}

double timeMs(void Function() f) {
  final sw = Stopwatch()..start();
  f();
  sw.stop();
  return sw.elapsedMicroseconds / 1000.0;
}

void main() {
  group('aggregateDashboard at scale', () {
    test('500 sessions: all time, 30 days and 7 days; the numbers add up', () {
      final sessions = synthSessions(500);
      final now = DateTime(2027, 2, 15, 12);
      late DashboardAggregate all, month, week;
      final tAll = timeMs(() => all = aggregateDashboard(sessions, now: now));
      final tMonth = timeMs(() => month = aggregateDashboard(sessions, periodDays: 30, now: now));
      final tWeek = timeMs(() => week = aggregateDashboard(sessions, periodDays: 7, now: now));
      // ignore: avoid_print
      print('aggregateDashboard(500 sessions): all ${tAll.toStringAsFixed(0)} ms, 30 d ${tMonth.toStringAsFixed(0)} ms, '
          '7 d ${tWeek.toStringAsFixed(0)} ms; visits ${all.totalVisits}, weekly bars ${all.weeklyBuckets}, '
          'bars ${all.activity.length}');

      final ai = sessions.where((s) => s.aiMode).toList();
      expect(all.aiSessions, ai.length);
      expect(all.otherSessions, sessions.length - ai.length);
      expect(all.totalVisits, ai.fold<int>(0, (n, s) => n + s.visits.length));
      expect(all.visitsByHour.fold<int>(0, (a, b) => a + b) + all.visitsWithoutClock, all.totalVisits);
      expect(all.activity.fold<int>(0, (a, b) => a + b.count), all.visitsByHour.fold<int>(0, (a, b) => a + b));
      expect(month.totalVisits, lessThanOrEqualTo(all.totalVisits));
      expect(week.totalVisits, lessThanOrEqualTo(month.totalVisits));
      expect(all.taxa, hasLength(kDashboardRanks.length));
      expect(all.identifiedSessions + all.unnamedSessions, lessThanOrEqualTo(all.aiSessions));
      expect(tAll, lessThan(3000));
      expect(tMonth, lessThan(3000));
    });

    test('run time grows about in line with the session count (500 .. 4000)', () {
      final ms = <int, double>{};
      for (final n in [500, 1000, 2000, 4000]) {
        final sessions = synthSessions(n, visitsEach: 30, identified: 10);
        ms[n] = timeMs(() => aggregateDashboard(sessions, now: DateTime(2027, 2, 15)));
      }
      // ignore: avoid_print
      print('aggregateDashboard ms by session count: ${ms.entries.map((e) => '${e.key}:${e.value.toStringAsFixed(0)}').join(' ')}');
      // 8 times the sessions must not cost more than ~40 times the time.
      expect(ms[4000]!, lessThan(max(ms[500]!, 5) * 40));
      expect(ms[4000]!, lessThan(10000));
    });

    test('one session with 20000 track IDs and 2000 guessed clips', () {
      // clockUnsure() walks all guessed clips for every track ID.
      final base = localMs(2026, 6, 1, 8);
      final s = SessionDashboardStats(
        startMs: base,
        endMs: base + 86400000,
        aiMode: true,
        visits: [for (var i = 0; i < 20000; i++) (base + i * 4000, base + i * 4000 + 2000)],
        guessedClips: [for (var i = 0; i < 2000; i++) (base + i * 40000 + 1, base + i * 40000 + 2)],
      );
      late DashboardAggregate agg;
      final t = timeMs(() => agg = aggregateDashboard([s]));
      // ignore: avoid_print
      print('aggregateDashboard(20000 track IDs x 2000 guessed clips): ${t.toStringAsFixed(0)} ms');
      expect(agg.totalVisits, 20000);
      expect(agg.visitsWithoutClock, lessThan(20000));
      expect(t, lessThan(5000));
    });

    test('200000 track IDs in 100 sessions (long field season)', () {
      final sessions = synthSessions(100, visitsEach: 2000, identified: 1, seed: 5);
      late DashboardAggregate agg;
      final t = timeMs(() => agg = aggregateDashboard(sessions, now: DateTime(2027, 2, 15)));
      // ignore: avoid_print
      print('aggregateDashboard(100 sessions x 2000 track IDs): ${t.toStringAsFixed(0)} ms');
      expect(agg.totalVisits, greaterThan(150000));
      expect(t, lessThan(5000));
    });

    test('a track ID with a wrong phone clock (1970) does not turn the all-time chart into thousands of bars', () {
      final good = synthSessions(3, days: 30, visitsEach: 5, identified: 0);
      final wrong = SessionDashboardStats(
        startMs: 60000, // 1970-01-01, phone clock lost its time
        endMs: 120000,
        aiMode: true,
        visits: const [(61000, 65000)],
      );
      final agg = aggregateDashboard([...good, wrong], now: DateTime(2026, 12, 1));
      // ignore: avoid_print
      print('1970 outlier: ${agg.activity.length} bars (weekly: ${agg.weeklyBuckets})');
      expect(agg.activity.length, lessThanOrEqualTo(200));
      expect(agg.visitsWithoutClock, 1);
    });

    test('a track ID with a far-future clock (year 9999) stays fast and small', () {
      final good = synthSessions(3, days: 30, visitsEach: 5, identified: 0);
      final future = SessionDashboardStats(
        startMs: 253402300800000 - 100000, // year 9999
        endMs: 253402300800000,
        aiMode: true,
        visits: const [(253402300000000, 253402300400000)],
      );
      late DashboardAggregate agg;
      final t = timeMs(() => agg = aggregateDashboard([...good, future], now: DateTime(2026, 12, 1)));
      // ignore: avoid_print
      print('year-9999 outlier: ${agg.activity.length} bars in ${t.toStringAsFixed(0)} ms');
      expect(agg.activity.length, lessThanOrEqualTo(200));
      expect(agg.visitsWithoutClock, 1);
    });

    test('a time stamp beyond the DateTime range does not throw', () {
      // A cached dashboard_stats.json (or a log) with a huge number reads as
      // an int; DateTime.fromMillisecondsSinceEpoch then throws.
      final s = SessionDashboardStats(
        startMs: 9000000000000000,
        endMs: 9000000000000001,
        aiMode: true,
        visits: const [(9000000000000000, 9000000000000001)],
      );
      expect(() => aggregateDashboard([s]), returnsNormally);
      expect(aggregateDashboard([s]).visitsWithoutClock, 1);
      // A valid but absurd date (year 3000) also stays out of the charts.
      final y3000 = DateTime(3000).millisecondsSinceEpoch;
      final far = SessionDashboardStats(startMs: y3000, endMs: y3000 + 1000, aiMode: true, visits: [(y3000, y3000 + 1000)]);
      final agg = aggregateDashboard([far], now: DateTime(2026, 12, 1));
      expect(agg.visitsWithoutClock, 1);
      expect(agg.activity.length, lessThanOrEqualTo(200));
    });

    test('periodDays 0 or negative still gives a non-empty chart', () {
      for (final p in [0, -3]) {
        final agg = aggregateDashboard(synthSessions(2), periodDays: p, now: DateTime(2026, 12, 1));
        expect(agg.activity, isNotEmpty, reason: 'periodDays $p');
      }
    });

    test('empty input, sessions without visits and sessions that end before they start', () {
      expect(aggregateDashboard(const []).totalVisits, 0);
      final odd = [
        const SessionDashboardStats(startMs: 0, endMs: 0, aiMode: false, visits: []),
        const SessionDashboardStats(startMs: 5000, endMs: 1000, aiMode: true, visits: []),
        const SessionDashboardStats(startMs: -5000, endMs: -1000, aiMode: true, visits: [(-4000, -5000)]),
      ];
      final agg = aggregateDashboard(odd, now: DateTime(2026, 12, 1));
      expect(agg.totalRecordedMs, greaterThanOrEqualTo(0));
      expect(agg.longestVisitMs, greaterThanOrEqualTo(0));
      expect(agg.medianVisitMs, greaterThanOrEqualTo(0));
    });
  });

  group('scanPastSessions at scale', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('stress_scan'));
    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    Directory makeSession(String name, {int startMs = 1700000000000, int lines = 30, bool end = true, int files = 0}) {
      final d = Directory('${root.path}/$name')..createSync();
      final b = StringBuffer('{"type":"start_of_session","time_ms":$startMs,"config":{"captureTrigger":"detector"}}\n');
      for (var i = 0; i < lines; i++) {
        b.write('{"type":"detections","time_ms":${startMs + i * 100},"frame_ms":${startMs + i * 100},"tracks":[{"track_id":${i % 5},"class_name":"bee","confidence":0.8}]}\n');
      }
      if (end) b.write('{"type":"end_of_session","time_ms":${startMs + lines * 100},"ended_normally":true}\n');
      File('${d.path}/session.jsonl').writeAsStringSync(b.toString());
      if (files > 0) {
        final frames = Directory('${d.path}/roi_frames')..createSync();
        for (var i = 0; i < files; i++) {
          File('${frames.path}/roi_$i.jpg').writeAsBytesSync(const [1, 2, 3]);
        }
      }
      return d;
    }

    test('300 session folders (30 photos each): the scan finishes quickly, newest first', () async {
      for (var i = 0; i < 300; i++) {
        makeSession('s_$i', startMs: 1700000000000 + i * 3600000, files: 30);
      }
      final sw = Stopwatch()..start();
      final all = await scanPastSessions(root: root);
      sw.stop();
      // ignore: avoid_print
      print('scanPastSessions(300 folders x 30 photos): ${sw.elapsedMilliseconds} ms');
      expect(all, hasLength(300));
      expect(all.first.name, 's_299');
      expect(all.last.name, 's_0');
      expect(all.every((s) => s.endedNormally && s.duration == const Duration(milliseconds: 3000)), isTrue);
      expect(all.every((s) => s.sizeBytes > 90), isTrue);
      expect(sw.elapsedMilliseconds, lessThan(15000));
    });

    test('the folder size walk costs per file: one session with 6000 photos', () async {
      makeSession('big', files: 6000);
      final sw = Stopwatch()..start();
      final all = await scanPastSessions(root: root);
      sw.stop();
      // ignore: avoid_print
      print('scanPastSessions(1 folder x 6000 photos): ${sw.elapsedMilliseconds} ms '
          '(${(sw.elapsedMicroseconds / 6000).toStringAsFixed(0)} us per file)');
      expect(all, hasLength(1));
      expect(sw.elapsedMilliseconds, lessThan(10000));
    });

    test('odd logs: empty, one byte, binary, cut JSON, only newlines, no start record', () async {
      final rng = Random(3);
      final logs = <String, List<int>>{
        'empty': const [],
        'one_byte': const [123],
        'newlines': List.filled(5000, 10),
        'cut_json': utf8.encode('{"type":"start_of_session","time_ms":17000000000'),
        'binary': List.generate(40000, (_) => rng.nextInt(256)),
        'no_start': utf8.encode('{"type":"end_of_session","time_ms":1700000100000,"ended_normally":true}\n'),
        'utf8_cut': [...utf8.encode('{"type":"start_of_session","time_ms":1700000000000,"x":"'), 0xC3],
        'crlf': utf8.encode('{"type":"start_of_session","time_ms":1700000000000}\r\n{"type":"end_of_session","time_ms":1700000005000,"ended_normally":true}\r\n'),
      };
      for (final e in logs.entries) {
        final d = Directory('${root.path}/${e.key}')..createSync();
        File('${d.path}/session.jsonl').writeAsBytesSync(e.value);
      }
      final all = await scanPastSessions(root: root);
      expect(all.map((s) => s.name).toSet(), logs.keys.toSet(), reason: 'every folder with a session.jsonl is listed');
      expect(all.firstWhere((s) => s.name == 'crlf').duration, const Duration(seconds: 5));
    });

    test('a session whose start record is larger than 64 KB is still listed with its start time', () async {
      final d = Directory('${root.path}/huge_start')..createSync();
      final pad = 'x' * 70000;
      File('${d.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":1700000000000,"config":{"notes":"$pad"}}\n'
        '{"type":"end_of_session","time_ms":1700000060000,"ended_normally":true}\n',
      );
      final all = await scanPastSessions(root: root);
      expect(all.single.start, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(all.single.duration, const Duration(seconds: 60));
    });

    test('end_of_session followed by a long video_cleanup record is still found as the clean end', () async {
      final d = Directory('${root.path}/cleaned')..createSync();
      final clips = [for (var i = 0; i < 900; i++) 'clip_20261020_${100000 + i}_${i % 7}.mp4'];
      File('${d.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":1700000000000,"config":{}}\n'
        '{"type":"end_of_session","time_ms":1700000060000,"ended_normally":true}\n'
        '${jsonEncode({'type': 'video_cleanup', 'time_ms': 1700009000000, 'mode': 'all', 'clips': clips, 'freed_bytes': 1})}\n',
      );
      final all = await scanPastSessions(root: root);
      expect(all.single.endedNormally, isTrue);
      expect(all.single.duration, const Duration(seconds: 60));
      // The Dashboard reads the same tail: the session's end, not the cleanup time.
      expect((await DashboardStatsCache.forSession(d)).endMs, 1700000060000);
    });

    test('one session with a bad time value does not hide the other sessions', () async {
      for (var i = 0; i < 5; i++) {
        makeSession('good_$i', startMs: 1700000000000 + i * 1000);
      }
      final bad = Directory('${root.path}/bad_time')..createSync();
      File('${bad.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":"yesterday","config":{}}\n',
      );
      final bad2 = Directory('${root.path}/bad_time_huge')..createSync();
      File('${bad2.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":99999999999999999999,"config":{}}\n',
      );
      final all = await scanPastSessions(root: root);
      expect(all.map((s) => s.name).toSet().containsAll({for (var i = 0; i < 5; i++) 'good_$i'}), isTrue,
          reason: 'listed: ${all.map((s) => s.name).toList()}');
      // A bad time_ms falls back to the file time, so these stay listed too.
      expect(all.map((s) => s.name), containsAll(['bad_time', 'bad_time_huge']));
    });
  });

  group('DashboardStatsCache over many folders', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('stress_dash'));
    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('60 folders with 20000-line logs: cold then warm', () async {
      final rng = Random(9);
      final dirs = <Directory>[];
      for (var s = 0; s < 60; s++) {
        final d = Directory('${root.path}/s_$s')..createSync();
        final startMs = 1700000000000 + s * 86400000;
        final b = StringBuffer('{"type":"start_of_session","time_ms":$startMs,"config":{"captureTrigger":"detector"}}\n');
        for (var i = 0; i < 20000; i++) {
          final ms = startMs + i * 100;
          if (i % 4 == 0) {
            b.write('{"type":"fps","time_ms":$ms,"fps":9.0,"pipeline_fps":10.0,"inf_ms":55.0}\n');
          } else {
            b.write('{"type":"detections","time_ms":$ms,"frame_ms":$ms,"tracks":[{"track_id":${1 + (i ~/ 500) + rng.nextInt(2)},"class_name":"bee","confidence":0.8}]}\n');
          }
        }
        b.write('{"type":"end_of_session","time_ms":${startMs + 2000000},"ended_normally":true}\n');
        File('${d.path}/session.jsonl').writeAsStringSync(b.toString());
        dirs.add(d);
      }
      final cold = Stopwatch()..start();
      final first = <SessionDashboardStats>[];
      for (final d in dirs) {
        first.add(await DashboardStatsCache.forSession(d));
      }
      cold.stop();
      final warm = Stopwatch()..start();
      final second = <SessionDashboardStats>[];
      for (final d in dirs) {
        second.add(await DashboardStatsCache.forSession(d));
      }
      warm.stop();
      // ignore: avoid_print
      print('DashboardStatsCache 60 x 20000 lines: cold ${cold.elapsedMilliseconds} ms, warm ${warm.elapsedMilliseconds} ms');
      expect(first.every((s) => s.aiMode && s.visits.isNotEmpty), isTrue);
      expect([for (final s in second) s.visits.length], [for (final s in first) s.visits.length]);
      expect(warm.elapsedMilliseconds, lessThan(cold.elapsedMilliseconds));
      expect(cold.elapsedMilliseconds, lessThan(40000));
    });

    test('a corrupt cache file, a log that vanished and a folder without a log never throw', () async {
      final a = Directory('${root.path}/a')..createSync();
      File('${a.path}/session.jsonl').writeAsStringSync('{"type":"start_of_session","time_ms":1700000000000,"config":{}}\n');
      File('${a.path}/dashboard_stats.json').writeAsStringSync('{"version":4,"log_len":"x"');
      expect((await DashboardStatsCache.forSession(a)).startMs, 1700000000000);

      final b = Directory('${root.path}/b')..createSync();
      expect((await DashboardStatsCache.forSession(b)).aiMode, isFalse);

      final c = Directory('${root.path}/c')..createSync();
      File('${c.path}/session.jsonl').writeAsStringSync('{"type":"start_of_session","time_ms":1700000000000,"config":{}}\n');
      await DashboardStatsCache.forSession(c);
      // A valid-looking cache whose numbers are text instead of numbers.
      final cache = File('${c.path}/dashboard_stats.json');
      final j = jsonDecode(cache.readAsStringSync()) as Map<String, dynamic>;
      j['start_ms'] = 'oops';
      cache.writeAsStringSync(jsonEncode(j));
      expect((await DashboardStatsCache.forSession(c)).startMs, 1700000000000);
    });
  });
}
