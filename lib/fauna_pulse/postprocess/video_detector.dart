// FaunaPulse (round 225): offline ("AI later") detection over a session's videos.
//
// Pass 1 of the video pipeline. Every clip in the session's `videos/` folder
// is decoded natively, the ROI square (or the whole frame) is cut out, and
// the detector runs on one frame per 1/analysisFps seconds. Boxes go to
// `video_detections.jsonl` as `raw_detections` records, the same shape live
// sessions log (tracking/tracker_replay.dart reads both), plus `clip`,
// `pts_us` and `frame` so every box can be found in the video again.
//
// Detecting is the slow step and tracking (pass 2) the fast one, so the boxes
// are kept: the tracker can be re-run with other settings without touching
// the model. The file is append-only and resumable: a killed run continues
// each clip after its last analysed frame. Different settings (model,
// thresholds, frame rate, ROI) need a fresh file, because boxes from two
// settings in one file would count frames twice; see [VideoSettingsChanged].
//
// The native side is injected ([VideoBackend]) so the driver's logic is
// unit-testable without a phone.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:ultralytics_yolo/ultralytics_yolo.dart'
    show VideoChunk, VideoFrameSource, VideoInfo;

import '../logging/app_error_hooks.dart';
import '../logging/device_thermal.dart';
import '../logging/thermal_pause.dart';
import 'video_start_time.dart';

/// The native decode + detect path (see VideoFrameSource.kt).
abstract class VideoBackend {
  Future<VideoInfo> info(String path);
  Future<void> open(String path, VideoRunConfig config, {required int startPtsUs});
  Future<VideoChunk> next();
  Future<void> close();
}

/// [VideoBackend] over the plugin, using the detector loaded as [instanceId]
/// (`YOLO.instanceId` after `loadModel`).
class NativeVideoBackend implements VideoBackend {
  final String instanceId;
  const NativeVideoBackend(this.instanceId);

  @override
  Future<VideoInfo> info(String path) => VideoFrameSource.info(path);

  @override
  Future<void> open(String path, VideoRunConfig config, {required int startPtsUs}) => VideoFrameSource.open(
    path,
    instanceId: instanceId,
    confidence: config.confidence,
    iou: config.iou,
    roi: config.roi,
    startPtsUs: startPtsUs,
    minIntervalUs: config.minIntervalUs,
    maxSidePx: config.maxSidePx,
  );

  @override
  Future<VideoChunk> next() => VideoFrameSource.next();

  @override
  Future<void> close() => VideoFrameSource.close();
}

/// Settings of one analysis run, echoed into the file's header record.
class VideoRunConfig {
  /// Model id as the catalog stores it, and its readable name.
  final String modelPath;
  final String modelName;
  final double confidence;
  final double iou;
  final bool useGpu;

  /// Frames analysed per second of video; 0 = every frame. 15 matches the
  /// live default, so video and live results compare like for like.
  final double analysisFps;

  /// Analysed square as (cx, cy, side) fractions of the upright frame (the
  /// live ROI convention), or null for the whole frame.
  final List<double>? roi;

  /// Larger areas are averaged down to about this many pixels per side
  /// before detection (the model shrinks them further anyway).
  final int maxSidePx;

  const VideoRunConfig({
    required this.modelPath,
    required this.modelName,
    required this.confidence,
    required this.iou,
    required this.useGpu,
    this.analysisFps = 15,
    this.roi,
    this.maxSidePx = 1280,
  });

  int get minIntervalUs => analysisFps <= 0 ? 0 : (1e6 / analysisFps).round();

  /// The settings that change the boxes: a file made with other values
  /// cannot be continued.
  Map<String, dynamic> get identity => {
    'model': modelPath,
    'confidence': confidence,
    'iou': iou,
    'analysis_fps': analysisFps,
    'roi': roi,
    'max_side_px': maxSidePx,
  };
}

/// Thrown by [VideoDetector.run] when the session's existing results were
/// made with other settings and `startOver` was not set. The UI asks the
/// user before replacing hours of analysis.
class VideoSettingsChanged implements Exception {
  final Map<String, dynamic> previous;
  const VideoSettingsChanged(this.previous);
  @override
  String toString() => 'The existing video results were made with other settings: $previous';
}

