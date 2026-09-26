// FaunaPulse (round 228): finding visits in a session's analysed videos
// (pass 2 of the video pipeline, "offline tracking").
//
// Pass 1 (video_detector.dart) saved the detector's boxes of every analysed
// frame in video_detections.jsonl. Here they run through the same tracker a
// live session uses (ByteTrack or C-BIoU with the same seconds-based
// settings, built by SessionConfig.buildTracker and driven by the replay
// loop of tracking/tracker_replay.dart). The tracker links the boxes of one
// insect from frame to frame into one visit with a number (track id). This
// takes seconds, so it can be repeated with other tracking settings without
// running the detector again.
//
// Output, all rewritten on every run:
//  * post_tracks.jsonl: shaped like the live session log (`detections` and
//    `track_event` records, stamped with the frame's own time, plus `clip`,
//    `frame` and `pts_us`), between a `post_track_start` and a
//    `post_track_end` record;
//  * visits.csv and mot/<clip>.txt (track_export.dart).
// Each file is written under a temporary name and renamed when complete, so
// a crash never leaves a half file in place of a good one.
//
// Kept frames (round 234): per visit, the frames a live session would have
// photographed (the first one, then one every N s for up to M s: the same
// TrackKeepRule). Here they are only chosen and named: the due tracks carry
// `jpeg` in their `detections` entries and a `capture` record follows, as in
// a live log, so the summary's photo viewer, the gallery copy and the
// identification read them unchanged. The pictures themselves are saved
// from the clips afterwards (video_frame_keeper.dart) into roi_frames/; a
// frame not saved yet is simply skipped by every reader.
//
// Only clips whose analysis finished are tracked. One tracker follows
// insects from one clip into the next only when the next clip's first
// analysed frame comes after the previous clip's last one, within the
// occlusion tolerance (clips recorded back to back). Otherwise the tracker
// starts fresh, because imported files can overlap or carry wrong clocks.
// Track ids stay unique across the whole session.
//
// Times come from each frame's own time stamp in the video, never from
// frame number / frame rate: phone videos often have a variable frame rate.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:archive/archive.dart';

import '../capture/roi_capture.dart' show TrackKeepRule, roiPhotoFileName;
import '../logging/app_error_hooks.dart';
import '../logging/session_logger.dart' show isoWithOffset;
import '../logging/track_source.dart' show postTracksFileName;
import '../models/roi.dart' show boxInRoi;
import '../models/session_config.dart';
import '../models/track.dart';
import '../tracking/tracker_replay.dart';
import 'track_export.dart';
import 'video_detector.dart';
import 'video_run_samples.dart';

/// Which frames of each visit are kept as photos (round 234): the first
/// one, then one every [stepSeconds] for up to [durationSeconds] after the
/// visit began; the rule a live session takes its photos by.
class KeepFramesSettings {
  final double stepSeconds;
  final double durationSeconds;
  const KeepFramesSettings({this.stepSeconds = 1, this.durationSeconds = 10});

  Map<String, dynamic> toJson() => {'step_seconds': stepSeconds, 'duration_seconds': durationSeconds};

  static KeepFramesSettings? fromJson(Object? j) {
    if (j is! Map) return null;
    final step = (j['step_seconds'] as num?)?.toDouble();
    final duration = (j['duration_seconds'] as num?)?.toDouble();
    if (step == null || duration == null) return null;
    return KeepFramesSettings(stepSeconds: step, durationSeconds: duration);
  }

  @override
  bool operator ==(Object other) =>
      other is KeepFramesSettings && other.stepSeconds == stepSeconds && other.durationSeconds == durationSeconds;

  @override
  int get hashCode => Object.hash(stepSeconds, durationSeconds);
}

/// One frame chosen to be kept, from its `capture` record in
/// post_tracks.jsonl: where it is in which clip, and the file it is saved to.
class KeptFrame {
  final String file;
  final String clip;
  final int ptsUs;
  final int frameMs;

  /// The analysed area in upright frame pixels `[x, y, width, height]`: the
  /// part of the frame that is saved.
  final List<int> roiPx;
  final List<int> trackIds;

  const KeptFrame({
    required this.file,
    required this.clip,
    required this.ptsUs,
    required this.frameMs,
    required this.roiPx,
    required this.trackIds,
  });

