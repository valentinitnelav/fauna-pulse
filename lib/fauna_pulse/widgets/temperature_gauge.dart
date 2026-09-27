// FaunaPulse: battery temperature against a long job's pause limit (round
// 210 in the identification screen; shared with the video analysis in 227).

import 'package:flutter/material.dart';

import 'setting_help.dart' show helperTextStyle;

/// A bar that turns from green to amber to red as [tempC] nears [limitC],
/// plus cooling advice while [paused]. [limitWhere] names where the limit is
/// set, for the explanation line.
List<Widget> temperatureGauge(double tempC, double limitC, {required bool paused, required String limitWhere}) {
  const floor = 25.0;
  final frac = ((tempC - floor) / (limitC - floor)).clamp(0.0, 1.0);
  final color = tempC >= limitC
      ? Colors.redAccent
      : tempC >= limitC - 4
      ? Colors.amber
      : Colors.lightGreen;
  return [
    const SizedBox(height: 8),
    Row(
      children: [
        Icon(Icons.device_thermostat, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: frac, minHeight: 8, color: color, backgroundColor: Colors.white12),
          ),
        ),
        const SizedBox(width: 8),
        Text('${tempC.toStringAsFixed(1)} °C', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
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
