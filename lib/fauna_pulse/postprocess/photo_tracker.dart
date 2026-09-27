// FaunaPulse (round 237): visits found afterwards in the photos of a motion or
// time-lapse session (video plan Phase 2d, part 2).
//
// Those sessions saved photos without running the AI; "Run AI on photos"
// (post_detector.dart) later finds the insects in each photo. This file
// follows them from photo to photo with the same tracker a live session uses
// (SessionConfig.buildTracker, replayed by tracker_replay.dart), so one insect
// seen in many photos counts as one visit. That only works when the photos
// are close in time: at one photo a second an insect moves too far between
// two photos to be matched reliably, so the screen offers it only for
// sessions whose photo step is at most [PhotoTracker.maxStepSeconds].
//
// Output is the same post_tracks.jsonl as "Find visits" on videos
// (video_tracker.dart), so the summary, dashboard and identification read it
// unchanged (track_source.dart picks it for sessions without live tracking):
// `post_track_start` (`source: photos`), `detections` records whose track
// entries name the photo in `jpeg` (as live photos do), `track_event`
// records and `post_track_end`; plus visits.csv, with times counted from the
// session's start. A high-res photo and its `_live` companion are one
// moment: the photo's own result is used, the companion's only when the
// photo has no box or its analysis failed. Photos whose analysis failed are
// left out (no result is not "no insect"; the tracker bridges them).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import '../logging/app_error_hooks.dart';
import '../logging/session_logger.dart' show isoWithOffset;
import '../logging/track_source.dart' show postTracksFileName;
import '../models/session_config.dart';
import '../models/track.dart';
import '../tracking/tracker_replay.dart';
import 'photo_keep.dart' show pairBase;
import 'post_detector.dart';
import 'track_export.dart';
import 'video_tracker.dart' show VideoTrackResult;

/// Whether a session's photos can be followed from photo to photo.
class PhotoTrackability {
  /// `detector`, `motion` or `timelapse` (the session's capture trigger).
  final String trigger;

  /// The session's photo step, or null when its log does not say.
  final double? stepSeconds;

  /// Photos with an analysis result.
  final int analysedPhotos;

  /// `time_ms` of the newest analysis run (`post_start`): a visits file made
  /// before it misses that run's results.
  final int? lastRunMs;

  const PhotoTrackability({
    required this.trigger,
    required this.stepSeconds,
    required this.analysedPhotos,
    this.lastRunMs,
  });

  /// The AI already followed the insects while recording.
  bool get trackedLive => trigger == 'detector';

  /// Photos too far apart to follow an insect.
  bool get tooSparse => stepSeconds == null || stepSeconds! > PhotoTracker.maxStepSeconds + 1e-9;

  bool get possible => !trackedLive && !tooSparse && analysedPhotos > 0;
}

class PhotoTracker {
  /// The longest photo step at which photos are followed (plan Phase 2d).
  static const maxStepSeconds = 0.5;

  static Future<PhotoTrackability> trackability(Directory sessionDir) async {
    final start = _startRecord(sessionDir);
    final config = start?['config'];
    String trigger = 'detector';
    double? step;
    if (config is Map) {
      trigger = (config['captureTrigger'] as String?) ??
          ((config['motionOnlyCapture'] as bool? ?? false) ? 'motion' : 'detector');
      step = (config['stepSeconds'] as num?)?.toDouble();
    }
    final read = _readResults(sessionDir);
    return PhotoTrackability(
      trigger: trigger,
      stepSeconds: step,
      analysedPhotos: read.results.length,
      lastRunMs: read.lastRunMs,
    );
  }

