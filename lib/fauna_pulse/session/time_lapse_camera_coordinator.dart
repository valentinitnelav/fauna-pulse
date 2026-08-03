// FaunaPulse — camera parking between time-lapse bursts (round 163,
// perf review E3).
//
// In time-lapse mode the camera hardware runs 100% of the time even though
// photos may flow for only seconds per half hour — the sensor/ISP standing
// load is the dominant heat/power cost of an otherwise idle session (the r82
// measurements). When the user opts in (SessionConfig.timeLapseCameraSleep),
// the camera screen fully unbinds the camera ("parks" it, the same
// `pause()` the r94 scheduled sleep uses) between bursts and rebinds it
// shortly before the next one.
//
// This class is the DECISION logic only: pure, clock-injected ("ms since the
// recording started", like TimeLapsePlan/SchedulePlan) and unit-testable.
// The camera screen owns the async platform calls and reports their outcomes
// back via the transition methods, so a missed timer tick or a failed wake
// can never wedge the state machine — every query re-derives from the plan
// and the wall clock.

import '../capture/time_lapse_plan.dart';

/// Where the camera stands in the park/wake cycle.
enum TimeLapseCameraState {
  /// Camera bound, frames flowing — the normal state (also the state during
  /// every burst).
  running,

  /// Camera fully unbound between bursts. The preview is frozen and NO
  /// frames arrive — the camera-delivery watchdog must be suppressed.
  parked,

  /// A wake (rebind) has been issued; waiting for the first fresh frame.
  /// Photos must NOT be captured yet: the native frame cache still holds the
  /// pre-park frame, which could be many minutes stale.
  warming,

  /// A wake failed (no frame within the allowance): parking is disabled for
  /// the rest of the session and the camera is left bound — scientific
  /// reliability over power saving.
  fallbackBound,
}

/// What the camera screen should do right now — the answer to [
/// TimeLapseCameraCoordinator.actionAt].
enum TimeLapseCameraAction { none, park, wake }

class TimeLapseCameraCoordinator {
  /// The session's burst schedule (anchored at recording start, like the
  /// screen's own copy).
  final TimeLapsePlan plan;

  /// Plan-level gate: parking is only worth the rebind cost/risk when the
  /// bursts leave at least this much idle time between them.
  final int minIdleGapMs;

  /// How long before the next scheduled burst the wake is issued, so the
  /// camera is warm (auto-exposure/focus settled, fresh frames cached) when
  /// the first photo is due.
  final int prewakeLeadMs;

  /// How long the screen waits for a fresh frame after a wake before
  /// declaring the wake failed (mirrors the r94 scheduled-wake deadline).
  final int wakeAllowanceMs;

  /// A late tick can land close to the prewake moment; parking for less than
  /// this is churn (unbind + immediate rebind), so stay bound instead.
  final int minParkMs;

  TimeLapseCameraCoordinator({
    required this.plan,
    this.minIdleGapMs = 30000,
    this.prewakeLeadMs = 10000,
    this.wakeAllowanceMs = 20000,
    this.minParkMs = 10000,
  });

  TimeLapseCameraState _state = TimeLapseCameraState.running;
  TimeLapseCameraState get state => _state;

  /// Whether this plan can ever park: bursts must really end (non-continuous)
  /// and the start-to-start interval must leave ≥ [minIdleGapMs] of idle
  /// time between a burst's end and the next burst's start.
  bool get parkingPossible =>
      !plan.continuous && plan.intervalMs - plan.burstMs >= minIdleGapMs;

  /// True while the absence of frames is intentional — the camera-delivery
  /// watchdog (which reads 10 s of silence as a camera failure) must skip
  /// these states. In [TimeLapseCameraState.fallbackBound] after a FAILED
  /// wake the watchdog deliberately fires: at that point silence really is a
  /// camera problem the user should see.
  bool get cameraIntentionallyDown =>
      _state == TimeLapseCameraState.parked ||
      _state == TimeLapseCameraState.warming;

  /// True when captured frames are trustworthy (bound camera, fresh frames).
  /// While parked or warming the native frame cache holds the pre-park frame
  /// — a "photo" taken then could show the scene from half an hour ago.
  bool get framesUsable =>
      _state == TimeLapseCameraState.running ||
      _state == TimeLapseCameraState.fallbackBound;

  /// The moment (ms since recording start) the wake for the burst after
  /// [sinceStartMs] should be issued.
  int prewakeAt(int sinceStartMs) =>
      plan.nextBurstStartAt(sinceStartMs) - prewakeLeadMs;

  /// What the screen should do at [sinceStartMs]. Pure — repeated calls give
  /// the same answer until a transition method is invoked, so a busy screen
  /// can safely skip a tick and ask again later.
  TimeLapseCameraAction actionAt(int sinceStartMs) {
    switch (_state) {
      case TimeLapseCameraState.fallbackBound:
      case TimeLapseCameraState.warming:
        return TimeLapseCameraAction.none;
      case TimeLapseCameraState.parked:
        // Wake at the prewake moment — or immediately when a late tick (OS
        // doze) already landed inside the burst. The plan math preserves the
        // original wall-clock grid either way: a late wake starts the burst's
        // photos late but never shifts the schedule.
        if (plan.inBurstAt(sinceStartMs) ||
            sinceStartMs >= prewakeAt(sinceStartMs)) {
          return TimeLapseCameraAction.wake;
        }
        return TimeLapseCameraAction.none;
      case TimeLapseCameraState.running:
        if (!parkingPossible || plan.inBurstAt(sinceStartMs)) {
          return TimeLapseCameraAction.none;
        }
        // Between bursts with enough idle left to be worth the unbind.
        if (prewakeAt(sinceStartMs) - sinceStartMs >= minParkMs) {
          return TimeLapseCameraAction.park;
        }
        return TimeLapseCameraAction.none;
    }
  }

  /// Extra timer deadline the coordinator needs beyond the plan's own photo
  /// cadence: while parked, a tick must land at the prewake moment (the
  /// plan's next-burst delay alone would wake 10 s too late). Null when the
  /// plan's cadence suffices. The caller caps the delay (≤ 60 s) as usual.
  int? nextEventDelayMs(int sinceStartMs) {
    if (_state != TimeLapseCameraState.parked) return null;
    final wait = prewakeAt(sinceStartMs) - sinceStartMs;
    return wait > 0 ? wait : 1;
  }

  // --- Transitions, reported by the screen after each async platform call.

  /// The camera was successfully unbound.
  void parked() => _state = TimeLapseCameraState.parked;

  /// The rebind was issued; frames are not fresh yet.
  void wakeStarted() => _state = TimeLapseCameraState.warming;

  /// A fresh frame arrived after the wake — photos may flow again.
  void wakeSucceeded() => _state = TimeLapseCameraState.running;

  /// No fresh frame within [wakeAllowanceMs] (or the park/rebind call itself
  /// failed): leave the camera bound and never park again this session.
  void disableParking() => _state = TimeLapseCameraState.fallbackBound;
}
