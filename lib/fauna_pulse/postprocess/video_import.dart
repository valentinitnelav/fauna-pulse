// FaunaPulse (round 227): turns picked video files into a session folder.
//
// An imported session looks like a recorded one from the outside (a folder
// under sessions/ with a session.jsonl), so the home list, rename, delete and
// later the summary work unchanged:
//
//   sessions/<name>/videos/<clip>.mp4   the files, moved or copied in
//   sessions/<name>/session.jsonl       start_of_session {source: imported_video}
//                                       video_clip per clip (start time + its source)
//                                       end_of_session {ended_normally: true}
//
// The log holds only provenance (what was imported, when each clip started
// and how that time was found); detection results go to separate files.
// Paths in the log are relative to the session folder, so renaming the
// session keeps working.
//
// Round 252: a fragmented MP4 (as YouTube downloaders save them) is written
// once more as a plain MP4 on the way in (every frame copied unchanged): the
// phone's player cannot jump in a fragmented one and showed boxes on the
// wrong picture after every jump.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoFrameSource, VideoInfo;

import '../logging/session_logger.dart';
import '../logging/session_rename.dart' show sanitizeSessionName;
import 'video_detector.dart';
import 'video_start_time.dart';

/// One picked file: the file picker's copy, its original name and facts.
class ImportClip {
  final String path;
  final String name;
  final int sizeBytes;
  final VideoInfo info;
  final VideoStartGuess guess;

  /// A fragmented MP4 ([isFragmentedMp4]): rewritten as a plain one on import.
  final bool fragmented;
  const ImportClip({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.info,
    required this.guess,
    this.fragmented = false,
  });

  int get durationMs => info.durationMs ?? 0;

  /// Why this file cannot be imported (plain language), or null.
  String? get problem {
    final ext = name.split('.').last.toLowerCase();
    if (!name.contains('.') || !VideoDetector.videoExtensions.contains(ext)) {
      return 'Not a supported video file (${VideoDetector.videoExtensions.join(', ')}).';
    }
    return info.unsupportedReason;
  }
}

/// Start of every clip after [layOutClips], shifted by [shiftMs] (the
/// user's correction of the session start on the import screen).
List<ClipStart> planImport(List<ImportClip> clips, {int shiftMs = 0}) {
  final laid = layOutClips([
    for (var i = 0; i < clips.length; i++) ClipStart(clips[i].name, clips[i].durationMs, clips[i].guess, index: i),
  ]);
  if (shiftMs == 0) return laid;
  return [
    for (final c in laid)
      ClipStart(c.name, c.durationMs, c.guess, index: c.index, startMs: c.startMs + shiftMs, source: 'user'),
  ];
}

