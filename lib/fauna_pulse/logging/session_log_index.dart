// FaunaPulse — one streaming session-log index for the summary screen
// (round 163, perf review E5).
//
// The summary screen used to run THREE independent full-file parses of
// session.jsonl on the UI isolate (graphs + track spans, photos, ROI
// history), each via `readAsLines()` — a file-sized `List<String>` plus a
// JSON decode per line per parse, i.e. seconds of jank and a heap spike
// after a long field session. This class replaces all of them with ONE
// streaming pass (`File.openRead()` → UTF-8 decode → `LineSplitter`, so no
// whole-file string or line list ever exists) executed OFF the UI isolate
// via `Isolate.run`; the summary screen caches a single Future of it and
// every tab consumes the same immutable result.
//
// A second bounded streaming pass runs only when the session contains
// high-res photos with known content moments (the round-114/115 box
// time-matching needs the detections records a second time; the
// FrameBracketAccumulator keeps memory O(photos), never O(frames)).
//
// Parity rules (KEEP when editing):
//  * `detection` (one line per track, sessions ≤ round 68) and `detections`
//    (one line per frame, round 69+) must BOTH be understood everywhere.
//  * Malformed/truncated lines (crash mid-write) are skipped silently, like
//    the screen's old `_tryDecode`.
//  * The cheap head/tail stats path (`_loadStats` in the summary screen,
//    same pattern in home/analysis screens) stays separate on purpose — the
//    headline numbers must appear before this full parse finishes.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../capture/roi_capture.dart' show roiStreamSideFromLog;
import 'photo_box_matcher.dart';

/// One `power` record's raw readings (unit quirks are handled at display
/// time by the summary's energy-series builder, not here).
class IndexedPowerSample {
  final int ms;

  /// Instantaneous current (µA per the Android spec; mA on some phones).
  final int? currentUa;

  /// Battery voltage (mV).
  final int? voltageMv;

  /// Remaining charge counter (µAh) — spec-reliable units.
  final int? chargeUah;

  /// Power computed at capture time (last-resort fallback).
  final double? loggedW;

  /// Battery reported charging/full at sample time (null on older logs).
  final bool? isCharging;

  /// A power source was attached at sample time (round 188; null on older
  /// logs). Catches the full-battery-on-power-bank case that reports
  /// NOT_CHARGING while plugged — either flag invalidates the energy series.
  final bool? isPlugged;

  const IndexedPowerSample({
    required this.ms,
    required this.currentUa,
    required this.voltageMv,
    required this.chargeUah,
    required this.loggedW,
    required this.isCharging,
    this.isPlugged,
  });
}

/// One detection box logged against a photo's TRIGGER frame, ROI-normalized
/// (0..1). Label text is built by the screen (display concern), so this
/// carries the raw fields the label derives from.
class IndexedPhotoBox {
  final double left, top, right, bottom;
  final int? trackId;
  final String? className;
  final double? confidence;

  /// True when this entry carried the photo's filename itself (its schedule
  /// triggered the shot); false for insects co-detected in the same frame.
  final bool triggered;

  const IndexedPhotoBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.trackId,
    required this.className,
    required this.confidence,
    required this.triggered,
  });
}

/// Everything the log said about one saved photo (trigger boxes, capture
/// metadata, the r108 live companion, the r114/115 time-matched box result).
class IndexedPhoto {
  final String name;
  final List<IndexedPhotoBox> boxes;
  final List<int> trackIds; // sorted ascending
  final Map<int, double> trackConf;
  final int captureMs;

  /// ROI pixel size when the photo was saved (square crop). Null if no ROI
  /// record preceded the photo in the log.
  final int? resW;
  final int? resH;

  /// The r108 sync companion's file name / saved side, when logged.
  final String? liveName;
  final int? livePx;
  final int? contentLagMs;
  final int? liveLagMs;

  /// Round 114: the high-res photo's CONTENT moment (epoch ms) — measured or
  /// (when [contentAtApprox]) reconstructed from the r108 lags.
  final int? contentAtMs;
  final bool contentAtApprox;

  /// Round 114/115 time-matched boxes for the high-res view (null → the
  /// screen falls back to trigger boxes; [stillMatchNote] says why).
  final PhotoBoxResult? stillMatch;
  final bool stillWithinTol;
  final String? stillMatchNote;

  /// True for a reference photo (gt_frames/): clock-driven, no boxes.
  final bool isReference;

