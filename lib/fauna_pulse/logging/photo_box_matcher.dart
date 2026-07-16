// FaunaPulse — time-matching detection frames to high-res ROI photos
// (round 114).
//
// A high-res photo's CONTENT lags its trigger by a measured 0.17–0.8 s, so
// the trigger frame's boxes often miss the insect's real position on it. The
// detector, however, kept running and logging boxes the whole time — so the
// summary viewer (and offline post-processing) can instead use the detections
// record whose frame time is CLOSEST to the photo's content moment. All of
// this happens at display/parse time: nothing here runs in the live pipeline.
//
// Pure functions + a small accumulator, kept out of the summary screen so the
// matching rules are unit-testable without widgets.

/// A photo's content moment (epoch ms) and whether it was measured or
/// reconstructed from lags.
typedef ContentMoment = ({int ms, bool approx});

/// The photo content moment of one `capture` record, or null when the record
/// is not a high-res capture (fast-path photos ARE their trigger moment — no
/// matching needed).
///
///  * r114+ logs carry `content_at_ms` — the sensor-exposure moment mapped to
///    epoch natively (precise).
///  * r108–113 logs (and odd HALs) are reconstructed as
///    `captured_at_ms + content_lag_ms + (live_lag_ms ?? 0)`: `content_lag_ms`
///    is measured from the takePicture() call, which happens AFTER the
///    trigger by the dispatch gap; the companion grab runs first, so
///    `live_lag_ms` brackets that gap. Flagged [ContentMoment.approx].
ContentMoment? contentMomentOf(Map<dynamic, dynamic> rec) {
  final exact = (rec['content_at_ms'] as num?)?.toInt();
  if (exact != null && exact > 0) return (ms: exact, approx: false);
  final contentLag = (rec['content_lag_ms'] as num?)?.toDouble();
  final capturedAt = (rec['captured_at_ms'] as num?)?.toInt();
  if (contentLag == null || capturedAt == null) return null;
  final liveLag = (rec['live_lag_ms'] as num?)?.toInt() ?? 0;
  return (ms: capturedAt + contentLag.round() + liveLag, approx: true);
}

/// How far (ms) a matched frame may sit from the photo's content moment
/// before the match is rejected: 1.5× the session's median frame interval,
/// floored at 250 ms. Adaptive because the detector cadence varies hugely
/// (10 FPS cap, 3 FPS throttle floor, gate sleep); a display-time heuristic,
/// deliberately NOT a user Setting.
int toleranceMs(List<int> frameIntervalsMs) {
  if (frameIntervalsMs.isEmpty) return 250;
  final sorted = [...frameIntervalsMs]..sort();
  final median = sorted[sorted.length ~/ 2];
  final t = (1.5 * median).round();
  return t < 250 ? 250 : t;
}

/// True when a `roi_update` landed between the trigger and the photo's
/// content moment — the matched frame's `box_in_roi` would then be relative
/// to a DIFFERENT ROI than the photo's crop, so the match must be rejected
/// (fall back to trigger boxes rather than draw a mis-scaled box).
///
/// The window end is widened by [kRoiUpdateStampLagMs]: `roi_update` records
/// are debounced (~2 s stability), so their `time_ms` is stamped ~2 s AFTER
/// the actual move — conservative rejection beats a wrong box.
bool roiMovedInWindow(
  List<int> roiUpdateTimesMs,
  int triggerMs,
  int contentMs,
) {
  for (final t in roiUpdateTimesMs) {
    if (t > triggerMs && t <= contentMs + kRoiUpdateStampLagMs) return true;
  }
  return false;
}

/// See [roiMovedInWindow]: the debouncer's stability window (2 s) plus slack.
const int kRoiUpdateStampLagMs = 2500;

/// How far (ms) on EACH side of a photo's content moment a detector frame may
/// sit and still be used for box placement (round 115). Deliberately wider
/// than [toleranceMs]: capturing a high-res photo PAUSES the analysis stream
/// (ImageCapture competes with ImageAnalysis — session_16 measured frame
/// holes of 133–1532 ms bracketing every capture, exactly where the content
/// moment falls), and a 1.4 s-away frame still beats the ~0.5 s-away trigger
/// boxes r114 wrongly fell back to.
const int kBracketWindowMs = 1500;

/// Maximum before→after span (ms) across which linear interpolation is still
/// trusted; beyond it the nearer side alone is used (a straight line across
/// more unobserved time than this is a guess, not an estimate).
const int kMaxBracketGapMs = 2000;

/// One detections record considered for one photo.
class MatchedFrame {
  /// Signed distance frame − content moment (ms): negative = the matched
  /// frame is OLDER than the photo's content.
  final int deltaMs;

  /// The record's raw `tracks` entries (maps with `track_id`, `box_in_roi`…).
  final List<Map<String, dynamic>> tracks;

  const MatchedFrame({required this.deltaMs, required this.tracks});
}

/// The nearest detector frames on each side of one photo's content moment:
/// [before] has `deltaMs <= 0`, [after] has `deltaMs > 0`; either is null
/// when no frame fell inside the window on that side.
typedef FrameBracket = ({MatchedFrame? before, MatchedFrame? after});

