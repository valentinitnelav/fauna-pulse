// FaunaPulse — free-storage reading.
//
// A field session writes JPEGs for hours; the one resource it can exhaust is
// disk space. This asks the native side (StatFs on the session volume) how
// much room is left so the recording screen can show it and the session log
// can record it alongside the thermal samples.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_error_hooks.dart';

/// Total size in bytes of everything inside a session folder (the log, the
/// captured JPEGs, diagnostic logcat files). Only file *metadata* is read,
/// never file contents. Shared by the session lists and the session summary
/// so both always show the same number. Null when the folder cannot be
/// listed (deleted meanwhile).
Future<int?> folderSizeBytes(Directory dir) async => (await folderSizesBytes([dir]))[dir.path];

/// The sizes of several folders in one hop to a helper isolate (round 349,
/// perf review H2). The walk used to await the length of every file on the
/// UI isolate, one round trip to the I/O thread each: about 0.14 ms per file
/// on a Xiaomi 11T Pro, so a 5,000-photo session cost 0.7 s on every visit of
/// Home or Sessions. Keys are the folder paths; a folder that cannot be
/// listed has no entry. A file that vanishes mid-walk gives a slightly-off
/// total.
Future<Map<String, int>> folderSizesBytes(Iterable<Directory> dirs) async {
  final paths = [for (final d in dirs) d.path];
  if (paths.isEmpty) return const {};
  try {
    final walk = await Isolate.run(() => _walkFolderSizes(paths));
    if (walk.error != null) logSwallowed('session_size_scan', walk.error!);
    if (kDebugMode) {
      debugPrint('session_sizes: ${paths.length} folders, ${walk.files} files, ${walk.ms} ms');
    }
    return walk.sizes;
  } catch (e) {
    // The helper isolate could not run: the sizes stay unknown.
    logSwallowed('session_size_scan', e);
    return const {};
  }
}

/// The walk itself, on the helper isolate: sync calls only, so each file is
/// one stat and not one round trip. A folder that cannot be listed is left
/// out; a file or subfolder that fails mid-walk is skipped and the first such
/// error is reported.
({Map<String, int> sizes, int files, int ms, String? error}) _walkFolderSizes(List<String> paths) {
  final sw = Stopwatch()..start();
  final sizes = <String, int>{};
  var files = 0;
  String? error;
  for (final path in paths) {
    final List<FileSystemEntity> top;
    try {
      top = Directory(path).listSync(followLinks: false);
    } catch (e) {
      error ??= '$e';
      continue;
    }
    var total = 0;
    final pending = [top];
    while (pending.isNotEmpty) {
      for (final e in pending.removeLast()) {
        try {
          if (e is File) {
            total += e.lengthSync();
            files++;
          } else if (e is Directory) {
            pending.add(e.listSync(followLinks: false));
          }
        } catch (err) {
          error ??= '$err';
        }
      }
    }
    sizes[path] = total;
  }
  return (sizes: sizes, files: files, ms: sw.elapsedMilliseconds, error: error);
}

/// Formats a byte count with the unit that fits its magnitude — "412 KB",
/// "8.3 MB", "1.2 GB" — so a log-only session and a multi-gigabyte
/// photo-heavy one both read naturally (same 1024-based convention as the
/// problem-report size). [unitOf]: use the unit that fits this other number
/// instead, so two sizes in one sentence share one unit (round 319: never
/// "needs 1.2 GB, but only 765.2 MB is free").
String formatBytes(int bytes, {int? unitOf}) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  final unit = unitOf ?? bytes;
  if (unit >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (unit >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (unit >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// "only 0.7 GB is free", or "almost no storage is free" when the number in
/// the unit of [unitOf] would read 0.0.
String freeStorageClause(int freeBytes, {required int unitOf}) {
  final free = formatBytes(freeBytes, unitOf: unitOf);
  return free.startsWith('0.0 ') ? 'almost no storage is free' : 'only $free is free';
}

/// [bytes] in MB, for a sentence that also names a setting in MB ("Keep
/// free storage"). Whole MB like the setting; rounded down, so 4999.6 MB never
/// reads as "5000 MB free, but ... needs at least 5000 MB".
String formatMegabytes(int bytes) => '${bytes ~/ (1024 * 1024)} MB';

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
