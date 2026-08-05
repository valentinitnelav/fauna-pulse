// Unit tests for the cross-session dashboard (round 186): the pure
// aggregation math (period filter, hour histogram, day/week bucketing,
// highlights) and the per-session stats cache (compute from a real
// session.jsonl, cache hit, staleness on log change, AI-mode detection).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/logging/dashboard_stats.dart';

/// Epoch ms for a LOCAL wall-clock moment (the aggregation buckets by local
/// time, so tests must build inputs the same way).
int localMs(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime(y, m, d, h, min).millisecondsSinceEpoch;

SessionDashboardStats session({
  required int startMs,
  int? endMs,
  bool aiMode = true,
  List<(int, int)> visits = const [],
}) => SessionDashboardStats(
  startMs: startMs,
  endMs: endMs ?? startMs + 3600000,
  aiMode: aiMode,
  visits: visits,
);

void main() {
  group('aggregateDashboard', () {
    test('sums visits, buckets by local hour, finds the busiest hour', () {
      final s1 = session(
        startMs: localMs(2026, 7, 1, 9),
        endMs: localMs(2026, 7, 1, 11),
        visits: [
          (localMs(2026, 7, 1, 9, 10), localMs(2026, 7, 1, 9, 11)),
          (localMs(2026, 7, 1, 10, 5), localMs(2026, 7, 1, 10, 6)),
          (localMs(2026, 7, 1, 10, 40), localMs(2026, 7, 1, 10, 42)),
        ],
      );
      final agg = aggregateDashboard([s1]);
      expect(agg.totalVisits, 3);
      expect(agg.aiSessions, 1);
      expect(agg.visitsByHour[9], 1);
      expect(agg.visitsByHour[10], 2);
      expect(agg.busiestHour, 10);
      expect(agg.totalRecordedMs, 2 * 3600000);
      expect(agg.visitsPerHour, closeTo(1.5, 1e-9));
      // 1 min + 1 min + 2 min of visit time.
      expect(agg.totalVisitMs, 4 * 60000);
      expect(agg.longestVisitMs, 2 * 60000);
      expect(agg.meanVisitMs, closeTo(4 * 60000 / 3, 1e-9));
    });

    test('non-AI sessions are excluded from numbers but counted separately',
        () {
      final ai = session(
        startMs: localMs(2026, 7, 1, 9),
        visits: [(localMs(2026, 7, 1, 9, 1), localMs(2026, 7, 1, 9, 2))],
      );
      final motion = session(
        startMs: localMs(2026, 7, 1, 12),
        aiMode: false,
      );
      final agg = aggregateDashboard([ai, motion]);
      expect(agg.totalVisits, 1);
      expect(agg.aiSessions, 1);
      expect(agg.otherSessions, 1);
    });

    test('period filter works on the session start time', () {
      final old = session(
        startMs: localMs(2026, 6, 1, 9),
        visits: [(localMs(2026, 6, 1, 9, 1), localMs(2026, 6, 1, 9, 2))],
      );
      final recent = session(
        startMs: localMs(2026, 7, 20, 9),
        visits: [(localMs(2026, 7, 20, 9, 1), localMs(2026, 7, 20, 9, 2))],
      );
      final agg = aggregateDashboard(
        [old, recent],
        sinceMs: localMs(2026, 7, 1),
      );
      expect(agg.totalVisits, 1);
      expect(agg.aiSessions, 1);
    });

    test('daily activity is contiguous with zero-filled gaps + record day',
        () {
      final s = session(
        startMs: localMs(2026, 7, 1, 9),
        visits: [
          (localMs(2026, 7, 1, 9, 0), localMs(2026, 7, 1, 9, 1)),
          (localMs(2026, 7, 3, 9, 0), localMs(2026, 7, 3, 9, 1)),
          (localMs(2026, 7, 3, 10, 0), localMs(2026, 7, 3, 10, 1)),
        ],
      );
      final agg = aggregateDashboard([s]);
      expect(agg.weeklyBuckets, isFalse);
      expect(agg.activity.map((b) => b.count), [1, 0, 2]);
      expect(agg.activity.first.day, DateTime(2026, 7, 1));
      expect(agg.recordDay, DateTime(2026, 7, 3));
      expect(agg.recordDayCount, 2);
    });

    test('a span over ~2 months switches to weekly buckets', () {
      final s = session(
        startMs: localMs(2026, 4, 1, 9),
        visits: [
          (localMs(2026, 4, 1, 9, 0), localMs(2026, 4, 1, 9, 1)),
          (localMs(2026, 4, 9, 9, 0), localMs(2026, 4, 9, 9, 1)),
          (localMs(2026, 7, 1, 9, 0), localMs(2026, 7, 1, 9, 1)),
        ],
      );
      final agg = aggregateDashboard([s]);
      expect(agg.weeklyBuckets, isTrue);
      expect(agg.activity.first.day, DateTime(2026, 4, 1));
      expect(agg.activity.first.count, 1);
      expect(agg.activity[1].count, 1); // Apr 9 lands in week 2
      expect(agg.activity.map((b) => b.count).reduce((a, b) => a + b), 3);
    });

    test('empty input yields safe zero/null values', () {
      final agg = aggregateDashboard(const []);
      expect(agg.totalVisits, 0);
      expect(agg.busiestHour, isNull);
      expect(agg.recordDay, isNull);
      expect(agg.activity, isEmpty);
      expect(agg.visitsPerHour, 0);
      expect(agg.meanVisitMs, 0);
    });
  });

  group('DashboardStatsCache', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dash_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File writeLog(Directory dir, List<String> lines) =>
        File('${dir.path}/session.jsonl')
          ..writeAsStringSync('${lines.join('\n')}\n');

    String start(int ms, {String trigger = 'detector'}) => jsonEncode({
      'type': 'start_of_session',
      'time_ms': ms,
      'config': {'captureTrigger': trigger},
    });

    String detections(int ms, List<int> ids) => jsonEncode({
      'type': 'detections',
      'time_ms': ms,
      'frame_ms': ms,
      'tracks': [
        for (final id in ids)
          {
            'track_id': id,
            'class_name': 'bee',
            'confidence': 0.9,
            'box_in_roi': {
              'left': 0.1,
              'top': 0.1,
              'right': 0.2,
              'bottom': 0.2,
            },
          },
      ],
    });

    String end(int ms) => jsonEncode({
      'type': 'end_of_session',
      'time_ms': ms,
      'ended_normally': true,
    });

    test('computes stats from the log and writes the cache file', () async {
      writeLog(tmp, [
        start(1000),
        detections(2000, [1]),
        detections(3000, [1, 2]),
        detections(4000, [2]),
        end(9000),
      ]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.aiMode, isTrue);
      expect(stats.startMs, 1000);
      expect(stats.endMs, 9000);
      expect(stats.visits, [(2000, 3000), (3000, 4000)]);
      expect(
        File('${tmp.path}/${DashboardStatsCache.fileName}').existsSync(),
        isTrue,
      );
    });

    test('a valid cache is used instead of re-parsing', () async {
      writeLog(tmp, [start(1000), detections(2000, [1]), end(9000)]);
      await DashboardStatsCache.forSession(tmp);
      // Doctor the cached stats WITHOUT touching the log: a cache hit
      // returns the doctored value, a re-parse would return the true one.
      final cacheFile = File('${tmp.path}/${DashboardStatsCache.fileName}');
      final j = jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      j['start_ms'] = 42;
      cacheFile.writeAsStringSync(jsonEncode(j));
      final again = await DashboardStatsCache.forSession(tmp);
      expect(again.startMs, 42);
    });

    test('a changed log invalidates the cache', () async {
      final log = writeLog(tmp, [start(1000), detections(2000, [1]), end(9000)]);
      final first = await DashboardStatsCache.forSession(tmp);
      expect(first.visits, hasLength(1));
      log.writeAsStringSync(
        '${detections(10000, [7])}\n${end(11000)}\n',
        mode: FileMode.append,
      );
      final second = await DashboardStatsCache.forSession(tmp);
      expect(second.visits, hasLength(2));
      expect(second.endMs, 11000);
    });

    test('motion/time-lapse sessions report aiMode false', () async {
      writeLog(tmp, [start(1000, trigger: 'timelapse'), end(9000)]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.aiMode, isFalse);
    });

    test('a crashed session (no end record) uses the last track activity',
        () async {
      writeLog(tmp, [start(1000), detections(2000, [1])]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.endMs, 2000);
      expect(stats.visits, [(2000, 2000)]);
    });

    test('a missing log yields an inert non-AI stats object', () async {
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.aiMode, isFalse);
      expect(stats.visits, isEmpty);
    });
  });
}
