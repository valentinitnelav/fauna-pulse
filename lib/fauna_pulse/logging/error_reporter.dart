// FaunaPulse — error reporting.
//
// Builds a single, self-contained plain-text diagnostic report and saves it to a
// folder reachable over USB/adb, so a problem (e.g. an incompatible AI model that
// won't run) can be reviewed later or sent to the developer. The report bundles:
//   * app version + device / Android version,
//   * a short description of what went wrong (the "trigger") and any error text,
//   * the most recent saved crash files (see crash_store.dart),
//   * the session settings in effect,
//   * a head + tail sample of the latest session log (if any),
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
import 'package:shared_preferences/shared_preferences.dart';

import '../models/session_config.dart';

import 'app_error_hooks.dart';
import 'crash_store.dart';
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

  /// Where the "Email…" button sends reports. Deliberately empty by default —
  /// the address is handed to testers privately, never shipped in the app —
  /// and stored app-wide (shared_preferences), NOT in SessionConfig, so it can
  /// never leak into a session.jsonl start record that gets shared.
  static const String _recipientEmailPrefsKey = 'report_recipient_email';

  /// Builds the report text and writes it to `error_reports/` under the app's
  /// external files directory (browsable over USB and pullable with `adb pull`).
  /// Returns the saved file and its size; never throws (best-effort sections).
  static Future<ErrorReport> build({
    required String trigger,
    String? userDescription,
    String? errorDetail,
    SessionConfig? config,
    File? sessionLog,
    int logcatLines = 2000,
    int sessionLogHeadLines = 30,
    int sessionLogTailLines = 200,
  }) async {
    final now = DateTime.now();
    final b = StringBuffer();
    b.writeln('==== FaunaPulse — Error Report ====');
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

    // Crash files persist across restarts (crash_store.dart + the Kotlin
    // handler), so a report made AFTER a crash still carries its trace —
    // the user never has to find or attach anything by hand.
    final crashes = await CrashStore.recent();
    if (crashes.isNotEmpty) {
      b.writeln(
        '-- Recent crashes (${crashes.length} saved in the last 7 days) --',
      );
      for (final f in crashes) {
        b.writeln('--- ${f.uri.pathSegments.last} ---');
        b.writeln(await _crashFileText(f));
      }
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
        '(first $sessionLogHeadLines + last $sessionLogTailLines lines) --',
      );
      b.writeln(
        await _sampledLog(sessionLog, sessionLogHeadLines, sessionLogTailLines),
      );
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
    final recipient = await loadRecipientEmail();
    if (recipient.isNotEmpty) {
      b.writeln('Send this file to: $recipient');
    }
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
        subject: 'FaunaPulse error report',
        text: 'FaunaPulse error report attached.',
      ),
    );
  }

  /// Opens an email app with the recipient, subject and the report already
  /// attached (share_plus cannot pre-fill a recipient, so this goes through
  /// the native `sendEmail` — see diagnostics.dart). Returns false when no
  /// email app could be opened.
  static Future<bool> emailTo(ErrorReport report, String recipient) async {
    return Diagnostics.sendEmail(
      path: report.file.path,
      to: recipient.trim(),
      subject: 'FaunaPulse error report',
      body: 'FaunaPulse error report attached.',
    );
  }

  /// The saved "send reports to" address ('' when not set yet).
  static Future<String> loadRecipientEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_recipientEmailPrefsKey)?.trim() ?? '';
    } catch (e) {
      logSwallowed('report_email_load', e);
      return '';
    }
  }

  /// Persists the "send reports to" address so it only has to be typed once.
  static Future<void> saveRecipientEmail(String email) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_recipientEmailPrefsKey, email.trim());
    } catch (e) {
      logSwallowed('report_email_save', e);
    }
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

  /// A head + tail sample of [file] (so a big session log doesn't bloat the
  /// report): the first lines carry the start-record metadata, the last ones
  /// the failure-time context. Reads the whole file but keeps only the sample.
  static Future<String> _sampledLog(File file, int head, int tail) async {
    try {
      return headTailSample(await file.readAsLines(), head: head, tail: tail);
    } catch (e) {
      return '(could not read session log: $e)';
    }
  }

  /// A crash file's content, capped so a report never balloons on one file.
  static Future<String> _crashFileText(File file, {int maxLines = 200}) async {
    try {
      return headTailSample(await file.readAsLines(), head: maxLines, tail: 0);
    } catch (e) {
      return '(could not read crash file: $e)';
    }
  }
}

/// Joins [lines] keeping only the first [head] and last [tail], with an
/// `… N lines omitted …` marker in between. Every kept line is additionally
/// capped at [maxLineChars] (a single `raw_detections` record can be huge).
String headTailSample(
  List<String> lines, {
  required int head,
  required int tail,
  int maxLineChars = 2000,
}) {
  String cap(String l) => l.length <= maxLineChars
      ? l
      : '${l.substring(0, maxLineChars)}…[truncated]';
  if (lines.length <= head + tail) return lines.map(cap).join('\n');
  return [
    ...lines.take(head).map(cap),
    '… ${lines.length - head - tail} lines omitted …',
    ...lines.sublist(lines.length - tail).map(cap),
  ].join('\n');
}
