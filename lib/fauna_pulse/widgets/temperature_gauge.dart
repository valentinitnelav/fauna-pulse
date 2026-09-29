// FaunaPulse: battery temperature against a long job's pause limit (round
// 210 in the identification screen; shared with the video analysis in 227).
// Round 252: a scale with a pointer instead of a filling bar, which sat under
// the job's progress bar and read as a second one (time left?) (owner).

import 'package:flutter/material.dart';

import 'setting_help.dart' show helperTextStyle;

/// Where the scale starts (°C): a phone at rest indoors.
const _floorC = 25.0;

/// A labelled scale from [_floorC] to [limitC] (green, amber for the last
/// 4 °C) with a pointer at [tempC], plus cooling advice while [paused].
/// [limitWhere] names where the limit is set, for the explanation line.
List<Widget> temperatureGauge(double tempC, double limitC, {required bool paused, required String limitWhere}) {
  final frac = ((tempC - _floorC) / (limitC - _floorC)).clamp(0.0, 1.0);
  final color = tempC >= limitC
      ? Colors.redAccent
      : tempC >= limitC - 4
      ? Colors.amber
      : Colors.lightGreen;
  return [
    const SizedBox(height: 10),
    Row(
      children: [
        Icon(Icons.device_thermostat, size: 18, color: color),
        const SizedBox(width: 4),
        const Expanded(child: Text('Phone temperature', style: TextStyle(fontSize: 13))),
        Text('${tempC.toStringAsFixed(1)} °C', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      ],
    ),
    const SizedBox(height: 2),
    SizedBox(
      height: 16,
      width: double.infinity,
      child: CustomPaint(
        key: const Key('temperature_scale'),
        painter: _ScalePainter(frac, amberFrom: ((limitC - 4 - _floorC) / (limitC - _floorC)).clamp(0.0, 1.0)),
      ),
    ),
    Row(
      children: [
        Text('${_floorC.toStringAsFixed(0)} °C', style: helperTextStyle),
        const Spacer(),
        Text('pauses at ${limitC.toStringAsFixed(0)} °C', style: helperTextStyle),
      ],
    ),
    Text(
      'Battery temperature; the run pauses at ${limitC.toStringAsFixed(0)} °C and resumes below '
      '${(limitC - 3).toStringAsFixed(0)} °C (limit $limitWhere).',
      style: helperTextStyle,
    ),
    if (paused)
      const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text(
          'Cooling down. Put the phone on a cool, hard surface out of the sun (or in front of a '
          'fan); a case traps heat. It resumes by itself.',
          style: TextStyle(color: Colors.amber, fontSize: 12),
        ),
      ),
  ];
}

/// The whole scale is always coloured (green, then amber from [amberFrom]);
/// only the white pointer moves, so it does not fill up like a progress bar.
class _ScalePainter extends CustomPainter {
  final double frac;
  final double amberFrom;
  const _ScalePainter(this.frac, {required this.amberFrom});

  @override
  void paint(Canvas canvas, Size size) {
    const trackH = 4.0, pointerW = 10.0;
    final top = size.height - trackH - 2;
    final track = RRect.fromLTRBR(0, top, size.width, top + trackH, const Radius.circular(2));
    canvas.drawRRect(
      track,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.lightGreen, Colors.lightGreen, Colors.amber, Colors.amber],
          stops: [0, amberFrom, amberFrom, 1],
        ).createShader(track.outerRect),
    );
    // The pause limit: a red end mark.
    canvas.drawRect(Rect.fromLTWH(size.width - 3, top - 3, 3, trackH + 5), Paint()..color = Colors.redAccent);
    // Pointer: a downward triangle on a short needle through the track.
    final x = (frac * size.width).clamp(pointerW / 2, size.width - pointerW / 2);
    final white = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(x - 1, top - 3, 2, trackH + 5), white);
    canvas.drawPath(
      Path()
        ..moveTo(x - pointerW / 2, 0)
        ..lineTo(x + pointerW / 2, 0)
        ..lineTo(x, top - 1)
        ..close(),
      white,
    );
  }

  @override
  bool shouldRepaint(_ScalePainter old) => old.frac != frac || old.amberFrom != amberFrom;
}
