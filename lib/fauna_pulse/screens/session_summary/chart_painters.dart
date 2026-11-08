// FaunaPulse, session summary screen:
// the painters of the Graphs tab (timeline and time series) and their axis helpers.
//
// A `part` of session_summary_screen.dart: that screen's State class is split into
// extensions, one file per part of the screen, so each file stays readable
// while the private fields stay shared (Dart privacy is per library, and a
// part file belongs to the main file's library). Fields, getters and the
// lifecycle overrides stay in the main file; part files hold methods only.

part of '../session_summary_screen.dart';

/// Mean, median, min and max of a time series' values (the `ms` timestamps are
/// ignored). Median is the middle value of the sorted samples (the average of
/// the two middle ones for an even count) — a robust "typical" value that, unlike
/// the mean, isn't pulled by a few extreme spikes. Pure Dart (just a sort), so no
/// extra dependency. Returns null for an empty series.
({double mean, double median, double min, double max})? _seriesStats(
  List<(int ms, double v)> points,
) {
  if (points.isEmpty) return null;
  final vals = [for (final p in points) p.$2]..sort();
  final n = vals.length;
  final mean = vals.reduce((a, b) => a + b) / n;
  final median = n.isOdd ? vals[n ~/ 2] : (vals[n ~/ 2 - 1] + vals[n ~/ 2]) / 2;
  return (mean: mean, median: median, min: vals.first, max: vals.last);
}

/// "Nice number" rounding (Heckbert's algorithm) used to pick human-friendly axis
/// steps: it snaps [x] to the nearest 1, 2 or 5 × 10ⁿ. With [round] true it picks
/// the closest nice value; with it false it picks the smallest nice value ≥ [x].
/// This is why the axes land on round numbers (e.g. 0, 5, 10, 15) instead of
/// awkward fractions (e.g. 0, 2.5, 5).
double _niceNum(double x, {required bool round}) {
  if (x <= 0) return 1;
  final exp = (log(x) / ln10).floor();
  final f = x / pow(10, exp);
  double nf;
  if (round) {
    nf = f < 1.5
        ? 1
        : f < 3
        ? 2
        : f < 7
        ? 5
        : 10;
  } else {
    nf = f <= 1
        ? 1
        : f <= 2
        ? 2
        : f <= 5
        ? 5
        : 10;
  }
  return nf * pow(10, exp).toDouble();
}

/// One labelled tick on the time (X) axis: [ms] is the offset from session start.
class _TimeTick {
  final double ms;
  final String label;
  const _TimeTick(this.ms, this.label);
}

/// Builds readable, round time ticks across a session of [totalMs] milliseconds.
/// It chooses the unit (seconds / minutes / hours / days) so the session spans at
/// least a few whole units — so you never see an awkward step like "0.5 h" — and
/// places ticks at nice round multiples (e.g. every 2 min, or every 5 h).
List<_TimeTick> _timeTicks(double totalMs) {
  if (totalMs <= 0) return const [_TimeTick(0, '0 s')];
  const units = <(double, String)>[
    (1000.0, 's'),
    (60000.0, 'min'),
    (3600000.0, 'h'),
    (86400000.0, 'd'),
  ];
  // Largest unit that still gives ≥ 3 whole units across the session.
  var unitMs = units.first.$1;
  var suffix = units.first.$2;
  for (final u in units) {
    if (totalMs / u.$1 >= 3) {
      unitMs = u.$1;
      suffix = u.$2;
    } else {
      break;
    }
  }
  final totalUnits = totalMs / unitMs;
  var step = _niceNum(totalUnits / 5, round: true); // aim for ~5 ticks
  if (step < 1) step = 1; // never a fractional unit step
  final ticks = <_TimeTick>[];
  for (var v = 0.0; v <= totalUnits + step * 1e-3; v += step) {
    ticks.add(_TimeTick(v * unitMs, '${v.toStringAsFixed(0)} $suffix'));
  }
  return ticks;
}

/// A nice value (Y) axis: rounded min/max bounds and a round step, so the
/// horizontal gridlines sit on readable numbers that comfortably cover the data
/// (with a little headroom) instead of just min/mid/max.
({double niceMin, double niceMax, double step}) _niceValueAxis(
  double lo,
  double hi,
) {
  if (hi - lo < 1e-9) hi = lo + 1; // flat series: give it a unit of room
  final range = _niceNum(hi - lo, round: false);
  final step = _niceNum(range / 4, round: true); // ~4 intervals (5 lines)
  final niceMin = (lo / step).floor() * step;
  final niceMax = (hi / step).ceil() * step;
  return (niceMin: niceMin, niceMax: niceMax, step: step);
}

