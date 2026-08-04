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
/// bursts happen. Round 174 (owner decision): the spacing is a BREAK between
/// bursts ([gapMs], one burst's end to the next one's start — the "Time
/// between bursts" setting, and exactly the window in which the round-163
/// camera parking may power the camera off). Before round 174 the setting was
/// START-TO-START spacing, which silently meant "continuous" whenever it was
/// ≤ the photo duration — the owner's session_2 surprise (10 s bursts
/// "every 10 s" never paused).
class TimeLapsePlan {
  /// Milliseconds between photos inside a burst (the "Photo step" setting).
  final int stepMs;

  /// Burst length in milliseconds (the "Photo duration" setting) — photos are
  /// taken while the time into the burst is ≤ this (matching the scheduler
  /// window's exclusive `> durationMs` cutoff).
  final int burstMs;

  /// Break between bursts in milliseconds (the "Time between bursts"
  /// setting): from one burst's END to the next burst's START. 0 = no break,
  /// photos flow continuously every step.
  final int gapMs;

  const TimeLapsePlan({
    required this.stepMs,
    required this.burstMs,
    required this.gapMs,
  }) : assert(stepMs > 0),
       assert(burstMs > 0),
       assert(gapMs >= 0);

  /// No break configured: photos never stop.
  bool get continuous => gapMs == 0;

  /// One full cycle: a burst plus its break. With no break this is just
  /// [burstMs] — cycles must keep advancing even then, because the shared
  /// capture window hard-stops [burstMs] after its start and the caller
  /// re-arms it only on a cycle CHANGE (round 173: a "cycle 0 forever"
  /// definition starved the window after the first photo duration).
  int get cycleMs => burstMs + gapMs;

  /// Which cycle [sinceStartMs] falls in (0-based). Every advance re-arms the
  /// capture window: at a burst start after a break, or seamlessly at the
  /// window seam when [continuous] (one photo per step across it — no
  /// duplicate, no gap).
  int cycleIndexAt(int sinceStartMs) {
    final t = sinceStartMs < 0 ? 0 : sinceStartMs;
    return t ~/ cycleMs;
  }

  /// Whether photos should be flowing at [sinceStartMs].
  bool inBurstAt(int sinceStartMs) {
    if (continuous) return true;
    final t = sinceStartMs < 0 ? 0 : sinceStartMs;
    return t % cycleMs <= burstMs;
  }

  /// Start (ms since recording start) of the next cycle strictly after
  /// [sinceStartMs]'s. In [continuous] mode that is the next window re-anchor
  /// (photos never pause around it).
  int nextBurstStartAt(int sinceStartMs) =>
      (cycleIndexAt(sinceStartMs) + 1) * cycleMs;

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

/// Pure torch schedule for nocturnal time-lapse (round 180): the LED torch
/// should be ON from [leadMs] before each burst (so the camera's auto-exposure
/// settles under the final lighting before the first photo) through the
/// burst's end, and OFF in the break. Same clock-injection style as
/// [TimeLapsePlan]; the camera screen owns the actual platform calls and
/// re-issues them whenever the commanded state drifts from this schedule
/// (e.g. the camera-parking unbind physically kills the torch).
class TimeLapseTorchPlan {
  /// The session's burst schedule (the same instance the screen drives).
  final TimeLapsePlan plan;

  /// How long before each burst start the torch comes on.
  final int leadMs;

  const TimeLapseTorchPlan({required this.plan, required this.leadMs})
    : assert(leadMs >= 0);

  /// With no break (continuous photos) or a lead that covers the whole break,
  /// the torch simply never turns off.
  bool get alwaysOn => plan.continuous || leadMs >= plan.gapMs;

  /// Whether the torch should be lit at [sinceStartMs]. The first burst
  /// starts at 0, so it structurally gets no lead — the recording begins
  /// in-burst with the torch due immediately.
  bool shouldBeOnAt(int sinceStartMs) {
    if (alwaysOn || plan.inBurstAt(sinceStartMs)) return true;
    return plan.nextBurstStartAt(sinceStartMs) - sinceStartMs <= leadMs;
  }

  /// Extra timer deadline beyond the plan's own cadence, so a tick lands at
  /// each torch flip: the OFF edge just after a burst's inclusive end (the
  /// plan's in-burst delay is one step, which for long steps would leave the
  /// torch burning up to a whole step into the break), and the torch-on
  /// moment [leadMs] before the next burst (the plan's between-burst delay
  /// alone would arrive a whole lead too late). Null when no flip needs an
  /// extra tick: [alwaysOn], or inside the lead window where the plan's own
  /// delay (next burst start) is the next flip-relevant tick anyway. The
  /// caller caps and floors the delay like every other tick source.
  int? nextEventDelayMs(int sinceStartMs) {
    if (alwaysOn) return null;
    final t = sinceStartMs < 0 ? 0 : sinceStartMs;
    final inCycle = t % plan.cycleMs;
    if (inCycle <= plan.burstMs) {
      // In burst: the OFF edge is one ms past the inclusive burst end.
      final wait = plan.burstMs + 1 - inCycle;
      return wait > 0 ? wait : 1;
    }
    final torchOnAt = plan.nextBurstStartAt(t) - leadMs;
    if (t < torchOnAt) return torchOnAt - t;
    return null;
  }
}