/// Streams detections records past a fixed set of photo content moments and
/// keeps, PER PHOTO, the nearest frame on EACH side (round 115) — memory
/// stays O(photos), never O(frames), however long the session log is.
class FrameBracketAccumulator {
  /// Content moments sorted ascending, with the photo file names parallel.
  final List<int> _momentsMs;
  final List<String> _files;
  final int windowMs;

  final Map<String, MatchedFrame> _bestBefore = {};
  final Map<String, MatchedFrame> _bestAfter = {};

  FrameBracketAccumulator(
    Map<String, int> contentMsByFile, {
    this.windowMs = kBracketWindowMs,
  }) : _files = contentMsByFile.keys.toList(),
       _momentsMs = contentMsByFile.values.toList() {
    // Parallel sort by moment (insertion order of the two lists matches the
    // map's iteration order, so pair them up first).
    final pairs = [
      for (var i = 0; i < _files.length; i++) (_momentsMs[i], _files[i]),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 0; i < pairs.length; i++) {
      _momentsMs[i] = pairs[i].$1;
      _files[i] = pairs[i].$2;
    }
  }

  /// The bracket found for [file] (photo file name), sides null when nothing
  /// landed within [windowMs] on that side.
  FrameBracket bracketOf(String file) =>
      (before: _bestBefore[file], after: _bestAfter[file]);

  /// Offers one detections record to every photo whose content moment lies
  /// within [windowMs] of it. r114 offered each frame to at most TWO photos
  /// (binary-search neighbours) — with one capture pause spanning two
  /// photos' content moments, the second photo never received its post-hole
  /// frame. Now the scan walks outward until the window is exceeded; the
  /// walk touches only a handful of indices (high-res photos are ≥ ~1 s
  /// apart — sub-second steps force the fast path, which has no content
  /// moment).
  void feed(int frameTimeMs, List<Map<String, dynamic>> tracks) {
    if (_momentsMs.isEmpty || tracks.isEmpty) return;
    // Binary search: first moment >= frameTimeMs.
    var lo = 0, hi = _momentsMs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_momentsMs[mid] < frameTimeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // Moments < frameTime: this frame lies AFTER them (delta > 0).
    for (var i = lo - 1; i >= 0; i--) {
      final delta = frameTimeMs - _momentsMs[i];
      if (delta > windowMs) break;
      final cur = _bestAfter[_files[i]];
      if (cur == null || delta < cur.deltaMs) {
        _bestAfter[_files[i]] = MatchedFrame(deltaMs: delta, tracks: tracks);
      }
    }
    // Moments >= frameTime: this frame lies AT or BEFORE them (delta <= 0),
    // so an exact hit counts as "before" and the interpolation denominator
    // (after − before) stays > 0.
    for (var i = lo; i < _momentsMs.length; i++) {
      final delta = frameTimeMs - _momentsMs[i];
      if (-delta > windowMs) break;
      final cur = _bestBefore[_files[i]];
      if (cur == null || delta.abs() < cur.deltaMs.abs()) {
        _bestBefore[_files[i]] = MatchedFrame(deltaMs: delta, tracks: tracks);
      }
    }
  }
}

/// One track's box for a photo, ROI-normalized (0..1) like `box_in_roi`.
class PhotoTrackBox {
  final int? trackId;
  final double left, top, right, bottom;

  /// From the NEARER contributing frame — a confidence is a detector output,
  /// never fabricated by interpolation.
  final double? confidence;
  final String? className;

  /// True when both bracket frames contributed (position interpolated at the
  /// photo's content moment); false = taken verbatim from one frame.
  final bool interpolated;

  /// Signed deltas of the contributing frame(s) vs the content moment:
  /// before ≤ 0, after > 0; one is null for a single-side box.
  final int? beforeDeltaMs;
  final int? afterDeltaMs;

  /// True when a contributing raw entry carried `jpeg == photoFile` — the
  /// r111 cyan "triggered this shot" semantics.
  final bool triggered;

  const PhotoTrackBox({
    required this.trackId,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.confidence,
    required this.className,
    required this.interpolated,
    required this.beforeDeltaMs,
    required this.afterDeltaMs,
    required this.triggered,
  });
}

/// The box set + label metadata [buildPhotoBoxes] produced for one photo.
class PhotoBoxResult {
  final List<PhotoTrackBox> boxes;

  /// At least one / every box interpolated — drives the "estimated at this
  /// photo's moment" label wording.
  final bool anyInterpolated;
  final bool allInterpolated;

  /// The bracket's frame-level deltas (for the label); null on missing side.
  final int? beforeDeltaMs;
  final int? afterDeltaMs;

  /// min(|before|, after) over the sides present — compared to [toleranceMs]
  /// by the caller to pick the label TONE only, never to reject boxes
  /// (r114's rejection fell back to trigger boxes that were FARTHER away).
  final int nearestAbsDeltaMs;

  const PhotoBoxResult({
    required this.boxes,
    required this.anyInterpolated,
    required this.allInterpolated,
    required this.beforeDeltaMs,
    required this.afterDeltaMs,
    required this.nearestAbsDeltaMs,
  });
}

