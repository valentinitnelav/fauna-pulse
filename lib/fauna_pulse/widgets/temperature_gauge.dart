// FaunaPulse: the phone's state under a long job's progress line: battery
// temperature against the job's pause limit (round 210 in the identification
// screen; shared with the video analysis in 227), and since round 346 the
// whole phone's memory against the point where Android closes apps, plus one
// text line for this app's processor use.
// Round 252: a scale with a pointer instead of a filling bar, which sat under
// the job's progress bar and read as a second one (time left?) (owner). The
// memory scale keeps that rule: the scale is always fully coloured and only the
// pointer moves, so nothing here looks like progress.

import 'dart:math' show max;

import 'package:flutter/material.dart';

import '../logging/device_storage.dart' show formatBytes;
import '../logging/device_thermal.dart';
import 'setting_help.dart' show helperTextStyle;

/// Where the scale starts (°C): a phone at rest indoors.
const _floorC = 25.0;

/// Where the memory scale turns amber (share of the scale).
const _memoryAmberFrom = 0.85;

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
        const Expanded(child: Text('Battery temperature', style: TextStyle(fontSize: 13))),
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
    // Round 319: only what the title and the scale do not say already. Round
    // 346 (owner): say what the sensor is, so nobody takes it for the chip.
    Text(
      'Measured by the sensor inside the battery; the processor gets hot faster than this. '
      'After a heat pause, the run goes on by itself below ${(limitC - 3).toStringAsFixed(0)} °C. '
      // Shown only while a run goes on, when the settings cannot be opened.
      'To change the limit, open $limitWhere after the run.',
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

/// The whole phone's memory in use on a scale from 0 to the point where
/// Android starts closing apps (its low-memory line), with a pointer at the
/// current use and this app's own share in the text below. The scope is in
/// the title ("whole phone") on purpose: the processor line under it is this
/// app only, and the two must not read as the same kind of number. Empty when
/// the phone reported no memory figures.
List<Widget> memoryGauge(ThermalReading r) {
  final total = r.memTotalBytes, used = r.memUsedBytes, low = r.lowMemoryBytes;
  if (total == null || used == null || low == null || total <= 0) return const [];
  // Memory in use at which Android starts closing apps: the end of the scale.
  final limit = max(1, total - low);
  final frac = (used / limit).clamp(0.0, 1.0);
  final color = used >= limit
      ? Colors.redAccent
      : frac >= _memoryAmberFrom
      ? Colors.amber
      : Colors.lightGreen;
  // Every size in these lines shares the unit of the total ("one unit per sentence").
  String size(int bytes) => formatBytes(bytes, unitOf: total);
  final app = r.appMemoryBytes;
  return [
    const SizedBox(height: 10),
    Row(
      children: [
        Icon(Icons.memory, size: 18, color: color),
        const SizedBox(width: 4),
        const Expanded(child: Text('Memory in use, whole phone', style: TextStyle(fontSize: 13))),
        Text(size(used), style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      ],
    ),
    const SizedBox(height: 2),
    SizedBox(
      height: 16,
      width: double.infinity,
      child: CustomPaint(
        key: const Key('memory_scale'),
        painter: _ScalePainter(frac, amberFrom: _memoryAmberFrom),
      ),
    ),
    Row(
      children: [
        Text('0 ${size(total).split(' ').last}', style: helperTextStyle),
        const SizedBox(width: 8),
        // Flexible + ellipsis: a large font on a narrow phone must not overflow.
        Expanded(
          child: Text(
            'Android closes apps at ${size(limit)}',
            style: helperTextStyle,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
    Text(
      '${app == null ? 'FaunaPulse\'s own share is not known' : 'FaunaPulse holds ${size(app)} of it'}, '
      'mostly the loaded model. Near the end of the scale Android starts closing apps, the ones '
      'in the background first.',
      style: helperTextStyle,
    ),
  ];
}

/// One text line: the processor cores this app kept busy on average (its own
/// process only, which the line says; see [ThermalReading.appCpuCores]).
/// [engine] is where the model runs ("GPU" or "CPU"), when the page knows it:
/// it explains a low number, the model on the GPU leaves the cores little to
/// do. Empty until the second reading.
List<Widget> appCpuLine(ThermalReading r, {String engine = ''}) {
  final cores = r.appCpuCores, count = r.cpuCount;
  if (cores == null || count == null) return const [];
  final where = switch (engine) {
    'GPU' || 'CPU' => ' (model on the $engine)',
    _ => '',
  };
  return [
    Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'FaunaPulse: ${cores.toStringAsFixed(1)} of $count processor cores busy$where.',
        key: const Key('app_cpu_line'),
        style: helperTextStyle,
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
