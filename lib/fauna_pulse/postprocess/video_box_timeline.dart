// FaunaPulse (round 231): the AI's boxes of an imported session's videos,
// arranged by position in each clip, for the summary's Video tab.
//
// Two sources, both written by the video pipeline:
//  * video_detections.jsonl (pass 1): every analysed frame's boxes
//    (`raw_detections`), normalised to the whole upright frame, and each
//    clip's analysed area (`video_clip_done.roi_px`);
//  * post_tracks.jsonl (pass 2, "Find visits"): the tracked boxes with their
//    visit numbers (`detections`), stored relative to the analysed area.
//
// A frame's place in the clip is its own time stamp in the video (`pts_us`),
// the same clock the player reports. A box stays on screen until the next
// analysed frame, and at most 1.5 analysed-frame steps: gaps, a stopped
// analysis and the unanalysed end of a clip never show old boxes.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import '../logging/track_source.dart' show postTracksFileName;
import '../models/roi.dart';
import 'video_detector.dart';

/// One box to draw, normalised to the whole upright frame (0..1).
class TimelineBox {
  final Rect box;
  final double confidence;
  final String className;

  /// Visit number (track id), or null for a box straight from the detector.
  final int? trackId;

  /// The tracker kept the visit's place on this frame without a detection.
  final bool coasted;

  const TimelineBox({
    required this.box,
    required this.confidence,
    required this.className,
    this.trackId,
    this.coasted = false,
  });
}

/// One visit as seen in one clip: player positions of its first and last
/// tracked box.
class TimelineVisit {
  final int trackId;
  final int startMs;
  final int endMs;
  final String className;
  const TimelineVisit({required this.trackId, required this.startMs, required this.endMs, required this.className});
}

/// The boxes of one clip.
class ClipBoxes {
  final String clip;

  /// The clip's analysis finished.
  final bool done;

  /// Upright frame size in pixels, when the analysis reported it.
  final int width;
  final int height;

  /// Analysed area from the analysis itself, normalised; null when unknown.
  final Rect? analysedArea;

  /// Analysed square from the run's settings (cx, cy, side), the fallback
  /// for a clip whose analysis did not finish.
  final List<double>? settingsRoi;

  /// "Find visits" covered this clip, with the current analysis.
  final bool tracked;

  /// Analysed frames: player position (ms) and the detector's boxes.
  final List<int> _pos;
  final List<List<TimelineBox>> _raw;

  /// Tracked boxes by the analysed frame's position (only frames with one).
  final Map<int, List<TimelineBox>> _tracked;

  final List<TimelineVisit> visits;

  /// How long a frame's boxes stay on screen at most.
  final int holdMs;

  ClipBoxes._({
    required this.clip,
    required this.done,
    required this.width,
    required this.height,
    required this.analysedArea,
    required this.settingsRoi,
    required this.tracked,
    required List<int> pos,
    required List<List<TimelineBox>> raw,
    required Map<int, List<TimelineBox>> trackedBoxes,
    required this.visits,
    required this.holdMs,
  }) : _pos = pos,
       _raw = raw,
       _tracked = trackedBoxes;

  int get analysedFrames => _pos.length;

  /// Player position of the last analysed frame, or null before any.
  int? get lastAnalysedMs => _pos.isEmpty ? null : _pos.last;

  /// Index of the analysed frame shown at [ms], or -1 for none.
  int _frameAt(int ms) {
    var lo = 0, hi = _pos.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_pos[mid] <= ms) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (found < 0 || ms - _pos[found] > holdMs) return -1;
    return found;
  }

  /// Every box the detector found on the frame shown at [ms].
  List<TimelineBox> rawAt(int ms) {
    final i = _frameAt(ms);
    return i < 0 ? const [] : _raw[i];
  }

  /// The tracked boxes (visits) on the frame shown at [ms].
  List<TimelineBox> trackedAt(int ms) {
    final i = _frameAt(ms);
    return i < 0 ? const [] : _tracked[_pos[i]] ?? const [];
  }

  /// The analysed area for a frame of [frameAspect] (width / height), or
  /// null when the whole frame was analysed.
  Rect? areaFor(double frameAspect) {
    final r =
        analysedArea ??
        switch (settingsRoi) {
          [final cx, final cy, final side] => Roi(centerX: cx, centerY: cy, sideFraction: side).normalizedRect(frameAspect),
          _ => null,
        };
    if (r == null) return null;
    final whole = r.left <= 0.005 && r.top <= 0.005 && r.right >= 0.995 && r.bottom >= 0.995;
    return whole ? null : r;
  }
}

