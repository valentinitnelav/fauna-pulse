// FaunaPulse — minimal single-series bar chart (round 186, extracted round
// 187 so the per-session summary can reuse it).
//
// Chart style follows the app's dark theme: single-series amber bars
// (magnitude = one hue), recessive white24 baseline and white38 axis text,
// the value drawn above the tallest bar only (selective direct labeling — a
// number on every bar is noise), sparse x labels via [xLabelFor], legend-free
// (the surrounding title names the single series).
//
// The value axis on the left (round 362) has ticks at round numbers that follow
// the tallest bar ([barChartTickStep]): without it nobody could read a bar's
// height except the tallest one's.

import 'dart:math';

import 'package:flutter/material.dart';

import 'nice_axis.dart';

/// The distance between two ticks of the value axis: a round number (1, 2, 5,
/// 10, 20, 50, 100, ...) chosen from the tallest bar, so 7 gives 0, 2, 4, 6, 8,
/// 37 gives 0, 10, 20, 30, 40 and 1,300 gives 0, 500, 1000, 1500. Never under 1:
/// the bars are counts. A third of the tallest bar is the aim (3 to 6 ticks):
/// the charts are only about 100 px high.
int barChartTickStep(int maxValue) => max(1, niceNum(maxValue / 3, round: true).round());

class MiniBarChart extends StatelessWidget {
  final List<int> values;
  final String? Function(int index) xLabelFor;

  /// What the bars count (for example "Track IDs"), written upwards along the
  /// value axis; null leaves it out.
  final String? yLabel;

  const MiniBarChart({super.key, required this.values, required this.xLabelFor, this.yLabel});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _BarChartPainter(values, xLabelFor, yLabel));
}

class _BarChartPainter extends CustomPainter {
  final List<int> values;
  final String? Function(int index) xLabelFor;
  final String? yLabel;

  _BarChartPainter(this.values, this.xLabelFor, this.yLabel);

  @override
  void paint(Canvas canvas, Size size) {
    const labelBand = 14.0; // x-label strip under the baseline
    const peakBand = 12.0; // room for the peak count above the bars
    final plotH = size.height - labelBand - peakBand;
    final baselineY = peakBand + plotH;
    final n = values.length;
    if (n == 0 || plotH <= 0) return;

    // The value axis ends on the first tick at or above the tallest bar, so the
    // bars never reach past the top gridline.
    final maxV = values.reduce(max);
    final step = barChartTickStep(maxV);
    final axisMax = max(step, (maxV / step).ceil() * step);
    final ticks = [for (var v = 0; v <= axisMax; v += step) (v, _layout('$v', Colors.white38))];
    final yName = yLabel == null ? null : _layout(yLabel!, Colors.white38);
    // Left of the bars: the axis name (turned upwards, so its height is its
    // width here), then the tick numbers, right-aligned.
    final tickRight = (yName == null ? 0.0 : yName.height + 2) + ticks.map((t) => t.$2.width).reduce(max);
    final plotLeft = tickRight + 4;
    final plotW = size.width - plotLeft;
    if (plotW <= 0) return;
    double yFor(num v) => baselineY - plotH * v / axisMax;

    if (yName != null) {
      // Turned a quarter left around its start point: the text then runs upwards
      // and its line height lies to the right. Centred on the bars' height.
      canvas.save();
      canvas.translate(0, peakBand + plotH / 2 + yName.width / 2);
      canvas.rotate(-pi / 2);
      yName.paint(canvas, Offset.zero);
      canvas.restore();
    }
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    final baseline = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (final (v, label) in ticks) {
      final y = yFor(v);
      canvas.drawLine(Offset(plotLeft, y), Offset(size.width, y), v == 0 ? baseline : grid);
      label.paint(canvas, Offset(tickRight - label.width, y - label.height / 2));
    }

    final slot = plotW / n;
    final barW = (slot * 0.7).clamp(1.0, 24.0);
    final bar = Paint()..color = Colors.amber;
    int? peakIndex;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v > 0 && (peakIndex == null || v > values[peakIndex])) peakIndex = i;
      if (v > 0) {
        final x = plotLeft + slot * i + (slot - barW) / 2;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(x, yFor(v), x + barW, baselineY),
            topLeft: const Radius.circular(2),
            topRight: const Radius.circular(2),
          ),
          bar,
        );
      }
      final label = xLabelFor(i);
      if (label != null) {
        _centred(canvas, _layout(label, Colors.white38), plotLeft + slot * i + slot / 2, baselineY + 2, plotLeft, size.width);
      }
    }
    if (peakIndex != null) {
      final count = _layout('${values[peakIndex]}', Colors.white70);
      _centred(canvas, count, plotLeft + slot * peakIndex + slot / 2, yFor(values[peakIndex]) - count.height, plotLeft, size.width);
    }
  }

  TextPainter _layout(String s, Color color) => TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(color: color, fontSize: 10),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  /// Paints [tp] centred on [centerX], kept between [left] and [right].
  void _centred(Canvas canvas, TextPainter tp, double centerX, double top, double left, double right) {
    final x = (centerX - tp.width / 2).clamp(left, max(left, right - tp.width)).toDouble();
    tp.paint(canvas, Offset(x, top));
  }

  @override
  bool shouldRepaint(_BarChartPainter old) =>
      old.values != values || old.xLabelFor != xLabelFor || old.yLabel != yLabel;
}
