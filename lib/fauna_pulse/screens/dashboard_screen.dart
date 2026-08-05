// FaunaPulse — cross-session dashboard (round 186).
//
// Reached from the "Previous sessions" header on the home screen. Answers
// the citizen scientist's "what have I seen so far?": total insect visits
// across every AI-mode session, watch time, visit lengths, and two activity
// bar charts (by hour of day, by day/week). Motion and time-lapse sessions
// carry no track ids, so they are only mentioned in a note, never mixed
// into the numbers.
//
// Per-session stats come from DashboardStatsCache (dashboard_stats.dart):
// the first visit scans each log once (progress bar), afterwards the cached
// JSON makes opening instant. Aggregation is pure and synchronous, so the
// period selector re-renders without touching the disk.
//
// Chart style: see widgets/mini_bar_chart.dart (extracted round 187 so the
// per-session summary shares the same bars).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_error_hooks.dart';
import '../logging/dashboard_stats.dart';
import '../widgets/mini_bar_chart.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  int _done = 0, _total = 0;
  List<SessionDashboardStats> _stats = const [];

  /// Selected period in days back from now; null = all time.
  int? _periodDays = 7;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final collected = <SessionDashboardStats>[];
    try {
      final base =
          (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final root = Directory('${base.path}/sessions');
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

  int get _sinceMs => _periodDays == null
      ? 0
      : DateTime.now()
            .subtract(Duration(days: _periodDays!))
            .millisecondsSinceEpoch;

  @override
  Widget build(BuildContext context) {
    final agg = aggregateDashboard(_stats, sinceMs: _sinceMs);
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: SegmentedButton<int?>(
                segments: const [
                  ButtonSegment(value: 7, label: Text('7 days')),
                  ButtonSegment(value: 30, label: Text('30 days')),
                  ButtonSegment(value: null, label: Text('All time')),
                ],
                selected: {_periodDays},
                onSelectionChanged: (s) =>
                    setState(() => _periodDays = s.first),
              ),
            ),
            const SizedBox(height: 16),
            if (_loading) ...[
              LinearProgressIndicator(
                value: _total == 0 ? null : _done / _total,
              ),
              const SizedBox(height: 6),
              Text(
                'Reading session $_done of $_total… (only the first visit '
                'scans the logs; afterwards this opens instantly)',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 16),
            ],
            if (!_loading && agg.aiSessions == 0)
              _emptyState(agg)
            else ...[
              _tileGrid(agg),
              const SizedBox(height: 8),
              if (agg.busiestHour != null || agg.recordDay != null)
                _highlights(agg),
              const SizedBox(height: 8),
              _chartCard(
                title: 'Visits by time of day',
                subtitle: 'When your visitors were active (visit starts)',
                child: MiniBarChart(
                  values: agg.visitsByHour,
                  xLabelFor: (i) => switch (i) {
                    0 || 6 || 12 || 18 => '$i h',
                    _ => null,
                  },
                ),
              ),
              const SizedBox(height: 12),
              if (agg.activity.isNotEmpty)
                _chartCard(
                  title: agg.weeklyBuckets
                      ? 'Visits by week'
                      : 'Visits by day',
                  subtitle: agg.weeklyBuckets
                      ? 'Long period — each bar is one week'
                      : null,
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
              if (agg.otherSessions > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '${agg.otherSessions} motion/time-lapse '
                  'session${agg.otherSessions == 1 ? '' : 's'} in this '
                  'period ${agg.otherSessions == 1 ? 'is' : 'are'} not '
                  'counted: without the AI detector there are no track ids '
                  'to sum. Tip: "Run AI on photos" analyzes their saved '
                  'photos.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
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
              ? 'No AI-mode sessions in this period. The dashboard counts '
                    'visits via track ids, which only exist when the AI '
                    'detector records a session — the ${agg.otherSessions} '
                    'motion/time-lapse session'
                    '${agg.otherSessions == 1 ? '' : 's'} here '
                    'ha${agg.otherSessions == 1 ? 's' : 've'} none.'
              : 'No sessions in this period yet. Record a session with the '
                    'AI detector and its visits will show up here.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ],
    ),
  );

  /// The headline numbers as a 2-column tile grid. The visit total is the
  /// hero (amber); everything else stays in plain ink.
  Widget _tileGrid(DashboardAggregate agg) {
    Widget tile(String label, String value, {bool hero = false}) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: hero ? 28 : 20,
              fontWeight: FontWeight.bold,
              color: hero ? Colors.amber : Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );

    final tiles = <Widget>[
      tile('insect visits (track ids)', '${agg.totalVisits}', hero: true),
      tile('watch time', _hoursLabel(agg.totalRecordedMs)),
      tile(
        'visits per hour watched',
        agg.totalRecordedMs > 0 ? agg.visitsPerHour.toStringAsFixed(1) : '—',
      ),
      tile('AI sessions', '${agg.aiSessions}'),
      tile('average visit', _secondsLabel(agg.meanVisitMs.round())),
      tile('longest visit', _secondsLabel(agg.longestVisitMs)),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.4,
      children: tiles,
    );
  }

  /// "Busiest hour" / "record day" one-liners — the entertaining bit.
  Widget _highlights(DashboardAggregate agg) {
    final lines = <String>[
      if (agg.busiestHour case final h?)
        '🏆 Busiest hour: ${_two(h)}:00–${_two((h + 1) % 24)}:00',
      if (agg.recordDay case final d?)
        '📅 Record day: ${_dateShort(d)} (${agg.recordDayCount} '
            'visit${agg.recordDayCount == 1 ? '' : 's'})',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                l,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chartCard({
    required String title,
    String? subtitle,
    required Widget child,
  }) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white10,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 14)),
        if (subtitle != null)
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        const SizedBox(height: 10),
        SizedBox(height: 120, width: double.infinity, child: child),
      ],
    ),
  );

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _dateShort(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _hoursLabel(int ms) {
    final h = ms / Duration.millisecondsPerHour;
    if (h >= 10) return '${h.round()} h';
    if (h >= 1) return '${h.toStringAsFixed(1)} h';
    return '${(ms / Duration.millisecondsPerMinute).round()} min';
  }

  static String _secondsLabel(int ms) {
    if (ms >= 60000) {
      final m = ms ~/ 60000, s = (ms % 60000) ~/ 1000;
      return '$m min ${_two(s)} s';
    }
    return '${(ms / 1000).toStringAsFixed(1)} s';
  }
}

