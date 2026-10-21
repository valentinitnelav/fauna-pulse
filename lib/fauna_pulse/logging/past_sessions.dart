// FaunaPulse (round 277): the sessions saved on this phone, read for the home
// screen (how many, and the latest one) and the Sessions screen (search,
// filters, selection). Moved here from home_screen.dart when the owner asked
// for a Sessions screen of its own.
//
// Each session is a folder under sessions/ holding a session.jsonl log. Only
// the head and the tail of the log are read (the start and end records), so
// listing many sessions never scans a full, possibly huge, log.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../identification/identification_store.dart';
import '../postprocess/post_detector.dart';
import '../postprocess/video_detector.dart';
import 'app_error_hooks.dart';
import 'device_storage.dart';
import 'session_log_head.dart';

/// The folder holding every session (`…/Android/data/<pkg>/files/sessions`,
/// reachable over USB).
Future<Directory> sessionsRoot() async {
  final base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
  return Directory('${base.path}/sessions');
}

/// How a session was recorded, named as on the camera screen.
enum RecordingKind {
  liveDetection('Live detection'),
  motion('Motion'),
  timeLapse('Time-lapse'),
  importedVideos('Imported videos');

  final String label;
  const RecordingKind(this.label);
}

/// The kind of a session from its start record: videos imported from
/// elsewhere carry `source: imported_video`; the camera's trigger is in the
/// config (`captureTrigger`, or the older `motionOnlyCapture` flag). Sessions
/// older than the trigger setting ran the detector live.
RecordingKind recordingKindOf(Map<String, dynamic>? startRecord) {
  if (startRecord?['source'] == 'imported_video') return RecordingKind.importedVideos;
  final config = startRecord?['config'];
  if (config is Map) {
    if (config['captureTrigger'] == 'timelapse') return RecordingKind.timeLapse;
    if (config['captureTrigger'] == 'motion' || config['motionOnlyCapture'] == true) {
      return RecordingKind.motion;
    }
  }
  return RecordingKind.liveDetection;
}

/// One past session found on disk: its folder name and log file, the real
/// session [start]/[end] clock times read from the log (falling back to the
/// file's last-modified time when a record is missing), how long it ran
/// ([duration]), whether it stopped cleanly ([endedNormally]) and how much
/// storage the whole session folder uses ([sizeBytes]: log + photos +
/// diagnostic files). [end] and [duration] are null when the session has no
/// end record (e.g. it crashed before writing one).
class PastSession {
  final String name;
  final File logFile;
  final DateTime start;
  final DateTime? end;
  final Duration? duration;
  final bool endedNormally;
  final int sizeBytes;
  final RecordingKind kind;

  /// "Find animals" ran on its photos or videos afterwards (round 135).
  final bool hasAnalysis;

  /// Identification results exist (round 208).
  final bool hasIdentification;

  /// Clips in `videos/` (round 227), also once they were deleted to free
  /// storage (their boxes stay, round 236).
  final bool hasVideos;

  const PastSession(
    this.name,
    this.logFile,
    this.start, {
    this.end,
    this.duration,
    this.endedNormally = false,
    this.sizeBytes = 0,
    this.kind = RecordingKind.liveDetection,
    this.hasAnalysis = false,
    this.hasIdentification = false,
    this.hasVideos = false,
  });

  /// The session folder.
  Directory get dir => logFile.parent;
}

/// Every session under [root] (default [sessionsRoot]), newest first. An
/// error in one session folder skips only that folder; an error listing
/// [root] itself ends the scan with what was found so far.
Future<List<PastSession>> scanPastSessions({Directory? root}) async {
  final found = <PastSession>[];
  try {
    final dir = root ?? await sessionsRoot();
    if (!await dir.exists()) return found;
    for (final entity in dir.listSync()) {
      if (entity is! Directory) continue;
      // Per folder: one damaged log, or a file deleted while we scan (summary
      // replaced, clip cleanup, session deleted), skips only that folder;
      // the folders after it in the listing still show on Home and Sessions.
      try {
        final log = File('${entity.path}/session.jsonl');
        if (!log.existsSync()) continue;
        final span = await _readSessionSpan(log);
        final startMs = _msOrNull(span.startRecord?['time_ms']);
        final endMs = span.endMs;
        found.add(
          PastSession(
            entity.path.split('/').last,
            log,
            startMs != null ? DateTime.fromMillisecondsSinceEpoch(startMs) : log.statSync().modified,
            end: endMs != null ? DateTime.fromMillisecondsSinceEpoch(endMs) : null,
            duration: startMs != null && endMs != null && endMs >= startMs
                ? Duration(milliseconds: endMs - startMs)
                : null,
            endedNormally: span.endedNormally,
            sizeBytes: await folderSizeBytes(entity),
            kind: recordingKindOf(span.startRecord),
            hasAnalysis:
                File('${entity.path}/${PostDetector.outputFileName}').existsSync() ||
                File('${entity.path}/${VideoDetector.outputFileName}').existsSync(),
            hasIdentification: IdentificationPaths(entity).existingSummaries().isNotEmpty,
            hasVideos:
                VideoDetector.clipsOf(entity).isNotEmpty ||
                File('${entity.path}/${VideoDetector.outputFileName}').existsSync(),
          ),
        );
      } catch (e) {
        logSwallowed('session_list_scan_folder', e);
      }
    }
  } catch (e) {
    logSwallowed('session_list_scan', e);
  }
  found.sort((a, b) => b.start.compareTo(a.start));
  return found;
}

