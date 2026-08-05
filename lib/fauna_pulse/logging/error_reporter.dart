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

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/session_config.dart';

import 'app_error_hooks.dart';
import 'crash_store.dart';
import 'report_bundle.dart';
import 'diagnostics.dart';

/// A saved error report on disk, plus its size for showing the user.
class ErrorReport {
  final File file;
  final int sizeBytes;

  /// Screenshot copies saved next to the .txt (round 190).
  final List<File> attachments;

  /// The single shareable bundle (round 191): .txt + screenshots + sampled
  /// session files, zipped. Built whenever the report has more than the bare
  /// .txt — sharing several files of mixed types made some targets (the
  /// owner's WhatsApp test) drop ALL attachments, so Share always sends
  /// either the .txt alone or this one zip. Null when nothing else exists
  /// or zipping failed.
  final File? bundleZip;

  /// Zip member names beyond the .txt itself (screenshots + samples) — for
  /// the saved-dialog summary.
  final List<String> bundledNames;

  const ErrorReport({
    required this.file,
    required this.sizeBytes,
    this.attachments = const [],
    this.bundleZip,
    this.bundledNames = const [],
  });

  /// What Share actually sends: the bundle when one exists, else the .txt.
  File get shareFile => bundleZip ?? file;

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
  /// A public issue tracker link, shown in the report footer. Leave empty to
  /// omit the "Or open a GitHub issue" line from generated reports.
  static const String githubIssuesUrl =
      'https://github.com/valentinitnelav/fauna-pulse/issues';

  /// The public project repository, linked from the home screen's About
  /// dialog (round 183).
  static const String githubRepoUrl =
      'https://github.com/valentinitnelav/fauna-pulse';

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
    List<String> attachmentPaths = const [],
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

    // Round 190: email is deliberately NOT suggested (owner decision — no
    // mail-server load); the issue tracker leads, the share sheet / USB copy
    // follow. The dormant email plumbing (emailTo + the recipient pref)
    // stays in code for a possible later revival.
    b.writeln('==== How to send this report ====');
    if (githubIssuesUrl.isNotEmpty) {
      b.writeln(
        'Open a GitHub issue and paste this report\'s text (attach the '
        'screenshots if any): $githubIssuesUrl',
      );
    }
    b.writeln(
      'Or share it from the app with any messaging app of your choice, '
      'or copy it off the phone over USB.',
    );

    final dir = await _reportsDir();
    final stamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File('${dir.path}/report_$stamp.txt');

    // Screenshot attachments (round 190): the picker hands out temp-cache
    // copies that expire, so each is copied NOW into error_reports/ (the only
    // folder the report FileProvider serves) next to the .txt, sharing its
    // stamp. Failures are logged and skipped — the report itself must never
    // fail because a screenshot did.
    final attachments = <File>[];
    for (var i = 0; i < attachmentPaths.length; i++) {
      try {
        final src = File(attachmentPaths[i]);
        if (!src.existsSync()) continue;
        final dotExt = attachmentPaths[i].contains('.')
            ? attachmentPaths[i].substring(attachmentPaths[i].lastIndexOf('.'))
            : '.jpg';
        final copy = await src.copy(
          '${dir.path}/report_${stamp}_screenshot${i + 1}$dotExt',
        );
        attachments.add(copy);
      } catch (e) {
        logSwallowed('report_attach_copy', e);
      }
    }
    if (attachments.isNotEmpty) {
      b.writeln();
      b.writeln('-- Attached screenshots (${attachments.length}) --');
      for (final f in attachments) {
        b.writeln(f.uri.pathSegments.last);
      }
    }

    // Sampled session files (round 191): when the report is about a session,
    // its saved logcats / event records / analysis-run summaries travel as
    // separate bundle members — sampled, so a multi-hour session still
    // yields a small report (see report_bundle.dart for what is kept).
    final extras = sessionLog != null && sessionLog.existsSync()
        ? await collectSessionExtras(sessionLog.parent)
        : const <ReportExtra>[];
    if (extras.isNotEmpty) {
      b.writeln();
      b.writeln('-- Bundled session file samples (${extras.length}) --');
      for (final e in extras) {
        b.writeln(e.name);
      }
    }

    await file.writeAsString(b.toString());
    final size = await file.length();

