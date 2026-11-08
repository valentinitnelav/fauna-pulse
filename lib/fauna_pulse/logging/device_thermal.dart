// FaunaPulse — reads how warm/throttled the phone is.
//
// Real-time detection + tracking keeps the GPU/CPU busy and heats the phone up,
// which on a long field session can make Android "thermal throttle" (slow itself
// down to cool off). This talks to a tiny native method channel (see
// MainActivity.kt) to read the battery temperature in °C and the OS thermal
// status, so we can show it on screen and record it in the session log.
// The same call also brings the phone's memory and this app's processor use
// (round 346): they need no timer or channel of their own.

import 'dart:math' show min;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'app_error_hooks.dart';

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

  /// Whether the battery reported itself charging (or full) at the moment of
  /// the reading — an energy estimate is only valid while unplugged.
  final bool? isCharging;

  /// Whether ANY power source was attached (AC/USB/wireless), round 188.
  /// Distinct from [isCharging]: a full battery on a power bank reports
  /// NOT_CHARGING while still plugged — the charger then carries the load and
  /// the current sensor reads ~nothing, so power data is meaningless there
  /// too. The summary invalidates its energy series on either flag.
  final bool? isPlugged;

  /// "Thermal headroom" (0 = cool, 1 = at the throttling threshold; can briefly
  /// exceed 1). A fast, cross-device measure of how close the phone is to slowing
  /// itself down to cool off. Null on devices that don't support it (API < 30 or
  /// a NaN reading).
  final double? thermalHeadroom;

  /// Hottest CPU core sensor and hottest GPU sensor of the chip (°C), from the
  /// kernel's thermal zones (round 361). Only some makers let apps read them
  /// (Xiaomi yes, Samsung no), so both are null on many phones. They react
  /// within seconds, long before the battery warms, and show the slow-down that
  /// the battery sensor misses.
  final double? cpuTempC;
  final double? gpuTempC;

  /// Memory of the whole phone, in bytes: all of it, the part still free (the
  /// smaller of Android's availMem and the kernel's MemAvailable, the rule of
  /// `identifyFitsInBackground`: availMem can count page cache that cannot be
  /// freed), and the free amount below which Android starts closing background
  /// apps (ActivityManager.MemoryInfo.threshold). Null when the phone gave nothing.
  final int? memTotalBytes;
  final int? memFreeBytes;
  final int? lowMemoryBytes;

  /// Memory this app's process holds (VmRSS), bytes. The loaded model is most of it.
  final int? appMemoryBytes;

  /// Processor time this app's process has used since it started (ms, all its
  /// threads together) and the monotonic clock it was read at. [DeviceThermal]
  /// turns two readings into [appCpuCores]; the log keeps the raw time too.
  final int? appCpuMs;
  final int? uptimeMs;
  final int? cpuCount;

  /// Processor cores this app kept busy on average over about the last 10 s
  /// (0 to [cpuCount]). Its own process only: the camera and the video decoder
  /// run in other Android processes, so this is not the whole phone's load
  /// (which apps cannot read since Android 8). Null until a second reading.
  final double? appCpuCores;

  const ThermalReading({
    this.batteryTempC,
    this.thermalStatus,
    this.batteryCurrentUa,
    this.batteryVoltageMv,
    this.chargeCounterUah,
    this.isCharging,
    this.isPlugged,
    this.thermalHeadroom,
    this.cpuTempC,
    this.gpuTempC,
    this.memTotalBytes,
    this.memFreeBytes,
    this.lowMemoryBytes,
    this.appMemoryBytes,
    this.appCpuMs,
    this.uptimeMs,
    this.cpuCount,
    this.appCpuCores,
  });

  /// Memory in use by everything on the phone (bytes), or null.
  int? get memUsedBytes {
    final total = memTotalBytes, free = memFreeBytes;
    if (total == null || free == null) return null;
    return (total - free).clamp(0, total);
  }

  /// Instantaneous power draw in watts (W) = |current (A)| × voltage (V).
  /// Returns null if either current or voltage is unavailable.
  double? get powerW {
    final ua = batteryCurrentUa, mv = batteryVoltageMv;
    if (ua == null || mv == null || mv <= 0) return null;
    return (ua.abs() / 1e6) * (mv / 1e3);
  }

  /// "CPU 55 °C · GPU 48 °C" from the chip sensors, or null when the phone lets
  /// the app read neither. Whole degrees: the files keep the full reading.
  String? get chipLabel {
    final parts = [
      if (cpuTempC case final c?) 'CPU ${c.toStringAsFixed(0)} °C',
      if (gpuTempC case final g?) 'GPU ${g.toStringAsFixed(0)} °C',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
    'battery_temp_c': batteryTempC,
    'thermal_status': thermalStatus,
    'battery_current_ua': batteryCurrentUa,
    'battery_voltage_mv': batteryVoltageMv,
    'charge_counter_uah': chargeCounterUah,
    'is_charging': isCharging,
    'is_plugged': isPlugged,
    'thermal_headroom': thermalHeadroom,
    'cpu_temp_c': cpuTempC,
    'gpu_temp_c': gpuTempC,
    // Derived (so downstream R/Python don't have to recompute it).
    'power_w': powerW,
    'mem_total_bytes': memTotalBytes,
    'mem_free_bytes': memFreeBytes,
    'low_memory_bytes': lowMemoryBytes,
    'app_memory_bytes': appMemoryBytes,
    'app_cpu_ms': appCpuMs,
    'app_cpu_cores': appCpuCores,
    'cpu_count': cpuCount,
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
  static const MethodChannel _channel = MethodChannel('faunapulse/thermal');

  /// Round 170 (perf review E7): one native sample is shared by every caller
  /// within this window. The thermal and power sample timers are armed
  /// together with the same default interval, so their ticks land in the same
  /// instant and used to cost two identical channel calls each time; and
  /// Android's getThermalHeadroom() starts answering NaN when polled more
  /// than about once per second, which the user-configurable 1 s minimum
  /// interval could reach. 900 ms coalesces same-tick callers at every legal
  /// interval while a 1 s cadence still gets a fresh reading each tick.
  static const Duration cacheWindow = Duration(milliseconds: 900);

  // Cache stamps use a MONOTONIC clock (a Stopwatch only ever counts up), so
  // a wall-clock jump (NTP sync, timezone) can never poison the window.
  static final Stopwatch _monotonic = Stopwatch()..start();
  @visibleForTesting
  static Duration Function() now = () => _monotonic.elapsed;

  static ThermalReading? _cached;
  static Duration? _cachedAt;
  static Future<ThermalReading>? _inFlight;

  /// The previous native CPU-time reading (ms) and the phone clock it came
  /// with (ms), and the smoothed "cores busy" built from the readings so far.
  static (int cpuMs, int uptimeMs)? _lastCpu;
  static double? _cpuEma;

  /// "Cores busy" is an average over about this long (an exponential moving
  /// average): at the usual 10 s sample it is simply the last interval, while a
  /// job that reads every second (Identify reads per photo) still shows a
  /// steady number instead of one that jumps with every burst of work.
  static const Duration cpuWindow = Duration(seconds: 10);

  /// A gap longer than this between two readings starts the average afresh:
  /// the number would otherwise be the average of a long idle time (the
  /// longest sample interval a setting allows is 120 s).
  static const Duration cpuRestartGap = Duration(seconds: 150);

  @visibleForTesting
  static void resetForTesting() {
    _cached = null;
    _cachedAt = null;
    _inFlight = null;
    _lastCpu = null;
    _cpuEma = null;
    now = () => _monotonic.elapsed;
  }

  /// Folds a new native CPU-time reading into the running average and returns
  /// it, or null until two readings exist (or after a long gap).
  static double? _coresBusy(int? cpuMs, int? uptimeMs) {
    if (cpuMs == null || uptimeMs == null) return null;
    final prev = _lastCpu;
    _lastCpu = (cpuMs, uptimeMs);
    if (prev == null) return null;
    final dt = uptimeMs - prev.$2;
    if (dt <= 0 || dt > cpuRestartGap.inMilliseconds) {
      _cpuEma = null;
      return null;
    }
    final cores = ((cpuMs - prev.$1) / dt).clamp(0.0, double.infinity);
    final weight = min(1.0, dt / cpuWindow.inMilliseconds);
    final ema = _cpuEma;
    _cpuEma = ema == null ? cores : ema + weight * (cores - ema);
    return (_cpuEma! * 100).round() / 100;
  }

  /// Reads the current thermal state. Returns an empty reading on any error
  /// (e.g. iOS, or a platform that doesn't expose battery temperature).
  /// A reading younger than [cacheWindow] is served from cache, and callers
  /// arriving while a channel call is already underway share that call's
  /// result (the thermal and power timers tick in the same event-loop turn,
  /// so without this they would still fetch twice).
  static Future<ThermalReading> read() {
    final cached = _cached;
    final at = _cachedAt;
    if (cached != null && at != null && now() - at < cacheWindow) {
      return Future.value(cached);
    }
    return _inFlight ??= _fetch();
  }

  static Future<ThermalReading> _fetch() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getThermal');
      final ThermalReading reading;
      if (res == null) {
        reading = const ThermalReading();
      } else {
        int? n(String key) => (res[key] as num?)?.toInt();
        final avail = n('memAvailBytes'), kernel = n('memAvailableKernelBytes');
        final cpuMs = n('appCpuMs'), uptimeMs = n('uptimeMs');
        reading = ThermalReading(
          batteryTempC: (res['batteryTempC'] as num?)?.toDouble(),
          thermalStatus: res['thermalStatus'] as String?,
          batteryCurrentUa: n('batteryCurrentUa'),
          batteryVoltageMv: n('batteryVoltageMv'),
          chargeCounterUah: n('chargeCounterUah'),
          isCharging: res['isCharging'] as bool?,
          isPlugged: res['isPlugged'] as bool?,
          thermalHeadroom: (res['thermalHeadroom'] as num?)?.toDouble(),
          cpuTempC: (res['cpuTempC'] as num?)?.toDouble(),
          gpuTempC: (res['gpuTempC'] as num?)?.toDouble(),
          memTotalBytes: n('memTotalBytes'),
          memFreeBytes: avail == null || kernel == null ? avail ?? kernel : min(avail, kernel),
          lowMemoryBytes: n('lowMemoryBytes'),
          appMemoryBytes: n('appRssBytes'),
          appCpuMs: cpuMs,
          uptimeMs: uptimeMs,
          cpuCount: n('cpuCount'),
          appCpuCores: _coresBusy(cpuMs, uptimeMs),
        );
      }
      _cached = reading;
      _cachedAt = now();
      return reading;
    } catch (e) {
      logSwallowed('thermal_read', e);
      // Cache the empty reading too: a failing channel should not be
      // re-hammered by every caller inside the same window.
      _cached = const ThermalReading();
      _cachedAt = now();
      return const ThermalReading();
    } finally {
      _inFlight = null;
    }
  }
}
