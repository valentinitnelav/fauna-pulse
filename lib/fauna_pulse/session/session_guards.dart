// FaunaPulse (round 296): when a recording must stop by itself to end cleanly.
//
// Idea from FaunaLapse (`Guards`): a session that runs until the battery is empty or the
// storage is full ends in the middle of a file, with no end record. Stopping a little
// earlier closes the log and any open video properly. Pure, so it is unit tested; the
// camera screen calls it on its temperature sampling cadence (every 10 s by default).

/// Why a recording should stop now, or null to go on.
/// - `low_battery`: the phone runs on its own battery (not plugged in, not charging) and the
///   level is at or below [lowBatteryPercent] (0 = never).
/// - `storage_low`: free storage is below [storageReserveMb] megabytes (at least 50
///   since round 319; SessionConfig clamps it).
/// Unknown readings (null) never stop a recording.
String? guardStopReason({
  required int? batteryPercent,
  required bool? isPlugged,
  required bool? isCharging,
  required int? freeBytes,
  required int lowBatteryPercent,
  required int storageReserveMb,
}) {
  final onBattery = isPlugged != true && isCharging != true;
  if (lowBatteryPercent > 0 && onBattery && batteryPercent != null && batteryPercent <= lowBatteryPercent) {
    return 'low_battery';
  }
  if (storageBelowReserve(freeBytes, storageReserveMb)) {
    return 'storage_low';
  }
  return null;
}

/// Round 319: whether free storage is below the "Keep free storage" reserve, so a
/// recording must not start (the guard above would stop it at once). Unknown (null)
/// readings never block.
bool storageBelowReserve(int? freeBytes, int storageReserveMb) =>
    storageReserveMb > 0 && freeBytes != null && freeBytes < storageReserveMb * 1024 * 1024;
