// FaunaPulse — cross-session dashboard (round 186).
//
// Reached from the home screen's "Dashboard" button. Answers
// the citizen scientist's "what have I seen so far?": how many track IDs
// were found (the big number), how long the phone watched, track lengths,
// two activity bar charts (by hour of day, by day/week) and, round 304, the
// names the identification gave them per order, family, genus or species.
// Sessions without track IDs are only mentioned in a note, never mixed into
// the numbers.
//
// Per-session stats come from DashboardStatsCache (dashboard_stats.dart):
// the first opening scans each log once (progress bar), afterwards the
// cached JSON makes opening instant. Aggregation is pure and synchronous, so
// the period selector re-renders without touching the disk.
//
// Round 304 (owner): the number tiles had a fixed height and overflowed at
// phone width; they now take the height of their text. The rate per hour
// needs a minimum watch time (a few seconds of video gave "597.6 per
// hour"); the default period is "All time" (the main message is the
// overall count); the highlights moved into the chart subtitles.
//
// Round 305 (owner): the rate needs 1 h of watching and says it is a rough
// estimate; the two activity charts are always shown once reading is done,
// with zero bars and a line saying why when there is nothing to count.
//
// Chart style: see widgets/mini_bar_chart.dart (extracted round 187 so the
// per-session summary shares the same bars).

import 'dart:io';

import 'package:flutter/material.dart';

import '../identification/taxa_table.dart' show TaxonRow;
import '../logging/app_error_hooks.dart';
import '../logging/dashboard_stats.dart';
import '../logging/past_sessions.dart' show sessionsRoot;
import '../postprocess/photo_tracker.dart' show PhotoTracker;
import '../widgets/home_button.dart';
import '../widgets/mini_bar_chart.dart';
import '../widgets/setting_help.dart';

class DashboardScreen extends StatefulWidget {
  /// The folder holding the session folders (tests pass their own).
  final Future<Directory> Function() sessionsDir;

  /// The clock for the periods (tests pass a fixed day).
  final DateTime Function() now;

  const DashboardScreen({super.key, this.sessionsDir = sessionsRoot, this.now = DateTime.now});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  int _done = 0, _total = 0;
  List<SessionDashboardStats> _stats = const [];

  /// Selected period in calendar days up to today; null = all time.
  int? _periodDays;

  /// The rank the names card shows (null = the default, see [_namesCard]),
  /// and whether it lists every taxon.
  String? _rank;
  bool _allTaxa = false;