  const IndexedPhoto({
    required this.name,
    required this.boxes,
    required this.trackIds,
    required this.trackConf,
    required this.captureMs,
    required this.resW,
    required this.resH,
    required this.liveName,
    required this.livePx,
    required this.contentLagMs,
    required this.liveLagMs,
    required this.contentAtMs,
    required this.contentAtApprox,
    required this.stillMatch,
    required this.stillWithinTol,
    required this.stillMatchNote,
    required this.isReference,
  });
}

/// One settled mid-session ROI change (`roi_update` record), pre-projected
/// to the stream-grid side the user saw on screen (round 109 semantics).
typedef RoiHistoryEntry = ({
  int timeMs,
  int? sidePx,
  int? savesPx,
  String? source,
});

/// The one-parse aggregate every summary tab reads. Internal to the app —
/// never serialized; it must keep reading every existing session schema
/// without migration.
class SessionLogIndex {
  /// The decoded `start_of_session` record (first one in the log), or null
  /// on a truncated/empty file. The screen's cheap head/tail stats remain
  /// the primary source; this is the parse-time copy for derived values.
  final Map<String, dynamic>? startRecord;

  /// Per track id: (first seen ms, last seen ms) — the visit timeline lanes.
  final Map<int, (int, int)> trackSpans;

  // Diagnostic series ((time_ms, value) points, in log order).
  final List<(int, double)> temps;
  final List<(int, double)> headroom;
  final List<(int, double)> fps;
  final List<(int, double)> infMs;
  final List<IndexedPowerSample> powerSamples;

  /// Saved photos in log (≈ capture) order, and everything known about each.
  final List<String> photoOrder;
  final Map<String, IndexedPhoto> photos;

  /// Names that live in gt_frames/ (reference photos), not roi_frames/.
  final Set<String> referenceNames;

  final List<RoiHistoryEntry> roiHistory;

  const SessionLogIndex({
    required this.startRecord,
    required this.trackSpans,
    required this.temps,
    required this.headroom,
    required this.fps,
    required this.infMs,
    required this.powerSamples,
    required this.photoOrder,
    required this.photos,
    required this.referenceNames,
    required this.roiHistory,
  });

  /// Builds the index OFF the UI isolate. The whole parse (including the
  /// second bracket-matching pass) runs in a worker isolate; only the
  /// aggregate result is copied back.
  static Future<SessionLogIndex> build(File logFile) {
    final path = logFile.path;
    return Isolate.run(() => parseFile(path));
  }

  /// The parse itself — same isolate as the caller (used directly in tests;
  /// [build] wraps it in `Isolate.run` for the app).
  static Future<SessionLogIndex> parseFile(String path) async {
    final b = _IndexBuilder();
    await for (final line in _lines(path)) {
      b.feed(line);
    }
    // Pass 2 (round 114/115): only when at least one high-res photo has a
    // known content moment. Streams the file again instead of keeping every
    // line in memory (the old screen code re-iterated a full line list).
    if (b.contentMsByFile.isNotEmpty) {
      final acc = FrameBracketAccumulator(b.contentMsByFile);
      final intervals = <int>[];
      int? prevFrameMs;
      await for (final line in _lines(path)) {
        // Cheap prefilter (same as the old screen pass): only round-114+
        // detections records carry `frame_ms`.
        if (!line.contains('"detections"') || !line.contains('"frame_ms"')) {
          continue;
        }
        final rec = _tryDecode(line);
        if (rec == null || rec['type'] != 'detections') continue;
        // Prefer the sensor-exposure stamp (precise) over the emit stamp.
        final frameMs =
            (rec['frame_sensor_ms'] as num?)?.toInt() ??
            (rec['frame_ms'] as num?)?.toInt();
        if (frameMs == null) continue;
        if (prevFrameMs != null && intervals.length < 5000) {
          final d = frameMs - prevFrameMs;
          if (d > 0) intervals.add(d);
        }
        prevFrameMs = frameMs;
        final tracks = rec['tracks'];
        if (tracks is List) {
          acc.feed(frameMs, [
            for (final e in tracks)
              if (e is Map<String, dynamic>) e,
          ]);
        }
      }
      b.finishBracketMatching(acc, toleranceMs(intervals));
    }
    return b.result();
  }

  static Stream<String> _lines(String path) => File(path)
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  static Map<String, dynamic>? _tryDecode(String line) {
    try {
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      // A line truncated by a crash is expected in an append-only log.
      return null;
    }
  }
}