/// The start record, the end time and the clean-stop flag, from the head and
/// the tail of the log only. The head is read by [readLogHead], as in
/// track_source.dart: the start record (the first line) carries the whole
/// config and may pass 64 KB with long field notes.
Future<({Map<String, dynamic>? startRecord, int? endMs, bool endedNormally})> _readSessionSpan(File log) async {
  Map<String, dynamic>? startRecord;
  int? endMs;
  var endedNormally = false;
  try {
    final raf = await log.open();
    try {
      for (final l in (await readLogHead(raf)).split('\n')) {
        if (l.contains('"start_of_session"')) {
          startRecord = _tryDecode(l);
          break;
        }
      }
      final end = await readSessionLogEnd(raf);
      endMs = end.endMs;
      endedNormally = end.endedNormally;
    } finally {
      await raf.close();
    }
  } catch (e) {
    // Leave nulls; a truncated or empty file just gives an unknown duration.
    logSwallowed('session_duration_scan', e);
  }
  return (startRecord: startRecord, endMs: endMs, endedNormally: endedNormally);
}

/// Records appended to a session log after the recording ended (a clip
/// cleanup, a rename): their time is not recording time, and they must not
/// hide the end_of_session record before them.
const _laterRecords = {'"video_cleanup"', '"session_renamed"'};

/// The end of a session log, shared by the session lists and the Dashboard:
/// the `end_of_session` time and flag (null / false after a crash) and the
/// time of the last record written while recording (the crash fallback).
/// Reads a 16 KB tail and grows it (x4) only while it holds nothing but
/// later records and cut lines: one video_cleanup line lists every deleted
/// clip (ClipCleanup.run) and can pass 16 KB. A normal log stops at the first
/// window, so a huge crashed log is never read in full.
Future<({int? endMs, int? lastMs, bool endedNormally})> readSessionLogEnd(RandomAccessFile raf) async {
  final len = await raf.length();
  for (var win = 16384;; win *= 4) {
    final tailLen = min(win, len);
    await raf.setPosition(len - tailLen);
    final lines = utf8.decode(await raf.read(tailLen), allowMalformed: true).split('\n');
    int? lastMs;
    var sawRecording = false;
    for (final l in lines.reversed) {
      if (l.trim().isEmpty || _laterRecords.any(l.contains)) continue;
      final rec = _tryDecode(l);
      if (rec == null) continue; // a cut line (the window's first, or a crash's last)
      final t = _msOrNull(rec['time_ms']);
      if (rec['type'] == 'end_of_session') {
        return (endMs: t, lastMs: lastMs, endedNormally: rec['ended_normally'] == true);
      }
      sawRecording = true;
      lastMs ??= t;
    }
    if (sawRecording || tailLen == len) return (endMs: null, lastMs: lastMs, endedNormally: false);
  }
}

/// A time_ms value as an int, or null when it is not a number or lies outside
/// the DateTime range (hand-edited or corrupted log). Null makes the caller
/// fall back to the file time (start) or "no end time" instead of throwing.
int? _msOrNull(Object? v) {
  if (v is! num || !v.isFinite) return null;
  // 8.64e15 ms is the DateTime limit; check before toInt (1e20 would clamp).
  if (v.abs() > 8640000000000000) return null;
  return v.toInt();
}

Map<String, dynamic>? _tryDecode(String line) {
  try {
    return jsonDecode(line) as Map<String, dynamic>;
  } catch (_) {
    // Deliberately silent (B7-reviewed): a line cut by a crash is expected in
    // an append-only log, and this runs per line.
    return null;
  }
}
