// FaunaPulse (round 293): when a recording lets the screen go dark.
//
// Idea from FaunaLapse (its screen goes off by itself a few minutes after the last
// touch): during a recording the app holds the screen on only until [ScreenIdle.afterMs]
// after the last touch. Then it lets go, so the phone's own screen timeout (or the power
// button) switches the screen off, while the camera keeps recording (round 292). A touch
// brings the hold back and restarts the count. Pure and clock-injected, so it is unit
// tested; the camera screen owns the timer, the touch listener and the wakelock.

class ScreenIdle {
  ScreenIdle({required this.afterMs, required int nowMs}) : _lastTouchMs = nowMs;

  /// How long after the last touch the screen is let go; 0 or less = never.
  final int afterMs;
  int _lastTouchMs;
  bool _released = false;

  /// Whether the app has let the screen go (it no longer holds it on).
  bool get released => _released;

  /// A touch, or the app coming back on screen. Returns true when the screen
  /// must be held on again (it had been let go).
  bool touch(int nowMs) {
    _lastTouchMs = nowMs;
    if (!_released) return false;
    _released = false;
    return true;
  }

  /// Called regularly (about once a second). Returns true exactly once, at the
  /// moment the screen should be let go.
  bool tick(int nowMs) {
    if (_released || afterMs <= 0) return false;
    if (nowMs - _lastTouchMs < afterMs) return false;
    _released = true;
    return true;
  }
}
