// FaunaPulse — entry / welcome screen.
//
// Starts a new recording session, and lists previously recorded sessions so the
// user can re-open any of them and view its summary (stats + graphs + photos)
// without recording anything new.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../capture/crop_export.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../logging/error_reporter.dart';
import '../logging/session_rename.dart';
import '../models/session_config.dart';
import '../postprocess/post_detector.dart';
import 'analysis_screen.dart';
import 'camera_session_screen.dart';
import 'problem_description_screen.dart';
import 'session_summary_screen.dart';

/// One past session found on disk: its folder name and log file, the real
/// session [start]/[end] clock times read from the log (falling back to the
/// file's last-modified time when a record is missing), how long it ran
/// ([duration]), whether it stopped cleanly ([endedNormally]) and how much
/// storage the whole session folder uses ([sizeBytes] — log + photos +
/// diagnostic files). [end] and [duration] are null when the session has no
/// end record (e.g. it crashed before writing one).
class _PastSession {
  final String name;
  final File logFile;
  final DateTime start;
  final DateTime? end;
  final Duration? duration;
  final bool endedNormally;
  final int sizeBytes;

  /// Whether a post-hoc analysis output (post_detections.jsonl) exists for
  /// this session (round 135) — shown as a small badge on the row.
  final bool hasAnalysis;

  const _PastSession(
    this.name,
    this.logFile,
    this.start, {
    this.end,
    this.duration,
    this.endedNormally = false,
    this.sizeBytes = 0,
    this.hasAnalysis = false,
  });
}

/// Actions in the home screen's top-right "⋮" overflow menu: app-level
/// preferences and actions on ALL sessions at once (a single session is
/// managed from its own summary screen). Future bulk actions (filtering,
/// export, …) get their own value here. "Show setup tips" moved here from the
/// settings sheet in round 159 — it is an app-level preference, and this menu
/// is the established home for those (session settings stay on the camera
/// screen, which needs the live camera).
enum _HomeMenuAction { about, toggleSetupTips, deleteAllSessions }