/// Mutable accumulation state for one photo while the log streams past;
/// frozen into an [IndexedPhoto] at the end.
class _PhotoAcc {
  final String name;
  final List<IndexedPhotoBox> boxes = [];
  final Set<int> trackIds = {};
  final Map<int, double> trackConf = {};
  int captureMs = 0;
  int? resW, resH;
  String? liveName;
  int? livePx;
  int? contentLagMs;
  int? liveLagMs;
  int? contentAtMs;
  bool contentAtApprox = false;
  PhotoBoxResult? stillMatch;
  bool stillWithinTol = false;
  String? stillMatchNote;
  bool isReference = false;

  _PhotoAcc(this.name);
}

class _IndexBuilder {
  Map<String, dynamic>? startRecord;
  final Map<int, (int, int)> spans = {};
  final List<(int, double)> temps = [];
  final List<(int, double)> headroom = [];
  final List<(int, double)> fps = [];
  final List<(int, double)> infMs = [];
  final List<IndexedPowerSample> power = [];

  final List<String> order = [];
  final Map<String, _PhotoAcc> photos = {};
  final Set<String> referenceNames = {};

  /// `roi_update` stamps (debounced, so ~2 s late) — invalidate box↔photo
  /// time-matching across an ROI move (round 114).
  final List<int> roiUpdateTimes = [];
  final List<RoiHistoryEntry> roiHistory = [];

  /// Per high-res photo: its content moment — the pass-2 work list.
  final Map<String, int> contentMsByFile = {};

  // ROI pixel size carried forward from the start record / roi_update
  // records, so each photo gets the size in effect when it was captured.
  int? _curRoiW, _curRoiH;

  void _extendSpan(int? t, int? id) {
    if (id == null || t == null) return;
    final cur = spans[id];
    spans[id] = cur == null
        ? (t, t)
        : (cur.$1 < t ? cur.$1 : t, cur.$2 > t ? cur.$2 : t);
  }

  _PhotoAcc _photo(String name) {
    final existing = photos[name];
    if (existing != null) return existing;
    final acc = _PhotoAcc(name);
    photos[name] = acc;
    order.add(name);
    return acc;
  }

  void feed(String line) {
    if (line.trim().isEmpty) return;
    final rec = SessionLogIndex._tryDecode(line);
    if (rec == null) return;
    final t = (rec['time_ms'] as num?)?.toInt();
    switch (rec['type']) {
      case 'start_of_session':
        startRecord ??= rec;
        _readRoiDims(rec);
      case 'roi_update':
        _readRoiDims(rec);
        if (t != null) roiUpdateTimes.add(t);
        roiHistory.add((
          timeMs: t ?? 0,
          sidePx: _roiStreamSideOf(rec),
          savesPx: (rec['saves_px'] as num?)?.toInt(),
          source: rec['roi_source'] as String?,
        ));
      // 'detection': one line per track (sessions ≤ round 68).
      // 'detections': one line per frame with a `tracks` array (round 69+).
      case 'detection':
        _extendSpan(t, (rec['track_id'] as num?)?.toInt());
        _addPhotoEntry(rec, t ?? 0);
      case 'detections':
        final tracks = rec['tracks'];
        if (tracks is List) {
          // The frame's shared photo filename (one photo per frame at
          // most): handed to the entries that lack their own, so
          // co-detected insects appear on the photo too (round 86).
          String? frameJpeg;
          for (final e in tracks) {
            if (e is Map<String, dynamic> && e['jpeg'] is String) {
              frameJpeg = e['jpeg'] as String;
              break;
            }
          }
          for (final e in tracks) {
            if (e is Map<String, dynamic>) {
              _extendSpan(t, (e['track_id'] as num?)?.toInt());
              _addPhotoEntry(e, t ?? 0, frameJpeg: frameJpeg);
            }
          }
        }
      case 'thermal':
        if (t == null) break;
        final temp = (rec['battery_temp_c'] as num?)?.toDouble();
        if (temp != null) temps.add((t, temp));
        final hr = (rec['thermal_headroom'] as num?)?.toDouble();
        if (hr != null) headroom.add((t, hr));
        // Older sessions logged FPS inside the thermal record; keep reading
        // it so their graphs still work.
        final f = (rec['fps'] as num?)?.toDouble();
        if (f != null) fps.add((t, f));
      case 'fps':
        if (t == null) break;
        // Prefer `pipeline_fps` (round 85: the native `fps` EMA blended
        // motion-gate sleep gaps in on older sessions and read near zero).
        final f = ((rec['pipeline_fps'] ?? rec['fps']) as num?)?.toDouble();
        if (f != null) fps.add((t, f));
        final inf = (rec['inf_ms'] as num?)?.toDouble();
        if (inf != null) infMs.add((t, inf));
      case 'power':
        if (t == null) break;
        power.add(
          IndexedPowerSample(
            ms: t,
            currentUa: (rec['battery_current_ua'] as num?)?.toInt(),
            voltageMv: (rec['battery_voltage_mv'] as num?)?.toInt(),
            chargeUah: (rec['charge_counter_uah'] as num?)?.toInt(),
            loggedW: (rec['power_w'] as num?)?.toDouble(),
            isCharging: rec['is_charging'] as bool?,
            isPlugged: rec['is_plugged'] as bool?,
          ),
        );
      case 'capture':
        _readCapture(rec);
      case 'motion_capture' || 'timelapse_capture':
        // Motion-only / time-lapse mode: the discovery line for its photo
        // (the detector never ran, so no detections record carries the name).
        final jpeg = rec['jpeg'] as String?;
        if (jpeg != null && jpeg.isNotEmpty && !photos.containsKey(jpeg)) {
          final p = _photo(jpeg);
          // Prefer the exact trigger moment (round 99, == the filename
          // stamp) over this record's log-queue time_ms; old logs lack it.
          p.captureMs = (rec['captured_at_ms'] as num?)?.toInt() ?? t ?? 0;
          p.resW = _curRoiW;
          p.resH = _curRoiH;
        }
      case 'gt_capture':
        // Reference photo: no boxes by design (clock-driven); the record is
        // written after the JPEG landed and carries the exact saved side.
        final jpeg = rec['jpeg'] as String?;
        if (jpeg != null && jpeg.isNotEmpty && !photos.containsKey(jpeg)) {
          final p = _photo(jpeg);
          p.captureMs = (rec['captured_at_ms'] as num?)?.toInt() ?? t ?? 0;
          final px = (rec['saved_px'] as num?)?.toInt();
          if (px != null && px > 0) {
            p.resW = px;
            p.resH = px;
          } else {
            p.resW = _curRoiW;
            p.resH = _curRoiH;
          }
          p.isReference = true;
          referenceNames.add(jpeg);
        }
    }
  }