/// Decimal places suited to a (possibly small) axis step, so tiny ranges (e.g.
/// energy in fractions of a watt-hour) still read clearly while whole-number
/// steps show no needless ".0".
int _decimalsFor(double step) {
  if (step >= 1) return 0;
  return (-(log(step) / ln10)).ceil().clamp(1, 4);
}

/// Gantt timeline: one labelled lane per track id with a bar from first to last
/// sighting, end-dots, and a time axis (seconds/minutes/hours) along the bottom.
/// m:ss.s, or h:mm:ss from an hour on: a track ID's start or end on the timeline (round 247),
/// the same form as the Video tab's track list.
String ganttTime(int ms) {
  final s = ms ~/ 1000;
  String two(int n) => n.toString().padLeft(2, '0');
  if (s >= 3600) return '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}';
  return '${s ~/ 60}:${two(s % 60)}.${ms % 1000 ~/ 100}';
}

class _GanttPainter extends CustomPainter {
  final List<int> ids;
  final Map<int, (int first, int last)> spans;
  final int startMs;
  final int endMs;
  final double laneHeight;
  final double axisHeight;
  final bool showLabels;

  _GanttPainter({
    required this.ids,
    required this.spans,
    required this.startMs,
    required this.endMs,
    required this.laneHeight,
    required this.axisHeight,
    this.showLabels = true,
  });

  static const double _gutter = 44.0;

  @override
  void paint(Canvas canvas, Size size) {
    final totalMs = (endMs - startMs).toDouble();
    final plotLeft = _gutter;
    final plotWidth = size.width - _gutter;
    final plotBottom = size.height - axisHeight;

    double xForMs(int ms) => plotLeft + ((ms - startMs) / totalMs) * plotWidth;

    final axisPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    final barPaint = Paint()..color = const Color(0xFF00E5FF);
    final dotPaint = Paint()..color = const Color(0xFFFFEB3B);

    for (final tk in _timeTicks(totalMs)) {
      final x = plotLeft + (tk.ms / totalMs) * plotWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, plotBottom), axisPaint);
      _text(
        canvas,
        tk.label,
        Offset(x + 2, plotBottom + 6),
        Colors.white54,
        10,
      );
    }

    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      // Round 305: never left of the session start (the index already clamps
      // a first sighting from just before recording began).
      final first = max(spans[id]!.$1, startMs);
      final last = max(spans[id]!.$2, first);
      final yCenter = i * laneHeight + laneHeight / 2;
      if (showLabels) {
        _text(canvas, '#$id', Offset(4, yCenter - 7), Colors.white70, 11);
      }
      final barHalf = (laneHeight * 0.35).clamp(1.5, 5.0);
      final x1 = xForMs(first);
      final x2 = xForMs(last);
      final barRect = Rect.fromLTRB(
        x1,
        yCenter - barHalf,
        (x2 - x1) < 2 ? x1 + 2 : x2,
        yCenter + barHalf,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(barRect, const Radius.circular(2)),
        barPaint,
      );
      if (showLabels) {
        canvas.drawCircle(Offset(x1, yCenter), 3, dotPaint);
        canvas.drawCircle(Offset(x2, yCenter), 3, dotPaint);
        // Round 247: start and end, counted from the session start like the axis; right of the
        // bar, or left of it when the bar runs to the edge, or left out when neither fits.
        final label = TextPainter(
          text: TextSpan(
            text: '${ganttTime(first - startMs)}–${ganttTime(last - startMs)}',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final y = yCenter - label.height / 2;
        if (x2 + 6 + label.width <= size.width) {
          label.paint(canvas, Offset(x2 + 6, y));
        } else if (x1 - 6 - label.width >= plotLeft) {
          label.paint(canvas, Offset(x1 - 6 - label.width, y));
        }
      }
    }
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _GanttPainter old) =>
      old.ids != ids || old.startMs != startMs || old.endMs != endMs;
}

/// A simple time series (temperature or FPS) drawn as a line, y-axis auto-scaled.
class _SeriesPainter extends CustomPainter {
  final List<(int ms, double v)> points;
  final int startMs;
  final int endMs;
  final Color color;
  final String unit;