  KeptFrame named(String name) =>
      KeptFrame(file: name, clip: clip, ptsUs: ptsUs, frameMs: frameMs, roiPx: roiPx, trackIds: trackIds);

  /// Same picture: same clip, moment and area.
  bool samePicture(KeptFrame o) =>
      o.clip == clip && o.ptsUs == ptsUs && o.roiPx.length == roiPx.length && _sameInts(o.roiPx, roiPx);

  static bool _sameInts(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static KeptFrame? fromRecord(Map<String, dynamic> rec) {
    final file = rec['file'];
    final clip = rec['clip'];
    final pts = rec['pts_us'];
    final roi = rec['roi_px'];
    if (file is! String || clip is! String || pts is! num || roi is! List || roi.length != 4) return null;
    return KeptFrame(
      file: file,
      clip: clip,
      ptsUs: pts.toInt(),
      frameMs: (rec['captured_at_ms'] as num?)?.toInt() ?? 0,
      roiPx: [for (final v in roi) (v as num).toInt()],
      trackIds: [for (final v in (rec['track_ids'] as List? ?? const [])) (v as num).toInt()],
    );
  }
}

/// What one tracking run found.
class VideoTrackResult {
  final int visits;
  final int clipsTracked;
  final int clipsLeftOut;
  final int frames;

  /// Frames chosen to be kept (round 234; saved afterwards).
  final int keptFrames;
  final Duration elapsed;
  const VideoTrackResult({
    required this.visits,
    required this.clipsTracked,
    required this.clipsLeftOut,
    required this.frames,
    this.keptFrames = 0,
    required this.elapsed,
  });
}

/// The head and tail records of an existing post_tracks.jsonl, for the
/// screen: what was found, from which detections, with which settings.
class PostTrackSummary {
  final int visits;
  final List<String> clips;

  /// `time_ms` of the detection run's first `video_run_start` record: a
  /// different value means the videos were analyzed again since.
  final int? detectionsRunMs;
  final double occlusionSeconds;
  final double minHitsSeconds;
  final String algorithm;

  /// This run's `run_id`: identification remembers it, so it can tell when
  /// the visits (and their numbers) were found again since (round 234).
  final int? runId;

  /// The kept-frames rule of this run, or null when none were kept.
  final KeepFramesSettings? keep;
  final int keptFrames;

  const PostTrackSummary({
    required this.visits,
    required this.clips,
    required this.detectionsRunMs,
    required this.occlusionSeconds,
    required this.minHitsSeconds,
    required this.algorithm,
    this.runId,
    this.keep,
    this.keptFrames = 0,
  });
}

/// One analysed clip, gathered from video_detections.jsonl.
class _Clip {
  final String name;
  int startMs = 0;
  int durationMs = 0;
  int width = 0;
  int height = 0;
  bool done = false;
  Rect roi = const Rect.fromLTWH(0, 0, 1, 1);
  List<String> names = const [];

  /// `roi_px` of `video_clip_done` (upright pixels), or null for none.
  List<int>? roiPx;
  List<ReplayFrame> frames = [];
  _Clip(this.name);
}

class VideoTracker {
  static const outputFileName = postTracksFileName;

  /// Folder of the kept frames: the one live photos use.
  static const framesDirName = 'roi_frames';

