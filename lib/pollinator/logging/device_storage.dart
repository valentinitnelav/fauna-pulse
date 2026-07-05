// Pollinator Monitor — free-storage reading.
//
// A field session writes JPEGs for hours; the one resource it can exhaust is
// disk space. This asks the native side (StatFs on the session volume) how
// much room is left so the recording screen can show it and the session log
// can record it alongside the thermal samples.

import 'package:flutter/services.dart';

/// One free-storage sample. All-null when the platform gave us nothing
/// (e.g. running on a platform without the channel) — the UI hides itself.
class StorageReading {
  final int? freeBytes;
  final int? totalBytes;

  const StorageReading({this.freeBytes, this.totalBytes});

  static const double _bytesPerGb = 1024 * 1024 * 1024;

  double? get freeGb => freeBytes == null ? null : freeBytes! / _bytesPerGb;

  /// Below this the readout carries a warning marker: at typical ROI-photo
  /// sizes this is hours of session left, i.e. "clean up before you mount
  /// the phone", not yet an emergency.
  static const double lowGb = 1.0;

  bool get isLow => freeGb != null && freeGb! < lowGb;

  /// Status-line text, e.g. `Storage free: 12.4 GB`. Always GB with one
  /// decimal — the unit never silently switches scale. Empty when unknown.
  String get label {
    final gb = freeGb;
    if (gb == null) return '';
    final text = 'Storage free: ${gb.toStringAsFixed(1)} GB';
    return isLow ? '⚠ $text' : text;
  }

  /// Log fields, merged into `start_of_session` / `thermal` records.
  Map<String, dynamic> toJson() => {
    'free_storage_bytes': freeBytes,
    'total_storage_bytes': totalBytes,
  };
}

class DeviceStorage {
  // Same channel as DeviceThermal: both are one-shot device-stat reads.
  static const MethodChannel _channel = MethodChannel('pollinator/thermal');

  /// Reads free/total bytes of the volume holding [path] (null = the app's
  /// external-files dir, where sessions are saved). Never throws.
  static Future<StorageReading> read({String? path}) async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'getFreeStorage',
        {'path': path},
      );
      return StorageReading(
        freeBytes: (map?['freeBytes'] as num?)?.toInt(),
        totalBytes: (map?['totalBytes'] as num?)?.toInt(),
      );
    } catch (_) {
      return const StorageReading();
    }
  }
}
