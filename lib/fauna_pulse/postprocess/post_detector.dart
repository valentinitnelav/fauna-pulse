// FaunaPulse — post-hoc batch detection over a session's saved ROI photos.
//
// "Post-hoc" = after the fact: instead of (or in addition to) detecting insects
// live during recording, this module walks the JPEGs a finished session saved
// in its `roi_frames/` folder and runs the detector on each one, at whatever
// speed the phone manages — there is no real-time constraint, so a larger /
// higher-resolution model can be used than during live recording.
//
// Results are appended to `post_detections.jsonl` inside the session folder
// (same strict one-JSON-object-per-line format as session.jsonl — never
// pretty-printed). The file is append-only, which makes a run *resumable*:
// on a restart the driver first reads which photos already have a
// `post_detection` record and skips them.
//
// The detector itself is injected as a function ([PredictFn]) so the driver's
// logic (which files to process, how to time-stamp them, how records look) is
// unit-testable without the native inference channel.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../logging/app_error_hooks.dart';

/// Runs the model on one encoded JPEG and returns the plugin's result map
/// (the shape `YOLO.predict` returns: a 'detections' list whose entries carry
/// `className`, `confidence` and a 0..1 `normalizedBox`).
typedef PredictFn = Future<Map<String, dynamic>> Function(Uint8List imageBytes);

/// Progress callback: [done] of [total] pending photos handled so far in THIS
/// run (processed + failed), with the average per-photo wall time in ms.
typedef PostProgressFn = void Function(int done, int total, double avgMs);

/// What a finished (or cancelled) run did.
class PostRunResult {
  /// Photos successfully processed in this run.
  final int processed;

  /// Photos that errored (unreadable file, inference failure) in this run.
  final int failed;

  /// Photos skipped because an earlier run already processed them.
  final int skippedDone;

  final Duration elapsed;
  final bool cancelled;

  const PostRunResult({
    required this.processed,
    required this.failed,
    required this.skippedDone,
    required this.elapsed,
    required this.cancelled,
  });
}

/// The capture moment encoded in a session photo's file name, as milliseconds
/// since epoch (local time), or null when the name doesn't carry one.
///
/// Photo names look like `roi_k7x2_2026-07-14_153045_123.jpg` — the date/time
/// part is the TRIGGER moment stamped by the capture pipeline, and the docs
/// declare the file name (plus the JSONL log) the capture-time ground truth,
/// so parsing it here needs no log scan.
int? capturedAtMsFromPhotoName(String name) {
  final m = RegExp(
    r'_(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})(\d{2})_(\d{3})',
  ).firstMatch(name);
  if (m == null) return null;
  try {
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
      int.parse(m.group(7)!),
    ).millisecondsSinceEpoch;
  } catch (_) {
    return null;
  }
}

/// Selects which of a session's photo file names to process, sorted by name
/// (which equals capture order within a session).
///
/// High-res photos save a trigger-moment companion crop as `<name>_live.jpg`
/// (round 108). BOTH members of such a pair are analyzed (round 137): the
/// companion is lower-resolution but exactly the trigger moment and often
/// sharper (no capture lag / motion ghosting), so it can catch an insect the
/// high-res photo missed — and vice versa. The keep/cleanup logic treats the
/// pair as one unit (photo_keep.dart), so a hit on either member keeps both.
List<String> selectPhotoNames(Iterable<String> allJpegNames) {
  return allJpegNames.where((n) => n.toLowerCase().endsWith('.jpg')).toList()
    ..sort();
}

/// File names already carrying a `post_detection` record in an existing
/// post_detections.jsonl content, so a resumed run can skip them.
Set<String> processedNamesFromJsonl(String jsonlContent) {
  final done = <String>{};
  for (final line in const LineSplitter().convert(jsonlContent)) {
    if (!line.contains('"post_detection"')) continue;
    try {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      if (rec['type'] == 'post_detection' && rec['jpeg'] is String) {
        done.add(rec['jpeg'] as String);
      }
    } catch (_) {
      // A line truncated by a crash/kill is expected in an append-only file.
    }
  }
  return done;
}

/// One detected box parsed out of the plugin's result map.
class PostBox {
  final String className;
  final double confidence;

  /// Normalized (0..1 of the analyzed image) left/top/right/bottom edges.
  final double left, top, right, bottom;