class VideoBoxTimeline {
  /// Per clip name; clips without any record are absent.
  final Map<String, ClipBoxes> clips;

  /// "Find visits" ran, on the current analysis.
  final bool hasVisits;

  /// "Find visits" ran on an earlier analysis: its visits no longer match.
  final bool visitsStale;

  const VideoBoxTimeline({required this.clips, required this.hasVisits, required this.visitsStale});

  static const empty = VideoBoxTimeline(clips: {}, hasVisits: false, visitsStale: false);

  /// Reads the session's two files off the UI isolate.
  static Future<VideoBoxTimeline> load(Directory sessionDir) {
    final path = sessionDir.path;
    return Isolate.run(() => readSync(path));
  }

  static VideoBoxTimeline readSync(String sessionPath) {
    List<String> lines(String name) {
      final f = File('$sessionPath/$name');
      if (!f.existsSync()) return const [];
      return const LineSplitter().convert(utf8.decode(f.readAsBytesSync(), allowMalformed: true));
    }

    return parse(lines(VideoDetector.outputFileName), lines(postTracksFileName));
  }

  static VideoBoxTimeline parse(List<String> detectionLines, List<String> trackLines) {
    final c = <String, _ClipAcc>{};
    int? runMs;
    List<double>? settingsRoi;
    List<String>? anyNames;
    for (final rec in _records(detectionLines)) {
      final name = rec['clip'] as String?;
      switch (rec['type']) {
        case 'video_run_start':
          runMs ??= (rec['time_ms'] as num?)?.toInt();
          final roi = (rec['settings'] as Map?)?['roi'];
          settingsRoi = roi is List && roi.length == 3 ? [for (final v in roi) (v as num).toDouble()] : null;
        case 'video_clip_done' when name != null:
          final a = c.putIfAbsent(name, _ClipAcc.new)..done = true;
          a.width = (rec['frame_width'] as num?)?.toInt() ?? 0;
          a.height = (rec['frame_height'] as num?)?.toInt() ?? 0;
          final roi = rec['roi_px'];
          if (roi is List && roi.length == 4 && a.width > 0 && a.height > 0) {
            final r = [for (final v in roi) (v as num).toDouble()];
            a.area = Rect.fromLTWH(r[0] / a.width, r[1] / a.height, r[2] / a.width, r[3] / a.height);
          }
          final names = rec['class_names'];
          if (names is List && names.isNotEmpty) a.names = anyNames = [for (final n in names) '$n'];
        case 'raw_detections' when name != null:
          final pts = (rec['pts_us'] as num?)?.toInt();
          final boxes = rec['boxes'];
          if (pts == null || boxes is! List) continue;
          c.putIfAbsent(name, _ClipAcc.new).raw[(pts / 1000).round()] = [
            for (final b in boxes)
              if (b is List && b.length >= 6)
                (
                  Rect.fromLTRB((b[0] as num).toDouble(), (b[1] as num).toDouble(), (b[2] as num).toDouble(), (b[3] as num).toDouble()),
                  (b[4] as num).toDouble(),
                  (b[5] as num).toInt(),
                ),
          ];
      }
    }

    // Visits: only when they were found on this very analysis.
    var trackedClips = <String>{};
    var stale = false;
    final trackRecs = _records(trackLines).toList();
    if (trackRecs.isNotEmpty && trackRecs.first['type'] == 'post_track_start') {
      final start = trackRecs.first;
      stale = (start['detections_run_ms'] as num?)?.toInt() != runMs;
      if (!stale) trackedClips = {for (final n in (start['clips'] as List? ?? const [])) '$n'};
    }
    if (trackedClips.isNotEmpty) {
      for (final rec in trackRecs) {
        final name = rec['clip'] as String?;
        final pts = (rec['pts_us'] as num?)?.toInt();
        final tracks = rec['tracks'];
        if (rec['type'] != 'detections' || name == null || pts == null || tracks is! List) continue;
        final a = c[name];
        if (a == null || !trackedClips.contains(name)) continue;
        final area = a.area ?? const Rect.fromLTWH(0, 0, 1, 1);
        final ms = (pts / 1000).round();
        a.tracked[ms] = [
          for (final t in tracks)
            if (t is Map && t['box_in_roi'] is Map)
              TimelineBox(
                box: _fromArea((t['box_in_roi'] as Map).cast<String, dynamic>(), area),
                confidence: (t['confidence'] as num?)?.toDouble() ?? 0,
                className: '${t['class_name'] ?? ''}',
                trackId: (t['track_id'] as num?)?.toInt(),
                coasted: t['coasted'] == true,
              ),
        ];
      }
    }

    final clips = <String, ClipBoxes>{};
    for (final MapEntry(key: name, value: a) in c.entries) {
      final names = a.names ?? anyNames ?? const [];
      final pos = a.raw.keys.toList()..sort();
      clips[name] = ClipBoxes._(
        clip: name,
        done: a.done,
        width: a.width,
        height: a.height,
        analysedArea: a.area,
        settingsRoi: settingsRoi,
        tracked: trackedClips.contains(name),
        pos: pos,
        raw: [
          for (final p in pos)
            [
              for (final (box, conf, cls) in a.raw[p]!)
                TimelineBox(box: box, confidence: conf, className: cls >= 0 && cls < names.length ? names[cls] : 'class$cls'),
            ],
        ],
        trackedBoxes: a.tracked,
        visits: _visits(a.tracked),
        holdMs: _holdMs(pos),
      );
    }
    return VideoBoxTimeline(clips: clips, hasVisits: trackedClips.isNotEmpty, visitsStale: stale);
  }

