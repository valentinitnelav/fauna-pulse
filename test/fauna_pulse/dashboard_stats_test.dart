// Unit tests for the cross-session dashboard (round 186): the pure
// aggregation math (period filter, hour histogram, day/week bucketing,
// highlights) and the per-session stats cache (compute from a real
// session.jsonl, cache hit, staleness on log change, AI-mode detection).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart' show kRankNames;
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
    test('sums track IDs, buckets by local hour, finds the busiest hour', () {
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
      // Track lengths 1 min, 1 min and 2 min.
      expect(agg.longestVisitMs, 2 * 60000);
      expect(agg.medianVisitMs, 60000);
    });

    test('sessions without live detection are excluded from numbers but counted separately',
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
        periodDays: 30,
        now: DateTime(2026, 7, 25, 15),
      );
      expect(agg.totalVisits, 1);
      expect(agg.aiSessions, 1);
    });

    test('a period is calendar days: today and the days before it', () {
      // 7 days on Jul 25 = Jul 19 00:00 onwards, as the Sessions filter.
      final inside = session(startMs: localMs(2026, 7, 19, 0, 30));
      final outside = session(startMs: localMs(2026, 7, 18, 23, 59));
      final agg = aggregateDashboard(
        [inside, outside],
        periodDays: 7,
        now: DateTime(2026, 7, 25, 15),
      );
      expect(agg.aiSessions, 1);
      expect(periodStart(7, DateTime(2026, 7, 25, 15)), DateTime(2026, 7, 19));
    });

    test('a fixed period shows a bar for each of its days', () {
      final s = session(
        startMs: localMs(2026, 7, 23, 9),
        visits: [(localMs(2026, 7, 23, 9, 1), localMs(2026, 7, 23, 9, 2))],
      );
      final agg = aggregateDashboard([s], periodDays: 7, now: DateTime(2026, 7, 25, 15));
      expect(agg.activity, hasLength(7));
      expect(agg.activity.first.day, DateTime(2026, 7, 19));
      expect(agg.activity.last.day, DateTime(2026, 7, 25));
      expect(agg.activity.map((b) => b.count), [0, 0, 0, 0, 1, 0, 0]);
    });

    // The local 23-hour day of 2027 (the spring clock change), if this
    // computer's time zone has one (Central Europe: Mar 28).
    final short = [
      for (var d = DateTime(2027); d.year == 2027; d = DateTime(d.year, d.month, d.day + 1))
        if (DateTime(d.year, d.month, d.day + 1).difference(d).inHours == 23) d,
    ];
    test('days across the spring clock change keep one bar each', () {
      // Counting by calendar date keeps the day after the short one (the
      // old count of 24-hour steps dropped it).
      final d = short.first;
      final before = DateTime(d.year, d.month, d.day - 1, 9), after = DateTime(d.year, d.month, d.day + 1, 9);
      final s = session(
        startMs: before.millisecondsSinceEpoch,
        visits: [
          (before.millisecondsSinceEpoch, before.millisecondsSinceEpoch + 60000),
          (after.millisecondsSinceEpoch, after.millisecondsSinceEpoch + 60000),
        ],
      );
      final agg = aggregateDashboard([s]);
      expect(agg.activity.map((b) => b.day), [
        DateTime(before.year, before.month, before.day),
        DateTime(d.year, d.month, d.day),
        DateTime(after.year, after.month, after.day),
      ]);
      expect(agg.activity.map((b) => b.count), [1, 0, 1]);
    }, skip: short.isEmpty ? 'this time zone has no clock change (run with TZ=Europe/Berlin)' : false);

    test('no rate per hour below 10 minutes of watching', () {
      final short = session(
        startMs: localMs(2026, 7, 1, 9),
        endMs: localMs(2026, 7, 1, 9) + 6000,
        visits: [(localMs(2026, 7, 1, 9), localMs(2026, 7, 1, 9) + 5000)],
      );
      expect(aggregateDashboard([short]).visitsPerHour, isNull);
      final tenMinutes = session(
        startMs: localMs(2026, 7, 1, 9),
        endMs: localMs(2026, 7, 1, 9, 10),
        visits: [(localMs(2026, 7, 1, 9, 1), localMs(2026, 7, 1, 9, 2))],
      );
      expect(aggregateDashboard([tenMinutes]).visitsPerHour, closeTo(6, 1e-9));
    });

    test('busiest hour and record day need something to compare', () {
      final oneHour = session(
        startMs: localMs(2026, 7, 1, 9),
        visits: [
          (localMs(2026, 7, 1, 9, 1), localMs(2026, 7, 1, 9, 2)),
          (localMs(2026, 7, 1, 9, 5), localMs(2026, 7, 1, 9, 6)),
        ],
      );
      final agg = aggregateDashboard([oneHour]);
      expect(agg.busiestHour, isNull);
      expect(agg.recordDay, isNull);
      // A tie names neither.
      final tie = session(
        startMs: localMs(2026, 7, 1, 9),
        visits: [
          (localMs(2026, 7, 2, 9), localMs(2026, 7, 2, 9, 1)),
          (localMs(2026, 7, 1, 10), localMs(2026, 7, 1, 10, 1)),
        ],
      );
      expect(aggregateDashboard([tie]).recordDay, isNull);
      expect(aggregateDashboard([tie]).busiestHour, isNull);
      expect(aggregateDashboard([tie]).recordDayCount, 0);
    });

    test('videos with a guessed filming time count, but not in the charts by time', () {
      final known = session(
        startMs: localMs(2026, 7, 1, 9),
        visits: [(localMs(2026, 7, 1, 9, 1), localMs(2026, 7, 1, 9, 2))],
      );
      // One import: a clip with a known time (8:00) and a guessed one (22:00).
      final mixed = SessionDashboardStats(
        startMs: localMs(2026, 7, 1, 8),
        endMs: localMs(2026, 7, 1, 22, 1),
        aiMode: true,
        guessedClips: [(localMs(2026, 7, 1, 22), localMs(2026, 7, 1, 22, 1))],
        visits: [
          (localMs(2026, 7, 1, 8, 0), localMs(2026, 7, 1, 8, 0) + 4000),
          (localMs(2026, 7, 1, 22), localMs(2026, 7, 1, 22) + 4000),
        ],
      );
      final agg = aggregateDashboard([known, mixed]);
      expect(agg.totalVisits, 3);
      expect(agg.visitsWithoutClock, 1, reason: 'only the track ID of the guessed clip');
      expect(agg.visitsByHour[22], 0);
      expect(agg.visitsByHour[8], 1);
      expect(agg.visitsByHour[9], 1);
      expect(agg.activity.map((b) => b.count), [2]);
    });

    test('taxa: current identifications counted per rank, outdated and missing ones noted', () {
      Map<String, dynamic> t(List<String> path, String? rank, {String? headline}) => {
        'headline': headline ?? (rank == null ? 'unidentified' : path.last),
        'identified_rank': rank,
        'ladder': [for (final n in path) {'taxon': n}],
      };
      const top = ['Animalia', 'Arthropoda', 'Insecta'];
      final bombus = t([...top, 'Hymenoptera', 'Apidae', 'Bombus'], 'genus');
      final apis = t([...top, 'Hymenoptera', 'Apidae', 'Apis', 'Apis mellifera'], 'species');
      final fly = t([...top, 'Diptera', 'Syrphidae'], 'family');
      // One track ID per entry, as in real results (plus the suspect ones).
      SessionDashboardStats withTaxa(int trackIds, SessionTaxa? taxa) => SessionDashboardStats(
        startMs: localMs(2026, 7, 1, 9),
        endMs: localMs(2026, 7, 1, 10),
        aiMode: true,
        visits: [
          for (var i = 0; i < trackIds; i++) (localMs(2026, 7, 1, 9, i), localMs(2026, 7, 1, 9, i) + 5000),
        ],
        taxa: taxa,
      );
      final agg = aggregateDashboard([
        withTaxa(3, SessionTaxa(outdated: false, tracks: [bombus, apis], suspect: 1)),
        withTaxa(3, SessionTaxa(outdated: false, tracks: [bombus, fly, t(const [], null)])),
        withTaxa(2, SessionTaxa(outdated: true, tracks: [fly, fly], suspect: 5)),
        withTaxa(1, null),
      ]);
      // Named: the 4 named entries of the current results; the outdated
      // session's names and suspects are not counted.
      expect(agg.totalVisits, 9);
      expect(agg.namedVisits, 4);
      expect(agg.suspectVisits, 1);
      expect(agg.identifiedSessions, 2);
      expect(agg.unnamedSessions, 2); // the outdated one and the one without
      // A live session where no animal came has nothing to identify.
      final empty = SessionDashboardStats(startMs: localMs(2026, 7, 1, 9), endMs: localMs(2026, 7, 1, 10), aiMode: true, visits: const []);
      expect(aggregateDashboard([empty]).unnamedSessions, 0);
      expect(agg.taxa.map((r) => r.rank), ['order', 'family', 'genus', 'species']);
      final orders = agg.taxa.first;
      expect([for (final r in orders.rows) (r.taxon, r.visits)], [
        ('Hymenoptera', 3),
        ('Diptera', 1),
        ('unidentified', 1),
      ]);
      expect(orders.distinct, 2);
      final genera = agg.taxa[2];
      expect([for (final r in genera.rows) (r.taxon, r.visits)], [
        ('Bombus', 2),
        ('Apis', 1),
        ('not resolved to genus', 1),
        ('unidentified', 1),
      ]);
      expect(agg.taxa.last.distinct, 1); // only Apis mellifera reached species
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
      expect(agg.visitsPerHour, isNull);
      expect(agg.medianVisitMs, 0);
      expect(agg.taxa, isEmpty);
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

    // Round 229: imported videos count once "Find visits" has run.
    String importedStart(int ms) => jsonEncode({
      'type': 'start_of_session',
      'time_ms': ms,
      'source': 'imported_video',
    });

    File writePost(List<String> lines, {int observedMs = 60000}) =>
        File('${tmp.path}/post_tracks.jsonl')..writeAsStringSync(
          '${[
            jsonEncode({'type': 'post_track_start', 'time_ms': 1000, 'observed_ms': observedMs}),
            ...lines,
          ].join('\n')}\n',
        );

    test('imported videos count once track IDs were found afterwards', () async {
      writeLog(tmp, [importedStart(1000), end(3600000)]);
      final before = await DashboardStatsCache.forSession(tmp);
      expect(before.aiMode, isFalse);

      writePost([
        detections(2000, [1]),
        detections(4000, [1]),
      ]);
      final after = await DashboardStatsCache.forSession(tmp);
      expect(after.aiMode, isTrue);
      expect(after.visits, [(2000, 4000)]);
      // Visits per hour use the filmed time, not start to end.
      expect(after.observedMs, 60000);
      expect(after.recordedMs, 60000);
      expect(aggregateDashboard([after]).totalRecordedMs, 60000);
    });

    test('running "Find track IDs" again invalidates the cache', () async {
      writeLog(tmp, [importedStart(1000), end(9000)]);
      writePost([detections(2000, [1])]);
      expect((await DashboardStatsCache.forSession(tmp)).visits, hasLength(1));
      writePost([
        detections(2000, [1]),
        detections(6000, [2]),
      ]);
      expect((await DashboardStatsCache.forSession(tmp)).visits, hasLength(2));
    });

    test('a live detection session ignores a post_tracks.jsonl', () async {
      writeLog(tmp, [start(1000), detections(2000, [1]), end(9000)]);
      writePost([
        detections(3000, [5]),
        detections(4000, [6]),
      ]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.visits, [(2000, 2000)]);
      expect(stats.observedMs, isNull);
      expect(stats.recordedMs, 8000);
    });

    test('a crashed session ends at its last logged record, not at a later cleanup', () async {
      writeLog(tmp, [
        start(1000),
        detections(2000, [1]),
        jsonEncode({'type': 'thermal', 'time_ms': 70000, 'battery_c': 30.0}),
        '{"type":"fps","time_ms":75', // cut by the crash
        jsonEncode({'type': 'video_cleanup', 'time_ms': 999999999, 'clips': []}),
      ]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.endMs, 70000);
      expect(stats.recordedMs, 69000);
    });

    String clip(String source, {String? guess, int start = 1000, bool? weak}) => jsonEncode({
      'type': 'video_clip',
      'time_ms': start,
      'start_epoch_ms': start,
      'duration_ms': 4000,
      'file': 'videos/a.mp4',
      'start_time_source': source,
      'start_time_guess_source': ?guess,
      'start_time_weak': ?weak,
    });

    test('the clips of an imported video whose filming time is a guess', () async {
      writeLog(tmp, [importedStart(1000), clip('file_time'), end(9000)]);
      writePost([detections(2000, [1])]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.guessedClips, [(1000, 5000)]);
      expect(stats.clockUnsure(2000), isTrue);
      expect(stats.clockUnsure(6000), isFalse);
      // The cache keeps them.
      expect((await DashboardStatsCache.forSession(tmp)).guessedClips, [(1000, 5000)]);
      // Set by the user at import: trusted.
      writeLog(tmp, [importedStart(1000), clip('user', guess: 'file_time'), end(9000)]);
      expect((await DashboardStatsCache.forSession(tmp)).guessedClips, isEmpty);
      // Placed after a clip whose day only was known: still a guess; the
      // first clip's time is known.
      writeLog(tmp, [
        importedStart(1000),
        clip('metadata'),
        clip('after_previous', guess: 'file_name_date', start: 5000),
        end(9000),
      ]);
      expect((await DashboardStatsCache.forSession(tmp)).guessedClips, [(5000, 9000)]);
      // A file name that disagrees with the time stored in the file (round
      // 304: only the flag tells).
      writeLog(tmp, [importedStart(1000), clip('file_name', weak: true), end(9000)]);
      expect((await DashboardStatsCache.forSession(tmp)).guessedClips, hasLength(1));
      writeLog(tmp, [importedStart(1000), clip('file_name'), end(9000)]);
      expect((await DashboardStatsCache.forSession(tmp)).guessedClips, isEmpty);
    });

    Map<String, dynamic> idTrack(int? id, List<String> path, String? rank, {bool suspect = false, String? src}) => {
      'track_id': id,
      'track_ids': [?id],
      'suspect': suspect,
      'headline': rank == null ? 'unidentified' : path[kRankNames.indexOf(rank)],
      'identified_rank': rank,
      'src': ?src,
      'ladder': [
        for (final n in path) {'rank': 'r', 'taxon': n, 'p': 0.9},
      ],
      'crops': [
        {'src': 'roi.jpg', 'p_ladder': [1.0]},
      ],
    };

    void writeIdentification(String pack, List<Map<String, dynamic>> tracks, {int? runId}) {
      final dir = Directory('${tmp.path}/identification')..createSync(recursive: true);
      File('${dir.path}/tracks_$pack.json').writeAsStringSync(jsonEncode({'tracks': tracks}));
      File('${dir.path}/summary_$pack.json').writeAsStringSync(
        jsonEncode({
          'pack_id': pack,
          'tracks_total': tracks.length,
          if (runId != null) 'capture': {'track_ids_run_id': runId},
        }),
      );
    }

    const bombus = ['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', 'Bombus terrestris'];

    test('reads the newest identification, without suspects or photos without a track ID', () async {
      writeLog(tmp, [start(1000), detections(2000, [1, 2, 3]), end(9000)]);
      writeIdentification('p', [
        idTrack(1, bombus, 'genus'),
        idTrack(2, bombus, 'species', suspect: true),
        idTrack(null, bombus, 'genus', src: 'motion.jpg'),
        idTrack(3, const [], null),
      ]);
      final stats = await DashboardStatsCache.forSession(tmp);
      final taxa = stats.taxa!;
      expect(taxa.outdated, isFalse);
      expect(taxa.tracks, hasLength(2));
      expect(taxa.suspect, 1);
      expect((await DashboardStatsCache.forSession(tmp)).taxa!.suspect, 1);
      // The ladder is cut at the identified rank: genus, not the species.
      expect(taxa.tracks.first['ladder'], hasLength(6));
      expect(taxa.tracks.first['headline'], 'Bombus');
      expect(taxa.tracks.last['headline'], 'unidentified');
      // The cache keeps the names only, and gives back the same shape.
      final cached = await DashboardStatsCache.forSession(tmp);
      expect(cached.taxa!.tracks, taxa.tracks);
      final raw = File('${tmp.path}/${DashboardStatsCache.fileName}').readAsStringSync();
      expect(raw, isNot(contains('crops')));
    });

    test('an unchanged identification is read from the cache, not again from its files', () async {
      writeLog(tmp, [start(1000), detections(2000, [1]), end(9000)]);
      writeIdentification('p', [idTrack(1, bombus, 'genus')]);
      await DashboardStatsCache.forSession(tmp);
      final cacheFile = File('${tmp.path}/${DashboardStatsCache.fileName}');
      final j = jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      ((j['taxa'] as Map)['tracks'] as List).first['headline'] = 'X';
      cacheFile.writeAsStringSync(jsonEncode(j));
      expect((await DashboardStatsCache.forSession(tmp)).taxa!.tracks.first['headline'], 'X');
    });

    test('a new identification run replaces the cached taxa', () async {
      writeLog(tmp, [start(1000), detections(2000, [1]), end(9000)]);
      expect((await DashboardStatsCache.forSession(tmp)).taxa, isNull);
      writeIdentification('a', [idTrack(1, bombus, 'genus')]);
      expect((await DashboardStatsCache.forSession(tmp)).taxa!.tracks, hasLength(1));
      // Another name list scored later is the newest one.
      sleep(const Duration(milliseconds: 20));
      writeIdentification('b', [idTrack(1, bombus, 'genus'), idTrack(2, bombus, 'genus')]);
      expect((await DashboardStatsCache.forSession(tmp)).taxa!.tracks, hasLength(2));
      Directory('${tmp.path}/identification').deleteSync(recursive: true);
      expect((await DashboardStatsCache.forSession(tmp)).taxa, isNull);
    });

    test('an identification of track IDs found before the last "Find track IDs" is outdated', () async {
      writeLog(tmp, [importedStart(1000), end(9000)]);
      // A finished run, as VideoTracker.readSummary (the results screen's
      // check) needs: start and end record.
      File('${tmp.path}/post_tracks.jsonl').writeAsStringSync(
        '${jsonEncode({'type': 'post_track_start', 'time_ms': 1000, 'run_id': 222, 'observed_ms': 60000, 'clips': [], 'occlusion_seconds': 3, 'min_hits_seconds': 1})}\n'
        '${detections(2000, [1])}\n'
        '${jsonEncode({'type': 'post_track_end', 'time_ms': 3000, 'run_id': 222, 'track_ids': 1})}\n',
      );
      writeIdentification('p', [idTrack(1, bombus, 'genus')], runId: 111);
      expect((await DashboardStatsCache.forSession(tmp)).taxa!.outdated, isTrue);
      writeIdentification('p', [idTrack(1, bombus, 'genus')], runId: 222);
      expect((await DashboardStatsCache.forSession(tmp)).taxa!.outdated, isFalse);
    });

    test('joined track IDs: one entry, counted as all its track IDs in the named share', () async {
      writeLog(tmp, [start(1000), detections(2000, [1, 2]), detections(3000, [3]), end(9000)]);
      writeIdentification('p', [
        {...idTrack(1, bombus, 'genus'), 'track_ids': [1, 2]},
        idTrack(3, const [], null),
      ]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.taxa!.tracks.first['track_id_count'], 2);
      final cached = await DashboardStatsCache.forSession(tmp);
      expect(cached.taxa!.tracks.first['track_id_count'], 2);
      final agg = aggregateDashboard([cached]);
      expect(agg.totalVisits, 3);
      expect(agg.namedVisits, 2);
      expect(agg.joinedVisits, 2);
      expect(agg.joinedEntries, 1);
      expect(agg.taxa[2].rows.first.visits, 1); // the genus row counts the entry once
    });

    test('names given per photo before the session had track IDs need identifying again', () async {
      writeLog(tmp, [start(1000), detections(2000, [1]), end(9000)]);
      writeIdentification('p', [idTrack(null, bombus, 'genus', src: 'a.jpg')]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.taxa!.outdated, isTrue);
      expect(aggregateDashboard([stats]).unnamedSessions, 1);
    });

    test('a new identification keeps the numbers read from the log', () async {
      writeLog(tmp, [start(1000), detections(2000, [1]), end(9000)]);
      await DashboardStatsCache.forSession(tmp);
      final cacheFile = File('${tmp.path}/${DashboardStatsCache.fileName}');
      final j = jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      j['start_ms'] = 42; // a re-read of the log would give 1000
      cacheFile.writeAsStringSync(jsonEncode(j));
      writeIdentification('p', [idTrack(1, bombus, 'genus')]);
      final stats = await DashboardStatsCache.forSession(tmp);
      expect(stats.startMs, 42);
      expect(stats.taxa!.tracks, hasLength(1));
    });

    test('a cache from an older app version is computed again', () async {
      writeLog(tmp, [start(1000), detections(2000, [1]), end(9000)]);
      await DashboardStatsCache.forSession(tmp);
      final cacheFile = File('${tmp.path}/${DashboardStatsCache.fileName}');
      final j = jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      j['version'] = 1;
      j['start_ms'] = 42;
      cacheFile.writeAsStringSync(jsonEncode(j));
      expect((await DashboardStatsCache.forSession(tmp)).startMs, 1000);
    });

    test('filmed time survives the cache round trip', () {
      const s = SessionDashboardStats(startMs: 1, endMs: 2, aiMode: true, visits: [], observedMs: 7);
      expect(SessionDashboardStats.fromJson(s.toJson()).observedMs, 7);
      expect(session(startMs: 1).toJson().containsKey('observed_ms'), isFalse);
    });
  });
}
