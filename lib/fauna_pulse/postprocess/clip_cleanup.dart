// FaunaPulse (round 236): deleting a session's videos once their visits are
// found, to free storage (video plan Phase 2d, after photo_keep.dart's
// cleanup of photos).
//
// The videos take most of a session's space, but everything the app derives
// from them survives without them: the AI's boxes (video_detections.jsonl),
// the visits (post_tracks.jsonl, visits.csv, mot/) and the kept frames
// (roi_frames/). "Find visits" can run again from the boxes. What goes is
// playing a clip, running the AI on it again (another square or model) and
// keeping other frames from it; the tracker never overwrites or deletes kept
// frames whose clip is gone (video_tracker.dart).
//
// Two choices, clips are kept by default:
//   * the clips in which the current visits have no box at all;
//   * every clip (offered once all are analysed, followed by "Find visits"
//     and their kept frames saved; the screen checks that).
// Each deletion appends a `video_cleanup` record to session.jsonl, which only
// grows and already lists the imported clips, so what happened to them stays
// on record (DATA_GUIDE §9).

import 'dart:convert';
import 'dart:io';

import '../logging/app_error_hooks.dart';
import '../logging/session_logger.dart' show isoWithOffset;
import 'video_detector.dart';
import 'video_tracker.dart';

/// What a cleanup would delete.
class ClipCleanupPlan {
  /// `without_visits`, `all` or `cut_off` (the record's `mode`).
  final String mode;
  final List<String> deleteNames;
  final int deleteBytes;

  const ClipCleanupPlan({required this.mode, required this.deleteNames, required this.deleteBytes});

  bool get isEmpty => deleteNames.isEmpty;
}

class ClipCleanup {
  static const recordType = 'video_cleanup';
  static const modeWithoutVisits = 'without_track_ids'; // "without_visits" before round 248
  static const modeAll = 'all';

  /// Round 243: clips cut off by a killed app (see VideoDetector.isReadableVideo).
  static const modeCutOff = 'cut_off';

  /// Clips followed by the current "Find visits" (its `clips`) in which no
  /// visit has a box, and whose file is still there.
  static Future<ClipCleanupPlan> planWithoutVisits(Directory sessionDir) async {
    final tracked = <String>{};
    final withVisits = <String>{};
    final file = File('${sessionDir.path}/${VideoTracker.outputFileName}');
    if (file.existsSync()) {
      await for (final line
          in file.openRead().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
        // Visits leave `detections` and `track_event` records in every clip
        // they are seen in, a visit running on into the next clip included.
        final start = line.startsWith('{"type":"post_track_start"');
        if (!start && !line.startsWith('{"type":"detections"') && !line.startsWith('{"type":"track_event"')) {
          continue;
        }
        try {
          final rec = jsonDecode(line) as Map;
          if (start) {
            tracked.addAll([for (final c in rec['clips'] as List? ?? const []) '$c']);
          } else if (rec['clip'] is String) {
            withVisits.add(rec['clip'] as String);
          }
        } catch (_) {
          // a torn line
        }
      }
    }
    return _plan(sessionDir, modeWithoutVisits, (name) => tracked.contains(name) && !withVisits.contains(name));
  }

  /// Every clip file of the session.
  static Future<ClipCleanupPlan> planAll(Directory sessionDir) async => _plan(sessionDir, modeAll, (_) => true);

  /// The clips that cannot be read because the app stopped while recording them.
  static Future<ClipCleanupPlan> planCutOff(Directory sessionDir) async {
    final cut = {for (final f in VideoDetector.cutOffClipsOf(sessionDir)) f.uri.pathSegments.last};
    return _plan(sessionDir, modeCutOff, cut.contains);
  }

  static ClipCleanupPlan _plan(Directory sessionDir, String mode, bool Function(String name) delete) {
    final names = <String>[];
    var bytes = 0;
    for (final f in VideoDetector.clipsOf(sessionDir)) {
      final name = f.uri.pathSegments.last;
      if (!delete(name)) continue;
      names.add(name);
      bytes += f.lengthSync();
    }
    return ClipCleanupPlan(mode: mode, deleteNames: names..sort(), deleteBytes: bytes);
  }

  /// Deletes [plan]'s clips and appends the `video_cleanup` record. Returns
  /// how many files were deleted (a file already gone counts as done).
  static Future<int> run(Directory sessionDir, ClipCleanupPlan plan) async {
    final deleted = <String>[];
    var freed = 0;
    for (final name in plan.deleteNames) {
      try {
        final f = File('${sessionDir.path}/videos/$name');
        if (f.existsSync()) {
          freed += f.lengthSync();
          f.deleteSync();
        }
        deleted.add(name);
      } catch (e) {
        logSwallowed('video_cleanup_delete', e);
      }
    }
    try {
      final now = DateTime.now();
      File('${sessionDir.path}/session.jsonl').writeAsStringSync(
        '${jsonEncode({
          'type': recordType,
          'time_ms': now.millisecondsSinceEpoch,
          'time_iso': isoWithOffset(now),
          'mode': plan.mode,
          'clips': deleted,
          'freed_bytes': freed,
          'track_ids_run_id': ?(await VideoTracker.readSummary(sessionDir))?.runId,
        })}\n',
        mode: FileMode.append,
      );
    } catch (e) {
      logSwallowed('video_cleanup_record', e);
    }
    return deleted.length;
  }

  /// The clips deleted by a cleanup, with when (from session.jsonl).
  static Future<Map<String, DateTime>> deletedClips(Directory sessionDir) async {
    final out = <String, DateTime>{};
    final log = File('${sessionDir.path}/session.jsonl');
    if (!log.existsSync()) return out;
    try {
      await for (final line
          in log.openRead().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
        if (!line.contains('"$recordType"')) continue;
        try {
          final rec = jsonDecode(line) as Map;
          if (rec['type'] != recordType) continue;
          final at = DateTime.fromMillisecondsSinceEpoch((rec['time_ms'] as num).toInt());
          for (final c in rec['clips'] as List? ?? const []) {
            out['$c'] = at;
          }
        } catch (_) {
          // a torn line
        }
      }
    } catch (e) {
      logSwallowed('video_cleanup_read', e);
    }
    return out;
  }
}
