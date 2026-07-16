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

/// The best (nearest-in-time) detections record found for one photo.
class MatchedFrame {
  /// Signed distance frame − content moment (ms): negative = the matched
  /// frame is OLDER than the photo's content.
  final int deltaMs;

  /// The record's raw `tracks` entries (maps with `track_id`, `box_in_roi`…).
  final List<Map<String, dynamic>> tracks;

  const MatchedFrame({required this.deltaMs, required this.tracks});
}

/// Streams detections records past a fixed set of photo content moments and
/// keeps, PER PHOTO, only the nearest frame seen so far — memory stays
/// O(photos), never O(frames), however long the session log is.
class NearestFrameAccumulator {
  /// Content moments sorted ascending, with the photo file names parallel.
  final List<int> _momentsMs;
  final List<String> _files;

  /// Best candidate so far per photo file.
  final Map<String, MatchedFrame> best = {};

  NearestFrameAccumulator(Map<String, int> contentMsByFile)
    : _files = contentMsByFile.keys.toList(),
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

  /// Offers one detections record. [tracks] is only materialized into the
  /// [best] map when this frame improves on a photo's current candidate.
  void feed(int frameTimeMs, List<Map<String, dynamic>> tracks) {
    if (_momentsMs.isEmpty || tracks.isEmpty) return;
    // Binary search: first moment >= frameTimeMs; that moment and the one
    // before it are the only candidates this frame can be nearest to.
    var lo = 0, hi = _momentsMs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_momentsMs[mid] < frameTimeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (final i in [lo - 1, lo]) {
      if (i < 0 || i >= _momentsMs.length) continue;
      final delta = frameTimeMs - _momentsMs[i];
      final cur = best[_files[i]];
      if (cur == null || delta.abs() < cur.deltaMs.abs()) {
        best[_files[i]] = MatchedFrame(deltaMs: delta, tracks: tracks);
      }
    }
  }
}