/// Per-session actions in the gear menu on each "Previous sessions" row
/// (round 182). The gear replaced a decorative histogram icon; it groups
/// everything that manages ONE session without opening its summary: rename,
/// gallery export, post-hoc analysis (same as the row long-press) and
/// delete. Opening the summary stays the row tap.
enum _SessionAction { rename, exportPhotos, analyze, delete }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _starting = false;
  bool _loadingSessions = true;
  List<_PastSession> _sessions = const [];

  /// Whether the one-time setup reminder shows at session start. Mirrors the
  /// inverse of the persisted "hide" flag ([kHideSessionInfoPrefKey]); shown
  /// as a check item in the ⋮ menu.
  bool _showSetupTips = true;

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _loadSetupTipsPref();
  }

  /// Reads the persisted "hide setup tips" flag so the menu check item
  /// reflects the current state.
  Future<void> _loadSetupTipsPref() async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getBool(kHideSessionInfoPrefKey) ?? false;
    if (!mounted) return;
    setState(() => _showSetupTips = !hidden);
  }

  /// Turns the one-time setup reminder on/off by writing the persisted flag.
  /// On = reminder shows next time a session screen opens; Off = stays hidden.
  Future<void> _toggleSetupTips() async {
    setState(() => _showSetupTips = !_showSetupTips);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kHideSessionInfoPrefKey, !_showSetupTips);
  }

  /// Scans the app's sessions folder for past sessions (a sub-folder containing
  /// a session.jsonl), newest first.
  Future<void> _loadSessions() async {
    setState(() => _loadingSessions = true);
    final found = <_PastSession>[];
    try {
      final base =
          (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/sessions');
      if (await dir.exists()) {
        for (final entity in dir.listSync()) {
          if (entity is! Directory) continue;
          final log = File('${entity.path}/session.jsonl');
          if (log.existsSync()) {
            // Read just the first/last records to learn when the session started,
            // ended and how long it ran (cheap — no full scan, even for a huge log).
            final span = await _readSessionSpan(log);
            final sizeBytes = await folderSizeBytes(entity);
            final start = span.startMs != null
                ? DateTime.fromMillisecondsSinceEpoch(span.startMs!)
                : log.statSync().modified;
            final end = span.endMs != null
                ? DateTime.fromMillisecondsSinceEpoch(span.endMs!)
                : null;
            final dur =
                (span.startMs != null &&
                    span.endMs != null &&
                    span.endMs! >= span.startMs!)
                ? Duration(milliseconds: span.endMs! - span.startMs!)
                : null;
            found.add(
              _PastSession(
                entity.path.split('/').last,
                log,
                start,
                end: end,
                duration: dur,
                endedNormally: span.endedNormally,
                sizeBytes: sizeBytes,
                hasAnalysis: File(
                  '${entity.path}/${PostDetector.outputFileName}',
                ).existsSync(),
              ),
            );
          }
        }
      }
      found.sort((a, b) => b.start.compareTo(a.start));
    } catch (e) {
      // Leave empty on any error (e.g. storage not ready).
      logSwallowed('session_list_scan', e);
    }
    if (mounted) {
      setState(() {
        _sessions = found;
        _loadingSessions = false;
      });
    }
  }

  /// Reads only the head and tail of a session log to recover its start time, end
  /// time and clean-stop flag — the same cheap head/tail trick the summary screen
  /// uses, so listing many sessions never scans a full (possibly huge) log.
  Future<({int? startMs, int? endMs, bool endedNormally})> _readSessionSpan(
    File log,
  ) async {
    int? startMs, endMs;
    var endedNormally = false;
    try {
      final raf = await log.open();
      try {
        final len = await raf.length();
        // Head: the first record is the session start.
        final head = await raf.read(min(8192, len));
        for (final l in utf8.decode(head, allowMalformed: true).split('\n')) {
          if (l.contains('"start_of_session"')) {
            startMs = (_tryDecode(l)?['time_ms'] as num?)?.toInt();
            break;
          }
        }
        // Tail: the last record (if any) is the session end.
        final tailLen = min(16384, len);
        await raf.setPosition(len - tailLen);
        final tail = await raf.read(tailLen);
        final tailLines = utf8
            .decode(tail, allowMalformed: true)
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        for (final l in tailLines.reversed) {
          if (l.contains('"end_of_session"')) {
            final rec = _tryDecode(l);
            endMs = (rec?['time_ms'] as num?)?.toInt();
            endedNormally = rec?['ended_normally'] == true;
            break;
          }
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      // Leave nulls; a truncated/empty file just yields an unknown duration.
      logSwallowed('session_duration_scan', e);
    }
    return (startMs: startMs, endMs: endMs, endedNormally: endedNormally);
  }

  Map<String, dynamic>? _tryDecode(String line) {
    try {
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      // Deliberately silent (B7-reviewed): a line truncated by a crash is
      // expected in an append-only log, and this runs per line.
      return null;
    }
  }

  /// Formats a session length so the unit always matches the duration: **mm:ss**
  /// under an hour, **hh:mm:ss** for 1–24 h, and **dd:hh:mm:ss** at a day or more
  /// (sessions can run for days). Matches the live REC-banner clock's style.
  String _formatDuration(Duration d) {
    final total = d.inSeconds;
    final days = total ~/ 86400;
    final h = (total % 86400) ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (days > 0) return '${two(days)}:${two(h)}:${two(m)}:${two(s)}';
    if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  /// A small rounded "pill" showing the session length. Amber with a timer icon
  /// for a normally-ended session; orange with a warning icon and the word
  /// "incomplete" when there is no end record (a crash / force-stop).
  Widget _durationPill(_PastSession s) {
    final complete = s.duration != null;
    final color = complete ? Colors.amber : Colors.orange;
    final label = complete ? _formatDuration(s.duration!) : 'incomplete';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            complete ? Icons.timer_outlined : Icons.warning_amber_rounded,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _starting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission is required.')),
        );
      }
      return;
    }
    final config = await SessionConfig.load();
    if (!mounted) return;
    setState(() => _starting = false);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraSessionScreen(initialConfig: config),
      ),
    );
    // A new session may have been recorded; refresh the list on return.
    _loadSessions();
  }

  /// Opens the analysis screen, optionally preselecting [sessionDirPath]
  /// (a long-press on a session row). Rescans on return — a finished run
  /// adds the row's "analyzed" badge.
  Future<void> _openAnalysis([String? sessionDirPath]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AnalysisScreen(initialSessionPath: sessionDirPath),
      ),
    );
    _loadSessions();
  }

  Future<void> _openSession(_PastSession s) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionSummaryScreen(logFile: s.logFile),
      ),
    );
    // The summary can DELETE its session (round 90) — rescan so the list and
    // the per-session sizes stay accurate.
    _loadSessions();
  }

  /// Rename dialog for one session (round 182). The heavy lifting —
  /// folder rename, start-record update, `session_renamed` audit record —
  /// is `renameSession` (logging/session_rename.dart); this dialog only
  /// collects the name and shows any failure inline so the user can correct
  /// it without retyping.
  Future<void> _renameSession(_PastSession s) async {
    final controller = TextEditingController(text: s.name);
    String? error;
    var busy = false;
    final renamed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Rename session'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                enabled: !busy,
                decoration: InputDecoration(
                  labelText: 'Session name',
                  border: const OutlineInputBorder(),
                  errorText: error,
                  errorMaxLines: 3,
                  helperText:
                      'Letters, digits, spaces, - and _ '
                      '(anything else becomes _).',
                  helperMaxLines: 2,
                ),
                onChanged: (_) {
                  if (error != null) setSt(() => error = null);
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Renames the session folder and updates the name inside the '
                'session\'s data log too (the change itself is documented '
                'there as a "session_renamed" record). Photos keep their '
                'file names.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setSt(() => busy = true);
                      try {
                        await renameSession(
                          s.logFile.parent,
                          controller.text,
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop(true);
                      } on SessionRenameException catch (e) {
                        setSt(() {
                          busy = false;
                          error = e.message;
                        });
                      } catch (e) {
                        setSt(() {
                          busy = false;
                          error = 'Rename failed: $e';
                        });
                      }
                    },
              child: const Text('Rename'),
            ),
          ],
        ),
      ),
    );
    final newName = sanitizeSessionName(controller.text);
    controller.dispose();
    if (renamed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Session renamed to "$newName".')),
      );
      _loadSessions();
    }
  }

  /// Whole-session gallery export from the gear menu (round 182): the same
  /// scan → confirm → copy flow as the summary's Overview button (shared
  /// `scanSessionPhotos` / `exportPhotosToGallery` helpers), with the
  /// progress shown as a modal dialog since this screen has no inline slot.
  Future<void> _exportSessionPhotos(_PastSession s) async {
    final scan = await scanSessionPhotos(s.logFile.parent.path);
    if (!mounted) return;
    if (scan.files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This session has no saved photos to export.'),
        ),
      );
      return;
    }
    final album = galleryAlbumName(s.name);
    final n = scan.referenceCount;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Export ${scan.files.length} photos to Gallery?'),
        content: Text(
          'Copies every saved photo of this session into the phone\'s '
          'Gallery app, as the album "Pictures/FaunaPulse/$album". '
          '${n > 0 ? 'Includes $n reference photo${n == 1 ? '' : 's'} '
                    '(fixed-interval shots, taken whether or not anything '
                    'was detected). ' : ''}'
          'The copies take about ${formatBytes(scan.bytes)} of extra '
          'storage; the originals stay in the session folder. Photos '
          'already exported are skipped, so re-running is safe.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Export',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;

    // Modal progress: the export runs in chunks, so the bar moves while the
    // dialog blocks other taps. `progressOpen` guards the final pop against
    // the Android back button dismissing the dialog first.
    var done = 0;
    final total = scan.files.length;
    StateSetter? progressUpdate;
    var progressOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Exporting photos…'),
          content: StatefulBuilder(
            builder: (ctx, setSt) {
              progressUpdate = setSt;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: total == 0 ? null : done / total,
                  ),
                  const SizedBox(height: 8),
                  Text('Photo $done of $total', style: const TextStyle(fontSize: 13)),
                ],
              );
            },
          ),
        ),
      ).then((_) => progressOpen = false),
    );
    final res = await exportPhotosToGallery(
      scan.files,
      album,
      onProgress: (d, _) {
        done = d;
        progressUpdate?.call(() {});
      },
    );
    if (!mounted) return;
    if (progressOpen) Navigator.of(context, rootNavigator: true).pop();
    final msg = !res.supported
        ? 'Export to Gallery needs Android 10 or newer — this phone runs an '
              'older Android. The photos are still on the phone in the '
              'session folder (reachable over USB).'
        : 'Exported ${res.exported} photos to Gallery ▸ '
              'Pictures/FaunaPulse/$album.'
              '${res.skipped > 0 ? ' ${res.skipped} were already there.' : ''}'
              '${res.failed > 0 ? ' ${res.failed} failed — try again.' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    _loadSessions();
  }

  /// Delete ONE session from the gear menu (round 182) — same confirmation
  /// language and delete call as the summary's red button (round 90).
  Future<void> _confirmDeleteSession(_PastSession s) async {
    final size = s.sizeBytes > 0 ? ' (${formatBytes(s.sizeBytes)})' : '';
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(
          'This permanently deletes "${s.name}"$size from the phone: the '
          'data log, all metadata and every saved photo. '
          'This cannot be undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await s.logFile.parent.delete(recursive: true);
    } catch (e) {
      logSwallowed('session_delete', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete the session.')),
        );
      }
      return;
    }
    _loadSessions();
  }

  /// Asks for typed confirmation, then deletes EVERY listed session.
  ///
  /// Bulk-deleting field data is the most destructive action in the app, so a
  /// single stray tap must never be enough: the red button only arms once the
  /// word "delete" is typed. Each recognized session folder is deleted
  /// individually (never the whole `sessions/` root) so anything else placed
  /// under `sessions/` — e.g. over USB — survives.
  Future<void> _confirmDeleteAllSessions() async {
    final sessions = List<_PastSession>.of(_sessions);
    if (sessions.isEmpty) return;
    final totalBytes = sessions.fold<int>(0, (sum, s) => sum + s.sizeBytes);
    final sure = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteAllSessionsDialog(
        count: sessions.length,
        totalBytes: totalBytes,
      ),
    );
    if (sure != true || !mounted) return;

    // Folders with thousands of photos take a while to delete — block the UI
    // behind a progress dialog so nothing races the deletes.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text('Deleting ${sessions.length} sessions…')),
          ],
        ),
      ),
    );
    var failures = 0;
    for (final s in sessions) {
      try {
        await s.logFile.parent.delete(recursive: true);
      } catch (e) {
        failures++;
        logSwallowed('sessions_delete_all', e);
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss progress dialog
    if (failures > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not delete $failures session${failures == 1 ? '' : 's'}.',
          ),
        ),
      );
    }
    _loadSessions();
  }

  /// The calendar date, e.g. `2026-06-22`.
  String _dateOnly(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// The wall-clock time of day, `hh:mm:ss`.
  String _timeOnly(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  /// Builds a diagnostic report from outside a session (e.g. after a crash and
  /// restart): the last-used settings, the most recent session log if any, and
  /// the app's recent technical log. Saves it locally and offers to send it.
  Future<void> _reportProblem() async {
    // Ask the user to describe the problem first (required). Cancelling aborts.
    final description = await showProblemDescriptionEditor(context);
    if (description == null || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    ErrorReport? report;
    try {
      final config = await SessionConfig.load();
      final lastLog = _sessions.isNotEmpty ? _sessions.first.logFile : null;
      report = await ErrorReporter.build(
        trigger: 'User-initiated report (Report a problem)',
        userDescription: description,
        config: config,
        sessionLog: lastLog,
      );
    } catch (e) {
      logSwallowed('error_report_build', e);
      report = null;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss spinner
    if (report == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the report.')),
      );
      return;
    }
    final saved = report;
    // The developer's address is handed out privately and typed once; it is
    // remembered app-wide (never in SessionConfig — see ErrorReporter).
    final knownEmail = await ErrorReporter.loadRecipientEmail();
    if (!mounted) return;
    final choice = await showDialog<ReportSendChoice>(
      context: context,
      builder: (_) =>
          ReportSavedDialog(report: saved, initialEmail: knownEmail),
    );
    if (choice == null || !mounted) return;
    if (choice.viaEmail) {
      await ErrorReporter.saveRecipientEmail(choice.email);
      final opened = await ErrorReporter.emailTo(saved, choice.email);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No email app found — use Share instead.'),
          ),
        );
      }
    } else {
      await ErrorReporter.share(saved);
    }
  }

  /// The top-right "⋮" menu (a PopupMenuButton — Android's standard
  /// "more actions" button) for actions that affect all sessions at once.
  /// The ⋮ menu's About dialog (round 183; replaced the landing-screen
  /// tagline): a condensed version of the README's Overview, the app version
  /// (from the build, so it can never drift) and a link to the public GitHub
  /// repository. `showAboutDialog` also provides the standard "View
  /// licenses" page, which an AGPL app should expose anyway.
  Future<void> _showAbout() async {
    PackageInfo? info;
    try {
      info = await PackageInfo.fromPlatform();
    } catch (e) {
      logSwallowed('about_package_info', e);
    }
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'FaunaPulse',
      applicationVersion: info != null
          ? 'v${info.version} (build ${info.buildNumber})'
          : null,
      applicationIcon: const Icon(
        Icons.emoji_nature,
        size: 40,
        color: Colors.amber,
      ),
      children: [
        const SizedBox(height: 8),
        const Text(
          'A passive, non-invasive field tool for monitoring flower-visiting '
          'insects (and, with a suitable detection model, other wildlife) at '
          'a fixed spot. Place the square region of interest over a flower: '
          'FaunaPulse detects, tracks and photographs visitors fully '
          'on-device (no internet needed) and logs every visit with '
          'timestamps, so visitation rates can be computed afterwards in R '
          'or Python. AI-free motion-triggered and time-lapse capture, '
          'scheduled multi-day runs and post-capture AI analysis of saved '
          'photos are built in.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 14),
        InkWell(
          onTap: () async {
            try {
              await launchUrl(
                Uri.parse(ErrorReporter.githubRepoUrl),
                mode: LaunchMode.externalApplication,
              );
            } catch (e) {
              logSwallowed('about_open_github', e);
            }
          },
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.code, size: 18, color: Colors.lightBlueAccent),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'github.com/valentinitnelav/fauna-pulse',
                  style: TextStyle(
                    color: Colors.lightBlueAccent,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _overflowMenu() {
    return PopupMenuButton<_HomeMenuAction>(
      icon: const Icon(Icons.more_vert, color: Colors.white70),
      tooltip: 'All-session actions',
      onSelected: (action) {
        switch (action) {
          case _HomeMenuAction.about:
            _showAbout();
          case _HomeMenuAction.toggleSetupTips:
            _toggleSetupTips();
          case _HomeMenuAction.deleteAllSessions:
            _confirmDeleteAllSessions();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _HomeMenuAction.about,
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 20, color: Colors.white70),
              SizedBox(width: 10),
              Text('About FaunaPulse'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: _HomeMenuAction.toggleSetupTips,
          checked: _showSetupTips,
          child: const Text('Show setup tips at session start'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _HomeMenuAction.deleteAllSessions,
          enabled: _sessions.isNotEmpty,
          child: Row(
            children: [
              Icon(
                Icons.delete_sweep,
                size: 20,
                color: _sessions.isNotEmpty
                    ? Colors.red.shade300
                    : Colors.white38,
              ),
              const SizedBox(width: 10),
              const Text('Delete all sessions…'),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 24),
                // One nature icon only (round 183): the camera icon that
                // used to sit beside it read as a "take a photo" button.
                // The old tagline is gone too — what the app does now lives
                // in the ⋮ menu's About dialog.
                const Icon(Icons.emoji_nature, size: 56, color: Colors.amber),
                const SizedBox(height: 8),
                const Text(
                  'FaunaPulse',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _starting ? null : _start,
                  icon: _starting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.videocam),
                  label: const Text('New session'),
                ),
                const SizedBox(height: 6),
                // Post-hoc analysis (round 135): run a (bigger) detector over a
                // finished session's saved photos — no camera, no time limit.
                OutlinedButton.icon(
                  onPressed: _openAnalysis,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('Analyze saved photos'),
                ),
                const SizedBox(height: 6),
                // Always-available entry point so a problem can be reported even after
                // the app restarts (e.g. following a crash) — the report still captures
                // the recent technical log. Outlined like the analyze button
                // above it (round 183): a bare text label did not read as
                // tappable.
                OutlinedButton.icon(
                  onPressed: _reportProblem,
                  icon: const Icon(Icons.bug_report_outlined, size: 18),
                  label: const Text('Report a problem'),
                ),
                const SizedBox(height: 16),
                // A full-width rule marks where the action block ends and
                // the session history begins (round 183).
                const Divider(height: 1, color: Colors.white24),
                const SizedBox(height: 10),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Previous sessions',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                Expanded(child: _sessionList()),
              ],
            ),
            // Floats over the top-right corner (the title block stays centered).
            Positioned(top: 0, right: 4, child: _overflowMenu()),
          ],
        ),
      ),
    );
  }

  Widget _sessionList() {
    if (_loadingSessions) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sessions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No recorded sessions yet.\nTap "New session" to start one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadSessions,
      child: ListView.separated(
        itemCount: _sessions.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final s = _sessions[i];
          return ListTile(
            // The gear menu (round 182) replaced a purely decorative
            // histogram icon: per-session management (rename, export,
            // analyze, delete) lives here, opening the summary stays the
            // row tap.
            leading: PopupMenuButton<_SessionAction>(
              icon: const Icon(Icons.settings, color: Colors.amber),
              tooltip: 'Session actions',
              onSelected: (a) {
                switch (a) {
                  case _SessionAction.rename:
                    _renameSession(s);
                  case _SessionAction.exportPhotos:
                    _exportSessionPhotos(s);
                  case _SessionAction.analyze:
                    _openAnalysis(s.logFile.parent.path);
                  case _SessionAction.delete:
                    _confirmDeleteSession(s);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _SessionAction.rename,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.drive_file_rename_outline),
                    title: Text('Rename session'),
                  ),
                ),
                PopupMenuItem(
                  value: _SessionAction.exportPhotos,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.photo_library_outlined),
                    title: Text('Export photos to Gallery'),
                  ),
                ),
                PopupMenuItem(
                  value: _SessionAction.analyze,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.auto_awesome_outlined),
                    title: Text('Analyze photos'),
                  ),
                ),
                PopupMenuItem(
                  value: _SessionAction.delete,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_forever, color: Colors.red),
                    title: Text(
                      'Delete session',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
            title: Row(
              children: [
                Flexible(child: Text(s.name, overflow: TextOverflow.ellipsis)),
                if (s.hasAnalysis)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: 'Post-hoc analysis results exist',
                      child: Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: Colors.lightBlueAccent,
                      ),
                    ),
                  ),
              ],
            ),
            // Two compact lines under the name: the calendar date with the
            // folder's storage size on the right, then the start→end clock
            // times on the left with a colour-coded duration pill on the right.
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _dateOnly(s.start),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      const Icon(
                        Icons.sd_storage_outlined,
                        size: 13,
                        color: Colors.white38,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        formatBytes(s.sizeBytes),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(
                        Icons.schedule,
                        size: 13,
                        color: Colors.white38,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        // "14:30:05 → 15:42:11" (end shown as "—" if the session
                        // has no end record).
                        '${_timeOnly(s.start)} → '
                        '${s.end != null ? _timeOnly(s.end!) : '—'}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Spacer(),
                      _durationPill(s),
                    ],
                  ),
                ],
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openSession(s),
            // Long-press = analyze THIS session (same screen the "Analyze
            // saved photos" button opens, with the session preselected).
            onLongPress: () => _openAnalysis(s.logFile.parent.path),
          );
        },
      ),
    );
  }
}

