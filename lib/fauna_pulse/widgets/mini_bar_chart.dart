// FaunaPulse — minimal single-series bar chart (round 186, extracted round
// 187 so the per-session summary can reuse it).
//
// Chart style follows the app's dark theme: single-series amber bars
// (magnitude = one hue), recessive white24 baseline and white38 axis text,
// the value drawn above the tallest bar only (selective direct labeling — a
// number on every bar is noise), sparse x labels via [xLabelFor], legend-free
// (the surrounding title names the single series).

import 'package:flutter/material.dart';

class MiniBarChart extends StatelessWidget {
  final List<int> values;
  final String? Function(int index) xLabelFor;

  const MiniBarChart({super.key, required this.values, required this.xLabelFor});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _BarChartPainter(values, xLabelFor));
}

class _BarChartPainter extends CustomPainter {
  final List<int> values;
  final String? Function(int index) xLabelFor;

  _BarChartPainter(this.values, this.xLabelFor);

  @override
  void paint(Canvas canvas, Size size) {
    const labelBand = 14.0; // x-label strip under the baseline
    const peakBand = 12.0; // room for the peak count above the bars
    final plotH = size.height - labelBand - peakBand;
    final baselineY = peakBand + plotH;
    final n = values.length;
    if (n == 0 || plotH <= 0) return;

    final baseline = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      baseline,
    );

    final maxV = values.reduce((a, b) => a > b ? a : b);
    final slot = size.width / n;
    final barW = (slot * 0.7).clamp(1.0, 24.0);
    final bar = Paint()..color = Colors.amber;
    int? peakIndex;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v > 0 && (peakIndex == null || v > values[peakIndex])) peakIndex = i;
      if (v > 0) {
        final h = maxV == 0 ? 0.0 : plotH * v / maxV;
        final x = slot * i + (slot - barW) / 2;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, baselineY - h, barW, h),
            topLeft: const Radius.circular(2),
            topRight: const Radius.circular(2),
          ),
          bar,
        );
      }
      final label = xLabelFor(i);
      if (label != null) {
        _text(
          canvas,
          label,
          Offset(slot * i + slot / 2, baselineY + 2),
          anchorCenterX: true,
          color: Colors.white38,
          clampWidth: size.width,
        );
      }
    }
    if (peakIndex != null) {
      _text(
        canvas,
        '${values[peakIndex]}',
        Offset(slot * peakIndex + slot / 2, 0),
        anchorCenterX: true,
        color: Colors.white70,
        clampWidth: size.width,
      );
    }
  }

  void _text(
    Canvas canvas,
    String s,
    Offset topCenter, {
    required bool anchorCenterX,
    required Color color,
    required double clampWidth,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var x = anchorCenterX ? topCenter.dx - tp.width / 2 : topCenter.dx;
    x = x.clamp(0.0, (clampWidth - tp.width).clamp(0.0, clampWidth));
    tp.paint(canvas, Offset(x, topCenter.dy));
  }

  @override
  bool shouldRepaint(_BarChartPainter old) =>
      old.values != values || old.xLabelFor != xLabelFor;
}
