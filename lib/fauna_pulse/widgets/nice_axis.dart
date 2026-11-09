// FaunaPulse: round numbers for chart axes, shared by the summary's line graphs
// (screens/session_summary/chart_painters.dart) and the bar charts (mini_bar_chart.dart).

import 'dart:math';

/// "Nice number" rounding (Heckbert's algorithm) used to pick human-friendly axis
/// steps: it snaps [x] to the nearest 1, 2 or 5 × 10ⁿ. With [round] true it picks
/// the closest nice value; with it false it picks the smallest nice value ≥ [x].
/// This is why the axes land on round numbers (e.g. 0, 5, 10, 15) instead of
/// awkward fractions (e.g. 0, 2.5, 5).
double niceNum(double x, {required bool round}) {
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
