// FaunaPulse: feedback reports ("Send feedback" in the Home menu).
//
// Builds one self-contained plain-text report and saves it in the app's internal storage (not
// reachable over USB), then zips it with the tester's screenshots, so feedback can be sent by
// email or shared. The report bundles:
//   * a report ID, app version + device / Android version,
//   * the tester's own words and what triggered the report (and any error text),
//   * the most recent saved crash files (see crash_store.dart),
//   * the session settings in effect,
//   * sampled files of one chosen session (see report_bundle.dart),
//   * this app's recent log output ("logcat", captured natively).
//
// "logcat" = the stream of log lines Android apps print while running; it usually
// contains the underlying stack trace when something fails.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/session_config.dart';

import 'app_error_hooks.dart';
import 'crash_store.dart';
import 'report_bundle.dart';
import 'diagnostics.dart';

/// A saved feedback report on disk: the .txt, the screenshot copies and the one zip that is
/// sent.
class ErrorReport {
  final File file;

  /// Size of [shareFile], the file that is sent.
  final int sizeBytes;

  /// Six letters or digits, in the .txt header and the email subject: it tells two emails
  /// apart and lets a reply name the report.
  final String id;

  /// The app's `version+build`, for example `0.12.0-beta.1+17` ('unknown' when unreadable).
  final String appVersion;

  /// Screenshot copies saved next to the .txt, as they are in the zip.
  final List<File> attachments;

  /// The one file that is sent: .txt + screenshots + sampled session files, zipped. One file
  /// of one type, because sharing several files of mixed types made some apps (WhatsApp in
  /// the owner's test) drop every attachment. Null only when zipping failed: then the .txt
  /// alone is sent.
  final File? bundleZip;

  /// Zip member names beyond the .txt itself (screenshots + samples).
  final List<String> bundledNames;

  /// What was left out to keep the zip small enough for an email, as a sentence; null when
  /// nothing was.
  final String? leftOut;

  const ErrorReport({
    required this.file,
    required this.sizeBytes,
    required this.id,
    required this.appVersion,
    this.attachments = const [],
    this.bundleZip,
    this.bundledNames = const [],
    this.leftOut,
  });

  /// What is sent: the bundle, or the .txt when zipping failed.
  File get shareFile => bundleZip ?? file;

  String get subject => ErrorReporter.feedbackSubject(appVersion, id);

  /// The email text: the tester's own words first (so they can be read on a phone without
  /// opening the zip), then one line on what is attached.
  String messageText(String userText) {
    final shots = attachments.length;
    final String attached;
    if (bundleZip == null) {
      attached = "Attached: a text file with the app's technical details ($humanSize).";
    } else {
      final pictures = shots == 0 ? '' : '$shots screenshot${shots == 1 ? '' : 's'} and ';
      attached = "Attached: one zip file with ${pictures}the app's technical details ($humanSize).";
    }
    return [
      if (userText.trim().isNotEmpty) userText.trim(),
      '($attached${leftOut == null ? '' : ' $leftOut'})',
    ].join('\n\n');
  }

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
  /// Where feedback goes: the tester's own email app sends it there ([email]). Public on
  /// purpose (it is also the Google Play contact and is named in the README and the privacy
  /// policy), so it is written here, once. FaunaLapse sends to it too.
  static const String feedbackEmail = 'biodiv.pulse@gmail.com';

  /// The public issue tracker, named in the report's footer for people who use GitHub.
  static const String githubIssuesUrl =
      'https://github.com/valentinitnelav/fauna-pulse/issues';

  /// The public project repository, linked from the home screen's About
  /// dialog (round 183).
  static const String githubRepoUrl =
      'https://github.com/valentinitnelav/fauna-pulse';

  /// The privacy policy, opened from the home screen's Menu. Google Play's
  /// User Data policy asks for a privacy policy link inside the app, not
  /// only in the store listing. It points at main, the released version:
  /// develop can hold policy text for changes not released yet.
  static const String privacyPolicyUrl =
      '$githubRepoUrl/blob/main/PRIVACY_POLICY.md';

