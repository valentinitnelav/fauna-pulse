// FaunaPulse — cross-session dashboard statistics (round 186).
//
// The home screen's Dashboard aggregates every session with track IDs (live
// detection, and since round 229 also sessions whose track IDs were found
// afterwards in their videos or photos) into totals and activity
// histograms: how many track IDs over a period, at which hours of the day,
// on which days. Sessions without track IDs are counted separately and
// shown only as a "not counted" note.
//
// Per-session numbers are derived with SessionLogIndex (the summary's
// streaming parser, so the legacy `detection` format and truncated lines are
// handled identically to the summary screen) and cached as
// `dashboard_stats.json` INSIDE the session folder, keyed by the log's
// length + mtime. A finished log rarely changes, so the cache is computed
// once per session; the events that do rewrite or extend it (a rename, a
// clip cleanup) change length/mtime and simply trigger one recompute.
//
// Round 229: imported-video sessions count too once "Find visits" has run.
// Their visits come from post_tracks.jsonl (track_source.dart), whose length
// + mtime join the cache key, so re-finding visits recomputes.
//
// Round 304: the session's newest identification (the one "View results"
// opens) joins the cache, so the Dashboard can count track IDs per order,
// family, genus and species exactly as the results screen does; the
// summary file's name, length and mtime join the key. Also: the per-hour
// rate needs a minimum watch time, a crashed session ends at its last
// logged record, imported videos whose filming time was only guessed stay
// out of the charts by time, periods are calendar days (as the Sessions
// filter), and day buckets count calendar days (a 23-hour spring day no
// longer drops a bar).
//
// Round 305: track lengths start at the tracker's first sighting (the
// shared TrackSpans rule, as track_ids.csv); the rate per hour needs 1 h of
// watching; the day chart always has its days, at zero without data.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import '../identification/identification_store.dart' show IdentificationPaths;
import '../identification/label_pack.dart' show kRankNames;
import '../identification/taxa_table.dart';
import '../postprocess/video_tracker.dart' show VideoTracker;
import 'app_error_hooks.dart';
import 'session_log_index.dart';
import 'track_source.dart';

/// Below this much watching, a "per hour" rate would scale a few minutes up
/// to an hour and mostly show chance, so the Dashboard shows no rate.
const kRateMinWatchMs = Duration.millisecondsPerHour;

/// The ranks the Dashboard counts taxa at (the results screen's chips).
const kDashboardRanks = ['order', 'family', 'genus', 'species'];

/// One session's newest identification, as the Dashboard counts it.
class SessionTaxa {
  /// The track IDs were found again after this identification ran, so its
  /// numbers point at other track IDs (the results screen says "run
  /// identification again"). The Dashboard leaves such results out.
  final bool outdated;

  /// One entry per identified track ID (track IDs joined by identification
  /// count once), suspect ones left out as on the results screen. Shaped for
  /// [aggregateTracks]: `headline`, `identified_rank` and a `ladder` of
  /// `{taxon}` from kingdom down to the identified rank; `track_id_count` =
  /// how many track IDs the entry covers (more than 1 when joined).
  final List<Map<String, dynamic>> tracks;

  /// Track IDs left out as suspect (likely false detections).
  final int suspect;

  const SessionTaxa({required this.outdated, required this.tracks, this.suspect = 0});

  Map<String, dynamic> toJson() => {
    'outdated': outdated,
    if (suspect > 0) 'suspect': suspect,
    'tracks': [
      for (final t in tracks)
        {
          'headline': t['headline'],
          'identified_rank': t['identified_rank'],
          'ladder': [for (final s in t['ladder'] as List) (s as Map)['taxon']],
          'track_id_count': t['track_id_count'],
        },
    ],
  };

