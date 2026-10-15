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
// Round 240: a live AI session that also recorded the ROI as video has a
// third source, the live AI's own tracked boxes in session.jsonl, placed on
// its clips by camera time ([readLiveSync]).
//
// A frame's place in the clip is its own time stamp in the video (`pts_us`),
// the same clock the player reports. A box stays on screen until the next
// analysed frame, and at most 1.5 analysed-frame steps: gaps, a stopped
// analysis and the unanalysed end of a clip never show old boxes.
//
// Round 305: a track ID starts at the tracker's first sighting, as in
// track_ids.csv: its `created` event says how long before its first box
// (logged only from confirmation on) the tracker first saw the animal.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
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

/// One visit as seen in one clip: player positions of its start (the first
/// sighting in the clip it began in, else its first tracked box) and its last
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

  /// Positions (ms) of the analysed frames with at least one box (round 247).
  late final List<int> rawBoxMs = [
    for (var i = 0; i < _pos.length; i++)
      if (_raw[i].isNotEmpty) _pos[i],
  ];

  /// Round 307: the stretches (start, end in ms) with at least one track ID, for the time bar:
  /// the visits' spans, merged where they overlap.
  late final List<(int, int)> trackSpans = _merge([for (final v in visits) (v.startMs, v.endMs)]);

  /// How long the clip has at least one track ID (ms).
  late final int trackedMs = trackSpans.fold(0, (sum, s) => sum + s.$2 - s.$1);

  /// Round 307: the stretches (ms) in which "All boxes" draws a box: each analysed frame with
  /// one, until the next analysed frame (at most [holdMs], as [rawAt]).
  late final List<(int, int)> rawSpans = _merge([
    for (var i = 0; i < _pos.length; i++)
      if (_raw[i].isNotEmpty) (_pos[i], i + 1 < _pos.length ? min(_pos[i + 1], _pos[i] + holdMs) : _pos[i] + holdMs),
  ]);

  /// [spans] sorted by start, with those that overlap or touch joined into one.
  static List<(int, int)> _merge(List<(int, int)> spans) {
    final out = <(int, int)>[];
    for (final (start, end) in spans..sort((a, b) => a.$1.compareTo(b.$1))) {
      if (out.isNotEmpty && start <= out.last.$2) {
        out.last = (out.last.$1, max(out.last.$2, end));
      } else {
        out.add((start, end));
      }
    }
    return out;
  }

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

  /// The boxes are the live AI's, found while recording (round 240).
  final bool live;

  const VideoBoxTimeline({required this.clips, required this.hasVisits, required this.visitsStale, this.live = false});

  static const empty = VideoBoxTimeline(clips: {}, hasVisits: false, visitsStale: false);

  /// Reads the live AI's boxes for the session's clips off the UI isolate.
  static Future<VideoBoxTimeline> loadLive(Directory sessionDir) {
    final path = sessionDir.path;
    return Isolate.run(() => readLiveSync(path));
  }

  /// Round 240: the live AI's tracked boxes (session.jsonl `detections`) on
  /// the clips recorded during that session (`video_clip` records). Each clip
  /// is the live ROI square, so a box's `box_in_roi` is its place in the
  /// video; a record's place in a clip is its camera time (`frame_sensor_ms`,
  /// the clock of the clip's `start_epoch_ms`) minus the clip's start. Frames
  /// without an insect are not in the log, so a box shows for at most 1.5
  /// typical steps between logged frames.
  static VideoBoxTimeline readLiveSync(String sessionPath) {
    final f = File('$sessionPath/session.jsonl');
    if (!f.existsSync()) return empty;
    final recs = _records(const LineSplitter().convert(utf8.decode(f.readAsBytesSync(), allowMalformed: true))).toList();
    final spans = <(String, int, int)>[];
    for (final rec in recs) {
      if (rec['type'] != 'video_clip') continue;
      final file = rec['file'] as String?;
      final start = (rec['start_epoch_ms'] as num?)?.toInt();
      final dur = (rec['duration_ms'] as num?)?.toInt();
      if (file != null && start != null && dur != null) spans.add((file.split('/').last, start, dur));
    }
    final c = {for (final (name, _, _) in spans) name: _ClipAcc()..done = true};
    final leads = _leads(recs);
    for (final rec in recs) {
      if (rec['type'] != 'detections') continue;
      final t = ((rec['frame_sensor_ms'] ?? rec['frame_ms']) as num?)?.toInt();
      final tracks = rec['tracks'];
      if (t == null || tracks is! List) continue;
      for (final (name, start, dur) in spans) {
        if (t < start || t > start + dur) continue;
        final ms = t - start;
        final a = c[name]!;
        a.addLeads(rec, tracks, leads);
        a.raw[ms] = const [];
        a.tracked[ms] = [
          for (final tr in tracks)
            if (tr is Map && tr['box_in_roi'] is Map)
              TimelineBox(
                box: _fromArea((tr['box_in_roi'] as Map).cast<String, dynamic>(), const Rect.fromLTWH(0, 0, 1, 1)),
                confidence: (tr['confidence'] as num?)?.toDouble() ?? 0,
                className: '${tr['class_name'] ?? ''}',
                trackId: (tr['track_id'] as num?)?.toInt(),
                coasted: tr['coasted'] == true,
              ),
        ];
        break;
      }
    }
    return VideoBoxTimeline(
      clips: {
        for (final MapEntry(key: name, value: a) in c.entries)
          name: ClipBoxes._(
            clip: name,
            done: true,
            width: 0,
            height: 0,
            analysedArea: null,
            settingsRoi: null,
            tracked: true,
            pos: a.raw.keys.toList()..sort(),
            raw: [for (final _ in a.raw.keys) const <TimelineBox>[]],
            trackedBoxes: a.tracked,
            visits: _visits(a.tracked, a.leadMs),
            holdMs: _holdMs(a.raw.keys.toList()..sort()),
          ),
      },
      hasVisits: true,
      visitsStale: false,
      live: true,
    );
  }

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
      final leads = _leads(trackRecs);
      for (final rec in trackRecs) {
        final name = rec['clip'] as String?;
        final pts = (rec['pts_us'] as num?)?.toInt();
        final tracks = rec['tracks'];
        if (rec['type'] != 'detections' || name == null || pts == null || tracks is! List) continue;
        final a = c[name];
        if (a == null || !trackedClips.contains(name)) continue;
        a.addLeads(rec, tracks, leads);
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
        visits: _visits(a.tracked, a.leadMs),
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

  /// Per track ID, from its `created` event: the frame it was confirmed on
  /// (`frame_ms`) and how long after the first sighting that was (ms).
  static Map<int, (int, int)> _leads(Iterable<Map<String, dynamic>> recs) => {
    for (final r in recs)
      if (r['type'] == 'track_event' && r['event'] == 'created')
        if ((r['track_id'] as num?)?.toInt() case final id?)
          if (((r['frame_ms'] ?? r['time_ms']) as num?)?.toInt() case final at?)
            if ((r['first_seen_ms'] as num?)?.toInt() case final first?) id: (at, max(0, at - first)),
  };

  /// Each visit's span in the clip, and the class seen on most of its
  /// detected (not coasted) boxes. [leadMs] moves a start back to the first
  /// sighting, never before the clip's start.
  static List<TimelineVisit> _visits(Map<int, List<TimelineBox>> tracked, Map<int, int> leadMs) {
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
        TimelineVisit(
          trackId: id,
          startMs: max(0, start[id]! - (leadMs[id] ?? 0)),
          endMs: end[id]!,
          className: mostFrequent(classes[id]),
        ),
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

  /// Per track ID confirmed in this clip: ms from its first sighting to its
  /// first box here.
  final leadMs = <int, int>{};

  /// Notes the lead of each track ID whose `created` event fell on the
  /// frame of [rec] (its first box).
  void addLeads(Map<String, dynamic> rec, List<dynamic> tracks, Map<int, (int, int)> leads) {
    final at = ((rec['frame_ms'] ?? rec['time_ms']) as num?)?.toInt();
    for (final t in tracks) {
      final id = t is Map ? (t['track_id'] as num?)?.toInt() : null;
      final lead = leads[id];
      if (id != null && lead != null && lead.$1 == at) leadMs[id] = lead.$2;
    }
  }
}