  /// Whether the rate tile's (i) explanation is open. It opens at full
  /// width under the tile row: inside the half-width tile it made both
  /// tiles of the row very tall.
  bool _rateHelpOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final collected = <SessionDashboardStats>[];
    try {
      final root = await widget.sessionsDir();
      final dirs = <Directory>[];
      if (await root.exists()) {
        for (final entity in root.listSync()) {
          if (entity is Directory &&
              File('${entity.path}/session.jsonl').existsSync()) {
            dirs.add(entity);
          }
        }
      }
      if (mounted) setState(() => _total = dirs.length);
      for (final dir in dirs) {
        collected.add(await DashboardStatsCache.forSession(dir));
        if (mounted) setState(() => _done++);
      }
    } catch (e) {
      logSwallowed('dashboard_scan', e);
    }
    if (!mounted) return;
    setState(() {
      _stats = collected;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final agg = aggregateDashboard(_stats, periodDays: _periodDays, now: widget.now());
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard'), actions: const [HomeButton()]),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Center(
              child: SegmentedButton<int?>(
                // Without the tick, "30 days" still fits its third of the
                // width with a large system font.
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 7, label: Text('7 days')),
                  ButtonSegment(value: 30, label: Text('30 days')),
                  ButtonSegment(value: null, label: Text('All time')),
                ],
                selected: {_periodDays},
                onSelectionChanged: (s) => setState(() => _periodDays = s.first),
              ),
            ),
            const SizedBox(height: 16),
            if (_loading) ...[
              LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
              const SizedBox(height: 6),
              Text(
                'Reading session $_done of $_total… The first time takes a moment; '
                'afterwards the Dashboard opens at once.',
                style: helperTextStyle,
              ),
            ] else if (agg.aiSessions == 0) ...[
              _emptyState(agg),
              const SizedBox(height: 24),
              ..._activityCharts(agg),
            ] else ...[
              _hero(agg),
              const SizedBox(height: 8),
              _tiles(agg),
              const SizedBox(height: 12),
              ..._activityCharts(agg),
              if (agg.totalVisits > 0) ...[
                const SizedBox(height: 12),
                _namesCard(agg),
              ],
              ..._notes(agg),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState(DashboardAggregate agg) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      children: [
        const Icon(Icons.emoji_nature, size: 48, color: Colors.white24),
        const SizedBox(height: 12),
        Text(
          agg.otherSessions > 0
              ? 'No track IDs in this period: ${_count(agg.otherSessions, 'session')} here '
                    '${agg.otherSessions == 1 ? 'has' : 'have'} none. $_sources'
              : 'No sessions in this period yet. Record a session with live detection, or search photos or '
                    'videos with "Find animals", and the track IDs will show up here.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ],
    ),
  );

  /// The activity charts pooled over the sessions, always both (owner:
  /// hidden charts looked removed). Without a track ID with a known time the
  /// bars stay at zero and both subtitles say why.
  List<Widget> _activityCharts(DashboardAggregate agg) {
    final timed = agg.totalVisits - agg.visitsWithoutClock;
    final why = agg.totalVisits == 0
        ? 'No track IDs in this period yet: the bars appear once track IDs are recorded.'
        : timed == 0
        ? 'No times to show: ${agg.totalVisits == 1 ? 'this track ID comes' : 'these track IDs come'} from videos '
              'that do not say when they were filmed (the time can be set while importing them).'
        : null;
    return [
      _chartCard(
        title: 'Track IDs by time of day',
        subtitle:
            why ??
            [
              if (agg.busiestHour case final h?) 'Most at ${_two(h)}:00–${_two((h + 1) % 24)}:00.',
              'Hours you watched longer show more.',
            ].join(' '),
        child: MiniBarChart(
          values: agg.visitsByHour,
          xLabelFor: (i) => switch (i) {
            0 || 6 || 12 || 18 => '$i h',
            _ => null,
          },
        ),
      ),
      const SizedBox(height: 12),
      _chartCard(
        title: agg.weeklyBuckets ? 'Track IDs by week' : 'Track IDs by day',
        subtitle:
            why ??
            [
              if (agg.recordDay case final d?)
                'Record day: ${_dateShort(d)} (${_count(agg.recordDayCount, 'track ID')}).',
              if (agg.weeklyBuckets) 'Each bar is one week.',
            ].join(' '),
        child: MiniBarChart(
          values: [for (final b in agg.activity) b.count],
          xLabelFor: (i) {
            // First, last, and (when room) the middle bucket.
            final n = agg.activity.length;
            if (i == 0 || i == n - 1 || (n > 8 && i == n ~/ 2)) {
              return _dateShort(agg.activity[i].day);
            }
            return null;
          },
        ),
      ),
    ];
  }

  /// Where track IDs come from ("Find animals in photos" follows an animal
  /// only in photos taken close enough together).
  static final _sources =
      'Track IDs come from live detection, from "Find animals in videos", or from "Find animals in photos" '
      'when the photos were taken at most ${PhotoTracker.maxStepSeconds} s apart.';

  static const _card = BoxDecoration(
    color: Colors.white10,
    borderRadius: BorderRadius.all(Radius.circular(8)),
  );

  /// The main message: how many track IDs, in how many sessions.
  Widget _hero(DashboardAggregate agg) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    decoration: _card,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${agg.totalVisits}',
          key: const ValueKey('dashboard_total'),
          style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold, color: Colors.amber, height: 1.1),
        ),
        HelpLabel(
          label:
              '${agg.totalVisits == 1 ? 'track ID' : 'track IDs'} in ${_count(agg.aiSessions, 'session')}',
          labelStyle: const TextStyle(color: Colors.white70, fontSize: 14),
          helperText:
              'A track ID is one animal followed while it stays in the yellow square. If it leaves and comes '
              'back, or is lost for a moment, it gets a new track ID, so this is not the number of different '
              'animals, and a few track IDs can be false detections. Counted: sessions recorded with live '
              'detection, and photos or videos searched afterwards with "Find animals".',
        ),
      ],
    ),
  );

  /// Watch time, rate and track lengths: two rows of two tiles, each tile as
  /// tall as its text (a fixed height overflowed with a large font).
  Widget _tiles(DashboardAggregate agg) {
    final rate = agg.visitsPerHour;
    final none = agg.totalVisits == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tileRow(
          _tile(_watchLabel(agg.totalRecordedMs), 'watched'),
          _tile(
            // Below 1, two digits that matter: 1 track ID in 25 h is 0.040,
            // not "0.0".
            rate == null
                ? '–'
                : rate >= 1
                ? rate.toStringAsFixed(1)
                : rate.toStringAsPrecision(2),
            'track IDs per hour watched',
            note: rate == null
                ? 'shown from ${kRateMinWatchMs ~/ Duration.millisecondsPerHour} h watched'
                : 'rough estimate',
            open: _rateHelpOpen,
            onHelp: () => setState(() => _rateHelpOpen = !_rateHelpOpen),
          ),
        ),
        if (_rateHelpOpen)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Track IDs per hour watched: all track IDs of the sessions in this period divided by the hours '
              'those sessions watched (for videos, the filmed time). Rough, because a track ID is not always '
              'one animal and sessions differ in place, weather and time of day. Shown from '
              '${kRateMinWatchMs ~/ Duration.millisecondsPerHour} h, because a few minutes scaled up to an '
              'hour mostly show chance.',
              style: helperTextStyle,
            ),
          ),
        const SizedBox(height: 8),
        _tileRow(
          _tile(none ? '–' : _secondsLabel(agg.medianVisitMs), 'typical track length (median)'),
          _tile(none ? '–' : _secondsLabel(agg.longestVisitMs), 'longest track'),
        ),
      ],
    );
  }

  static Widget _tileRow(Widget a, Widget b) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [Expanded(child: a), const SizedBox(width: 8), Expanded(child: b)],
    ),
  );

  /// [onHelp] puts an (i) on the label ([open]: filled); tapping the label
  /// calls it (the explanation opens under the tile row, see [_rateHelpOpen]).
  static Widget _tile(String value, String label, {String? note, bool open = false, VoidCallback? onHelp}) => Container(
    padding: const EdgeInsets.all(12),
    decoration: _card,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          // One line, scaled down when too wide (so the row's measured
          // height is one line too).
          child: Text(
            value,
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 2),
        if (onHelp == null)
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12))
        else
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onHelp,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(child: Text(label, style: helperTextStyle)),
                const SizedBox(width: 4),
                Icon(open ? Icons.info : Icons.info_outline, size: 16, color: Colors.white38),
              ],
            ),
          ),
        if (note != null) Text(note, style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    ),
  );

  /// A chart under its title and subtitle (left out when empty).
  Widget _chartCard({required String title, required String subtitle, required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: _card,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 14)),
        if (subtitle.isNotEmpty) Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 10),
        SizedBox(height: 120, width: double.infinity, child: child),
      ],
    ),
  );

  /// Taxon rows shown before "Show all".
  static const _firstTaxa = 6;

  /// "Track IDs by name": the identification's names counted at one rank,
  /// as bars. The rank chips double as a count of the different taxa.
  Widget _namesCard(DashboardAggregate agg) {
    const title = 'Track IDs by name';
    if (agg.taxa.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: _card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(title, style: TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 4),
            Text(
              // Identified, but every track ID was suspect: the summary
              // line says so; otherwise nothing was identified yet.
              agg.identifiedSessions > 0
                  ? _namedLine(agg)
                  : 'No names yet. Open a session and tap "Identify organisms" to see here which animals were '
                        'found.',
              style: helperTextStyle,
            ),
          ],
        ),
      );
    }
    // Only ranks some name list reached (a list of genera has no species);
    // family by default, the rank identification aims for by default.
    final shown = [for (final t in agg.taxa) if (t.distinct > 0) t];
    final ranks = shown.isEmpty ? [agg.taxa.first] : shown;
    final current = ranks.firstWhere(
      (t) => t.rank == _rank,
      orElse: () => ranks.firstWhere((t) => t.rank == 'family', orElse: () => ranks.first),
    );
    final taxa = [for (final r in current.rows) if (!r.isBucket) r];
    final buckets = [for (final r in current.rows) if (r.isBucket) r];
    final visible = [...(_allTaxa ? taxa : taxa.take(_firstTaxa)), ...buckets];
    final maxCount = current.rows.fold<int>(1, (m, r) => r.visits > m ? r.visits : m);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HelpLabel(
            label: title,
            labelStyle: TextStyle(color: Colors.white, fontSize: 14),
            helperText:
                'Names are suggestions from each session\'s last identification: mistakes are possible, '
                'especially for animals that are not in the name list. Sessions named with different name '
                'lists are added together. A track ID named only at a higher rank is counted under "not '
                'resolved to …". As on the results screen, suspect track IDs (likely false detections) are '
                'left out, and track IDs joined into one count once.',
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: [
              for (final t in ranks)
                ChoiceChip(
                  label: Text('${t.rank[0].toUpperCase()}${t.rank.substring(1)} (${t.distinct})'),
                  selected: t == current,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() {
                    _rank = t.rank;
                    _allTaxa = false;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final r in visible) _taxonBar(r, maxCount),
          if (taxa.length > _firstTaxa)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _allTaxa = !_allTaxa),
                child: Text(_allTaxa ? 'Show fewer' : 'Show all ${taxa.length}'),
              ),
            ),
          const SizedBox(height: 4),
          Text(_namedLine(agg), style: helperTextStyle),
        ],
      ),
    );
  }

  /// How many track IDs got a name, and why the others or the bars differ.
  static String _namedLine(DashboardAggregate agg) => [
    'Named: ${agg.namedVisits} of ${_count(agg.totalVisits, 'track ID')}.',
    if (agg.suspectVisits > 0)
      '${_count(agg.suspectVisits, 'suspect track ID')} (likely false detections) left out, as on the results '
          'screen.',
    if (agg.joinedEntries > 0)
      'Joined by the identification, ${agg.joinedVisits} track IDs count as ${agg.joinedEntries} in the bars.',
    if (agg.unnamedSessions > 0)
      '${_count(agg.unnamedSessions, 'session')} ${agg.unnamedSessions == 1 ? 'has' : 'have'} no current names: '
          'open ${agg.unnamedSessions == 1 ? 'it' : 'them'} and tap "Identify organisms".',
  ].join(' ');

  /// One taxon: its name and count, a bar under them (long names keep the
  /// full width on a narrow phone). "not resolved to …" and the other
  /// grouping rows are dim, as on the results screen.
  static Widget _taxonBar(TaxonRow row, int maxCount) {
    final bucket = row.isBucket;
    final count = row.visits;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  row.taxon,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: bucket ? Colors.white54 : Colors.white, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Text('$count', style: TextStyle(color: bucket ? Colors.white54 : Colors.white70, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 3),
          FractionallySizedBox(
            widthFactor: (count / maxCount).clamp(0.02, 1.0),
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                color: bucket ? Colors.white24 : Colors.amber,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What the numbers leave out, in one place at the bottom.
  List<Widget> _notes(DashboardAggregate agg) => [
    for (final note in [
      if (agg.visitsWithoutClock > 0 && agg.visitsWithoutClock < agg.totalVisits)
        'Not in the charts by time: ${_count(agg.visitsWithoutClock, 'track ID')} from videos that do not say '
            'when they were filmed (the time can be set while importing them).',
      if (agg.otherSessions > 0) 'Not counted: ${_count(agg.otherSessions, 'session')} without track IDs. $_sources',
    ]) ...[
      const SizedBox(height: 12),
      Text(note, style: helperTextStyle),
    ],
  ];

  static String _count(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _dateShort(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  /// "6 s", "12 min", "3.5 h", "40 h": watch time from a few seconds of
  /// video to a season.
  /// Rounded down, so it never shows the 1 h the rate needs before it is
  /// reached ("59 min", then "1.0 h").
  static String _watchLabel(int ms) {
    if (ms < Duration.millisecondsPerMinute) return '${ms ~/ 1000} s';
    if (ms < Duration.millisecondsPerHour) return '${ms ~/ Duration.millisecondsPerMinute} min';
    final tenths = ms ~/ (Duration.millisecondsPerHour ~/ 10);
    return tenths >= 100 ? '${tenths ~/ 10} h' : '${(tenths / 10).toStringAsFixed(1)} h';
  }

  static String _secondsLabel(int ms) {
    if (ms >= 60000) {
      final m = ms ~/ 60000, s = (ms % 60000) ~/ 1000;
      return '$m min ${_two(s)} s';
    }
    return '${(ms / 1000).toStringAsFixed(1)} s';
  }
}