  void _readRoiDims(Map<String, dynamic> rec) {
    final roi = rec['roi'];
    if (roi is Map) {
      final w = (roi['width_px'] as num?)?.toInt();
      final h = (roi['height_px'] as num?)?.toInt();
      if (w != null) _curRoiW = w;
      if (h != null) _curRoiH = h;
    }
  }

  /// Stream-grid ROI side of a start/roi_update record — the ÷32 number the
  /// user saw on screen. Round-109+ records carry it directly; older ones
  /// get it recomputed from the record's `roi` block (which may be a
  /// high-res-frame projection) against the start record's analysis frame.
  int? _roiStreamSideOf(Map<String, dynamic> rec) {
    final direct = (rec['roi_side_stream_px'] as num?)?.toInt();
    if (direct != null && direct > 0) return direct;
    final roi = rec['roi'];
    if (roi is! Map) return null;
    final aw = (startRecord?['analysis_frame_width_px'] as num?)?.toInt() ?? 0;
    final ah = (startRecord?['analysis_frame_height_px'] as num?)?.toInt() ?? 0;
    return roiStreamSideFromLog(roi, aw, ah);
  }

  void _readCapture(Map<String, dynamic> rec) {
    final file = rec['file'] as String?;
    if (file == null || file.isEmpty) return;
    // Backstop: a photo no detections/motion_capture record ever named
    // (a lost line must not hide a saved JPEG) still becomes browsable —
    // seeded here, boxes simply empty.
    var p = photos[file];
    if (p == null) {
      p = _photo(file);
      p.captureMs = (rec['time_ms'] as num?)?.toInt() ?? 0;
    }
    // Round 99: prefer the exact trigger moment — the instant the filename
    // stamp encodes — over the earlier-seeded record times.
    final capMs = (rec['captured_at_ms'] as num?)?.toInt();
    if (capMs != null) p.captureMs = capMs;
    // The capture record carries the EXACT saved side (crop snapping +
    // target cap applied) — it overrides the ROI-geometry estimate (r64).
    final px = (rec['saved_px'] as num?)?.toInt();
    if (px != null && px > 0) {
      p.resW = px;
      p.resH = px;
    }
    // Sync companion (r108) + content lag: only high-res-path records carry
    // these; fast-path photos ARE live crops, so they have neither.
    final liveJpeg = rec['live_jpeg'] as String?;
    if (liveJpeg != null && liveJpeg.isNotEmpty) {
      p.liveName = liveJpeg;
      final livePx = (rec['live_saved_px'] as num?)?.toInt();
      if (livePx != null && livePx > 0) p.livePx = livePx;
      final liveLag = (rec['live_lag_ms'] as num?)?.toInt();
      if (liveLag != null) p.liveLagMs = liveLag;
    }
    final lagMs = (rec['content_lag_ms'] as num?)?.toDouble();
    if (lagMs != null) p.contentLagMs = lagMs.round();
    // Round 114: when this photo's content moment is known, pass 2 can
    // time-match detector frames to it.
    final moment = contentMomentOf(rec);
    if (moment != null) {
      p.contentAtMs = moment.ms;
      p.contentAtApprox = moment.approx;
      contentMsByFile[file] = moment.ms;
    }
  }

