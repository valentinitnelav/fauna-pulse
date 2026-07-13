/// Pure burst-schedule math for time-lapse capture mode (round 97).
///
/// No timers, no IO, no stored clock — every query takes "ms since the
/// recording started" (the same clock-injection style as `SchedulePlan`), so
/// the camera screen's timer can be dumb and self-healing: on every tick it
/// just asks this class what phase it is in and when to wake next.
///
/// A *burst* reuses the shared capture window the scheduler already
/// implements for motion events (first photo at the burst start, then one per
/// step, stopping after the photo duration); this class only decides WHEN
/// bursts happen: one starts every [intervalMs], counted START-TO-START (so
/// "every 30 minutes" stays every 30 minutes regardless of burst length). An
/// interval ≤ the burst duration means the bursts touch or overlap —
/// [continuous] time-lapse, photos flowing every step for the whole session.
class TimeLapsePlan {
  /// Milliseconds between photos inside a burst (the "Photo step" setting).
  final int stepMs;

  /// Burst length in milliseconds (the "Photo duration" setting) — photos are
  /// taken while the time into the burst is ≤ this (matching the scheduler
  /// window's exclusive `> durationMs` cutoff).
  final int burstMs;

  /// Milliseconds from the start of one burst to the start of the next.
  final int intervalMs;

  const TimeLapsePlan({
    required this.stepMs,
    required this.burstMs,
    required this.intervalMs,
  }) : assert(stepMs > 0),
       assert(burstMs > 0),
       assert(intervalMs > 0);

  /// Bursts touch or overlap: photos never stop, and there is only one
  /// endless "cycle".
  bool get continuous => intervalMs <= burstMs;

  /// Which burst cycle [sinceStartMs] falls in (0-based). Each cycle spans
  /// [intervalMs]; in [continuous] mode everything is cycle 0.
  int cycleIndexAt(int sinceStartMs) {
    final t = sinceStartMs < 0 ? 0 : sinceStartMs;
    return continuous ? 0 : t ~/ intervalMs;
  }

  /// Whether photos should be flowing at [sinceStartMs].
  bool inBurstAt(int sinceStartMs) {
    if (continuous) return true;
    final t = sinceStartMs < 0 ? 0 : sinceStartMs;
    return t % intervalMs <= burstMs;
  }

  /// Start (ms since recording start) of the next burst strictly after
  /// [sinceStartMs]'s cycle. Meaningless in [continuous] mode (never waits).
  int nextBurstStartAt(int sinceStartMs) =>
      (cycleIndexAt(sinceStartMs) + 1) * intervalMs;

  /// How long the driving timer should sleep from [sinceStartMs]: one step
  /// while photos are flowing, otherwise until the next burst begins. The
  /// caller is expected to cap this (e.g. at 60 s) so clock jumps and doze
  /// self-heal, and to floor it so a tick landing exactly on a burst edge
  /// can't spin.
  int nextTickDelayMs(int sinceStartMs) {
    if (inBurstAt(sinceStartMs)) return stepMs;
    final wait = nextBurstStartAt(sinceStartMs) - sinceStartMs;
    return wait > 0 ? wait : stepMs;
  }
}
