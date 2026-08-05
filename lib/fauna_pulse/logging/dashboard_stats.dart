// FaunaPulse — cross-session dashboard statistics (round 186).
//
// The home screen's Dashboard aggregates every AI-mode session (the mode
// where the tracker ran, so track ids = visits exist) into totals and
// activity histograms: how many insect visits over a period, at which hours
// of the day, on which days. Motion and time-lapse sessions carry no track
// ids, so they are counted separately and shown only as a "not included"
// note.
//
// Per-session numbers are derived with SessionLogIndex (the summary's
// streaming parser, so the legacy `detection` format and truncated lines are
// handled identically to the summary screen) and cached as
// `dashboard_stats.json` INSIDE the session folder, keyed by the log's
// length + mtime. A finished log never changes, so the cache is computed
// once per session; the two events that DO rewrite the log (a crash-truncated
// file growing on a resumed... it cannot — logs are per-session — and the
// r182 rename rewrite) change length/mtime and simply trigger one recompute.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'app_error_hooks.dart';
import 'session_log_index.dart';

/// One session's contribution to the dashboard, small enough to cache as a
/// few KB of JSON.
class SessionDashboardStats {
  /// Session start (epoch ms). Falls back to the log file's mtime when the
  /// start record was lost to a crash.
  final int startMs;

  /// Session end (epoch ms) — the `end_of_session` stamp, else the last
  /// track activity, else [startMs] (zero-length crashed session).
  final int endMs;

  /// True when the session ran the AI detector (tracker active). Motion and
  /// time-lapse sessions are false: no track ids exist there.
  final bool aiMode;

  /// Per confirmed track id: (first seen ms, last seen ms).
  final List<(int, int)> visits;

  const SessionDashboardStats({
    required this.startMs,
    required this.endMs,
    required this.aiMode,
    required this.visits,
  });

  int get recordedMs => max(0, endMs - startMs);

  Map<String, dynamic> toJson() => {
    'start_ms': startMs,
    'end_ms': endMs,
    'ai_mode': aiMode,
    'visits': [
      for (final (s, e) in visits) [s, e],
    ],
  };

  static SessionDashboardStats fromJson(Map<String, dynamic> j) =>
      SessionDashboardStats(
        startMs: (j['start_ms'] as num).toInt(),
        endMs: (j['end_ms'] as num).toInt(),
        aiMode: j['ai_mode'] == true,
        visits: [
          for (final v in (j['visits'] as List))
            (((v as List)[0] as num).toInt(), (v[1] as num).toInt()),
        ],
      );
}

/// Loads (or computes and caches) one session's [SessionDashboardStats].
class DashboardStatsCache {
  static const String fileName = 'dashboard_stats.json';
  static const int _version = 1;

  /// Cache-or-compute. Never throws: an unreadable session yields an empty
  /// non-AI stats object (excluded from every aggregate).
  static Future<SessionDashboardStats> forSession(Directory sessionDir) async {
    final log = File('${sessionDir.path}/session.jsonl');
    int logLen = 0, logMtime = 0;
    try {
      final stat = log.statSync();
      logLen = stat.size;
      logMtime = stat.modified.millisecondsSinceEpoch;
    } catch (e) {
      logSwallowed('dashboard_log_stat', e);
      return const SessionDashboardStats(
        startMs: 0,
        endMs: 0,
        aiMode: false,
        visits: [],
      );
    }

    final cacheFile = File('${sessionDir.path}/$fileName');
    try {
      if (cacheFile.existsSync()) {
        final j =
            jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
        if (j['version'] == _version &&
            (j['log_len'] as num?)?.toInt() == logLen &&
            (j['log_mtime_ms'] as num?)?.toInt() == logMtime) {
          return SessionDashboardStats.fromJson(j);
        }
      }
    } catch (e) {
      logSwallowed('dashboard_cache_read', e); // stale/corrupt → recompute
    }

    final stats = await _compute(log);
    try {
      await cacheFile.writeAsString(
        jsonEncode({
          'version': _version,
          'log_len': logLen,
          'log_mtime_ms': logMtime,
          ...stats.toJson(),
        }),
        flush: true,
      );
    } catch (e) {
      logSwallowed('dashboard_cache_write', e); // cache is best-effort
    }
    return stats;
  }