class VideoProgress {
  /// 0-based clip position and clip count.
  final int clipIndex;
  final int clipCount;
  final String clip;

  /// Position within the clip and its length, seconds.
  final double clipPosS;
  final double clipLengthS;

  /// Frames analysed in this run, and the average wall time per frame (ms).
  final int framesAnalysed;
  final double msPerFrame;
  final double? tempC;

  /// Non-empty while paused (plain-language reason).
  final String note;

  const VideoProgress({
    required this.clipIndex,
    required this.clipCount,
    required this.clip,
    required this.clipPosS,
    required this.clipLengthS,
    required this.framesAnalysed,
    required this.msPerFrame,
    this.tempC,
    this.note = '',
  });
}

class VideoRunResult {
  final int framesAnalysed;
  final int clipsDone;
  final int clipsFailed;
  final int thermalPauses;
  final Duration elapsed;
  final bool cancelled;
  const VideoRunResult({
    required this.framesAnalysed,
    required this.clipsDone,
    required this.clipsFailed,
    required this.thermalPauses,
    required this.elapsed,
    required this.cancelled,
  });
}

/// What an earlier (possibly killed) run left in the output file.
class VideoResume {
  /// `settings` of the last `video_run_start`, or null for no/empty file.
  final Map<String, dynamic>? settings;
  final Set<String> doneClips;

  /// Last analysed time stamp per clip.
  final Map<String, int> lastPtsUs;

  const VideoResume(this.settings, this.doneClips, this.lastPtsUs);

  static VideoResume parse(Iterable<String> lines) {
    Map<String, dynamic>? settings;
    final done = <String>{};
    final last = <String, int>{};
    for (final line in lines) {
      // Cheap prefilter: only three record types matter here.
      if (!line.contains('"raw_detections"') && !line.contains('"video_clip_done"') && !line.contains('"video_run_start"')) {
        continue;
      }
      Map<String, dynamic> rec;
      try {
        rec = (jsonDecode(line) as Map).cast<String, dynamic>();
      } catch (_) {
        continue; // a half-written last line after a kill
      }
      final clip = rec['clip'] as String?;
      switch (rec['type']) {
        case 'video_run_start':
          settings = (rec['settings'] as Map?)?.cast<String, dynamic>();
        case 'video_clip_done':
          if (clip != null) done.add(clip);
        case 'raw_detections':
          final pts = (rec['pts_us'] as num?)?.toInt();
          if (clip != null && pts != null && pts > (last[clip] ?? -1)) last[clip] = pts;
      }
    }
    return VideoResume(settings, done, last);
  }
}

class VideoDetector {
  static const outputFileName = 'video_detections.jsonl';
  static const videoExtensions = {'mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm'};

  final VideoBackend backend;
  final ThermalFn thermal;

  /// Sleep between temperature checks while paused.
  final Duration pausePoll;

  VideoDetector({required this.backend, ThermalFn? thermal, this.pausePoll = const Duration(seconds: 15)})
    : thermal = thermal ?? DeviceThermal.read;