  static SessionTaxa fromJson(Map<String, dynamic> j) => SessionTaxa(
    outdated: j['outdated'] == true,
    suspect: (j['suspect'] as num?)?.toInt() ?? 0,
    tracks: [
      for (final t in (j['tracks'] as List).cast<Map<String, dynamic>>())
        {
          'headline': t['headline'],
          'identified_rank': t['identified_rank'],
          'ladder': [
            for (final name in t['ladder'] as List) {'taxon': name},
          ],
          'track_id_count': t['track_id_count'],
        },
    ],
  );
}

/// One session's contribution to the dashboard, small enough to cache as a
/// few KB of JSON.
class SessionDashboardStats {
  /// Session start (epoch ms). Falls back to the log file's mtime when the
  /// start record was lost to a crash.
  final int startMs;

  /// Session end (epoch ms) — the `end_of_session` stamp, else the last
  /// logged record, else [startMs] (zero-length crashed session).
  final int endMs;

  /// True when the session has track IDs: the AI detector ran live (tracker
  /// active), or track IDs were found afterwards in its videos or photos.
  final bool aiMode;

  /// Per confirmed track id: (first seen ms, last seen ms).
  final List<(int, int)> visits;

  /// Filmed time of visits found afterwards (the clips' total length; the
  /// gaps between clips were not watched). Null for live sessions.
  final int? observedMs;

  /// The clips of an imported video whose filming time was only guessed
  /// (the file's copy time, or only the day from its name) and not set by
  /// the user, as (start ms, end ms): track IDs that begin in one have no
  /// known clock time, so they stay out of the charts by hour and day.
  final List<(int, int)> guessedClips;

  /// The newest identification, or null when the session has none.
  final SessionTaxa? taxa;

  const SessionDashboardStats({
    required this.startMs,
    required this.endMs,
    required this.aiMode,
    required this.visits,
    this.observedMs,
    this.guessedClips = const [],
    this.taxa,
  });

  /// True when the track ID that began at [startMs] has no known clock time.
  bool clockUnsure(int startMs) => guessedClips.any((c) => startMs >= c.$1 && startMs <= c.$2);

  int get recordedMs => observedMs ?? max(0, endMs - startMs);

  /// The same numbers with another identification.
  SessionDashboardStats withTaxa(SessionTaxa? taxa) => SessionDashboardStats(
    startMs: startMs,
    endMs: endMs,
    aiMode: aiMode,
    visits: visits,
    observedMs: observedMs,
    guessedClips: guessedClips,
    taxa: taxa,
  );

  Map<String, dynamic> toJson() => {
    'start_ms': startMs,
    'end_ms': endMs,
    'ai_mode': aiMode,
    'observed_ms': ?observedMs,
    if (guessedClips.isNotEmpty)
      'guessed_clips': [
        for (final (s, e) in guessedClips) [s, e],
      ],
    'track_ids': [
      for (final (s, e) in visits) [s, e],
    ],
    'taxa': ?taxa?.toJson(),
  };

  static SessionDashboardStats fromJson(Map<String, dynamic> j) =>
      SessionDashboardStats(
        startMs: (j['start_ms'] as num).toInt(),
        endMs: (j['end_ms'] as num).toInt(),
        aiMode: j['ai_mode'] == true,
        visits: [
          for (final v in ((j['track_ids'] ?? j['visits']) as List)) // "visits" before round 248
            (((v as List)[0] as num).toInt(), (v[1] as num).toInt()),
        ],
        observedMs: (j['observed_ms'] as num?)?.toInt(),
        guessedClips: [
          for (final c in (j['guessed_clips'] as List? ?? const []))
            (((c as List)[0] as num).toInt(), (c[1] as num).toInt()),
        ],
        taxa: j['taxa'] is Map
            ? SessionTaxa.fromJson((j['taxa'] as Map).cast<String, dynamic>())
            : null,
      );
}

/// Loads (or computes and caches) one session's [SessionDashboardStats].
class DashboardStatsCache {
  static const String fileName = 'dashboard_stats.json';