  static Future<SessionDashboardStats> _compute(File log) async {
    try {
      final index = await SessionLogIndex.build(log);
      final start = index.startRecord;
      final config = start?['config'];
      final startMs =
          (start?['time_ms'] as num?)?.toInt() ??
          log.statSync().modified.millisecondsSinceEpoch;
      final visits = [
        for (final span in index.trackSpans.values) (span.$1, span.$2),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      final lastActivity = visits.isEmpty
          ? startMs
          : visits.map((v) => v.$2).reduce(max);
      return SessionDashboardStats(
        startMs: startMs,
        endMs: max(await _readEndMs(log) ?? lastActivity, startMs),
        aiMode: _isAiMode(config),
        visits: visits,
      );
    } catch (e) {
      logSwallowed('dashboard_stats_compute', e);
      return const SessionDashboardStats(
        startMs: 0,
        endMs: 0,
        aiMode: false,
        visits: [],
      );
    }
  }

  /// Was the tracker running? `captureTrigger` exists since round 97
  /// ('detector' | 'motion' | 'timelapse'); before that the r95
  /// `motionOnlyCapture` bool marks the only no-AI mode; anything older is
  /// always an AI session. A session with no readable config is not
  /// countable, so it reports false.
  static bool _isAiMode(dynamic config) {
    if (config is! Map) return false;
    final trigger = config['captureTrigger'];
    if (trigger is String) return trigger == 'detector';
    return config['motionOnlyCapture'] != true;
  }

  /// The `end_of_session` stamp from the log tail (same cheap trick as the
  /// home list — never a full scan). Null when the session crashed.
  static Future<int?> _readEndMs(File log) async {
    try {
      final raf = await log.open();
      try {
        final len = await raf.length();
        final tailLen = min(16384, len);
        await raf.setPosition(len - tailLen);
        final tail = await raf.read(tailLen);
        final lines = utf8
            .decode(tail, allowMalformed: true)
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        for (final l in lines.reversed) {
          if (!l.contains('"end_of_session"')) continue;
          try {
            final rec = jsonDecode(l) as Map<String, dynamic>;
            return (rec['time_ms'] as num?)?.toInt();
          } catch (_) {
            return null; // truncated end line
          }
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      logSwallowed('dashboard_end_read', e);
    }
    return null;
  }
}

/// One activity-histogram bucket: the bucket's first day + its visit count.
typedef DayBucket = ({DateTime day, int count});

/// Everything the Dashboard screen renders, aggregated over the sessions
/// that fall inside the selected period. Pure + synchronous, so period
/// switches are instant and the math is unit-testable.
class DashboardAggregate {
  final int aiSessions;

  /// Motion/time-lapse sessions in the period — shown as a "not counted"
  /// note, never mixed into the visit numbers.
  final int otherSessions;
  final int totalVisits;
  final int totalRecordedMs;
  final int totalVisitMs;
  final int longestVisitMs;

  /// Visit STARTS per local hour of day (24 entries).
  final List<int> visitsByHour;

  /// Contiguous daily (or weekly, see [weeklyBuckets]) visit counts from the
  /// first to the last active bucket. Empty when there are no visits.
  final List<DayBucket> activity;

  /// True when the activity span exceeded ~2 months and [activity] was
  /// bucketed per week (7-day blocks anchored on the first day) to keep the
  /// bars readable.
  final bool weeklyBuckets;

  final int? busiestHour;
  final DateTime? recordDay;
  final int recordDayCount;

  const DashboardAggregate({
    required this.aiSessions,
    required this.otherSessions,
    required this.totalVisits,
    required this.totalRecordedMs,
    required this.totalVisitMs,
    required this.longestVisitMs,
    required this.visitsByHour,
    required this.activity,
    required this.weeklyBuckets,
    required this.busiestHour,
    required this.recordDay,
    required this.recordDayCount,
  });

  double get meanVisitMs => totalVisits == 0 ? 0 : totalVisitMs / totalVisits;

  /// Visits per recorded hour — the dashboard's headline rate.
  double get visitsPerHour => totalRecordedMs <= 0
      ? 0
      : totalVisits / (totalRecordedMs / Duration.millisecondsPerHour);
}

/// Aggregates [sessions] whose START falls at/after [sinceMs] (0 = all
/// time). Hour/day bucketing uses the device's local time — the biological
/// question ("when are pollinators active?") is about local solar-ish time.
DashboardAggregate aggregateDashboard(
  List<SessionDashboardStats> sessions, {
  int sinceMs = 0,
}) {
  final inPeriod = [
    for (final s in sessions)
      if (s.startMs >= sinceMs) s,
  ];
  final ai = [
    for (final s in inPeriod)
      if (s.aiMode) s,
  ];

  final byHour = List<int>.filled(24, 0);
  final byDay = <DateTime, int>{};
  var totalVisits = 0, totalVisitMs = 0, longest = 0, recordedMs = 0;
  for (final s in ai) {
    recordedMs += s.recordedMs;
    for (final (startMs, endMs) in s.visits) {
      totalVisits++;
      final dur = max(0, endMs - startMs);
      totalVisitMs += dur;
      longest = max(longest, dur);
      final local = DateTime.fromMillisecondsSinceEpoch(startMs);
      byHour[local.hour]++;
      final day = DateTime(local.year, local.month, local.day);
      byDay[day] = (byDay[day] ?? 0) + 1;
    }
  }

  int? busiestHour;
  for (var h = 0; h < 24; h++) {
    if (byHour[h] > 0 && (busiestHour == null || byHour[h] > byHour[busiestHour])) {
      busiestHour = h;
    }
  }
  DateTime? recordDay;
  var recordCount = 0;
  for (final e in byDay.entries) {
    if (e.value > recordCount) {
      recordDay = e.key;
      recordCount = e.value;
    }
  }

  // Contiguous daily buckets first–last active day; weekly when the span
  // would need more than ~2 months of bars.
  var activity = <DayBucket>[];
  var weekly = false;
  if (byDay.isNotEmpty) {
    final days = byDay.keys.toList()..sort();
    final first = days.first, last = days.last;
    final spanDays = last.difference(first).inDays + 1;
    weekly = spanDays > 62;
    if (weekly) {
      final weeks = <DateTime, int>{};
      for (final e in byDay.entries) {
        final offset = e.key.difference(first).inDays ~/ 7;
        final week = DateTime(first.year, first.month, first.day + offset * 7);
        weeks[week] = (weeks[week] ?? 0) + e.value;
      }
      final n = (spanDays + 6) ~/ 7;
      activity = [
        for (var i = 0; i < n; i++)
          (
            day: DateTime(first.year, first.month, first.day + i * 7),
            count:
                weeks[DateTime(first.year, first.month, first.day + i * 7)] ??
                0,
          ),
      ];
    } else {
      activity = [
        for (var i = 0; i < spanDays; i++)
          (
            day: DateTime(first.year, first.month, first.day + i),
            count:
                byDay[DateTime(first.year, first.month, first.day + i)] ?? 0,
          ),
      ];
    }
  }

  return DashboardAggregate(
    aiSessions: ai.length,
    otherSessions: inPeriod.length - ai.length,
    totalVisits: totalVisits,
    totalRecordedMs: recordedMs,
    totalVisitMs: totalVisitMs,
    longestVisitMs: longest,
    visitsByHour: byHour,
    activity: activity,
    weeklyBuckets: weekly,
    busiestHour: busiestHour,
    recordDay: recordDay,
    recordDayCount: recordCount,
  );
}
