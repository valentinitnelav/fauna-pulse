// FaunaPulse (round 208): which crops to identify, from a session's records.
//
// AI sessions: every logged box with a track id on every saved photo (the
// session log index already pairs photos with their trigger-frame boxes).
// The in-sync `_live.jpg` companion of a high-res photo is preferred when it
// exists, because the logged boxes were observed on that frame. Photos from
// no-AI sessions carry no track ids; their post-hoc boxes are identified per
// photo. Pure functions, unit-tested.

import 'dart:convert';

import '../logging/session_log_index.dart';

/// One crop to embed: which file, which normalised box, which visit.
class CropTask {
  /// File name in roi_frames/ that is actually read (companion or photo).
  final String source;

  /// The photo the log record belongs to (for joins with session.jsonl).
  final String photo;

  /// 'live' (companion, exact), 'trigger' (main photo, trigger-frame box) or
  /// 'post' (post_detections.jsonl box, no track id).
  final String boxSource;
  final int? trackId;
  final double left, top, right, bottom;
  final double detConf;
  final int? captureMs;

  const CropTask({
    required this.source,
    required this.photo,
    required this.boxSource,
    required this.trackId,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.detConf,
    required this.captureMs,
  });

  double get area => (right - left).clamp(0, 1) * (bottom - top).clamp(0, 1);

  /// Resume key: one embedding per (file, track, box).
  String get key =>
      '$source|${trackId ?? '-'}|${left.toStringAsFixed(4)},${top.toStringAsFixed(4)},'
      '${right.toStringAsFixed(4)},${bottom.toStringAsFixed(4)}';
}

/// Crops of an AI session from its log index. [fileExists] decides whether a
/// `_live` companion can be used.
List<CropTask> planFromIndex(
  SessionLogIndex index, {
  required bool Function(String name) fileExists,
}) {
  final out = <CropTask>[];
  for (final name in index.photoOrder) {
    final photo = index.photos[name];
    if (photo == null || photo.isReference) continue;
    final live = photo.liveName;
    final useLive = live != null && fileExists(live);
    for (final box in photo.boxes) {
      if (box.trackId == null) continue;
      out.add(
        CropTask(
          source: useLive ? live : name,
          photo: name,
          boxSource: useLive ? 'live' : 'trigger',
          trackId: box.trackId,
          left: box.left,
          top: box.top,
          right: box.right,
          bottom: box.bottom,
          detConf: box.confidence ?? photo.trackConf[box.trackId!] ?? 1.0,
          captureMs: photo.captureMs,
        ),
      );
    }
  }
  return out;
}

/// Crops of a no-AI session from post_detections.jsonl (last record per photo
/// wins, like the summary viewer). No track ids: each crop is its own unit.
List<CropTask> planFromPostDetections(String jsonl) {
  final byPhoto = <String, Map<String, dynamic>>{};
  for (final line in const LineSplitter().convert(jsonl)) {
    if (!line.contains('"post_detection"')) continue;
    try {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      if (rec['type'] == 'post_detection' && rec['jpeg'] is String) {
        byPhoto[rec['jpeg'] as String] = rec;
      }
    } catch (_) {
      // truncated tail line
    }
  }
  final out = <CropTask>[];
  final names = byPhoto.keys.toList()..sort();
  for (final name in names) {
    final rec = byPhoto[name]!;
    final boxes = rec['boxes'];
    if (boxes is! List) continue;
    for (final b in boxes) {
      if (b is! Map) continue;
      final edges = b['box'];
      if (edges is! List || edges.length < 4) continue;
      out.add(
        CropTask(
          source: name,
          photo: name,
          boxSource: 'post',
          trackId: null,
          left: (edges[0] as num).toDouble(),
          top: (edges[1] as num).toDouble(),
          right: (edges[2] as num).toDouble(),
          bottom: (edges[3] as num).toDouble(),
          detConf: (b['conf'] as num?)?.toDouble() ?? 1.0,
          captureMs: (rec['captured_at_ms'] as num?)?.toInt(),
        ),
      );
    }
  }
  return out;
}

/// Keeps at most [maxPerTrack] crops per track id: the largest boxes (the
/// most pixels on the insect), returned in capture order. Crops without a
/// track id are never dropped.
List<CropTask> sampleTracks(List<CropTask> tasks, int maxPerTrack) {
  if (maxPerTrack <= 0) return tasks;
  final byTrack = <int, List<CropTask>>{};
  for (final t in tasks) {
    if (t.trackId != null) (byTrack[t.trackId!] ??= []).add(t);
  }
  final keep = <CropTask>{};
  for (final list in byTrack.values) {
    if (list.length <= maxPerTrack) {
      keep.addAll(list);
      continue;
    }
    final sorted = [...list]..sort((a, b) => b.area.compareTo(a.area));
    keep.addAll(sorted.take(maxPerTrack));
  }
  return [
    for (final t in tasks)
      if (t.trackId == null || keep.contains(t)) t,
  ];
}