  /// Tracks every finished clip of [sessionDir] with [config]'s tracker
  /// settings and writes post_tracks.jsonl, visits.csv and mot/. With
  /// [keep], chooses the frames to keep per visit (see the file header).
  /// Throws a [StateError] when no clip has finished its analysis yet.
  static Future<VideoTrackResult> run(Directory sessionDir, SessionConfig config, {KeepFramesSettings? keep}) async {
    final started = DateTime.now();
    final input = File('${sessionDir.path}/${VideoDetector.outputFileName}');
    if (!input.existsSync()) throw StateError('The videos were not analyzed yet.');
    final lines = await input
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .toList();

    // Clip facts: start time and size from the last `video_clip_start`,
    // analysed area and class names from `video_clip_done`.
    final clips = <String, _Clip>{};
    Map<String, dynamic>? detectionSettings;
    int? detectionsRunMs;
    for (final line in lines) {
      if (!line.contains('"video_')) continue;
      Map<String, dynamic> rec;
      try {
        rec = (jsonDecode(line) as Map).cast<String, dynamic>();
      } catch (_) {
        continue; // a half-written line after a kill
      }
      final name = rec['clip'] as String?;
      switch (rec['type']) {
        case 'video_run_start':
          detectionsRunMs ??= (rec['time_ms'] as num?)?.toInt();
          detectionSettings = (rec['settings'] as Map?)?.cast<String, dynamic>();
        case 'video_clip_start' when name != null:
          final c = clips.putIfAbsent(name, () => _Clip(name));
          c.startMs = (rec['start_epoch_ms'] as num?)?.toInt() ?? c.startMs;
          c.durationMs = (rec['duration_ms'] as num?)?.toInt() ?? c.durationMs;
          c.width = (rec['width'] as num?)?.toInt() ?? c.width;
          c.height = (rec['height'] as num?)?.toInt() ?? c.height;
        case 'video_clip_done' when name != null:
          final c = clips.putIfAbsent(name, () => _Clip(name));
          c.done = true;
          final w = (rec['frame_width'] as num?)?.toInt() ?? 0;
          final h = (rec['frame_height'] as num?)?.toInt() ?? 0;
          if (w > 0 && h > 0) {
            c.width = w;
            c.height = h;
          }
          final roi = rec['roi_px'];
          if (roi is List && roi.length == 4 && c.width > 0 && c.height > 0) {
            final r = [for (final v in roi) (v as num).toDouble()];
            c.roi = Rect.fromLTWH(r[0] / c.width, r[1] / c.height, r[2] / c.width, r[3] / c.height);
            c.roiPx = [for (final v in r) v.round()];
          }
          final names = rec['class_names'];
          if (names is List) c.names = [for (final n in names) '$n'];
      }
    }

    // Frames per finished clip, in video order, each time stamp once (a
    // resumed run never repeats one, but a torn line could).
    for (final f in parseRawDetectionLines(lines)) {
      final c = clips[f.clip];
      if (c == null || !c.done) continue;
      final names = c.names;
      c.frames.add(
        ReplayFrame(
          timestampMs: f.timestampMs,
          clip: f.clip,
          frameIndex: f.frameIndex,
          ptsUs: f.ptsUs,
          detections: [
            for (final d in f.detections)
              Detection(
                box: d.box,
                confidence: d.confidence,
                classIndex: d.classIndex,
                className: d.classIndex >= 0 && d.classIndex < names.length ? names[d.classIndex] : d.className,
              ),
          ],
        ),
      );
    }
    final tracked = clips.values.where((c) => c.done).toList();
    if (tracked.isEmpty) throw StateError('No clip has finished its analysis yet.');
    for (final c in tracked) {
      final seen = <int>{};
      c.frames = c.frames.where((f) => seen.add(f.ptsUs ?? f.timestampMs)).toList()
        ..sort((a, b) => (a.ptsUs ?? a.timestampMs).compareTo(b.ptsUs ?? b.timestampMs));
    }
    int firstMs(_Clip c) => c.frames.isEmpty ? c.startMs : c.frames.first.timestampMs;
    tracked.sort((a, b) => firstMs(a) != firstMs(b) ? firstMs(a).compareTo(firstMs(b)) : a.name.compareTo(b.name));

    // Stretches of clips one tracker follows through (see the file header).
    final stretches = <List<_Clip>>[];
    final continued = <String>[];
    for (final c in tracked.where((c) => c.frames.isNotEmpty)) {
      if (stretches.isNotEmpty) {
        final gap = c.frames.first.timestampMs - stretches.last.last.frames.last.timestampMs;
        if (gap > 0 && gap <= config.occlusionSeconds * 1000) {
          stretches.last.add(c);
          continued.add(c.name);
          continue;
        }
      }
      stretches.add([c]);
    }

    final runId = started.millisecondsSinceEpoch;
    final fps0 = (detectionSettings?['analysis_fps'] as num?)?.toDouble() ?? 15;

    // Kept frames: names as live photos have them (the session's token plus
    // the frame's time), one per frame. A name already taken moves on by
    // 1 ms. An existing file of that name is taken over only when the last
    // run kept it and it can be made again from its video (or it already
    // shows this picture); a file no run kept (a camera photo, say) or whose
    // video is gone is never overwritten.
    final framesDir = Directory('${sessionDir.path}/$framesDirName');
    final oldKept = {for (final k in await readKeptFrames(sessionDir)) k.file: k};
    final videoThere = <String, bool>{};
    bool canRemake(String clip) =>
        videoThere.putIfAbsent(clip, () => File('${sessionDir.path}/videos/$clip').existsSync());
    final token = keep == null ? '' : _fileToken(sessionDir);
    final kept = <String, KeptFrame>{};
    String keptName(KeptFrame want) {
      for (var ms = want.frameMs; ; ms++) {
        final name = roiPhotoFileName(ms, token);
        if (kept.containsKey(name)) continue;
        if (!File('${framesDir.path}/$name').existsSync()) return name;
        final old = oldKept[name];
        if (old != null && (old.samePicture(want) || canRemake(old.clip))) return name;
      }
    }

    final out = File('${sessionDir.path}/$outputFileName');
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
      'detections_run_ms': detectionsRunMs,
      'detection_settings': detectionSettings,
      'occlusion_seconds': config.occlusionSeconds,
      'min_hits_seconds': config.minHitsSeconds,
      'tracker': config.buildTracker(fps0).effectiveParamsJson(),
      'clips': [for (final c in tracked) c.name],
      'observed_ms': _observedMs(tracked),
      'clips_continuing_previous': continued,
      'clips_left_out': [
        for (final c in clips.values)
          if (!c.done) c.name,
      ],
      'keep_frames': keep?.toJson(),
      if (keep != null) 'file_token': token,
    });

