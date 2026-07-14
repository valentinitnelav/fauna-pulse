// FaunaPulse — free-storage reading.
//
// A field session writes JPEGs for hours; the one resource it can exhaust is
// disk space. This asks the native side (StatFs on the session volume) how
// much room is left so the recording screen can show it and the session log
// can record it alongside the thermal samples.

import 'dart:io';

import 'package:flutter/services.dart';

import 'app_error_hooks.dart';

/// Total size in bytes of everything inside a session folder (the log, the
/// captured JPEGs, diagnostic logcat files). Only file *metadata* is read —
/// never file contents — so this stays quick even for a photo-heavy session
/// with thousands of images. Shared by the home history list and the session
/// summary so both always show the same number.
Future<int> folderSizeBytes(Directory dir) async {
  var total = 0;
  try {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
  } catch (e) {
    // A vanished file mid-scan just yields a slightly-off total.
    logSwallowed('session_size_scan', e);
  }
  return total;
}

/// Formats a byte count with the unit that fits its magnitude — "412 KB",
/// "8.3 MB", "1.2 GB" — so a log-only session and a multi-gigabyte
/// photo-heavy one both read naturally (same 1024-based convention as the
/// problem-report size).
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

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
  static const MethodChannel _channel = MethodChannel('faunapulse/thermal');

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
    } catch (e) {
      // Polled periodically while recording; the trace is rate-limited.
      logSwallowed('storage_read', e);
      return const StorageReading();
    }
  }
}