  /// 3 (round 304): end of crashed sessions, guessed_clips, taxa with the
  /// suspect count (2 was a test build of the same round). 4 (round 305):
  /// track spans start at the first sighting, so cached lengths are redone.
  static const int _version = 4;

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

    // Visits found afterwards (round 229); 0/0 when there are none, which is
    // also what an older cache without these keys reads as.
    int tracksLen = 0, tracksMtime = 0;
    final tracks = File('${sessionDir.path}/$postTracksFileName');
    if (tracks.existsSync()) {
      try {
        final stat = tracks.statSync();
        tracksLen = stat.size;
        tracksMtime = stat.modified.millisecondsSinceEpoch;
      } catch (e) {
        logSwallowed('dashboard_tracks_stat', e);
      }
    }

    // The newest identification summary (round 304): a new run, a re-score
    // or a deletion changes its name, length or mtime.
    String? idName;
    int idLen = 0, idMtime = 0;
    File? summary;
    try {
      final summaries = IdentificationPaths(sessionDir).existingSummaries();
      if (summaries.isNotEmpty) {
        summary = summaries.first;
        final stat = summary.statSync();
        idName = summary.path.split('/').last;
        idLen = stat.size;
        idMtime = stat.modified.millisecondsSinceEpoch;
      }
    } catch (e) {
      logSwallowed('dashboard_id_stat', e);
    }

    final cacheFile = File('${sessionDir.path}/$fileName');
    SessionDashboardStats? sameLog;
    try {
      if (cacheFile.existsSync()) {
        final j =
            jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
        if (j['version'] == _version &&
            (j['log_len'] as num?)?.toInt() == logLen &&
            (j['log_mtime_ms'] as num?)?.toInt() == logMtime &&
            ((j['tracks_len'] as num?)?.toInt() ?? 0) == tracksLen &&
            ((j['tracks_mtime_ms'] as num?)?.toInt() ?? 0) == tracksMtime) {
          final cached = SessionDashboardStats.fromJson(j);
          if (j['id_file'] == idName &&
              ((j['id_len'] as num?)?.toInt() ?? 0) == idLen &&
              ((j['id_mtime_ms'] as num?)?.toInt() ?? 0) == idMtime) {
            return cached;
          }
          sameLog = cached;
        }
      }
    } catch (e) {
      logSwallowed('dashboard_cache_read', e); // stale/corrupt → recompute
    }