    final visits = <int, VideoVisit>{};
    final mot = <String, List<MotRow>>{};
    var frames = 0, detections = 0, idBase = 0;
    try {
      for (final stretch in stretches) {
        final all = [for (final c in stretch) ...c.frames];
        final fps = _fpsOf(all) ?? fps0;
        var maxId = 0;
        final rule = keep == null
            ? null
            : TrackKeepRule(
                stepMs: (keep.stepSeconds * 1000).round(),
                durationMs: (keep.durationSeconds * 1000).round(),
              );
        // Clip a first sighting belongs to: the last clip of the stretch
        // that had begun by then.
        _Clip clipAt(int ms) => stretch.lastWhere((c) => c.frames.first.timestampMs <= ms, orElse: () => stretch.first);
        final report = replayTracker(
          tracker: config.buildTracker(fps),
          frames: all,
          occlusionSeconds: config.occlusionSeconds,
          minHitsSeconds: config.minHitsSeconds,
          initialFps: fps,
          onFrame: (frame, tracks, events) {
            final clip = clips[frame.clip]!;
            final pts = frame.ptsUs;
            // Every frame, as live: the rule also forgets ended visits.
            final due = rule == null || pts == null
                ? const <int>[]
                : rule.due([for (final t in tracks) t.id], frame.timestampMs);
            String? jpeg;
            if (due.isNotEmpty) {
              final want = KeptFrame(
                file: '',
                clip: clip.name,
                ptsUs: pts!,
                frameMs: frame.timestampMs,
                roiPx: clip.roiPx ?? [0, 0, clip.width, clip.height],
                trackIds: [for (final id in due) idBase + id],
              );
              jpeg = keptName(want);
              kept[jpeg] = want.named(jpeg);
            }
            if (tracks.isNotEmpty) {
              write('detections', frame.timestampMs, {
                'frame_ms': frame.timestampMs,
                'clip': clip.name,
                'frame': frame.frameIndex,
                'pts_us': frame.ptsUs,
                'tracks': [
                  for (final t in tracks)
                    {
                      'track_id': idBase + t.id,
                      'class_index': t.classIndex,
                      'class_name': t.className,
                      'confidence': t.confidence,
                      'box_in_roi': boxInRoi(t.box, clip.roi),
                      if (t.timeSinceUpdate > 0) 'coasted': true,
                      if (jpeg != null && due.contains(t.id)) 'jpeg': jpeg,
                    },
                ],
              });
            }
            if (jpeg != null) {
              final k = kept[jpeg]!;
              final roiPx = k.roiPx;
              write('capture', frame.timestampMs, {
                'file': jpeg,
                'captured_at_ms': frame.timestampMs,
                'track_ids': k.trackIds,
                'source': 'video',
                'clip': clip.name,
                'frame': frame.frameIndex,
                'pts_us': pts,
                'roi_px': roiPx,
                // The saved picture is the analysed area at full size.
                if (roiPx[2] == roiPx[3]) 'saved_px': roiPx[2] else ...{'saved_w': roiPx[2], 'saved_h': roiPx[3]},
              });
            }
            for (final e in events) {
              maxId = max(maxId, e.trackId);
              write('track_event', e.atMs, {
                'event': e.kind.name,
                'track_id': idBase + e.trackId,
                'frame_ms': e.atMs,
                'clip': clip.name,
                'box_in_roi': boxInRoi(e.box, clip.roi),
                'hits': e.hits,
                'first_seen_ms': e.firstSeenMs,
                'last_seen_ms': e.lastSeenMs,
                if (e.framesMissed > 0) 'frames_missed': e.framesMissed,
                'reason': ?e.reason,
              });
            }
            for (final t in tracks) {
              maxId = max(maxId, t.id);
              final id = idBase + t.id;
              final v = visits.putIfAbsent(id, () {
                final start = clipAt(t.firstSeenMs);
                return VideoVisit(trackId: id, clip: start.name, clipStartMs: start.startMs, firstSeenMs: t.firstSeenMs);
              });
              v.lastSeenMs = t.lastSeenMs;
              if (t.timeSinceUpdate > 0) continue; // predicted, not seen
              v.addFrame(t.confidence, t.className);
              (mot[clip.name] ??= []).add((
                frame: (frame.frameIndex ?? 0) + 1,
                id: id,
                x: t.box.left * clip.width,
                y: t.box.top * clip.height,
                w: t.box.width * clip.width,
                h: t.box.height * clip.height,
                conf: t.confidence,
              ));
            }
          },
        );
        frames += report.frames;
        detections += report.detections;
        idBase += maxId;
      }
      write('post_track_end', DateTime.now().millisecondsSinceEpoch, {
        'run_id': runId,
        'visits': visits.length,
        'frames': frames,
        'detections': detections,
        'clips_tracked': tracked.length,
        'kept_frames': kept.length,
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
    // Frames the last run kept that this one does not keep as the same
    // picture go before the new file takes over: a crash in between leaves
    // the old records pointing at missing files (skipped by every reader),
    // never a name pointing at the wrong picture. Frames whose video is gone
    // stay: they can't be made again.
    for (final old in oldKept.values) {
      final now = kept[old.file];
      if (now != null && now.samePicture(old)) continue;
      if (!canRemake(old.clip)) continue;
      final f = File('${framesDir.path}/${old.file}');
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        logSwallowed('video_kept_frame_delete', e);
      }
    }
    await tmp.rename(out.path);
    await TrackExport.write(sessionDir, visits: visits.values, clips: [for (final c in tracked) c.name], mot: mot);
    return VideoTrackResult(
      visits: visits.length,
      clipsTracked: tracked.length,
      clipsLeftOut: clips.length - tracked.length,
      frames: frames,
      keptFrames: kept.length,
      elapsed: DateTime.now().difference(started),
    );
  }

  /// The session's `file_token` (start record of session.jsonl), which live
  /// photo names carry too; `video` when the log has none.
  static String _fileToken(Directory sessionDir) {
    try {
      final raf = File('${sessionDir.path}/session.jsonl').openSync();
      try {
        final head = utf8.decode(raf.readSync(min(65536, raf.lengthSync())), allowMalformed: true);
        for (final line in const LineSplitter().convert(head)) {
          if (!line.contains('"start_of_session"')) continue;
          final token = (jsonDecode(line) as Map)['file_token'];
          if (token is String && RegExp(r'^[a-z0-9]+$').hasMatch(token)) return token;
        }
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      logSwallowed('video_file_token', e);
    }
    return 'video';
  }

  /// The frames the current post_tracks.jsonl keeps, in its order (empty
  /// when there is none).
  static Future<List<KeptFrame>> readKeptFrames(Directory sessionDir) async {
    final file = File('${sessionDir.path}/$outputFileName');
    if (!file.existsSync()) return const [];
    final out = <KeptFrame>[];
    try {
      await for (final line
          in file.openRead().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
        if (!line.startsWith('{"type":"capture"')) continue;
        try {
          final k = KeptFrame.fromRecord((jsonDecode(line) as Map).cast<String, dynamic>());
          if (k != null) out.add(k);
        } catch (_) {
          // a torn line
        }
      }
    } catch (e) {
      logSwallowed('video_kept_frames_read', e);
    }
    return out;
  }

  /// Time the tracked clips cover, overlaps counted once: the dashboard's
  /// "recorded" time for visits per hour (gaps between clips were not
  /// filmed). A clip without a known length counts up to its last frame.
  static int _observedMs(List<_Clip> clips) {
    final spans = <(int, int)>[
      for (final c in clips)
        (c.startMs, max(c.startMs + c.durationMs, c.frames.isEmpty ? c.startMs : c.frames.last.timestampMs)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var total = 0, end = -1 << 62;
    for (final (s, e) in spans) {
      if (e <= end) continue;
      total += e - max(s, end);
      end = e;
    }
    return total;
  }

  /// Frame rate from the typical (median) gap between frames, or null for
  /// fewer than two frames.
  static double? _fpsOf(List<ReplayFrame> frames) {
    final gaps = <int>[
      for (var i = 1; i < frames.length; i++)
        if (frames[i].timestampMs > frames[i - 1].timestampMs) frames[i].timestampMs - frames[i - 1].timestampMs,
    ]..sort();
    return gaps.isEmpty ? null : 1000 / gaps[gaps.length ~/ 2];
  }

  /// Reads the first and last record of the session's post_tracks.jsonl, or
  /// null when there is none (or it is unreadable).
  static Future<PostTrackSummary?> readSummary(Directory sessionDir) async {
    final file = File('${sessionDir.path}/$outputFileName');
    if (!file.existsSync()) return null;
    try {
      final length = file.lengthSync();
      Future<String> read(int start, int end) =>
          file.openRead(start, end).transform(const Utf8Decoder(allowMalformed: true)).join();
      final head = await read(0, min(length, 65536));
      final tail = await read(max(0, length - 65536), length);
      final first = (jsonDecode(head.split('\n').first) as Map).cast<String, dynamic>();
      final last = (jsonDecode(tail.trimRight().split('\n').last) as Map).cast<String, dynamic>();
      if (first['type'] != 'post_track_start' || last['type'] != 'post_track_end') return null;
      return PostTrackSummary(
        visits: (last['visits'] as num).toInt(),
        clips: [for (final c in first['clips'] as List) '$c'],
        detectionsRunMs: (first['detections_run_ms'] as num?)?.toInt(),
        occlusionSeconds: (first['occlusion_seconds'] as num).toDouble(),
        minHitsSeconds: (first['min_hits_seconds'] as num).toDouble(),
        algorithm: '${(first['tracker'] as Map?)?['algorithm'] ?? ''}',
        runId: (first['run_id'] as num?)?.toInt(),
        keep: KeepFramesSettings.fromJson(first['keep_frames']),
        keptFrames: (last['kept_frames'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      logSwallowed('post_tracks_summary', e);
      return null;
    }
  }

  /// Zips the results and the logs they came from into [zipPath] for
  /// "Share results": visits.csv, mot/, post_tracks.jsonl,
  /// video_detections.jsonl (for re-tracking on a computer),
  /// session.jsonl (clip start times) and phone_during_analysis.csv (the
  /// phone's temperature, power and speed during the runs, round 232).
  /// Returns [zipPath], or null when writing failed.
  static Future<String?> writeResultsZip(String sessionPath, String zipPath) async {
    try {
      final archive = Archive();
      for (final name in [
        TrackExport.visitsFileName,
        outputFileName,
        VideoDetector.outputFileName,
        'session.jsonl',
      ]) {
        final f = File('$sessionPath/$name');
        if (f.existsSync()) archive.addFile(ArchiveFile.bytes(name, await f.readAsBytes()));
      }
      final phone = await VideoRunSamples.parseFile('$sessionPath/${VideoDetector.outputFileName}');
      if (phone != null && !phone.isEmpty) {
        archive.addFile(ArchiveFile.string(VideoRunSamples.csvFileName, phone.toCsv()));
      }
      final mot = Directory('$sessionPath/${TrackExport.motDirName}');
      if (mot.existsSync()) {
        final files = mot.listSync().whereType<File>().where((f) => f.path.endsWith('.txt')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          archive.addFile(ArchiveFile.bytes('${TrackExport.motDirName}/${f.uri.pathSegments.last}', await f.readAsBytes()));
        }
      }
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive), flush: true);
      return zipPath;
    } catch (e) {
      logSwallowed('video_results_zip', e);
      return null;
    }
  }
}
