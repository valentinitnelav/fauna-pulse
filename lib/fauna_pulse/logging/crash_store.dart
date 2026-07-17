// FaunaPulse — persistent crash files.
//
// Uncaught errors were only routed into the ACTIVE session's JSONL (see
// app_error_hooks.dart), so a crash outside a recording — or a crash that
// killed the process before anything was written — left no trace a later
// error report could pick up. This store writes each uncaught error to its
// own small timestamped text file under `crashes/` in the app's external
// files directory (browsable over USB, same root as `error_reports/`), and
// the error report embeds the most recent ones automatically.
//
// The native (Kotlin) side writes the SAME file format into the SAME folder
// from its process-wide uncaught-exception handler (MainActivity.kt,
// `writeCrashFile` — keep the two in sync), so Java/Kotlin crashes that kill
// the app before Dart can react are captured too.
//
// File name: `crash_<yyyy-MM-dd>_<HHmmss>.txt` — a fixed-width LOCAL-time
// stamp (same convention as photo filenames), so a plain name sort is a time
// sort. The first line inside carries the full ISO-8601 timestamp with
// milliseconds.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class CrashStore {
  /// Newest crash files kept on disk; older ones are pruned after each write.
  static const int maxFiles = 20;

  /// At most one crash file per this interval — an error thrown every frame
  /// must not fill the folder with near-identical files.
  static const Duration writeInterval = Duration(seconds: 10);

  static int _lastWriteMs = 0;

  /// Redirects the store to a plain directory so unit tests never need the
  /// platform channels behind path_provider.
  @visibleForTesting
  static Directory? debugDirOverride;

  /// Resets the write rate-limiter so tests don't suppress each other.
  @visibleForTesting
  static void resetForTest() => _lastWriteMs = 0;

  /// Writes one crash file (rate-limited). Never throws — capturing a crash
  /// must not be able to cause another one. Returns the file, or null when
  /// rate-limited or the write failed.
  static Future<File?> record({
    required String source,
    required Object error,
    StackTrace? stack,
  }) async {
    try {
      final now = DateTime.now();
      if (now.millisecondsSinceEpoch - _lastWriteMs <
          writeInterval.inMilliseconds) {
        return null;
      }
      _lastWriteMs = now.millisecondsSinceEpoch;
      final dir = await _crashesDir();
      final file = File('${dir.path}/${crashFileName(now)}');
      await file.writeAsString(crashFileBody(now, source, error, stack));
      await _prune(dir);
      return file;
    } catch (_) {
      // Deliberately silent: this runs inside the global error handlers, so
      // routing the failure back through them could loop.
      return null;
    }
  }

  /// The newest crash files (name sort == time sort), at most [limit], no
  /// older than [within] — for embedding into an error report. Includes files
  /// written by the native handler. Returns empty on any failure.
  static Future<List<File>> recent({
    int limit = 3,
    Duration within = const Duration(days: 7),
  }) async {
    try {
      final dir = await _crashesDir();
      final cutoff = crashFileName(DateTime.now().subtract(within));
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => _isCrashFile(f) && _fileName(f).compareTo(cutoff) >= 0)
              .toList()
            ..sort((a, b) => _fileName(b).compareTo(_fileName(a)));
      return files.take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<Directory> _crashesDir() async {
    Directory base;
    final override = debugDirOverride;
    if (override != null) {
      base = override;
    } else {
      try {
        base =
            (await getExternalStorageDirectory()) ??
            await getApplicationDocumentsDirectory();
      } catch (_) {
        base = await getApplicationDocumentsDirectory();
      }
    }
    final dir = Directory('${base.path}/crashes');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Deletes everything past the newest [maxFiles] crash files.
  static Future<void> _prune(Directory dir) async {
    final files =
        dir.listSync().whereType<File>().where(_isCrashFile).toList()
          ..sort((a, b) => _fileName(b).compareTo(_fileName(a)));
    for (final f in files.skip(maxFiles)) {
      try {
        await f.delete();
      } catch (_) {
        // Best-effort; a stuck file just lingers until the next prune.
      }
    }
  }

  static String _fileName(File f) => f.uri.pathSegments.last;

  static bool _isCrashFile(File f) {
    final name = _fileName(f);
    return name.startsWith('crash_') && name.endsWith('.txt');
  }
}

/// `crash_<yyyy-MM-dd>_<HHmmss>.txt` for [when] (local time, fixed width).
String crashFileName(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'crash_${when.year}-${two(when.month)}-${two(when.day)}'
      '_${two(when.hour)}${two(when.minute)}${two(when.second)}.txt';
}

/// The crash file's text. Mirrored by `writeCrashFile` in MainActivity.kt —
/// keep the two in sync so reports read identically whichever side wrote it.
String crashFileBody(
  DateTime when,
  String source,
  Object error,
  StackTrace? stack,
) {
  final b = StringBuffer();
  b.writeln('Crash captured: ${when.toIso8601String()} (local time)');
  b.writeln('Source: $source');
  b.writeln('Error: $error');
  if (stack != null) {
    b.writeln('Stack:');
    b.writeln(stack.toString().trimRight());
  }
  return b.toString();
}