    // Only the identification changed: keep the numbers from the log (a
    // long session's log takes a while to read) and read the new names.
    final stats = sameLog != null
        ? sameLog.withTaxa(summary == null ? null : await _readTaxa(sessionDir, summary))
        : await _compute(sessionDir, log, summary);
    try {
      await cacheFile.writeAsString(
        jsonEncode({
          'version': _version,
          'log_len': logLen,
          'log_mtime_ms': logMtime,
          if (tracksLen > 0) 'tracks_len': tracksLen,
          if (tracksLen > 0) 'tracks_mtime_ms': tracksMtime,
          'id_file': ?idName,
          if (idName != null) 'id_len': idLen,
          if (idName != null) 'id_mtime_ms': idMtime,
          ...stats.toJson(),
        }),
        flush: true,
      );
    } catch (e) {
      logSwallowed('dashboard_cache_write', e); // cache is best-effort
    }
    return stats;
  }

  static Future<SessionDashboardStats> _compute(Directory sessionDir, File log, File? summary) async {
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
      final afterwards = index.trackSource == TrackSource.afterwards;
      final tail = await _readTail(log);
      return SessionDashboardStats(
        startMs: startMs,
        endMs: max(tail.endMs ?? max(tail.lastMs ?? startMs, lastActivity), startMs),
        aiMode: afterwards || liveTrackerRan(config),
        visits: visits,
        observedMs: afterwards
            ? (index.postTrackStart?['observed_ms'] as num?)?.toInt()
            : null,
        guessedClips: start?['source'] == 'imported_video' ? await _guessedClips(log) : const [],
        taxa: summary == null ? null : await _readTaxa(sessionDir, summary),
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

  /// Records appended to a session log after the recording ended (a clip
  /// cleanup, a rename): their time is not recording time.
  static const _laterRecords = {'"video_cleanup"', '"session_renamed"'};

  /// From the log tail (same cheap trick as the home list, never a full
  /// scan): the `end_of_session` stamp, null when the session crashed, and
  /// the time of the last record written while recording (the crash
  /// fallback; phone samples arrive every 5 to 10 s).
  static Future<({int? endMs, int? lastMs})> _readTail(File log) async {
    int? endMs, lastMs;
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
          if (_laterRecords.any(l.contains)) continue;
          final Map<String, dynamic> rec;
          try {
            rec = jsonDecode(l) as Map<String, dynamic>;
          } catch (_) {
            continue; // a cut line (the window's first, or a crash's last)
          }
          final t = (rec['time_ms'] as num?)?.toInt();
          if (rec['type'] == 'end_of_session') {
            endMs = t;
            break;
          }
          lastMs ??= t;
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      logSwallowed('dashboard_end_read', e);
    }
    return (endMs: endMs, lastMs: lastMs);
  }

  /// Clip start sources that are only a guess (video_start_time.dart).
  static const _guessedStarts = {'file_time', 'file_name_date'};

  /// The clips whose `video_clip` record says their start was guessed and
  /// the user did not set it (`start_time_weak` since round 304; the guess's
  /// source for older imports), as (start ms, end ms). Imported-video logs
  /// are a few KB.
  static Future<List<(int, int)>> _guessedClips(File log) async {
    final out = <(int, int)>[];
    try {
      for (final l in await log.readAsLines()) {
        if (!l.contains('"video_clip"')) continue;
        final rec = jsonDecode(l) as Map<String, dynamic>;
        if (rec['type'] != 'video_clip' || rec['start_time_source'] == 'user') continue;
        if (rec['start_time_weak'] == true ||
            _guessedStarts.contains(rec['start_time_source']) ||
            _guessedStarts.contains(rec['start_time_guess_source'])) {
          final start = ((rec['start_epoch_ms'] ?? rec['time_ms']) as num).toInt();
          out.add((start, start + ((rec['duration_ms'] as num?)?.toInt() ?? 0)));
        }
      }
    } catch (e) {
      logSwallowed('dashboard_clock_read', e);
    }
    return out;
  }

  /// The identification behind [summary] (the session's newest), compacted
  /// for [SessionTaxa]. Outdated exactly as the results screen judges it:
  /// made from another "Find track IDs" run than the session's last one.
  /// Also outdated: an identification of photos only (made before the
  /// session had track IDs). Null when the files cannot be read.
  static Future<SessionTaxa?> _readTaxa(Directory sessionDir, File summary) async {
    try {
      final s = jsonDecode(await summary.readAsString()) as Map<String, dynamic>;
      final capture = s['capture'] as Map?;
      final usedRunId = ((capture?['track_ids_run_id'] ?? capture?['visits_run_id']) as num?)?.toInt();
      final renumbered =
          usedRunId != null && (await VideoTracker.readSummary(sessionDir))?.runId != usedRunId;
      final name = summary.path.split('/').last;
      final stem = name.substring('summary_'.length, name.length - '.json'.length);
      final tracksPath = IdentificationPaths(sessionDir).tracksJson(stem).path;
      // The full tracks file holds every crop (megabytes for a long
      // session): parse it off the screen's thread, keep only the names.
      final read = await Isolate.run(() => compactIdentifiedTracks(tracksPath));
      return SessionTaxa(outdated: renumbered || read.photosOnly, tracks: read.tracks, suspect: read.suspect);
    } catch (e) {
      logSwallowed('dashboard_taxa_read', e);
      return null;
    }
  }
}

