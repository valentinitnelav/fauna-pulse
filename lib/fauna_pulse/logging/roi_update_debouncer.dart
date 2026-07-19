// FaunaPulse — settles a continuously-changing value into ONE log record.
//
// Round 109 introduced this for ROI drags: the ROI overlay fires its change
// callback continuously while the user drags or resizes, and until then every
// tick wrote its own `roi_update` line while recording — dozens of records
// for one adjustment, none of them the value the user actually settled on.
// This helper waits until the value has been STABLE for [delay] (default 2 s)
// and then writes a single record, so the log reads as "X was changed to Y at
// time T". Round 132 generalized the same logic for mid-session focus changes
// ([SettledUpdateDebouncer]); [RoiUpdateDebouncer] keeps its name and ROI
// equality.
//
// Only the LOGGING is debounced: the on-screen state (ROI box, camera focus)
// must keep following the finger immediately — the caller keeps that outside
// this class. The write callback is invoked at settle time so the payload it
// builds reflects the settled state, not a mid-drag one.

import 'dart:async';

import '../models/roi.dart';

/// Debounces a stream of value changes into one settled write per adjustment.
/// Equality defaults to `==` (works out of the box for Dart record types);
/// pass [equals] for types without value equality.
class SettledUpdateDebouncer<T> {
  SettledUpdateDebouncer({
    this.delay = const Duration(seconds: 2),
    bool Function(T a, T b)? equals,
  }) : _equals = equals ?? ((a, b) => a == b);

  /// How long the value must sit unchanged before the pending value is logged.
  final Duration delay;

  final bool Function(T a, T b) _equals;

  T? _lastLogged;
  T? _pending;
  Timer? _timer;

  bool _same(T? a, T? b) => a != null && b != null && _equals(a, b);

  /// Call at recording start with the value already written into the start
  /// record, so an adjustment that ends back on the initial value logs
  /// nothing.
  void seed(T initial) {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _lastLogged = initial;
  }

  /// Report the current value (call on every change tick). Restarts the
  /// stability timer; when it fires, [write] runs with the settled value —
  /// unless it equals the last value logged (adjustment ended where it
  /// started).
  void notify(T value, void Function(T settled) write) {
    _pending = value;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      _flushPending(write);
    });
  }

  /// Write any still-pending value NOW (recording is stopping and the logger
  /// is about to close — the final value must not be lost to the timer).
  void flush(void Function(T settled) write) {
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

  void _flushPending(void Function(T settled) write) {
    final value = _pending;
    _pending = null;
    if (value == null || _same(value, _lastLogged)) return;
    _lastLogged = value;
    write(value);
  }
}

/// Settles ROI drags into ONE `roi_update` record per adjustment (round 109).
/// Adjusting the ROI mid-recording is discouraged anyway, so the summary's
/// ROI-history list stays short.
class RoiUpdateDebouncer extends SettledUpdateDebouncer<Roi> {
  RoiUpdateDebouncer({super.delay}) : super(equals: _sameRoi);

  static bool _sameRoi(Roi a, Roi b) =>
      a.centerX == b.centerX &&
      a.centerY == b.centerY &&
      a.sideFraction == b.sideFraction;
}
