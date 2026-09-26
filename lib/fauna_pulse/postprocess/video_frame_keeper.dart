// FaunaPulse (round 234): saves the frames "Find visits" chose to keep
// (video_tracker.dart: first frame of each visit, then one every N s for up
// to M s) from the clips into roi_frames/, where live photos go.
//
// The list comes from the `capture` records of post_tracks.jsonl. A frame
// whose file is already there is skipped, so a stopped or killed run
// continues where it left off, and "Find visits" again only costs the frames
// that changed. Each clip is read once, front to back, by the phone's video
// decoder (VideoFrameSource.kt); a long stretch without a wanted frame is
// jumped over. The saved picture is the analysed area at full size, JPEG
// quality 90.

import 'dart:io';

import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../logging/app_error_hooks.dart';
import 'video_tracker.dart';

/// The decoder calls the keeper needs; tests replace them.
abstract class FrameSaveBackend {
  Future<void> open(String path, List<int> roiPx);
  Future<SavedFramesChunk> save(List<int> ptsUs, List<String> paths);
  Future<void> close();
}

/// [FrameSaveBackend] over the plugin.
class NativeFrameSaveBackend implements FrameSaveBackend {
  const NativeFrameSaveBackend();

  @override
  Future<void> open(String path, List<int> roiPx) => VideoFrameSource.openFrames(path, roiPx: roiPx);

  @override
  Future<SavedFramesChunk> save(List<int> ptsUs, List<String> paths) =>
      VideoFrameSource.saveFrames(ptsUs: ptsUs, paths: paths);

  @override
  Future<void> close() => VideoFrameSource.close();
}

/// How many of a session's kept frames are saved.
class KeptFramesStatus {
  final int total;
  final int saved;

  /// Not saved and can't be: their video is no longer in videos/.
  final int noVideo;

  const KeptFramesStatus({required this.total, required this.saved, required this.noVideo});

  static const none = KeptFramesStatus(total: 0, saved: 0, noVideo: 0);

  /// Frames a run can still save.
  int get remaining => total - saved - noVideo;
}

/// What one [VideoFrameKeeper.run] did.
class KeepFramesResult {
  final int saved;

  /// Frames the clip did not reach (it ends earlier than its records say).
  final int missing;

  /// Frames not saved because their clip could not be read or is gone.
  final int failed;
  final bool cancelled;
  final Duration elapsed;

  const KeepFramesResult({
    required this.saved,
    required this.missing,
    required this.failed,
    required this.cancelled,
    required this.elapsed,
  });
}

class VideoFrameKeeper {
  /// Frames asked for per decoder call; each call also stops after its time
  /// budget, so progress and Stop stay responsive.
  static const batch = 12;

  final FrameSaveBackend backend;
  const VideoFrameKeeper({this.backend = const NativeFrameSaveBackend()});

  static Directory framesDirOf(Directory sessionDir) => Directory('${sessionDir.path}/${VideoTracker.framesDirName}');

  static Future<KeptFramesStatus> status(Directory sessionDir) async {
    final all = await VideoTracker.readKeptFrames(sessionDir);
    if (all.isEmpty) return KeptFramesStatus.none;
    final dir = framesDirOf(sessionDir).path;
    var saved = 0, noVideo = 0;
    final videoThere = <String, bool>{};
    for (final k in all) {
      if (File('$dir/${k.file}').existsSync()) {
        saved++;
      } else if (!videoThere.putIfAbsent(k.clip, () => File('${sessionDir.path}/videos/${k.clip}').existsSync())) {
        noVideo++;
      }
    }
    return KeptFramesStatus(total: all.length, saved: saved, noVideo: noVideo);
  }

  /// Saves every kept frame of [sessionDir] that is not saved yet.
  /// [onProgress] gets (frames dealt with, frames to deal with).
  Future<KeepFramesResult> run(
    Directory sessionDir, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final started = DateTime.now();
    final dir = framesDirOf(sessionDir);
    final todo = [
      for (final k in await VideoTracker.readKeptFrames(sessionDir))
        if (!File('${dir.path}/${k.file}').existsSync()) k,
    ];
    // One pass per clip (and area), in video order.
    final groups = <String, List<KeptFrame>>{};
    for (final k in todo) {
      (groups['${k.clip}|${k.roiPx.join(',')}'] ??= []).add(k);
    }
    final total = todo.length;
    var done = 0, saved = 0, missing = 0, failed = 0;
    var cancelled = false;
    onProgress?.call(0, total);
    if (total > 0) dir.createSync(recursive: true);
    for (final group in groups.values) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      group.sort((a, b) => a.ptsUs.compareTo(b.ptsUs));
      final video = File('${sessionDir.path}/videos/${group.first.clip}');
      if (!video.existsSync()) {
        failed += group.length;
        done += group.length;
        onProgress?.call(done, total);
        continue;
      }
      var rest = group;
      try {
        await backend.open(video.path, group.first.roiPx);
        while (rest.isNotEmpty) {
          if (isCancelled?.call() ?? false) {
            cancelled = true;
            break;
          }
          final ask = rest.take(batch).toList();
          final chunk = await backend.save(
            [for (final k in ask) k.ptsUs],
            [for (final k in ask) '${dir.path}/${k.file}'],
          );
          if (chunk.processed <= 0) throw StateError('The video decoder made no progress.');
          saved += chunk.saved.length;
          missing += chunk.missing.length;
          rest = rest.sublist(chunk.processed.clamp(0, rest.length));
          done += chunk.processed;
          onProgress?.call(done, total);
        }
      } catch (e) {
        logSwallowed('video_keep_frames', e);
        failed += rest.length;
        done += rest.length;
        onProgress?.call(done, total);
      } finally {
        try {
          await backend.close();
        } catch (e) {
          logSwallowed('video_keep_frames_close', e);
        }
      }
      if (cancelled) break;
    }
    return KeepFramesResult(
      saved: saved,
      missing: missing,
      failed: failed,
      cancelled: cancelled,
      elapsed: DateTime.now().difference(started),
    );
  }
}
