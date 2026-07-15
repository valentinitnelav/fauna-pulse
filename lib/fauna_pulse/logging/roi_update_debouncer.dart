// FaunaPulse — settles ROI drags into ONE roi_update log record (round 109).
//
// The ROI overlay fires its change callback continuously while the user drags
// or resizes, and until this round every tick wrote its own `roi_update` line
// while recording — dozens of records for one adjustment, none of them the
// value the user actually settled on. This helper waits until the ROI has
// been STABLE for [delay] (default 2 s) and then writes a single record, so
// the log (and the summary's ROI-history list built from it) reads as "the
// ROI was changed to X at time T". Adjusting the ROI mid-recording is
// discouraged anyway, so the list stays short.
//
// Only the LOGGING is debounced: the on-screen box and the inference ROI must
// keep following the finger immediately (the caller keeps those outside this
// class). The write callback is invoked at settle time so the payload it
// builds (saves_px, roi_source, roi_side_stream_px) reflects the settled
// state, not a mid-drag one.

import 'dart:async';

import '../models/roi.dart';

class RoiUpdateDebouncer {
  RoiUpdateDebouncer({this.delay = const Duration(seconds: 2)});

  /// How long the ROI must sit unchanged before the pending value is logged.
  final Duration delay;

  Roi? _lastLogged;
  Roi? _pending;
  Timer? _timer;

  static bool _same(Roi? a, Roi? b) =>
      a != null &&
      b != null &&
      a.centerX == b.centerX &&
      a.centerY == b.centerY &&
      a.sideFraction == b.sideFraction;

  /// Call at recording start with the ROI already written into the start
  /// record, so a drag that ends back on the initial geometry logs nothing.
  void seed(Roi initial) {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _lastLogged = initial;
  }

  /// Report the ROI's current geometry (call on every change tick). Restarts
  /// the stability timer; when it fires, [write] runs with the settled ROI —
  /// unless it equals the last value logged (drag ended where it started).
  void notify(Roi roi, void Function(Roi settled) write) {
    _pending = roi;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      _flushPending(write);
    });
  }

  /// Write any still-pending value NOW (recording is stopping and the logger
  /// is about to close — the final ROI must not be lost to the timer).
  void flush(void Function(Roi settled) write) {
    _timer?.cancel();
    _timer = null;
    _flushPending(write);
  }

  /// Drop any pending value without writing (dispose path).
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  void _flushPending(void Function(Roi settled) write) {
    final roi = _pending;
    _pending = null;
    if (roi == null || _same(roi, _lastLogged)) return;
    _lastLogged = roi;
    write(roi);
  }
}