    // One shareable file (round 191): zip whenever anything beyond the bare
    // .txt exists. On failure the report still stands — Share then sends
    // the .txt alone (screenshots stay on disk next to it).
    File? zip;
    if (attachments.isNotEmpty || extras.isNotEmpty) {
      zip = await writeReportZip(
        File('${dir.path}/report_$stamp.zip'),
        reportTxt: file,
        screenshots: attachments,
        extras: extras,
      );
    }
    return ErrorReport(
      file: file,
      sizeBytes: size,
      attachments: attachments,
      bundleZip: zip,
      bundledNames: [
        for (final f in attachments) f.uri.pathSegments.last,
        for (final e in extras) e.name,
      ],
    );
  }

  /// Opens the OS share sheet (email, Drive, etc.) with the report attached.
  static Future<void> share(ErrorReport report) async {
    // ONE file, always (round 191): the r190 multi-file share (.txt +
    // images) made WhatsApp deliver only the caption with every attachment
    // dropped (owner field test) — mixed MIME types are the suspect. The
    // bundle zip (or the bare .txt when there is nothing else) is a single
    // attachment of a single type, which every target handles.
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(report.shareFile.path)],
        subject: 'FaunaPulse error report',
        text: 'FaunaPulse error report attached.',
      ),
    );
  }

  /// DORMANT since round 190 (owner decision: don't encourage emailed
  /// reports — mail-server load). No UI calls this anymore; kept, with the
  /// recipient-email prefs pair below, in case a direct-email channel is
  /// revived later. Opens an email app with the recipient, subject and the
  /// report already attached (share_plus cannot pre-fill a recipient, so
  /// this goes through the native `sendEmail` — see diagnostics.dart).
  /// Returns false when no email app could be opened. Note it attaches only
  /// the .txt — a revival must extend the native intent for the round-190
  /// screenshot attachments.
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

  /// Redirects reports to a plain directory so unit tests never need the
  /// platform channels behind path_provider (same pattern as CrashStore).
  @visibleForTesting
  static Directory? debugDirOverride;

  static Future<Directory> _reportsDir() async {
    Directory base;
    final override = debugDirOverride;
    if (override != null) {
      base = override;
    } else {
      try {
        base =
            (await getExternalStorageDirectory()) ??
            await getApplicationDocumentsDirectory();
      } catch (e) {
        // Reports land in the internal dir instead (not browsable over USB).
        logSwallowed('reports_dir_external', e);
        base = await getApplicationDocumentsDirectory();
      }
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
  /// the failure-time context. Bounded read (round 162, perf review E5): only
  /// a head chunk and a tail chunk are read — the old whole-file
  /// `readAsLines()` held a potentially huge log in memory at exactly the
  /// moment things had already gone wrong.
  /// The session's GPS `location` (round 126) is stripped from the sample —
  /// field-site coordinates (possibly of protected species) must never ride
  /// along in a report shared by email. Redaction runs only on RETAINED lines.
  static Future<String> _sampledLog(File file, int head, int tail) async {
    try {
      return await boundedHeadTailSample(
        file,
        head: head,
        tail: tail,
        redact: redactLocation,
      );
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

/// Replaces the `location` block of a start_of_session JSONL line with a
/// `"location":"[redacted]"` marker (round 126). Lines without one — or that
/// fail to parse — pass through unchanged; a redaction failure must never
/// break a problem report.
String redactLocation(String line) {
  if (!line.contains('"location"')) return line;
  try {
    final obj = jsonDecode(line);
    if (obj is! Map<String, dynamic> || !obj.containsKey('location')) {
      return line;
    }
    obj['location'] = '[redacted]';
    return jsonEncode(obj);
  } catch (_) {
    return line;
  }
}

/// Bounded head+tail sample of a possibly huge file (round 162, perf review
/// E5). Reads at most [headBytes] + [tailBytes] from disk instead of the whole
/// file, following the `_loadStats()` pattern in the summary screen. Chunk
/// boundaries cut lines, so the trailing partial line of the head chunk and
/// the leading partial line of the tail chunk are dropped; [redact] (e.g.
/// [redactLocation]) runs only on lines that are actually kept. Small files
/// (length within the two chunk budgets) go through [headTailSample]
/// unchanged, marker and all.
Future<String> boundedHeadTailSample(
  File file, {
  required int head,
  required int tail,
  String Function(String line)? redact,
  int maxLineChars = 2000,
  int headBytes = 128 * 1024,
  int tailBytes = 512 * 1024,
}) async {
  String keep(String line) {
    final r = redact == null ? line : redact(line);
    return r.length <= maxLineChars
        ? r
        : '${r.substring(0, maxLineChars)}…[truncated]';
  }

  final raf = await file.open();
  try {
    final len = await raf.length();
    if (len <= headBytes + tailBytes) {
      final all = utf8.decode(await raf.read(len), allowMalformed: true);
      final lines = const LineSplitter().convert(all);
      final redacted = redact == null ? lines : lines.map(redact).toList();
      return headTailSample(
        redacted,
        head: head,
        tail: tail,
        maxLineChars: maxLineChars,
      );
    }

    // Head chunk: keep only complete lines (drop the trailing partial one —
    // the byte boundary almost certainly cut it mid-record).
    final headChunk = utf8.decode(
      await raf.read(headBytes),
      allowMalformed: true,
    );
    var headLines = const LineSplitter().convert(headChunk);
    if (!headChunk.endsWith('\n') && headLines.isNotEmpty) {
      headLines = headLines.sublist(0, headLines.length - 1);
    }

    // Tail chunk: drop the leading partial line (start after the first '\n').
    await raf.setPosition(len - tailBytes);
    final tailChunk = utf8.decode(
      await raf.read(tailBytes),
      allowMalformed: true,
    );
    final firstNewline = tailChunk.indexOf('\n');
    final tailLines = firstNewline < 0
        ? <String>[]
        : const LineSplitter().convert(tailChunk.substring(firstNewline + 1));

    final keptHead = headLines.take(head).map(keep);
    final keptTail = (tailLines.length <= tail
            ? tailLines
            : tailLines.sublist(tailLines.length - tail))
        .map(keep);
    // The total line count is unknown without reading the middle, so the
    // marker reports the file size instead of an exact omitted-line count.
    final marker =
        '… middle omitted (log is ${(len / (1024 * 1024)).toStringAsFixed(1)} MB; '
        'first $head + last $tail lines sampled) …';
    return [...keptHead, marker, ...keptTail].join('\n');
  } finally {
    await raf.close();
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
