// Pollinator Monitor — entry / welcome screen.
//
// Starts a new recording session, and lists previously recorded sessions so the
// user can re-open any of them and view its summary (stats + graphs + photos)
// without recording anything new.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../logging/error_reporter.dart';
import '../models/session_config.dart';
import 'camera_session_screen.dart';
import 'problem_description_screen.dart';
import 'session_summary_screen.dart';

/// One past session found on disk: its folder name and log file, the real
/// session [start]/[end] clock times read from the log (falling back to the
/// file's last-modified time when a record is missing), how long it ran
/// ([duration]) and whether it stopped cleanly ([endedNormally]). [end] and
/// [duration] are null when the session has no end record (e.g. it crashed
/// before writing one).
class _PastSession {
  final String name;
  final File logFile;
  final DateTime start;
  final DateTime? end;
  final Duration? duration;
  final bool endedNormally;
  const _PastSession(
    this.name,
    this.logFile,
    this.start, {
    this.end,
    this.duration,
    this.endedNormally = false,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _starting = false;
  bool _loadingSessions = true;
  List<_PastSession> _sessions = const [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
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
            final start = span.startMs != null
                ? DateTime.fromMillisecondsSinceEpoch(span.startMs!)
                : log.statSync().modified;
            final end = span.endMs != null
                ? DateTime.fromMillisecondsSinceEpoch(span.endMs!)
                : null;
            final dur = (span.startMs != null &&
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
              ),
            );
          }
        }
      }
      found.sort((a, b) => b.start.compareTo(a.start));
    } catch (_) {
      // Leave empty on any error (e.g. storage not ready).
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
    } catch (_) {
      // Leave nulls; a truncated/empty file just yields an unknown duration.
    }
    return (startMs: startMs, endMs: endMs, endedNormally: endedNormally);
  }

  Map<String, dynamic>? _tryDecode(String line) {
    try {
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
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

  Future<void> _openSession(_PastSession s) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionSummaryScreen(logFile: s.logFile),
      ),
    );
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
    } catch (_) {
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
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report saved'),
        content: Text(
          'Saved a ${saved.humanSize} report to:\n\n${saved.file.path}\n\n'
          'You can send it now, or find it later over USB.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ErrorReporter.share(saved);
            },
            child: const Text(
              'Send…',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            const Icon(Icons.local_florist, size: 56, color: Colors.amber),
            const SizedBox(height: 8),
            const Text(
              'Pollinator Monitor',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Detect and time flower-visiting insects in real time.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
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
            // Always-available entry point so a problem can be reported even after
            // the app restarts (e.g. following a crash) — the report still captures
            // the recent technical log.
            TextButton.icon(
              onPressed: _reportProblem,
              icon: const Icon(Icons.bug_report_outlined, size: 18),
              label: const Text('Report a problem'),
            ),
            const SizedBox(height: 14),
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
            leading: const Icon(Icons.bar_chart, color: Colors.amber),
            title: Text(s.name),
            // Two compact lines under the name: the calendar date, then the
            // start→end clock times on the left with a colour-coded duration pill
            // on the right.
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _dateOnly(s.start),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
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
          );
        },
      ),
    );
  }
}