/// The entries of a `tracks_<pack>.json` the Dashboard counts: one per
/// identified track ID, without suspect ones and without photos that have
/// no track ID, with the ladder cut to the identified rank (all that
/// [aggregateTracks] reads at the Dashboard's ranks). [suspect]: the track
/// IDs left out as suspect. [photosOnly]: the file has entries, but none for
/// a track ID.
({List<Map<String, dynamic>> tracks, int suspect, bool photosOnly}) compactIdentifiedTracks(String tracksJsonPath) {
  final full = jsonDecode(File(tracksJsonPath).readAsStringSync()) as Map<String, dynamic>;
  final all = (full['tracks'] as List? ?? const []).cast<Map<String, dynamic>>();
  final out = <Map<String, dynamic>>[];
  var withTrackId = 0, suspect = 0;
  for (final t in all) {
    final ids = t['track_ids'] as List? ?? [?t['track_id']];
    if (ids.isEmpty) continue;
    withTrackId++;
    if (t['suspect'] == true) {
      suspect += ids.length;
      continue;
    }
    final rank = t['identified_rank'] as String?;
    final depth = rank == null ? 0 : kRankNames.indexOf(rank) + 1;
    final ladder = (t['ladder'] as List? ?? const []).cast<Map<String, dynamic>>();
    out.add({
      'headline': '${t['headline']}',
      'identified_rank': rank,
      'ladder': [
        for (final step in ladder.take(depth)) {'taxon': '${step['taxon']}'},
      ],
      'track_id_count': ids.length,
    });
  }
  return (tracks: out, suspect: suspect, photosOnly: all.isNotEmpty && withTrackId == 0);
}

/// One activity-histogram bucket: the bucket's first day + its visit count.
typedef DayBucket = ({DateTime day, int count});

/// The taxa counted at one rank: rows as on the results screen (taxa by
/// count, then the "not resolved", "unidentified" and "no organism" rows).
class RankTaxa {
  final String rank;
  final List<TaxonRow> rows;
  const RankTaxa(this.rank, this.rows);

  /// How many different taxa were named at this rank.
  int get distinct => rows.where((r) => !r.isBucket).length;
}

/// Everything the Dashboard screen renders, aggregated over the sessions
/// that fall inside the selected period. Pure + synchronous, so period
/// switches are instant and the math is unit-testable.
class DashboardAggregate {
  final int aiSessions;

  /// Sessions without track IDs in the period (motion/time-lapse photos and
  /// imported videos before "Find animals"): shown as a "not counted" note,
  /// never mixed into the numbers.
  final int otherSessions;
  final int totalVisits;
  final int totalRecordedMs;
  final int longestVisitMs;

  /// The middle track length (half are shorter, half longer): lengths are
  /// skewed (a few insects rest for minutes), so the median says more about
  /// a typical track ID than the mean.
  final int medianVisitMs;

  /// Visit STARTS per local hour of day (24 entries).
  final List<int> visitsByHour;

  /// Daily (or weekly, see [weeklyBuckets]) visit counts: every day of a
  /// fixed period, or from the first to the last active day for all time.
  /// Never empty (round 305): without visits with a known time, a fixed
  /// period still has its days and all time the last 7 days, all at zero.
  final List<DayBucket> activity;

  /// True when the activity span exceeded ~2 months and [activity] was
  /// bucketed per week (7-day blocks anchored on the first day) to keep the
  /// bars readable.
  final bool weeklyBuckets;

  /// The hour with the most track IDs; null unless it has more than every
  /// other hour (one hour alone, or a tie, says nothing).
  final int? busiestHour;

  /// The day with the most track IDs; null unless it has more than every
  /// other day.
  final DateTime? recordDay;
  final int recordDayCount;

