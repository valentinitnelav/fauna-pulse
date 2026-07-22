// FaunaPulse — which analyzed photos to keep, and the cleanup that deletes
// the rest (round 136).
//
// The point of post-hoc analysis on AI-free sessions (motion / time-lapse
// capture) is storage triage: keep on the phone only the photos that most
// probably contain an insect. "Probably" is deliberately generous:
//
//   * a photo with at least one detection is kept;
//   * a photo within [gap] seconds of ANY detected photo is kept too — if the
//     detector fires in one photo and misses the next, it is most likely the
//     same individual, so the neighbour survives (this simple time rule covers
//     what a tracker would, without needing one at 1-photo-per-second cadence);
//   * a photo whose analysis FAILED (unreadable, inference error) is kept —
//     "no result" is not "no insect".
//
// Deletion appends a `post_cleanup` record to post_detections.jsonl so the
// file stays the audit trail of what happened to the session's photos.

import 'dart:convert';
import 'dart:io';

import '../logging/app_error_hooks.dart';
import 'post_detector.dart';

/// One photo's analysis outcome, parsed back out of post_detections.jsonl.
/// [hasBoxes] is null when the record carries an `error` instead of results.
class PhotoOutcome {
  final String name;
  final int? capturedAtMs;
  final bool? hasBoxes;
  const PhotoOutcome(this.name, this.capturedAtMs, this.hasBoxes);
}

/// Parses every `post_detection` record of [jsonlContent]; when a photo was
/// recorded more than once (a re-run with another model), the LAST record wins.
List<PhotoOutcome> photoOutcomesFromJsonl(String jsonlContent) {
  final latest = <String, PhotoOutcome>{};
  for (final line in const LineSplitter().convert(jsonlContent)) {
    if (!line.contains('"post_detection"')) continue;
    try {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      if (rec['type'] != 'post_detection' || rec['jpeg'] is! String) continue;
      final name = rec['jpeg'] as String;
      final boxes = rec['boxes'];
      latest[name] = PhotoOutcome(
        name,
        (rec['captured_at_ms'] as num?)?.toInt(),
        rec['error'] != null ? null : boxes is List && boxes.isNotEmpty,
      );
    } catch (_) {
      // Truncated lines are expected in an append-only file.
    }
  }
  return latest.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// The photo names to KEEP: detections, their time-neighbours within
/// [gapMs] milliseconds, and failed analyses (see the file comment).
Set<String> keepNames(List<PhotoOutcome> outcomes, int gapMs) {
  final keep = <String>{};
  final detectedTimes = <int>[];
  for (final o in outcomes) {
    if (o.hasBoxes == null || o.hasBoxes == true) keep.add(o.name);
    if (o.hasBoxes == true && o.capturedAtMs != null) {
      detectedTimes.add(o.capturedAtMs!);
    }
  }
  if (detectedTimes.isNotEmpty && gapMs > 0) {
    detectedTimes.sort();
    for (final o in outcomes) {
      final t = o.capturedAtMs;
      if (t == null || keep.contains(o.name)) continue;
      // Binary search for the nearest detection time around t.
      var lo = 0, hi = detectedTimes.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (detectedTimes[mid] < t) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      final nearBefore = lo > 0 && t - detectedTimes[lo - 1] <= gapMs;
      final nearAfter =
          lo < detectedTimes.length && detectedTimes[lo] - t <= gapMs;
      if (nearBefore || nearAfter) keep.add(o.name);
    }
  }
  return keep;
}

/// What a cleanup preview / run affects.
class CleanupPlan {
  final List<String> deleteNames;
  final int keepCount;
  final int deleteBytes;
  const CleanupPlan({
    required this.deleteNames,
    required this.keepCount,
    required this.deleteBytes,
  });
}

/// Sizes up a cleanup without deleting anything: which analyzed photos of
/// [sessionDir] fall outside [keep], including each one's `_live.jpg`
/// companion (the companion shows the same moment, so it goes with its main
/// photo), and how many bytes deleting them frees.
CleanupPlan planCleanup(
  Directory sessionDir,
  List<PhotoOutcome> outcomes,
  Set<String> keep,
) {
  final framesPath = '${sessionDir.path}/roi_frames';
  final deleteNames = <String>[];
  var bytes = 0;
  void addIfExists(String name) {
    final f = File('$framesPath/$name');
    if (!f.existsSync()) return;
    deleteNames.add(name);
    bytes += f.statSync().size;
  }

  for (final o in outcomes) {
    if (keep.contains(o.name)) continue;
    addIfExists(o.name);
    if (o.name.toLowerCase().endsWith('.jpg') && !o.name.endsWith('_live.jpg')) {
      addIfExists('${o.name.substring(0, o.name.length - 4)}_live.jpg');
    }
  }
  return CleanupPlan(
    deleteNames: deleteNames,
    keepCount: keep.length,
    deleteBytes: bytes,
  );
}

/// Deletes [plan]'s photos from [sessionDir]/roi_frames and appends a
/// `post_cleanup` audit record. Returns how many files were actually deleted
/// (a file already gone just counts as done).
Future<int> runCleanup(
  Directory sessionDir,
  CleanupPlan plan, {
  required double gapSeconds,
}) async {
  var deleted = 0;
  for (final name in plan.deleteNames) {
    try {
      final f = File('${sessionDir.path}/roi_frames/$name');
      if (f.existsSync()) {
        f.deleteSync();
        deleted++;
      }
    } catch (e) {
      logSwallowed('post_cleanup_delete', e);
    }
  }
  try {
    final now = DateTime.now();
    File(
      '${sessionDir.path}/${PostDetector.outputFileName}',
    ).writeAsStringSync(
      '${jsonEncode({
        'type': 'post_cleanup',
        'time_ms': now.millisecondsSinceEpoch,
        'time_iso': now.toIso8601String(),
        'gap_seconds': gapSeconds,
        'deleted': deleted,
        'kept': plan.keepCount,
        'freed_bytes': plan.deleteBytes,
      })}\n',
      mode: FileMode.append,
    );
  } catch (e) {
    logSwallowed('post_cleanup_record', e);
  }
  return deleted;
}

/// How the photos of a recorded session were triggered, read from the start
/// record of its session.jsonl (the `config` block every start record embeds).
/// [captureTrigger] is 'detector' / 'motion' / 'timelapse' (legacy configs
/// without the field map like SessionConfig.fromJson does); [modelPath] is
/// the model the session had selected (loaded but never run in the AI-free
/// modes).
class LiveSessionInfo {
  final String captureTrigger;
  final String? modelPath;
  const LiveSessionInfo(this.captureTrigger, this.modelPath);

  bool get usedDetectorLive => captureTrigger == 'detector';
}

/// Parses [logHead] (the first few KB of a session.jsonl) for the start
/// record's capture trigger + model. Null when no start record is found.
LiveSessionInfo? liveSessionInfoFromLogHead(String logHead) {
  for (final line in const LineSplitter().convert(logHead)) {
    if (!line.contains('"start_of_session"')) continue;
    try {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      final config = rec['config'];
      if (config is! Map) return const LiveSessionInfo('detector', null);
      // Same legacy mapping as SessionConfig: explicit captureTrigger wins,
      // then the round-95 motionOnlyCapture bool, else detector.
      final trigger =
          (config['captureTrigger'] as String?) ??
          ((config['motionOnlyCapture'] as bool? ?? false)
              ? 'motion'
              : 'detector');
      return LiveSessionInfo(trigger, config['modelPath'] as String?);
    } catch (_) {
      return null;
    }
  }
  return null;
}