  /// The session's clips (`videos/*`), sorted by file name.
  static List<File> clipsOf(Directory sessionDir) {
    final dir = Directory('${sessionDir.path}/videos');
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().where((f) {
      final name = f.path.split('/').last.toLowerCase();
      return videoExtensions.contains(name.split('.').last);
    }).toList()..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Clip start times (epoch ms) the session log knows, by file name: the
  /// import sheet or the recorder writes one `video_clip` record per clip.
  static Future<Map<String, int>> clipStartsFromLog(Directory sessionDir) async {
    final log = File('${sessionDir.path}/session.jsonl');
    final out = <String, int>{};
    if (!log.existsSync()) return out;
    final lines = log.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.contains('"video_clip"')) continue;
      try {
        final rec = jsonDecode(line) as Map;
        final file = rec['file'] as String?;
        final start = (rec['start_epoch_ms'] as num?)?.toInt();
        if (rec['type'] == 'video_clip' && file != null && start != null) out[file.split('/').last] = start;
      } catch (_) {}
    }
    return out;
  }

  /// Analyses every clip of [sessionDir] that is not finished yet, appending
  /// to [outputFileName]. Throws [VideoSettingsChanged] when the existing
  /// file was made with other settings, unless [startOver] (which replaces
  /// it). A clip that fails is logged (`video_clip_error`) and skipped; the
  /// next run retries it.
  Future<VideoRunResult> run(
    Directory sessionDir, {
    required VideoRunConfig config,
    void Function(VideoProgress p)? onProgress,
    bool Function()? isCancelled,
    double thermalLimitC = 40,
    String appVersion = '',
    bool startOver = false,
  }) async {
    final started = DateTime.now();
    final outFile = File('${sessionDir.path}/$outputFileName');
    var resume = outFile.existsSync()
        ? VideoResume.parse(await outFile.openRead().transform(utf8.decoder).transform(const LineSplitter()).toList())
        : const VideoResume(null, {}, {});
    final sameSettings = resume.settings == null || jsonEncode(resume.settings) == jsonEncode(config.identity);
    if (!sameSettings && !startOver) throw VideoSettingsChanged(resume.settings!);
    final replace = startOver && outFile.existsSync();
    if (replace) resume = const VideoResume(null, {}, {});

    final clips = clipsOf(sessionDir);
    final pending = clips.where((f) => !resume.doneClips.contains(f.path.split('/').last)).toList();
    final logStarts = await clipStartsFromLog(sessionDir);

    final sink = outFile.openWrite(mode: replace ? FileMode.write : FileMode.append);
    void writeRecord(String type, Map<String, dynamic> rec) {
      sink.writeln(jsonEncode({'type': type, 'time_ms': DateTime.now().millisecondsSinceEpoch, ...rec}));
    }

    writeRecord('video_run_start', {
      'settings': config.identity,
      'model_name': config.modelName,
      'use_gpu': config.useGpu,
      'thermal_limit_c': thermalLimitC,
      'clips_total': clips.length,
      'clips_pending': pending.length,
      if (replace) 'started_over': true,
      if (appVersion.isNotEmpty) 'app_version': appVersion,
    });

    var framesAnalysed = 0, clipsDone = 0, clipsFailed = 0, pauses = 0;
    var cancelled = false;
    final clock = Stopwatch()..start();

    for (var ci = 0; ci < pending.length && !cancelled; ci++) {
      final file = pending[ci];
      final clip = file.path.split('/').last;
      final clipClock = Stopwatch()..start();
      var clipFrames = 0, decoded = 0;
      var decodeMs = 0.0, convertMs = 0.0, inferMs = 0.0;
      var lastPts = resume.lastPtsUs[clip];
      VideoChunk? lastChunk;
      List<String>? names;
      try {
        final info = await backend.info(file.path);
        if (info.unsupportedReason != null) throw StateError(info.unsupportedReason!);
        final (startMs, startSource) = _clipStart(clip, info, file, logStarts);
        final firstPts = info.firstPtsUs ?? 0;
        final startPts = lastPts == null ? 0 : lastPts + (config.minIntervalUs > 0 ? config.minIntervalUs : 1);
        writeRecord('video_clip_start', {
          'clip': clip,
          'start_epoch_ms': startMs,
          'start_time_source': startSource,
          if (lastPts != null) 'resume_from_pts_us': startPts,
          'duration_ms': info.durationMs,
          'frame_count': info.frameCount,
          'mean_fps': info.meanFps,
          'nominal_fps': info.nominalFps,
          'width': info.width,
          'height': info.height,
          'rotation': info.rotation,
          'mime': info.mime,
        });
        await backend.open(file.path, config, startPtsUs: startPts);
        try {
          var done = false;
          double? tempC;
          while (!done) {
            if (isCancelled?.call() ?? false) {
              cancelled = true;
              break;
            }
            final warm = await waitWhileWarm(
              thermal: thermal,
              limitC: thermalLimitC,
              poll: pausePoll,
              isCancelled: isCancelled,
              onPaused: (t, note) => onProgress?.call(_progress(ci, pending.length, clip, lastPts, firstPts, info, framesAnalysed, clock, t, note)),
              errorTag: 'video_thermal',
            );
            tempC = warm.tempC;
            if (warm.paused) {
              pauses++;
              continue; // re-check cancel before the next chunk
            }
            final chunk = await backend.next();
            lastChunk = chunk;
            names ??= chunk.names;
            for (final f in chunk.frames) {
              writeRecord('raw_detections', {
                'frame_ms': startMs + ((f.ptsUs - firstPts) / 1000).round(),
                'clip': clip,
                'pts_us': f.ptsUs,
                'frame': f.frame,
                'boxes': f.boxes,
              });
              lastPts = f.ptsUs;
            }
            clipFrames += chunk.frames.length;
            framesAnalysed += chunk.frames.length;
            decoded += chunk.decoded;
            decodeMs += chunk.decodeMs;
            convertMs += chunk.convertMs;
            inferMs += chunk.inferMs;
            done = chunk.done;
            await sink.flush();
            onProgress?.call(_progress(ci, pending.length, clip, lastPts, firstPts, info, framesAnalysed, clock, tempC, ''));
          }
        } finally {
          await backend.close();
        }
        if (!cancelled) {
          writeRecord('video_clip_done', {
            'clip': clip,
            'frames_analysed': clipFrames,
            'frames_decoded': decoded,
            'frame_width': lastChunk?.frameWidth,
            'frame_height': lastChunk?.frameHeight,
            'roi_px': lastChunk?.roiPx,
            'class_names': names,
            'decode_ms': decodeMs.round(),
            'convert_ms': convertMs.round(),
            'infer_ms': inferMs.round(),
            'elapsed_ms': clipClock.elapsedMilliseconds,
          });
          clipsDone++;
        }
      } catch (e) {
        logSwallowed('video_detect_clip', e);
        writeRecord('video_clip_error', {
          'clip': clip,
          'error': e is PlatformException ? (e.message ?? e.code) : '$e',
          'at_pts_us': ?lastPts,
          'frames_analysed': clipFrames,
        });
        clipsFailed++;
      }
      await sink.flush();
    }

    writeRecord('video_run_end', {
      'clips_done': clipsDone,
      'clips_failed': clipsFailed,
      'frames_analysed': framesAnalysed,
      'thermal_pauses': pauses,
      'elapsed_ms': DateTime.now().difference(started).inMilliseconds,
      'ended_normally': !cancelled,
      if (cancelled) 'reason': 'cancelled',
    });
    await sink.flush();
    await sink.close();
    return VideoRunResult(
      framesAnalysed: framesAnalysed,
      clipsDone: clipsDone,
      clipsFailed: clipsFailed,
      thermalPauses: pauses,
      elapsed: DateTime.now().difference(started),
      cancelled: cancelled,
    );
  }

  /// Wall-clock start of [clip] and where it came from (see
  /// video_start_time.dart for the order of sources).
  static (int, String) _clipStart(String clip, VideoInfo info, File file, Map<String, int> logStarts) {
    final g = guessClipStart(
      fileName: clip,
      loggedMs: logStarts[clip],
      storedMs: info.creationEpochMs,
      durationMs: info.durationMs,
      fileModifiedMs: file.lastModifiedSync().millisecondsSinceEpoch,
    );
    return (g.epochMs, g.source);
  }

  static VideoProgress _progress(
    int ci,
    int count,
    String clip,
    int? lastPts,
    int firstPts,
    VideoInfo info,
    int frames,
    Stopwatch clock,
    double? tempC,
    String note,
  ) => VideoProgress(
    clipIndex: ci,
    clipCount: count,
    clip: clip,
    clipPosS: lastPts == null ? 0 : (lastPts - firstPts) / 1e6,
    clipLengthS: (info.durationMs ?? 0) / 1000,
    framesAnalysed: frames,
    msPerFrame: frames == 0 ? 0 : clock.elapsedMilliseconds / frames,
    tempC: tempC,
    note: note,
  );
}