  /// Track IDs left out of the charts by time: their videos do not say
  /// when they were filmed ([SessionDashboardStats.guessedClips]).
  final int visitsWithoutClock;

  /// Taxa per rank of [kDashboardRanks], over the sessions with a current
  /// identification. Empty when none has one.
  final List<RankTaxa> taxa;

  /// Track IDs that got a name (any rank), in the unit of [totalVisits]:
  /// joined track IDs count one each here (the [taxa] rows count them once).
  final int namedVisits;

  /// Track IDs of the counted identifications left out as suspect.
  final int suspectVisits;

  /// Track IDs joined by identification into entries of several (they
  /// count once in the [taxa] rows), and how many entries they make.
  final int joinedVisits;
  final int joinedEntries;

  /// Sessions whose identification is counted in [taxa].
  final int identifiedSessions;

  /// Sessions with track IDs and no usable identification: none yet, or an
  /// outdated one (their track IDs were found again since). Both need
  /// "Identify organisms"; sessions without track IDs are not counted.
  final int unnamedSessions;

  const DashboardAggregate({
    required this.aiSessions,
    required this.otherSessions,
    required this.totalVisits,
    required this.totalRecordedMs,
    required this.longestVisitMs,
    required this.medianVisitMs,
    required this.visitsByHour,
    required this.activity,
    required this.weeklyBuckets,
    required this.busiestHour,
    required this.recordDay,
    required this.recordDayCount,
    this.visitsWithoutClock = 0,
    this.taxa = const [],
    this.namedVisits = 0,
    this.suspectVisits = 0,
    this.joinedVisits = 0,
    this.joinedEntries = 0,
    this.identifiedSessions = 0,
    this.unnamedSessions = 0,
  });

  /// Track IDs per watched hour; null below [kRateMinWatchMs] of watching.
  double? get visitsPerHour => totalRecordedMs < kRateMinWatchMs
      ? null
      : totalVisits / (totalRecordedMs / Duration.millisecondsPerHour);
}

/// Calendar day number of a local date (days since 1970-01-01), from its
/// year, month and day only, so a 23- or 25-hour day (summer time) still
/// counts as one day.
int _dayNumber(DateTime local) =>
    DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// The key with the highest count, when no other key has as many (and at
/// least one other key has some).
int? _uniqueMax(Map<int, int> counts) {
  int? best;
  var tie = false, others = 0;
  for (final e in counts.entries) {
    if (e.value <= 0) continue;
    others++;
    if (best == null || e.value > counts[best]!) {
      best = e.key;
      tie = false;
    } else if (e.value == counts[best]) {
      tie = true;
    }
  }
  return tie || others < 2 ? null : best;
}

/// The local date of a [_dayNumber].
DateTime _dateOf(int dayNumber) {
  final u = DateTime.fromMillisecondsSinceEpoch(
    dayNumber * Duration.millisecondsPerDay,
    isUtc: true,
  );
  return DateTime(u.year, u.month, u.day);
}

/// The first moment of a period of [days] calendar days that ends today
/// ([now]'s day): today and the `days - 1` days before, as the Sessions
/// screen's "Last 7 days" filter.
DateTime periodStart(int days, DateTime now) =>
    DateTime(now.year, now.month, now.day - (days - 1));