/// Builds a photo's box set from its frame bracket (round 115):
///
///  * a track present on BOTH sides → each box edge linearly interpolated at
///    the content moment (constant velocity — the same assumption the live
///    tracker makes between frames);
///  * a track on ONE side (arrived/left during the capture pause, or the
///    tracker re-assigned its id across it) → that frame's box verbatim;
///  * bracket span > [maxTotalGapMs] → the nearer frame alone;
///  * no frame at all → null (caller falls back to trigger boxes and says
///    the insect had likely left).
PhotoBoxResult? buildPhotoBoxes({
  required MatchedFrame? before,
  required MatchedFrame? after,
  required String photoFile,
  int maxTotalGapMs = kMaxBracketGapMs,
}) {
  if (before == null && after == null) return null;
  var b = before;
  var a = after;
  if (b != null && a != null && a.deltaMs - b.deltaMs > maxTotalGapMs) {
    // Interpolating across that much unobserved time is a guess: keep only
    // the nearer frame.
    if (b.deltaMs.abs() <= a.deltaMs) {
      a = null;
    } else {
      b = null;
    }
  }

  ({Map<String, dynamic>? entry, int deltaMs}) findIn(
    MatchedFrame? f,
    int? id,
  ) {
    if (f == null || id == null) return (entry: null, deltaMs: 0);
    for (final e in f.tracks) {
      if ((e['track_id'] as num?)?.toInt() == id && e['box_in_roi'] is Map) {
        return (entry: e, deltaMs: f.deltaMs);
      }
    }
    return (entry: null, deltaMs: 0);
  }

  double edge(Map<dynamic, dynamic> box, String key) =>
      (box[key] as num?)?.toDouble() ?? 0;

  final boxes = <PhotoTrackBox>[];
  final seenIds = <int>{};
  // Union of boxed entries across both frames, in frame order (before first).
  for (final (frame, other) in [(b, a), (a, b)]) {
    if (frame == null) continue;
    for (final e in frame.tracks) {
      if (e['box_in_roi'] is! Map) continue;
      final id = (e['track_id'] as num?)?.toInt();
      if (id != null && !seenIds.add(id)) continue; // already emitted
      final pair = findIn(other, id);
      final boxHere = e['box_in_roi'] as Map;
      if (pair.entry != null) {
        // Both sides: interpolate at the content moment (delta 0). The
        // before frame has delta ≤ 0, the after > 0, so the weight of the
        // after box is -beforeDelta / (afterDelta - beforeDelta).
        final beforeE = frame.deltaMs <= pair.deltaMs ? e : pair.entry!;
        final afterE = identical(beforeE, e) ? pair.entry! : e;
        final dB = frame.deltaMs <= pair.deltaMs ? frame.deltaMs : pair.deltaMs;
        final dA = frame.deltaMs <= pair.deltaMs ? pair.deltaMs : frame.deltaMs;
        final w = (dA - dB) == 0 ? 0.0 : -dB / (dA - dB);
        final bb = beforeE['box_in_roi'] as Map;
        final ab = afterE['box_in_roi'] as Map;
        double lerp(String k) => edge(bb, k) + w * (edge(ab, k) - edge(bb, k));
        final nearer = dB.abs() <= dA ? beforeE : afterE;
        boxes.add(
          PhotoTrackBox(
            trackId: id,
            left: lerp('left'),
            top: lerp('top'),
            right: lerp('right'),
            bottom: lerp('bottom'),
            confidence: (nearer['confidence'] as num?)?.toDouble(),
            className: nearer['class_name'] as String?,
            interpolated: true,
            beforeDeltaMs: dB,
            afterDeltaMs: dA,
            triggered:
                beforeE['jpeg'] == photoFile || afterE['jpeg'] == photoFile,
          ),
        );
      } else {
        boxes.add(
          PhotoTrackBox(
            trackId: id,
            left: edge(boxHere, 'left'),
            top: edge(boxHere, 'top'),
            right: edge(boxHere, 'right'),
            bottom: edge(boxHere, 'bottom'),
            confidence: (e['confidence'] as num?)?.toDouble(),
            className: e['class_name'] as String?,
            interpolated: false,
            beforeDeltaMs: frame.deltaMs <= 0 ? frame.deltaMs : null,
            afterDeltaMs: frame.deltaMs > 0 ? frame.deltaMs : null,
            triggered: e['jpeg'] == photoFile,
          ),
        );
      }
    }
  }
  if (boxes.isEmpty) return null;
  final nearest = [
    if (b != null) b.deltaMs.abs(),
    if (a != null) a.deltaMs,
  ].reduce((x, y) => x < y ? x : y);
  return PhotoBoxResult(
    boxes: boxes,
    anyInterpolated: boxes.any((x) => x.interpolated),
    allInterpolated: boxes.every((x) => x.interpolated),
    beforeDeltaMs: b?.deltaMs,
    afterDeltaMs: a?.deltaMs,
    nearestAbsDeltaMs: nearest,
  );
}