  /// Follows the insects through the analysed photos of [sessionDir] and
  /// writes post_tracks.jsonl and visits.csv (both replaced).
  static Future<VideoTrackResult> run(Directory sessionDir, SessionConfig config) async {
    final started = DateTime.now();
    final start = _startRecord(sessionDir);
    final sessionStartMs = (start?['time_ms'] as num?)?.toInt() ?? 0;
    final startConfig = start?['config'];
    final trigger = startConfig is Map ? startConfig['captureTrigger'] as String? : null;
    final step = startConfig is Map ? (startConfig['stepSeconds'] as num?)?.toDouble() : null;
    final read = _readResults(sessionDir);

    // One frame per moment, in time order.
    final classes = <String>[];
    final frames = <ReplayFrame>[];
    final photoOf = <int, String>{}; // frame index → photo name
    final moments = <String, List<_Result>>{};
    for (final r in read.results.values) {
      (moments[pairBase(r.name)] ??= []).add(r);
    }
    final ordered = moments.entries.toList()..sort((a, b) => a.value.first.atMs.compareTo(b.value.first.atMs));
    for (final e in ordered) {
      final main = e.value.where((r) => r.name == e.key).firstOrNull;
      final live = e.value.where((r) => r.name != e.key).firstOrNull;
      final use = main != null && (main.boxes.isNotEmpty || live == null || live.boxes.isEmpty) ? main : live!;
      frames.add(
        ReplayFrame(
          timestampMs: use.atMs,
          frameIndex: frames.length,
          detections: [
            for (final b in use.boxes)
              Detection(
                box: Rect.fromLTRB(b.left, b.top, b.right, b.bottom),
                confidence: b.confidence,
                classIndex: classes.contains(b.className)
                    ? classes.indexOf(b.className)
                    : (classes..add(b.className)).length - 1,
                className: b.className,
              ),
          ],
        ),
      );
      photoOf[frames.length - 1] = e.key;
    }
    frames.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    final fps = _fpsOf(frames) ?? (step != null && step > 0 ? 1 / step : 2.0);
    final runId = started.millisecondsSinceEpoch;
    final out = File('${sessionDir.path}/$postTracksFileName');
    final tmp = File('${out.path}.tmp');
    final sink = tmp.openWrite();
    void write(String type, int atMs, Map<String, dynamic> payload) => sink.writeln(
      jsonEncode({
        'type': type,
        'time_ms': atMs,
        'time_iso': isoWithOffset(DateTime.fromMillisecondsSinceEpoch(atMs)),
        ...payload,
      }),
    );

    write('post_track_start', runId, {
      'run_id': runId,
      'source': 'photos',
      'detections_run_ms': read.lastRunMs,
      'detection_settings': read.lastRunSettings,
      'occlusion_seconds': config.occlusionSeconds,
      'min_hits_seconds': config.minHitsSeconds,
      'tracker': config.buildTracker(fps).effectiveParamsJson(),
      'clips': const <String>[],
      'photos': frames.length,
      'photo_step_s': ?step,
      // Time-lapse photos cover only their bursts; a motion session watched
      // the whole time (no photo = no movement), so its span counts.
      'observed_ms': ?(trigger == 'timelapse' ? _burstMs(frames, step) : null),
      'keep_frames': null,
    });

    final visits = <int, VideoVisit>{};
    var detections = 0;
    try {
      final report = replayTracker(
        tracker: config.buildTracker(fps),
        frames: frames,
        occlusionSeconds: config.occlusionSeconds,
        minHitsSeconds: config.minHitsSeconds,
        initialFps: fps,
        onFrame: (frame, tracks, events) {
          final photo = photoOf[frame.frameIndex];
          if (tracks.isNotEmpty) {
            write('detections', frame.timestampMs, {
              'frame_ms': frame.timestampMs,
              'tracks': [
                for (final t in tracks)
                  {
                    'track_id': t.id,
                    'class_index': t.classIndex,
                    'class_name': t.className,
                    'confidence': t.confidence,
                    'box_in_roi': _box(t.box),
                    if (t.timeSinceUpdate > 0) 'coasted': true else 'jpeg': ?photo,
                  },
              ],
            });
          }
          for (final e in events) {
            write('track_event', e.atMs, {
              'event': e.kind.name,
              'track_id': e.trackId,
              'frame_ms': e.atMs,
              'box_in_roi': _box(e.box),
              'hits': e.hits,
              'first_seen_ms': e.firstSeenMs,
              'last_seen_ms': e.lastSeenMs,
              if (e.framesMissed > 0) 'frames_missed': e.framesMissed,
              'reason': ?e.reason,
            });
          }
          for (final t in tracks) {
            final v = visits.putIfAbsent(
              t.id,
              () => VideoVisit(trackId: t.id, clip: '', clipStartMs: sessionStartMs, firstSeenMs: t.firstSeenMs),
            );
            v.lastSeenMs = t.lastSeenMs;
            if (t.timeSinceUpdate == 0) v.addFrame(t.confidence, t.className);
          }
        },
      );
      detections = report.detections;
      write('post_track_end', DateTime.now().millisecondsSinceEpoch, {
        'run_id': runId,
        'visits': visits.length,
        'frames': frames.length,
        'detections': detections,
        'clips_tracked': 0,
        'kept_frames': 0,
        'elapsed_ms': DateTime.now().difference(started).inMilliseconds,
      });
      await sink.flush();
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {} // the first error is the one to report
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
    await tmp.rename(out.path);
    await TrackExport.writeAtomic(
      File('${sessionDir.path}/${TrackExport.visitsFileName}'),
      TrackExport.visitsCsv(visits.values),
    );
    return VideoTrackResult(
      visits: visits.length,
      clipsTracked: 0,
      clipsLeftOut: 0,
      frames: frames.length,
      elapsed: DateTime.now().difference(started),
    );
  }

  /// A photo is the analysed area itself: box_in_roi is the box.
  static Map<String, double> _box(Rect b) => {'left': b.left, 'top': b.top, 'right': b.right, 'bottom': b.bottom};

  /// Median frame rate of [frames], or null with too few.
  static double? _fpsOf(List<ReplayFrame> frames) {
    final gaps = [
      for (var i = 1; i < frames.length; i++)
        if (frames[i].timestampMs > frames[i - 1].timestampMs) frames[i].timestampMs - frames[i - 1].timestampMs,
    ]..sort();
    return gaps.isEmpty ? null : 1000 / gaps[gaps.length ~/ 2];
  }

  /// Time the photos cover, burst by burst: photos closer than five photo
  /// steps (at least 1 s) belong to one burst, which covers from its first
  /// photo to one step after its last.
  static int? _burstMs(List<ReplayFrame> frames, double? step) {
    if (frames.isEmpty || step == null || step <= 0) return null;
    final stepMs = (step * 1000).round();
    final splitMs = max(1000, 5 * stepMs);
    var total = 0;
    var first = frames.first.timestampMs, last = first;
    for (final f in frames.skip(1)) {
      if (f.timestampMs - last > splitMs) {
        total += last - first + stepMs;
        first = f.timestampMs;
      }
      last = f.timestampMs;
    }
    return total + last - first + stepMs;
  }

  static Map<String, dynamic>? _startRecord(Directory sessionDir) {
    try {
      final raf = File('${sessionDir.path}/session.jsonl').openSync();
      try {
        final head = utf8.decode(raf.readSync(min(65536, raf.lengthSync())), allowMalformed: true);
        for (final line in const LineSplitter().convert(head)) {
          if (!line.contains('"start_of_session"')) continue;
          return (jsonDecode(line) as Map).cast<String, dynamic>();
        }
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      logSwallowed('photo_tracker_start', e);
    }
    return null;
  }

  /// The newest result per photo (a re-analysis replaces older ones), and the
  /// newest analysis run's time and settings.
  static ({Map<String, _Result> results, int? lastRunMs, Map<String, dynamic>? lastRunSettings}) _readResults(
    Directory sessionDir,
  ) {
    final results = <String, _Result>{};
    int? lastRunMs;
    Map<String, dynamic>? lastRunSettings;
    final file = File('${sessionDir.path}/${PostDetector.outputFileName}');
    if (!file.existsSync()) return (results: results, lastRunMs: null, lastRunSettings: null);
    for (final line in const LineSplitter().convert(file.readAsStringSync())) {
      if (!line.contains('"post_detection"') && !line.contains('"post_start"')) continue;
      Map<String, dynamic> rec;
      try {
        rec = (jsonDecode(line) as Map).cast<String, dynamic>();
      } catch (_) {
        continue; // a torn line
      }
      if (rec['type'] == 'post_start') {
        lastRunMs = (rec['time_ms'] as num?)?.toInt();
        lastRunSettings = {
          for (final k in const ['model', 'model_name', 'confidence', 'iou', 'sahi'])
            if (rec[k] != null) k: rec[k],
        };
        continue;
      }
      final name = rec['jpeg'];
      if (rec['type'] != 'post_detection' || name is! String) continue;
      if (rec['error'] != null) {
        results.remove(name); // no result is not "no insect"
        continue;
      }
      final at = (rec['captured_at_ms'] as num?)?.toInt() ?? capturedAtMsFromPhotoName(name);
      if (at == null) continue;
      results[name] = _Result(name, at, [
        for (final b in rec['boxes'] as List? ?? const [])
          if (b is Map && b['box'] is List && (b['box'] as List).length == 4)
            PostBox(
              className: '${b['class_name'] ?? 'insect'}',
              confidence: (b['conf'] as num?)?.toDouble() ?? 0,
              left: ((b['box'] as List)[0] as num).toDouble(),
              top: ((b['box'] as List)[1] as num).toDouble(),
              right: ((b['box'] as List)[2] as num).toDouble(),
              bottom: ((b['box'] as List)[3] as num).toDouble(),
            ),
      ]);
    }
    return (results: results, lastRunMs: lastRunMs, lastRunSettings: lastRunSettings);
  }
}

class _Result {
  final String name;
  final int atMs;
  final List<PostBox> boxes;
  const _Result(this.name, this.atMs, this.boxes);
}