/// Whether [f] is a fragmented MP4: its pictures sit in `moof` boxes after
/// an index without frames (YouTube downloaders, some recorders). Reads only
/// the top-level box headers.
bool isFragmentedMp4(File f) {
  RandomAccessFile? raf;
  try {
    final len = f.lengthSync();
    raf = f.openSync();
    var pos = 0;
    while (pos + 8 <= len) {
      raf.setPositionSync(pos);
      final h = raf.readSync(16);
      if (h.length < 8) return false;
      final type = String.fromCharCodes(h.sublist(4, 8));
      if (pos == 0 && type != 'ftyp') return false; // not an MP4 family file
      if (type == 'moof') return true;
      var size = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
      if (size == 1 && h.length == 16) {
        size = 0;
        for (var i = 8; i < 16; i++) {
          size = (size << 8) | h[i];
        }
      }
      if (size < 8) return false;
      pos += size;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    raf?.closeSync();
  }
}

/// A fragmented clip could not be rewritten; [toString] is the message the
/// import screen shows.
class ImportRewriteFailed implements Exception {
  final String clip;
  final String reason;
  const ImportRewriteFailed(this.clip, this.reason);

  @override
  String toString() =>
      '$clip could not be rewritten as a plain MP4 ($reason). Convert it on a computer without '
      're-compressing (e.g. "ffmpeg -i in.mp4 -c copy out.mp4") and import the result.';
}

/// A file-system-safe clip name: letters, digits, `_`, `-`, `.` only.
String safeClipName(String name) {
  final s = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
  return s.isEmpty ? 'clip.mp4' : s;
}

/// Suggested session name: `video_` plus the first clip's local date.
String defaultImportName(int firstStartMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(firstStartMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return 'video_${t.year}${two(t.month)}${two(t.day)}';
}

/// Creates the session under [sessionsDir] (a numeric suffix is added when
/// the name is taken, as for recordings), moves or copies every clip into
/// `videos/` and writes session.jsonl. [startExtras] (device, app version)
/// go into the start record. A fragmented clip is rewritten by [remux]
/// instead (default: the native one), reporting its share done through
/// [onRewrite]. Returns the new session folder.
Future<Directory> importVideos({
  required Directory sessionsDir,
  required String sessionName,
  required List<ImportClip> clips,
  int shiftMs = 0,
  Map<String, dynamic> startExtras = const {},
  void Function(int done, int total, String name)? onProgress,
  void Function(double fraction)? onRewrite,
  Future<Map<String, dynamic>> Function(String src, String dst) remux = VideoFrameSource.remux,
}) async {
  final plan = planImport(clips, shiftMs: shiftMs);

  final safe = sanitizeSessionName(sessionName).isEmpty ? 'video' : sanitizeSessionName(sessionName);
  var dir = Directory('${sessionsDir.path}/$safe');
  for (var i = 2; dir.existsSync(); i++) {
    dir = Directory('${sessionsDir.path}/${safe}_$i');
  }
  final videos = Directory('${dir.path}/videos')..createSync(recursive: true);

  // Move or copy in start order; two picks with one name get a suffix.
  final fileNames = <int, String>{};
  final rewritten = <int, Map<String, dynamic>>{};
  int sizeOf(int index) => (rewritten[index]?['bytes'] as num?)?.toInt() ?? clips[index].sizeBytes;
  for (var i = 0; i < plan.length; i++) {
    final clip = clips[plan[i].index];
    onProgress?.call(i, plan.length, clip.name);
    final base = safeClipName(clip.name);
    final dot = base.lastIndexOf('.');
    var target = base;
    for (var k = 2; fileNames.containsValue(target); k++) {
      target = dot > 0 ? '${base.substring(0, dot)}_$k${base.substring(dot)}' : '${base}_$k';
    }
    fileNames[plan[i].index] = target;
    final to = File('${videos.path}/$target');
    if (!clip.fragmented) {
      await _moveOrCopy(File(clip.path), to);
      continue;
    }
    // Written under another name first, so a killed import leaves no
    // half file that looks like a clip.
    final part = File('${to.path}.part');
    final progress = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (part.existsSync() && clip.sizeBytes > 0) onRewrite?.call(min(1.0, part.lengthSync() / clip.sizeBytes));
    });
    try {
      rewritten[plan[i].index] = await remux(clip.path, part.path);
    } catch (e) {
      // Nothing is logged yet: no half session is left behind.
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort; the error below is what the user needs.
      }
      throw ImportRewriteFailed(clip.name, '$e');
    } finally {
      progress.cancel();
    }
    await part.rename(to.path);
    try {
      await File(clip.path).delete();
    } on FileSystemException {
      // The picker's cache is cleared after the import anyway.
    }
  }
  onProgress?.call(plan.length, plan.length, '');

  final first = plan.first.startMs;
  final last = plan.map((c) => c.endMs).reduce(max);
  final logger = SessionLogger(File('${dir.path}/session.jsonl'))..open();
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
  final rng = Random.secure();
  logger.logStart({
    'session_id': DateTime.now().millisecondsSinceEpoch.toString(),
    // Frames saved from these clips later carry this token, as photos do.
    'file_token': String.fromCharCodes(Iterable.generate(4, (_) => alphabet.codeUnitAt(rng.nextInt(36)))),
    'source': 'imported_video',
    'imported_at': isoWithOffset(DateTime.now()),
    ...startExtras,
    'video': {
      'clips': plan.length,
      'total_duration_ms': plan.fold<int>(0, (s, c) => s + c.durationMs),
      'total_bytes': [for (var i = 0; i < clips.length; i++) sizeOf(i)].fold<int>(0, (s, b) => s + b),
      if (shiftMs != 0) 'start_shift_ms': shiftMs,
    },
  }, at: DateTime.fromMillisecondsSinceEpoch(first));
  for (final c in plan) {
    final clip = clips[c.index];
    final info = clip.info;
    final rw = rewritten[c.index];
    logger.logVideoClip({
      'file': 'videos/${fileNames[c.index]}',
      'original_name': clip.name,
      'start_epoch_ms': c.startMs,
      'start_time_source': c.source,
      if (c.source != c.guess.source) 'start_time_guess_source': c.guess.source,
      if (shiftMs != 0) 'start_time_shift_ms': shiftMs,
      'duration_ms': info.durationMs,
      'size_bytes': sizeOf(c.index),
      if (rw != null) ...{
        'rewritten_from': 'fragmented_mp4',
        'original_size_bytes': clip.sizeBytes,
        'rewrite_ms': rw['elapsedMs'],
        if ((rw['droppedTracks'] as List?)?.isNotEmpty ?? false) 'rewrite_dropped_tracks': rw['droppedTracks'],
      },
      'width': info.width,
      'height': info.height,
      'rotation': info.rotation,
      'codec': info.mime,
      'frame_count': info.frameCount,
      'fps_mean': info.meanFps,
      'fps_nominal': info.nominalFps,
      'stored_time_ms': ?info.creationEpochMs,
    }, at: DateTime.fromMillisecondsSinceEpoch(c.startMs));
  }
  logger.logEnd({'ended_normally': true, 'source': 'imported_video'}, at: DateTime.fromMillisecondsSinceEpoch(last));
  await logger.close();
  return dir;
}

/// A rename is instant but only works on one storage volume (the picker's
/// cache is on another), so fall back to copy + delete.
Future<void> _moveOrCopy(File from, File to) async {
  try {
    await from.rename(to.path);
  } on FileSystemException {
    await from.copy(to.path);
    try {
      await from.delete();
    } on FileSystemException {
      // The picker's cache is cleared after the import anyway.
    }
  }
}
