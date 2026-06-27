// Pollinator Monitor — reads how warm/throttled the phone is.
//
// Real-time detection + tracking keeps the GPU/CPU busy and heats the phone up,
// which on a long field session can make Android "thermal throttle" (slow itself
// down to cool off). This talks to a tiny native method channel (see
// MainActivity.kt) to read the battery temperature in °C and the OS thermal
// status, so we can show it on screen and record it in the session log.

import 'package:flutter/services.dart';

/// One reading: battery temperature in °C and a thermal-status label
/// ("none".."shutdown"), plus the live battery power figures used to estimate how
/// much ENERGY a session consumes. Any field may be null if the device doesn't
/// expose it.
///
/// Power terms in plain language:
///   - "power" (watts, W) = how fast energy is being used *right now*.
///   - "energy" (watt-hours, Wh) = the *total* used over time (power × hours).
///     Note: the everyday phrase "watts per hour" is a misnomer — W is already a
///     rate, and the accumulated total is watt-hours (Wh).
class ThermalReading {
  final double? batteryTempC;
  final String? thermalStatus;

  /// Instantaneous battery current in microamps (µA). Sign/units vary by phone,
  /// so [powerW] uses its magnitude. Null if the device doesn't report it.
  final int? batteryCurrentUa;

  /// Battery voltage in millivolts (mV), e.g. 4012 → 4.012 V.
  final int? batteryVoltageMv;

  /// Remaining battery charge in microamp-hours (µAh). The drop in this value
  /// across a session is the reliable basis for the total energy estimate.
  final int? chargeCounterUah;

  /// Whether the phone was plugged in (charging/full) at the moment of the
  /// reading — an energy estimate is only valid while unplugged.
  final bool? isCharging;

  /// "Thermal headroom" (0 = cool, 1 = at the throttling threshold; can briefly
  /// exceed 1). A fast, cross-device measure of how close the phone is to slowing
  /// itself down to cool off. Null on devices that don't support it (API < 30 or
  /// a NaN reading).
  final double? thermalHeadroom;

  const ThermalReading({
    this.batteryTempC,
    this.thermalStatus,
    this.batteryCurrentUa,
    this.batteryVoltageMv,
    this.chargeCounterUah,
    this.isCharging,
    this.thermalHeadroom,
  });

  /// Instantaneous power draw in watts (W) = |current (A)| × voltage (V).
  /// Returns null if either current or voltage is unavailable.
  double? get powerW {
    final ua = batteryCurrentUa, mv = batteryVoltageMv;
    if (ua == null || mv == null || mv <= 0) return null;
    return (ua.abs() / 1e6) * (mv / 1e3);
  }

  Map<String, dynamic> toJson() => {
    'battery_temp_c': batteryTempC,
    'thermal_status': thermalStatus,
    'battery_current_ua': batteryCurrentUa,
    'battery_voltage_mv': batteryVoltageMv,
    'charge_counter_uah': chargeCounterUah,
    'is_charging': isCharging,
    'thermal_headroom': thermalHeadroom,
    // Derived (so downstream R/Python don't have to recompute it).
    'power_w': powerW,
  };

  /// A short chip label, e.g. "31.2°C" or "31.2°C (severe)". Empty when nothing
  /// could be read.
  String get shortLabel {
    if (batteryTempC == null) return thermalStatus ?? '';
    final t = '${batteryTempC!.toStringAsFixed(1)}°C';
    final throttling =
        thermalStatus != null && thermalStatus != 'none' && thermalStatus != '';
    return throttling ? '$t ($thermalStatus)' : t;
  }
}

class DeviceThermal {
  static const MethodChannel _channel = MethodChannel('pollinator/thermal');

  /// Reads the current thermal state. Returns an empty reading on any error
  /// (e.g. iOS, or a platform that doesn't expose battery temperature).
  static Future<ThermalReading> read() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getThermal');
      if (res == null) return const ThermalReading();
      return ThermalReading(
        batteryTempC: (res['batteryTempC'] as num?)?.toDouble(),
        thermalStatus: res['thermalStatus'] as String?,
        batteryCurrentUa: (res['batteryCurrentUa'] as num?)?.toInt(),
        batteryVoltageMv: (res['batteryVoltageMv'] as num?)?.toInt(),
        chargeCounterUah: (res['chargeCounterUah'] as num?)?.toInt(),
        isCharging: res['isCharging'] as bool?,
        thermalHeadroom: (res['thermalHeadroom'] as num?)?.toDouble(),
      );
    } catch (_) {
      return const ThermalReading();
    }
  }
}