  /// Largest zip [build] makes. Gmail sends emails of up to 25 MB, other services less, and
  /// an email grows by about a third on its way (attachments travel as text).
  static const int maxZipBytes = 20 * 1024 * 1024;

  /// Room kept for the .txt when the zip is planned (its logcat and crash parts are text,
  /// which a zip makes several times smaller).
  static const int _txtAllowanceBytes = 1024 * 1024;

  /// Report files older than this are deleted when a new report is made: no screen opens
  /// them again, and an email app that waited for a network has sent them by then.
  static const Duration _keepReportsFor = Duration(days: 14);

  /// The email subject. Feedback emails are sorted by its start, so keep "FaunaPulse
  /// feedback" exact (FaunaLapse writes "FaunaLapse feedback").
  static String feedbackSubject(String appVersion, String id) => 'FaunaPulse feedback $appVersion $id';

  /// No 0/O and no 1/I: a person may read the ID out or type it into a reply.
  static const _idLetters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  @visibleForTesting
  static String newReportId([Random? random]) {
    final r = random ?? Random.secure();
    return String.fromCharCodes([for (var i = 0; i < 6; i++) _idLetters.codeUnitAt(r.nextInt(_idLetters.length))]);
  }

  /// Builds the report text and the zip in `error_reports/` under the app's internal support
  /// directory (the only folder the report FileProvider serves; not reachable over USB).
  /// Never throws for a failing part (each part is best-effort).
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
    int zipLimitBytes = maxZipBytes,
  }) async {
    final now = DateTime.now();
    final id = newReportId();
    final version = await _appVersion();
    final dir = await _reportsDir();
    await _deleteOldReports(dir, now);
    final stamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final base = '${dir.path}/feedback_${stamp}_$id';

    // Screenshots: the picker hands out temp-cache copies that expire, so each is copied NOW,
    // as a JPEG of limited size where it was not one ([feedbackScreenshotJpeg]). A failing
    // screenshot is logged and skipped: the report itself must never fail because of one.
    var attachments = <File>[];
    for (var i = 0; i < attachmentPaths.length; i++) {
      try {
        final src = File(attachmentPaths[i]);
        if (!src.existsSync()) continue;
        final picked = await src.readAsBytes();
        final bytes = await compute(feedbackScreenshotJpeg, picked) ?? picked;
        final copy = File('${base}_screenshot${i + 1}${pictureExtension(bytes, src.path)}');
        await copy.writeAsBytes(bytes, flush: true);
        attachments.add(copy);
      } catch (e) {
        logSwallowed('report_attach_copy', e);
      }
    }

    // Sampled session files: its event records, saved logcats and analysis-run summaries
    // travel as zip members (report_bundle.dart says what is kept).
    final log = sessionLog != null && sessionLog.existsSync() ? sessionLog : null;
    var extras = log != null ? await collectSessionExtras(log.parent) : const <ReportExtra>[];

    // Below [zipLimitBytes]: the session samples go first, then screenshots from the end.
    // Planned from the sizes before zipping, which is an upper bound (text shrinks in a zip,
    // JPEGs do not).
    var room = zipLimitBytes - _txtAllowanceBytes;
    final leftOutParts = <String>[];
    final shotSizes = [for (final f in attachments) f.lengthSync()];
    final samplesSize = extras.fold<int>(0, (sum, e) => sum + e.content.length);
    if (extras.isNotEmpty && samplesSize + shotSizes.fold<int>(0, (a, b) => a + b) > room) {
      extras = const [];
      leftOutParts.add('the session files');
    } else {
      room -= samplesSize;
    }
    var keep = 0;
    while (keep < attachments.length && shotSizes[keep] <= room) {
      room -= shotSizes[keep++];
    }
    if (keep < attachments.length) {
      for (final f in attachments.sublist(keep)) {
        _deleteQuietly(f);
      }
      final n = attachments.length - keep;
      leftOutParts.add('$n screenshot${n == 1 ? '' : 's'}');
      attachments = attachments.sublist(0, keep);
    }
    final leftOut = leftOutParts.isEmpty
        ? null
        : 'Left out to keep the email below ${zipLimitBytes ~/ (1024 * 1024)} MB: '
              '${leftOutParts.join(' and ')}.';

    final b = StringBuffer();
    b.writeln('==== FaunaPulse feedback ====');
    b.writeln('Report ID: $id');
    b.writeln('Version:   $version');
    b.writeln('Generated: ${now.toIso8601String()}');
    b.writeln('Trigger:   $trigger');
    b.writeln();

    // The user's own words come first: the most useful context for the developer.
    if (userDescription != null && userDescription.trim().isNotEmpty) {
      b.writeln('-- What the user wrote --');
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

    // With samples in the zip the .txt only points at them; without (none found, or left out
    // for size) it carries a head + tail excerpt of the log itself.
    if (log != null) {
      if (extras.isNotEmpty) {
        b.writeln('-- Session data: ${log.parent.path} --');
        b.writeln(
          'Sampled files from this session travel as separate members of '
          'the report zip (list at the end of this report).',
        );
        b.writeln();
      } else {
        b.writeln(
          '-- Session log: ${log.path} '
          '(first $sessionLogHeadLines + last $sessionLogTailLines lines) --',
        );
        b.writeln(
          await _sampledLog(
            log,
            sessionLogHeadLines,
            sessionLogTailLines,
          ),
        );
        b.writeln();
      }
    }

    // Live logcat of the current app run. Round 192: the pure CameraX noise
    // line is filtered out (it was most of the capture on the test device);
    // PERF/FRAMEPERF stay — with "No session data" chosen they are the
    // report's only performance record.
    b.writeln(
      '-- Logcat (last $logcatLines app log lines; camera noise removed) --',
    );
    final liveLogcat = await Diagnostics.captureLogcat(maxLines: logcatLines);
    b.writeln(
      liveLogcat == null
          ? '(logcat unavailable on this platform)'
          : liveLogcat.split('\n').where(keepLiveLogcatLine).join('\n'),
    );
    b.writeln();

    // For a person who got this file another way (Share another way, for example a colleague
    // in a messaging app). Reports live in internal app storage, so there is no USB copy.
    b.writeln('==== How to send this report ====');
    b.writeln('Please send this file by email to $feedbackEmail.');
    b.writeln(
      'Or open a GitHub issue and paste its text (issues are public, so '
      'read it first): $githubIssuesUrl',
    );

    if (attachments.isNotEmpty) {
      b.writeln();
      b.writeln('-- Attached screenshots (${attachments.length}) --');
      for (final f in attachments) {
        b.writeln(f.uri.pathSegments.last);
      }
    }

    if (extras.isNotEmpty) {
      b.writeln();
      b.writeln('-- Bundled session file samples (${extras.length}) --');
      for (final e in extras) {
        b.writeln(e.name);
      }
    }

    if (leftOut != null) {
      b.writeln();
      b.writeln(leftOut);
    }

    final file = File('$base.txt');
    await file.writeAsString(b.toString());

    // On failure the report still stands: the .txt alone is sent (screenshots stay on disk
    // next to it).
    final zip = await writeReportZip(
      File('$base.zip'),
      reportTxt: file,
      screenshots: attachments,
      extras: extras,
    );
    // Round 192: if zipping failed, the shared .txt would carry NO session
    // data (its body only points at the zip members) — append the classic
    // embedded log excerpt so the fallback file stays self-sufficient.
    if (zip == null && extras.isNotEmpty && log != null) {
      final fb = StringBuffer()
        ..writeln()
        ..writeln(
          '-- Session log (bundle zip failed; embedded fallback): '
          '${log.path} '
          '(first $sessionLogHeadLines + last $sessionLogTailLines lines) --',
        )
        ..writeln(
          await _sampledLog(
            log,
            sessionLogHeadLines,
            sessionLogTailLines,
          ),
        );
      await file.writeAsString(fb.toString(), mode: FileMode.append);
    }
    return ErrorReport(
      file: file,
      sizeBytes: await (zip ?? file).length(),
      id: id,
      appVersion: version,
      attachments: attachments,
      bundleZip: zip,
      bundledNames: [
        for (final f in attachments) f.uri.pathSegments.last,
        for (final e in extras) e.name,
      ],
      leftOut: leftOut,
    );
  }

  /// The text the user typed and did not send yet (round 362), '' when there is none.
  /// The feedback screen used to lose the text without a word when the user left it by
  /// mistake (Back, X, Home), or when Android closed the app while they picked screenshots in
  /// the photo picker. It stays until [email] or [share] hands the report to another app.
  /// Kept in a file of the reports folder, not in the saved settings: those go into Android's
  /// backup, and a user's free text should not.
  static Future<String> loadDraft() async {
    try {
      final f = await _draftFile();
      return await f.exists() ? await f.readAsString() : '';
    } catch (e) {
      logSwallowed('report_draft_load', e);
      return '';
    }
  }

  /// Keeps [text] as the draft; an empty text deletes it.
  static Future<void> saveDraft(String text) async {
    try {
      final f = await _draftFile();
      if (text.trim().isNotEmpty) {
        await f.writeAsString(text);
      } else if (await f.exists()) {
        await f.delete();
      }
    } catch (e) {
      logSwallowed('report_draft_save', e);
    }
  }

  /// Not a `.txt`: [listReports] takes every `.txt` of the folder for a report.
  static Future<File> _draftFile() async => File('${(await _reportsDir()).path}/$_draftName');

  static const _draftName = 'description_draft.md';

  /// Opens the phone's email app with the feedback address, the subject, [userText] and the
  /// zip filled in. Android's share window cannot fill in an address, so this goes through
  /// the native `sendEmail` (diagnostics.dart). Returns false when the phone has no email app.
  /// An opened email app counts as handed over, as a share does: the draft is cleared.
  /// Whether the user then presses Send cannot be known; email apps keep their own draft.
  static Future<bool> email(ErrorReport report, String userText) async {
    final opened = await Diagnostics.sendEmail(
      path: report.shareFile.path,
      to: feedbackEmail,
      subject: report.subject,
      body: report.messageText(userText),
    );
    if (opened) await saveDraft('');
    return opened;
  }

  /// Opens Android's share window with the report ([title] over its list of apps). Returns
  /// whether it went to an app.
  static Future<bool> share(ErrorReport report, String userText, {String? title}) async {
    // ONE file, always (round 191): the r190 multi-file share (.txt +
    // images) made WhatsApp deliver only the caption with every attachment
    // dropped (owner field test) — mixed MIME types are the suspect. The
    // bundle zip (or the bare .txt when zipping failed) is a single
    // attachment of a single type, which every target handles.
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(report.shareFile.path)],
        subject: report.subject,
        title: title,
        text: '${report.messageText(userText)}\n\nFeedback for the FaunaPulse developer: $feedbackEmail',
      ),
    );
    // A share window closed without choosing an app sent nothing: the text stays as the
    // draft. Otherwise (or when the phone cannot tell) the next feedback starts empty.
    final handed = result.status != ShareResultStatus.dismissed;
    if (handed) await saveDraft('');
    return handed;
  }

  /// Deletes the files of reports made before [_keepReportsFor] (each report leaves a .txt,
  /// its screenshot copies and a zip), never the draft.
  static Future<void> _deleteOldReports(Directory dir, DateTime now) async {
    try {
      for (final f in dir.listSync().whereType<File>()) {
        if (f.uri.pathSegments.last == _draftName) continue;
        if (now.difference(f.lastModifiedSync()) > _keepReportsFor) _deleteQuietly(f);
      }
    } catch (e) {
      logSwallowed('report_delete_old', e);
    }
  }

  static void _deleteQuietly(File f) {
    try {
      f.deleteSync();
    } catch (e) {
      logSwallowed('report_delete_file', e);
    }
  }

  static Future<String> _appVersion() async {
    try {
      final p = await PackageInfo.fromPlatform();
      return p.buildNumber.isEmpty ? p.version : '${p.version}+${p.buildNumber}';
    } catch (_) {
      return 'unknown';
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
      // Share grants temporary access to the chosen report only.
      base = await getApplicationSupportDirectory();
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
  /// The session's GPS `location` (round 126) and typed field notes (round 328)
  /// are stripped from the sample ([redactReportLine]): field-site coordinates
  /// (possibly of protected species) and names must never be included in a
  /// report that may be posted in public. Redaction runs only on RETAINED lines.
  static Future<String> _sampledLog(File file, int head, int tail) async {
    try {
      return await boundedHeadTailSample(
        file,
        head: head,
        tail: tail,
        redact: redactReportLine,
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

/// The keys of a start record's `field` block (FieldNotes.recordBlock; FaunaLapse writes the
/// same) that stay in reports: the phone, the two distances and the site photo file names, as
/// they can explain a problem. Everything else there is typed text, an own field or a
/// position, and a block copied from FaunaLapse can hold keys this app does not know, so the
/// rule names what may stay rather than what must go.
const _reportedFieldKeys = {
  'phone_maker', 'phone_model', 'phone_id', 'camera_height_m', 'detection_distance_m',
  'detection_distance_source', 'site_photos',
};

/// Keys of a position, removed wherever they appear in a line.
const _positionKeys = {'location', 'latitude', 'longitude', 'lat', 'lon'};
final _mayHoldPrivateData = RegExp(r'"(location|latitude|longitude|lat|lon|field)"');

/// One JSONL line as a problem report may carry it. A report may be posted in a public place
/// (a GitHub issue), so every position (round 126; at any depth since round 328) and every
/// value of the `field` block except [_reportedFieldKeys] become `"[redacted]"`. The keys stay
/// (in `custom` too), so the report still shows what was filled in. A line that may hold such
/// data but cannot be read (cut off when the app closed while writing) cannot be cleaned, so
/// it is replaced by a note. Never throws: a redaction failure must never break a report.
String redactReportLine(String line) {
  if (!_mayHoldPrivateData.hasMatch(line)) return line;
  try {
    final obj = jsonDecode(line);
    if (obj is! Map<String, dynamic>) return line;
    final field = obj['field'];
    if (field is Map) {
      for (final k in field.keys.toList()) {
        final v = field[k];
        if (v == null || _reportedFieldKeys.contains(k)) continue;
        if (k == 'custom' && v is Map) {
          for (final c in v.keys.toList()) {
            if (v[c] != null) v[c] = '[redacted]';
          }
        } else {
          field[k] = '[redacted]';
        }
      }
    }
    _redactPositions(obj);
    return jsonEncode(obj);
  } catch (_) {
    return '{"note":"a line with a position or field notes could not be read and was left out"}';
  }
}

void _redactPositions(Object? o) {
  if (o is Map) {
    for (final k in o.keys.toList()) {
      if (_positionKeys.contains(k)) {
        o[k] = '[redacted]';
      } else {
        _redactPositions(o[k]);
      }
    }
  } else if (o is List) {
    o.forEach(_redactPositions);
  }
}

/// Bounded head+tail sample of a possibly huge file (round 162, perf review
/// E5). Reads at most [headBytes] + [tailBytes] from disk instead of the whole
/// file, following the `_loadStats()` pattern in the summary screen. Chunk
/// boundaries cut lines, so the trailing partial line of the head chunk and
/// the leading partial line of the tail chunk are dropped; [redact] (e.g.
/// [redactReportLine]) runs only on lines that are actually kept. Small files
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
    final keptTail =
        (tailLines.length <= tail
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
