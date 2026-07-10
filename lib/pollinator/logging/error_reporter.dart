// Pollinator Monitor — error reporting.
//
// Builds a single, self-contained plain-text diagnostic report and saves it to a
// folder reachable over USB/adb, so a problem (e.g. an incompatible AI model that
// won't run) can be reviewed later or sent to the developer. The report bundles:
//   * app version + device / Android version,
//   * a short description of what went wrong (the "trigger") and any error text,
//   * the session settings in effect,
//   * the tail of the active session log (if any),
//   * this app's recent log output ("logcat", captured natively).
//
// "logcat" = the stream of log lines Android apps print while running; it usually
// contains the underlying stack trace when something fails.

import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/session_config.dart';

import 'app_error_hooks.dart';
import 'diagnostics.dart';

/// A saved error report on disk, plus its size for showing the user.
class ErrorReport {
  final File file;
  final int sizeBytes;
  const ErrorReport({required this.file, required this.sizeBytes});

  /// Size in human-readable units (e.g. "1.8 MB", "742 KB").
  String get humanSize {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (sizeBytes >= 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$sizeBytes B';
  }
}

class ErrorReporter {
  /// A public issue tracker link, shown in the report footer once a repository
  /// exists. Leave empty until then.
  static const String githubIssuesUrl =
      ''; // e.g. https://github.com/<you>/<repo>/issues

  /// Builds the report text and writes it to `error_reports/` under the app's
  /// external files directory (browsable over USB and pullable with `adb pull`).
  /// Returns the saved file and its size; never throws (best-effort sections).
  static Future<ErrorReport> build({
    required String trigger,
    String? userDescription,
    String? errorDetail,
    SessionConfig? config,
    File? sessionLog,
    int logcatLines = 3000,
    int sessionLogTailLines = 300,
  }) async {
    final now = DateTime.now();
    final b = StringBuffer();
    b.writeln('==== Pollinator Monitor — Error Report ====');
    b.writeln('Generated: ${now.toIso8601String()}');
    b.writeln('Trigger:   $trigger');
    b.writeln();

    // The user's own words come first — it's the most useful context for the
    // developer. Stored verbatim, including any markdown the user typed.
    if (userDescription != null && userDescription.trim().isNotEmpty) {
      b.writeln('-- What the user reported --');
      b.writeln(userDescription.trim());
      b.writeln();
    }

    b.writeln('-- App --');
    b.writeln(await _appInfo());
    b.writeln();

    b.writeln('-- Device --');
    b.writeln(await _deviceInfo());
    b.writeln();

    if (errorDetail != null && errorDetail.trim().isNotEmpty) {
      b.writeln('-- Error detail --');
      b.writeln(errorDetail.trim());
      b.writeln();
    }

    if (config != null) {
      b.writeln('-- Session settings --');
      b.writeln(const JsonEncoder.withIndent('  ').convert(config.toJson()));
      b.writeln();
    }

    if (sessionLog != null && sessionLog.existsSync()) {
      b.writeln(
        '-- Session log: ${sessionLog.path} '
        '(last $sessionLogTailLines lines) --',
      );
      b.writeln(await _tail(sessionLog, sessionLogTailLines));
      b.writeln();
    }

    b.writeln('-- Logcat (last $logcatLines app log lines) --');
    b.writeln(
      await Diagnostics.captureLogcat(maxLines: logcatLines) ??
          '(logcat unavailable on this platform)',
    );
    b.writeln();

    b.writeln('==== How to send this report ====');
    b.writeln(
      'Send this report to the developer using email or any messaging '
      'app of your choice (share it from the app, or copy it off the phone '
      'over USB).',
    );
    if (githubIssuesUrl.isNotEmpty) {
      b.writeln('Or open a GitHub issue: $githubIssuesUrl');
    }

    final dir = await _reportsDir();
    final stamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File('${dir.path}/report_$stamp.txt');
    await file.writeAsString(b.toString());
    final size = await file.length();
    return ErrorReport(file: file, sizeBytes: size);
  }

  /// Opens the OS share sheet (email, Drive, etc.) with the report attached.
  static Future<void> share(ErrorReport report) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(report.file.path)],
        subject: 'Pollinator Monitor error report',
        text: 'Pollinator Monitor error report attached.',
      ),
    );
  }

  /// All saved reports, newest first (for a "previous reports" list if wanted).
  static Future<List<File>> listReports() async {
    final dir = await _reportsDir();
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.txt'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  static Future<Directory> _reportsDir() async {
    Directory base;
    try {
      base =
          (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    } catch (e) {
      // Reports land in the internal dir instead (not browsable over USB).
      logSwallowed('reports_dir_external', e);
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/error_reports');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String> _appInfo() async {
    try {
      final p = await PackageInfo.fromPlatform();
      return 'App: ${p.appName} ${p.version} (build ${p.buildNumber})\n'
          'Package: ${p.packageName}';
    } catch (e) {
      return 'App info unavailable: $e';
    }
  }

  static Future<String> _deviceInfo() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return 'Model: ${a.manufacturer} ${a.model}\n'
            'Android: ${a.version.release} (SDK ${a.version.sdkInt})\n'
            'Device: ${a.device} / ${a.product}';
      }
      return 'Platform: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}';
    } catch (e) {
      return 'Device info unavailable: $e';
    }
  }

  /// Returns the last [lines] lines of [file] (so a big session log doesn't bloat
  /// the report). Reads the whole file but keeps only the tail.
  static Future<String> _tail(File file, int lines) async {
    try {
      final all = await file.readAsLines();
      if (all.length <= lines) return all.join('\n');
      return all.sublist(all.length - lines).join('\n');
    } catch (e) {
      return '(could not read session log: $e)';
    }
  }
}
