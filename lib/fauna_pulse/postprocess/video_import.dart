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

import 'dart:io';
import 'dart:math';

import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoInfo;

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
  const ImportClip({required this.path, required this.name, required this.sizeBytes, required this.info, required this.guess});

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
/// go into the start record. Returns the new session folder.
Future<Directory> importVideos({
  required Directory sessionsDir,
  required String sessionName,
  required List<ImportClip> clips,
  int shiftMs = 0,
  Map<String, dynamic> startExtras = const {},
  void Function(int done, int total, String name)? onProgress,
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
    await _moveOrCopy(File(clip.path), File('${videos.path}/$target'));
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
      'total_bytes': clips.fold<int>(0, (s, c) => s + c.sizeBytes),
      if (shiftMs != 0) 'start_shift_ms': shiftMs,
    },
  }, at: DateTime.fromMillisecondsSinceEpoch(first));
  for (final c in plan) {
    final clip = clips[c.index];
    final info = clip.info;
    logger.logVideoClip({
      'file': 'videos/${fileNames[c.index]}',
      'original_name': clip.name,
      'start_epoch_ms': c.startMs,
      'start_time_source': c.source,
      if (c.source != c.guess.source) 'start_time_guess_source': c.guess.source,
      if (shiftMs != 0) 'start_time_shift_ms': shiftMs,
      'duration_ms': info.durationMs,
      'size_bytes': clip.sizeBytes,
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
