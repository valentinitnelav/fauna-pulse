// FaunaPulse (round 225): pause a long background job while the phone is warm.
//
// Shared by identification (BioCLIP embedding) and video analysis, which both
// run for minutes to hours. The battery temperature is the simplest heat
// signal every phone reports. Once it reaches the limit the job waits until it
// has dropped [thermalResumeGapC] below it. The gap ("hysteresis") keeps the
// job from flickering on and off right at the limit.

import 'app_error_hooks.dart';
import 'device_thermal.dart';

/// Reads the phone's thermal state (default: DeviceThermal.read).
typedef ThermalFn = Future<ThermalReading> Function();

/// Degrees below the limit at which a paused job resumes.
const thermalResumeGapC = 3.0;

/// What one [waitWhileWarm] call saw.
class ThermalWait {
  /// Last battery temperature read (null when the phone doesn't report it).
  final double? tempC;

  /// Whether the job had to pause.
  final bool paused;

  /// The last full reading, so a caller that also logs the phone's state
  /// does not read the sensors a second time (null when reading failed).
  final ThermalReading? reading;

  const ThermalWait(this.tempC, this.paused, [this.reading]);
}

/// Reads the temperature once; when it is at or above [limitC], waits in
/// [poll] steps until it is back below `limitC - thermalResumeGapC` (or
/// [isCancelled] says stop). [onPaused] fires before every wait with the
/// temperature and a plain-language note for the progress line. [onReading]
/// gets every reading, with whether the job waits after it. [sleep] replaces
/// the wait in tests. Never throws: a failing reading just lets the job
/// continue.
Future<ThermalWait> waitWhileWarm({
  required ThermalFn thermal,
  required double limitC,
  required Duration poll,
  bool Function()? isCancelled,
  void Function(double tempC, String note)? onPaused,
  void Function(ThermalReading reading, bool paused)? onReading,
  Future<void> Function(Duration)? sleep,
  String errorTag = 'thermal_pause',
}) async {
  double? temp;
  ThermalReading? reading;
  var paused = false;
  try {
    reading = await thermal();
    temp = reading.batteryTempC;
    final resumeC = limitC - thermalResumeGapC;
    paused = temp != null && temp >= limitC;
    onReading?.call(reading, paused);
    if (paused) {
      while (temp != null && temp > resumeC) {
        onPaused?.call(temp, 'Phone warm ($temp °C); resuming below ${resumeC.toStringAsFixed(0)} °C');
        await (sleep ?? Future<void>.delayed)(poll);
        if (isCancelled?.call() ?? false) break;
        reading = await thermal();
        temp = reading.batteryTempC;
        onReading?.call(reading, temp != null && temp > resumeC);
      }
    }
  } catch (e) {
    logSwallowed(errorTag, e);
  }
  return ThermalWait(temp, paused, reading);
}