/// The type-to-confirm dialog for "Delete all sessions". Pops `true` only when
/// the user has typed `delete` and pressed the red button.
///
/// This is a real StatefulWidget (not a StatefulBuilder inside the caller) so
/// the text field's controller is owned and disposed by the dialog's own
/// State. Round 103's first field test crashed (fixed round 104) with an
/// `InheritedElement '_dependents.isEmpty'` assertion because the caller
/// disposed the controller — and pushed the progress dialog — while this
/// dialog was still animating out with the keyboard focused; letting the
/// framework drive the teardown order fixes that.
class DeleteAllSessionsDialog extends StatefulWidget {
  final int count;
  final int totalBytes;
  const DeleteAllSessionsDialog({
    super.key,
    required this.count,
    required this.totalBytes,
  });

  @override
  State<DeleteAllSessionsDialog> createState() =>
      _DeleteAllSessionsDialogState();
}

class _DeleteAllSessionsDialogState extends State<DeleteAllSessionsDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _close(bool result) {
    // Dismiss the keyboard BEFORE popping — tearing the route down while the
    // text field still holds focus is part of what crashed the first field
    // test (see the class comment).
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final armed = _typed.text.trim().toLowerCase() == 'delete';
    return AlertDialog(
      title: const Text('Delete ALL sessions?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This permanently deletes all ${widget.count} sessions '
            '(${formatBytes(widget.totalBytes)}) from the phone — every data '
            'log, all metadata and every saved photo. This cannot be undone.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _typed,
            autofocus: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Type "delete" to confirm',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => _close(false), child: const Text('Cancel')),
        TextButton(
          onPressed: armed ? () => _close(true) : null,
          child: Text(
            'Delete all',
            style: TextStyle(
              color: armed ? Colors.red : null,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

/// What the user chose in [ReportSavedDialog]. [viaEmail] sends to [email]
/// (a non-empty address); otherwise the generic OS share sheet opens.
/// The dialog pops null for "Done" (keep the file, send nothing).
class ReportSendChoice {
  final String email;
  const ReportSendChoice.share() : email = '';
  const ReportSendChoice.email(this.email);
  bool get viaEmail => email.isNotEmpty;
}

/// Shown after a problem report is written to disk: where it landed, an
/// optional developer email (typed once, remembered) and the two ways to
/// send it. A real StatefulWidget for the same teardown-order reason as
/// [DeleteAllSessionsDialog] (its class comment has the crash story).
class ReportSavedDialog extends StatefulWidget {
  final ErrorReport report;
  final String initialEmail;
  const ReportSavedDialog({
    super.key,
    required this.report,
    required this.initialEmail,
  });

  @override
  State<ReportSavedDialog> createState() => _ReportSavedDialogState();
}

class _ReportSavedDialogState extends State<ReportSavedDialog> {
  late final TextEditingController _email = TextEditingController(
    text: widget.initialEmail,
  );

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  /// Loose "looks like an address" check — just enough to keep the Email
  /// button disabled on obvious typos; the email app validates for real.
  bool get _emailPlausible =>
      RegExp(r'^\S+@\S+\.\S+$').hasMatch(_email.text.trim());

  void _close(ReportSendChoice? result) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Report saved'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saved a ${widget.report.humanSize} report to:\n\n'
            '${widget.report.file.path}\n\n'
            'You can send it now, or find it later over USB.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Developer email (optional)',
              helperText: 'Ask the developer for it — remembered next time.',
              helperMaxLines: 2,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => _close(null), child: const Text('Done')),
        TextButton(
          onPressed: _emailPlausible
              ? () => _close(ReportSendChoice.email(_email.text.trim()))
              : null,
          child: const Text('Email…'),
        ),
        TextButton(
          onPressed: () => _close(const ReportSendChoice.share()),
          child: const Text(
            'Share…',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
