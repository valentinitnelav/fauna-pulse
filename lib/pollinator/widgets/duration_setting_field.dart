// A duration input: a NumericSettingField plus a seconds/minutes/hours unit
// selector (round 97 — "Photo duration" and the time-lapse burst interval can
// be minutes or hours, and typing 1800 seconds for half an hour is error-
// prone). The value handed in and out is ALWAYS seconds; the unit only
// changes how the number is displayed and typed. Switching the unit converts
// the shown number in place — it never changes the stored duration.

import 'package:flutter/material.dart';

import 'numeric_setting_field.dart';

enum _Unit { s, min, h }

extension on _Unit {
  double get factor => switch (this) {
    _Unit.s => 1,
    _Unit.min => 60,
    _Unit.h => 3600,
  };

  String get label => switch (this) {
    _Unit.s => 's',
    _Unit.min => 'min',
    _Unit.h => 'h',
  };
}

class DurationSettingField extends StatefulWidget {
  const DurationSettingField({
    super.key,
    required this.label,
    required this.valueSeconds,
    required this.minSeconds,
    required this.maxSeconds,
    required this.onChanged,
    this.helperText,
  });

  final String label;
  final double valueSeconds;
  final double minSeconds;
  final double maxSeconds;

  /// Called with the new duration in SECONDS (already unit-converted).
  final ValueChanged<double> onChanged;
  final String? helperText;

  @override
  State<DurationSettingField> createState() => _DurationSettingFieldState();
}

class _DurationSettingFieldState extends State<DurationSettingField> {
  // Start in the largest unit that shows the current value as a round
  // number, so a stored 1800 s opens as "30 min", not "1800 s".
  late _Unit _unit = _inferUnit(widget.valueSeconds);

  static _Unit _inferUnit(double seconds) {
    if (seconds >= 3600 && seconds % 3600 == 0) return _Unit.h;
    if (seconds >= 60 && seconds % 60 == 0) return _Unit.min;
    return _Unit.s;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: NumericSettingField(
            label: widget.label,
            value: widget.valueSeconds / _unit.factor,
            min: widget.minSeconds / _unit.factor,
            max: widget.maxSeconds / _unit.factor,
            decimals: 1,
            unitSuffix: _unit.label,
            helperText: widget.helperText,
            onChanged: (v) => widget.onChanged(v * _unit.factor),
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<_Unit>(
          value: _unit,
          dropdownColor: Colors.black87,
          items: [
            for (final u in _Unit.values)
              DropdownMenuItem(
                value: u,
                child: Text(
                  u.label,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
          ],
          // Display-only change: the stored seconds stay the same.
          onChanged: (u) => setState(() => _unit = u ?? _unit),
        ),
      ],
    );
  }
}