  /// Joins one tracked insect's entry to a photo (both record shapes). Only
  /// the tracks whose photo step was DUE carry the `jpeg` filename;
  /// [frameJpeg] passes that filename to the OTHER tracks of the same frame
  /// record so every insect visible in the photo gets its box (round 86).
  void _addPhotoEntry(
    Map<String, dynamic> entry,
    int timeMs, {
    String? frameJpeg,
  }) {
    final own = entry['jpeg'] as String?;
    final jpeg = own ?? frameJpeg;
    if (jpeg == null || jpeg.isEmpty) return;
    var p = photos[jpeg];
    if (p == null) {
      // First discovery: seed the capture time and the ROI size in effect
      // now; a later `capture` record may override both with exact values.
      p = _photo(jpeg);
      p.captureMs = timeMs;
      if (_curRoiW != null && _curRoiH != null) {
        p.resW = _curRoiW;
        p.resH = _curRoiH;
      }
    }
    final tid = (entry['track_id'] as num?)?.toInt();
    if (tid != null) p.trackIds.add(tid);
    final conf = (entry['confidence'] as num?)?.toDouble();
    if (tid != null && conf != null) p.trackConf[tid] = conf;
    final box = entry['box_in_roi'];
    if (box is Map) {
      p.boxes.add(
        IndexedPhotoBox(
          left: (box['left'] as num?)?.toDouble() ?? 0,
          top: (box['top'] as num?)?.toDouble() ?? 0,
          right: (box['right'] as num?)?.toDouble() ?? 0,
          bottom: (box['bottom'] as num?)?.toDouble() ?? 0,
          trackId: tid,
          className: entry['class_name'] as String?,
          confidence: conf,
          triggered: own != null,
        ),
      );
    }
  }

  /// Applies the round-114/115 pass-2 results: per high-res photo either a
  /// matched box set or the reason it fell back to trigger boxes.
  void finishBracketMatching(FrameBracketAccumulator acc, int tolMs) {
    for (final MapEntry(key: file, value: contentMs)
        in contentMsByFile.entries) {
      final p = photos[file];
      if (p == null) continue;
      // ROI-move check FIRST (r115): a moved ROI genuinely invalidates the
      // coordinates, whatever frames exist.
      if (roiMovedInWindow(roiUpdateTimes, p.captureMs, contentMs)) {
        p.stillMatchNote = 'the ROI was moved before the photo landed';
        continue;
      }
      final bracket = acc.bracketOf(file);
      final result = buildPhotoBoxes(
        before: bracket.before,
        after: bracket.after,
        photoFile: file,
      );
      if (result == null) {
        p.stillMatchNote =
            'no detector frame within $kBracketWindowMs ms — the insect '
            "had likely left by this photo's moment";
        continue;
      }
      // r115: no hard tolerance rejection — it only picks the label tone.
      p.stillMatch = result;
      p.stillWithinTol = result.nearestAbsDeltaMs <= tolMs;
    }
  }

  SessionLogIndex result() => SessionLogIndex(
    startRecord: startRecord,
    trackSpans: spans,
    temps: temps,
    headroom: headroom,
    fps: fps,
    infMs: infMs,
    powerSamples: power,
    photoOrder: order,
    photos: {
      for (final MapEntry(key: name, value: p) in photos.entries)
        name: IndexedPhoto(
          name: name,
          boxes: p.boxes,
          trackIds: p.trackIds.toList()..sort(),
          trackConf: p.trackConf,
          captureMs: p.captureMs,
          resW: p.resW,
          resH: p.resH,
          liveName: p.liveName,
          livePx: p.livePx,
          contentLagMs: p.contentLagMs,
          liveLagMs: p.liveLagMs,
          contentAtMs: p.contentAtMs,
          contentAtApprox: p.contentAtApprox,
          stillMatch: p.stillMatch,
          stillWithinTol: p.stillWithinTol,
          stillMatchNote: p.stillMatchNote,
          isReference: p.isReference,
        ),
    },
    referenceNames: referenceNames,
    roiHistory: roiHistory,
  );
}