  /// Parsed JSON records; a torn line (app killed mid-write) is skipped.
  static Iterable<Map<String, dynamic>> _records(List<String> lines) sync* {
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final rec = jsonDecode(line);
        if (rec is Map) yield rec.cast<String, dynamic>();
      } catch (_) {}
    }
  }

  static Rect _fromArea(Map<String, dynamic> b, Rect area) {
    double v(String k) => (b[k] as num?)?.toDouble() ?? 0;
    return Rect.fromLTRB(
      area.left + v('left') * area.width,
      area.top + v('top') * area.height,
      area.left + v('right') * area.width,
      area.top + v('bottom') * area.height,
    );
  }

  /// 1.5 typical (median) steps between analysed frames; 100 ms for a clip
  /// with fewer than two frames.
  static int _holdMs(List<int> pos) {
    final steps = <int>[
      for (var i = 1; i < pos.length; i++)
        if (pos[i] > pos[i - 1]) pos[i] - pos[i - 1],
    ]..sort();
    return steps.isEmpty ? 100 : (steps[steps.length ~/ 2] * 1.5).round();
  }

  /// Each visit's span in the clip, and the class seen on most of its
  /// detected (not coasted) boxes.
  static List<TimelineVisit> _visits(Map<int, List<TimelineBox>> tracked) {
    final start = <int, int>{}, end = <int, int>{};
    final classes = <int, Map<String, int>>{};
    for (final ms in tracked.keys.toList()..sort()) {
      for (final b in tracked[ms]!) {
        final id = b.trackId;
        if (id == null) continue;
        start.putIfAbsent(id, () => ms);
        end[id] = ms;
        if (!b.coasted) (classes[id] ??= {}).update(b.className, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    // The first class on a tie, like visits.csv.
    String mostFrequent(Map<String, int>? counts) {
      String? best;
      for (final e in (counts ?? const {}).entries) {
        if (best == null || e.value > counts![best]!) best = e.key;
      }
      return best ?? '';
    }

    return [
      for (final id in start.keys)
        TimelineVisit(trackId: id, startMs: start[id]!, endMs: end[id]!, className: mostFrequent(classes[id])),
    ]..sort((a, b) => a.startMs != b.startMs ? a.startMs.compareTo(b.startMs) : a.trackId.compareTo(b.trackId));
  }
}

class _ClipAcc {
  bool done = false;
  int width = 0;
  int height = 0;
  Rect? area;
  List<String>? names;

  /// Position (ms) → (box, confidence, class index); a repeated time stamp
  /// keeps its last record.
  final raw = <int, List<(Rect, double, int)>>{};
  final tracked = <int, List<TimelineBox>>{};
}