  /// Time spans drawn as grey bands behind the line (cooling pauses).
  final List<(int, int)> shade;

  /// More series on the same axes (round 361: the chip temperatures beside the
  /// battery's); they widen the value axis, the labels stay those of [points].
  final List<(List<(int ms, double v)>, Color)> extra;

  _SeriesPainter({
    required this.points,
    required this.startMs,
    required this.endMs,
    required this.color,
    required this.unit,
    this.shade = const [],
    this.extra = const [],
  });

  static const double _gutter = 44.0;
  static const double _axisHeight = 22.0;

  @override
  void paint(Canvas canvas, Size size) {
    final totalMs = (endMs - startMs).toDouble();
    final plotLeft = _gutter;
    final plotWidth = size.width - _gutter;
    final plotBottom = size.height - _axisHeight;

    var lo = points.first.$2, hi = points.first.$2;
    for (final p in [...points, for (final (pts, _) in extra) ...pts]) {
      lo = min(lo, p.$2);
      hi = max(hi, p.$2);
    }
    // Round the value (Y) axis to readable bounds + step (e.g. 0,10,20,30,40,50
    // for temperature), with headroom, instead of just min/mid/max.
    final ax = _niceValueAxis(lo, hi);
    final vrange = (ax.niceMax - ax.niceMin) == 0
        ? 1.0
        : ax.niceMax - ax.niceMin;
    final vdec = _decimalsFor(ax.step);

    double xForMs(int ms) => plotLeft + ((ms - startMs) / totalMs) * plotWidth;
    double yForV(double v) =>
        plotBottom - ((v - ax.niceMin) / vrange) * plotBottom;

    final shadePaint = Paint()..color = Colors.white12;
    for (final (from, to) in shade) {
      final l = xForMs(from).clamp(plotLeft, size.width);
      final r = xForMs(to).clamp(plotLeft, size.width);
      canvas.drawRect(Rect.fromLTRB(l, 0, max(r, l + 2), plotBottom), shadePaint);
    }

    final axisPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    // Horizontal gridlines at the round value steps.
    for (var v = ax.niceMin; v <= ax.niceMax + ax.step * 1e-3; v += ax.step) {
      final y = yForV(v);
      canvas.drawLine(Offset(plotLeft, y), Offset(size.width, y), axisPaint);
      _text(
        canvas,
        '${v.toStringAsFixed(vdec)}$unit',
        Offset(2, y - 6),
        Colors.white54,
        10,
      );
    }
    // Dim vertical gridlines at the SAME round time ticks (and same _gutter) as
    // the Gantt timeline, so every graph lines up on the X (time) axis — a visual
    // cue that they share one timeline, not just matching ticks.
    for (final tk in _timeTicks(totalMs)) {
      final x = plotLeft + (tk.ms / totalMs) * plotWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, plotBottom), axisPaint);
      _text(
        canvas,
        tk.label,
        Offset(x + 2, plotBottom + 4),
        Colors.white54,
        10,
      );
    }

    _line(canvas, points, color, xForMs, yForV);
    for (final (pts, c) in extra) {
      if (pts.length >= 2) _line(canvas, pts, c, xForMs, yForV);
    }
  }

  /// One series as a line. A hole in the series (e.g. the motion gate kept the
  /// detector asleep, so no inference samples were logged for that stretch —
  /// round 77) must show as a gap, not as a straight bridge that looks like
  /// data. Any pause much longer than the series' median sampling interval
  /// breaks the line.
  void _line(
    Canvas canvas,
    List<(int ms, double v)> pts,
    Color c,
    double Function(int ms) xForMs,
    double Function(double v) yForV,
  ) {
    final linePaint = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final gaps = <int>[
      for (var i = 1; i < pts.length; i++) pts[i].$1 - pts[i - 1].$1,
    ]..sort();
    final medianGapMs = gaps.isEmpty ? 0 : gaps[gaps.length ~/ 2];
    final breakMs = max(3000, medianGapMs * 3);
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final x = xForMs(pts[i].$1);
      final y = yForV(pts[i].$2);
      final startsSegment = i == 0 || pts[i].$1 - pts[i - 1].$1 > breakMs;
      startsSegment ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, linePaint);
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _SeriesPainter old) =>
      old.points != points ||
      old.startMs != startMs ||
      old.endMs != endMs ||
      old.shade != shade ||
      old.extra != extra;
}
