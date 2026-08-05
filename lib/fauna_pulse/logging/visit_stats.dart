// FaunaPulse — per-session visit statistics for the summary's Graphs tab
// (round 187): the visit-length histogram and the visits-by-hour counts.
//
// Pure functions over the track spans the SessionLogIndex already provides
// ((first seen ms, last seen ms) per track id), so the math is unit-testable
// without any file or widget work. The cross-session Dashboard has its own
// aggregation in dashboard_stats.dart; these deliberately mirror its
// definitions (a "visit" = one track id, its start = first seen, local time)
// so a session's numbers always agree with the Dashboard's.

import 'dart:math';

/// The visit-length histogram: [values] holds the visit count per bin of
/// [binSeconds] (bin i covers `[i*bin, (i+1)*bin)` seconds). To keep the
/// chart readable at fine bin sizes, at most [maxBars] bars are built; when
/// the longest visit would need more, every visit at/beyond the last bar is
/// collected into it and [overflow] is true (its label should read "≥ …").
class DurationHistogram {
  final List<int> values;
  final int binSeconds;
  final bool overflow;

  const DurationHistogram({
    required this.values,
    required this.binSeconds,
    required this.overflow,
  });

  /// The inclusive lower edge (seconds) of bin [i] — for axis labels.
  int binStartSeconds(int i) => i * binSeconds;
}

/// Bins visit durations (ms) into [binSeconds]-wide bars. Returns an empty
/// histogram when there are no visits.
DurationHistogram visitDurationHistogram(
  Iterable<int> durationsMs,
  int binSeconds, {
  int maxBars = 60,
}) {
  assert(binSeconds > 0);
  final bins = <int>[];
  var overflow = false;
  for (final ms in durationsMs) {
    var i = (max(0, ms) / 1000 / binSeconds).floor();
    if (i >= maxBars) {
      i = maxBars - 1;
      overflow = true;
    }
    while (bins.length <= i) {
      bins.add(0);
    }
    bins[i]++;
  }
  return DurationHistogram(
    values: bins,
    binSeconds: binSeconds,
    overflow: overflow,
  );
}

/// Visit starts per local hour of day (24 entries) — the per-session version
/// of the Dashboard's "Visits by time of day" chart. [startsMs] are epoch ms.
List<int> visitsByHour(Iterable<int> startsMs) {
  final byHour = List<int>.filled(24, 0);
  for (final ms in startsMs) {
    byHour[DateTime.fromMillisecondsSinceEpoch(ms).hour]++;
  }
  return byHour;
}

/// Compact axis label for a duration in seconds: "45s", "5m", "1.5h".
String compactSecondsLabel(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) {
    final m = seconds / 60;
    return m == m.roundToDouble() ? '${m.round()}m' : '${(seconds / 60).toStringAsFixed(1)}m';
  }
  final h = seconds / 3600;
  return h == h.roundToDouble() ? '${h.round()}h' : '${h.toStringAsFixed(1)}h';
}