/// Aggregates [sessions] whose START falls inside the period: the last
/// [periodDays] calendar days up to [now] (null = all time). Hour/day
/// bucketing uses the device's local time: the biological question ("when
/// are pollinators active?") is about local solar-ish time.
DashboardAggregate aggregateDashboard(
  List<SessionDashboardStats> sessions, {
  int? periodDays,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final sinceMs = periodDays == null
      ? 0
      : periodStart(periodDays, today).millisecondsSinceEpoch;
  final inPeriod = [
    for (final s in sessions)
      if (s.startMs >= sinceMs) s,
  ];
  final ai = [
    for (final s in inPeriod)
      if (s.aiMode) s,
  ];

  final byHour = List<int>.filled(24, 0);
  final byDay = <int, int>{};
  final lengths = <int>[];
  var recordedMs = 0, withoutClock = 0;
  for (final s in ai) {
    recordedMs += s.recordedMs;
    for (final (startMs, endMs) in s.visits) {
      lengths.add(max(0, endMs - startMs));
      if (s.clockUnsure(startMs)) {
        withoutClock++;
        continue;
      }
      final local = DateTime.fromMillisecondsSinceEpoch(startMs);
      byHour[local.hour]++;
      final day = _dayNumber(local);
      byDay[day] = (byDay[day] ?? 0) + 1;
    }
  }

  final busiestHour = _uniqueMax({for (var h = 0; h < 24; h++) h: byHour[h]});
  final recordDay = _uniqueMax(byDay);

  // Daily buckets over the whole fixed period, or first–last active day for
  // all time (the last 7 days when none has a known time, so the empty chart
  // keeps its days); weekly when that would need more than ~2 months of bars.
  final int first, last;
  if (periodDays == null && byDay.isNotEmpty) {
    final days = byDay.keys.toList()..sort();
    first = days.first;
    last = days.last;
  } else {
    first = _dayNumber(periodStart(periodDays ?? 7, today));
    last = _dayNumber(today);
  }
  final spanDays = last - first + 1;
  final weekly = spanDays > 62;
  final step = weekly ? 7 : 1;
  final counts = List<int>.filled((spanDays + step - 1) ~/ step, 0);
  for (final e in byDay.entries) {
    final i = (e.key - first) ~/ step;
    if (e.key >= first && i < counts.length) counts[i] += e.value;
  }
  final activity = [
    for (var i = 0; i < counts.length; i++)
      (day: _dateOf(first + i * step), count: counts[i]),
  ];

  // Taxa (round 304): the sessions with a current identification.
  final identified = [
    for (final s in ai)
      if (s.taxa case final t? when !t.outdated) t,
  ];
  final idTracks = [for (final t in identified) ...t.tracks];
  var named = 0, joined = 0, joinedEntries = 0;
  for (final t in idTracks) {
    final headline = t['headline'];
    final n = (t['track_id_count'] as num?)?.toInt() ?? 1;
    if (t['identified_rank'] != null && headline != 'no organism' && headline != 'unidentified') named += n;
    if (n > 1) {
      joined += n;
      joinedEntries++;
    }
  }
  lengths.sort();
  return DashboardAggregate(
    aiSessions: ai.length,
    otherSessions: inPeriod.length - ai.length,
    totalVisits: lengths.length,
    totalRecordedMs: recordedMs,
    longestVisitMs: lengths.isEmpty ? 0 : lengths.last,
    medianVisitMs: lengths.isEmpty
        ? 0
        : lengths.length.isOdd
        ? lengths[lengths.length ~/ 2]
        : (lengths[lengths.length ~/ 2 - 1] + lengths[lengths.length ~/ 2]) ~/ 2,
    visitsByHour: byHour,
    activity: activity,
    weeklyBuckets: weekly,
    busiestHour: busiestHour,
    recordDay: recordDay == null ? null : _dateOf(recordDay),
    recordDayCount: recordDay == null ? 0 : byDay[recordDay]!,
    visitsWithoutClock: withoutClock,
    taxa: idTracks.isEmpty
        ? const []
        : [for (final r in kDashboardRanks) RankTaxa(r, aggregateTracks(idTracks, groupRank: r))],
    namedVisits: named,
    suspectVisits: identified.fold(0, (n, t) => n + t.suspect),
    joinedVisits: joined,
    joinedEntries: joinedEntries,
    identifiedSessions: identified.length,
    // Only sessions with track IDs have something to identify.
    unnamedSessions: ai.where((s) => s.visits.isNotEmpty && (s.taxa == null || s.taxa!.outdated)).length,
  );
}