  const PostBox({
    required this.className,
    required this.confidence,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  Map<String, dynamic> toJson() => {
    'class_name': className,
    'conf': confidence,
    // Fixed edge order [left, top, right, bottom], matching the live log's
    // box_in_roi convention.
    'box': [left, top, right, bottom],
  };
}

/// Parses the 'detections' list of a `YOLO.predict` result map.
List<PostBox> boxesFromPredictResult(Map<String, dynamic> result) {
  final detections = result['detections'];
  if (detections is! List) return const [];
  final out = <PostBox>[];
  for (final d in detections) {
    if (d is! Map) continue;
    final norm = d['normalizedBox'];
    if (norm is! Map) continue;
    double edge(String k) => (norm[k] as num?)?.toDouble() ?? 0;
    out.add(
      PostBox(
        className: (d['className'] as String?) ?? '',
        confidence: (d['confidence'] as num?)?.toDouble() ?? 0,
        left: edge('left'),
        top: edge('top'),
        right: edge('right'),
        bottom: edge('bottom'),
      ),
    );
  }
  return out;
}

/// Settings of one batch run, echoed into the output file's header record so
/// the results stay interpretable later (which model, which thresholds).
class PostRunConfig {
  /// Model id as the catalog stores it (official id / asset path / file path).
  final String modelPath;

  /// Human-readable model name for the header record.
  final String modelName;

  final double confidence;
  final double iou;
  final bool useGpu;

  /// Tiling parameters of a SAHI run (round 139, `SahiOptions.toJson`), or
  /// null for a plain run. Echoed into the header record only.
  final Map<String, dynamic>? sahi;

  const PostRunConfig({
    required this.modelPath,
    required this.modelName,
    required this.confidence,
    required this.iou,
    required this.useGpu,
    this.sahi,
  });
}

/// Walks one session folder's photos through [predict] and appends results to
/// `post_detections.jsonl` in that folder.
class PostDetector {
  static const outputFileName = 'post_detections.jsonl';

  final PredictFn predict;

  PostDetector({required this.predict});

  /// Processes every not-yet-processed photo of [sessionDir]'s `roi_frames/`
  /// — or EVERY photo when [force] is set (round 139: re-analyze with a
  /// different model or tiling settings; `photoOutcomesFromJsonl` takes the
  /// last record per photo, so the newest run wins everywhere downstream).
  ///
  /// Calls [onProgress] after every photo; checks [isCancelled] between photos
  /// so a cancel takes effect within one inference. Never throws for a single
  /// bad photo — it is recorded as failed and the run continues.
  Future<PostRunResult> run(
    Directory sessionDir, {
    required PostRunConfig config,
    PostProgressFn? onProgress,
    bool Function()? isCancelled,
    String appVersion = '',
    bool force = false,
  }) async {
    final started = DateTime.now();
    final framesDir = Directory('${sessionDir.path}/roi_frames');
    final outFile = File('${sessionDir.path}/$outputFileName');

    final allNames = framesDir.existsSync()
        ? framesDir
              .listSync()
              .whereType<File>()
              .map((f) => f.path.split('/').last)
              .where((n) => n.toLowerCase().endsWith('.jpg'))
              .toList()
        : <String>[];
    final candidates = selectPhotoNames(allNames);
    final done = outFile.existsSync()
        ? processedNamesFromJsonl(await outFile.readAsString())
        : <String>{};
    final pending = force
        ? candidates
        : candidates.where((n) => !done.contains(n)).toList();

    final sink = outFile.openWrite(mode: FileMode.append);
    void writeRecord(Map<String, dynamic> record) {
      final now = DateTime.now();
      sink.writeln(
        jsonEncode({
          'type': record.remove('_type'),
          'time_ms': now.millisecondsSinceEpoch,
          'time_iso': now.toIso8601String(),
          ...record,
        }),
      );
    }

    writeRecord({
      '_type': 'post_start',
      'model': config.modelPath,
      'model_name': config.modelName,
      'confidence': config.confidence,
      'iou': config.iou,
      'use_gpu': config.useGpu,
      'photos_total': candidates.length,
      'photos_pending': pending.length,
      if (force) 'reanalyzed_all': true,
      if (config.sahi != null) 'sahi': config.sahi,
      if (appVersion.isNotEmpty) 'app_version': appVersion,
    });

    var processed = 0, failed = 0;
    var cancelled = false;
    for (final name in pending) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final t0 = DateTime.now();
      try {
        final bytes = await File('${framesDir.path}/$name').readAsBytes();
        final result = await predict(bytes);
        final boxes = boxesFromPredictResult(result);
        writeRecord({
          '_type': 'post_detection',
          'jpeg': name,
          'captured_at_ms': capturedAtMsFromPhotoName(name),
          'infer_ms': DateTime.now().difference(t0).inMilliseconds,
          'boxes': [for (final b in boxes) b.toJson()],
        });
        processed++;
      } catch (e) {
        logSwallowed('post_detect_photo', e);
        writeRecord({
          '_type': 'post_detection',
          'jpeg': name,
          'captured_at_ms': capturedAtMsFromPhotoName(name),
          'error': '$e',
          'boxes': const <Map<String, dynamic>>[],
        });
        failed++;
      }
      final doneCount = processed + failed;
      // Flush periodically so a kill mid-run loses at most a few records.
      if (doneCount % 20 == 0) await sink.flush();
      onProgress?.call(
        doneCount,
        pending.length,
        DateTime.now().difference(started).inMilliseconds /
            (doneCount == 0 ? 1 : doneCount),
      );
    }

    final skippedDone = force ? 0 : done.length;
    writeRecord({
      '_type': 'post_end',
      'processed': processed,
      'failed': failed,
      'skipped_done': skippedDone,
      'ended_normally': !cancelled,
      if (cancelled) 'reason': 'cancelled',
    });
    await sink.flush();
    await sink.close();

    return PostRunResult(
      processed: processed,
      failed: failed,
      skippedDone: skippedDone,
      elapsed: DateTime.now().difference(started),
      cancelled: cancelled,
    );
  }
}
