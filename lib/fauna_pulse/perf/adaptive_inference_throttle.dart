// Pollinator Monitor — adaptive (thermal-aware) inference-rate throttle.
//
// Why this exists: the detector runs on the CPU here, and running it
// flat-out ("uncapped") keeps the processor ~100% busy. After ~1 minute the
// chip overheats and the OS quietly slows the CPU (thermal throttling) — the
// per-frame inference time balloons (e.g. 75 ms → 285 ms) and the frame rate
// collapses to ~3 fps and stays there. The phone's battery-temperature sensor
// does NOT see this in time, so we can't steer by temperature.
//
// What this does: it caps how often inference runs so the CPU keeps a cooling
// margin. It targets a "duty cycle" — the fraction of time the CPU spends doing
// inference. If a frame takes `infMs` and we run `fps` times per second, the
// busy fraction is `fps * infMs / 1000`. We pick the fps that hits a target
// duty (default 50%):
//
//   desiredFps = dutyTarget * 1000 / infMs
//
// This is self-correcting WITHOUT a thermometer: when the chip starts to warm,
// `infMs` rises, so `desiredFps` falls, which lightens the load and lets it
// cool; when it recovers, `infMs` drops and we slowly raise the rate again.
//
// The class is deliberately free of Flutter/platform dependencies so it can be
// unit-tested in isolation.

import 'dart:math' as math;

class AdaptiveInferenceThrottle {
  /// Never cap below this (a session below a few fps is not useful).
  final int minFps;

  /// Never run faster than this (the user's "max inference rate"; also keeps
  /// the cap sane when the model is very fast).
  final int ceilFps;

  /// Target CPU busy fraction for inference (0..1). Lower = cooler/steadier but
  /// fewer fps; higher = more fps but more heat.
  final double dutyTarget;

  /// Smoothing weight for the inference-time EMA (0..1). Higher = reacts faster
  /// to a rising `infMs` (heat) but is noisier.
  final double smoothing;

  double _infMsEma = 0;
  int? _applied;

  AdaptiveInferenceThrottle({
    required this.minFps,
    required this.ceilFps,
    this.dutyTarget = 0.5,
    this.smoothing = 0.3,
  });

  /// The cap most recently returned by [update] (null before the first call).
  int? get applied => _applied;

  /// Smoothed per-frame inference time (ms) the controller is acting on.
  double get infMsEma => _infMsEma;

  /// Feed the latest per-frame inference time (ms); returns the inference-rate
  /// cap (fps) to apply now. Drops immediately when the chip warms (responsive)
  /// but rises at most +1 fps per call (slow, to avoid bouncing straight back
  /// into the overheat that caused the drop).
  int update(double infMs) {
    if (infMs > 0) {
      _infMsEma = _infMsEma == 0
          ? infMs
          : smoothing * infMs + (1 - smoothing) * _infMsEma;
    }
    final base = _infMsEma > 0 ? _infMsEma : 75.0; // sane guess pre-measurement
    final desired = (dutyTarget * 1000.0 / base).floor().clamp(minFps, ceilFps);

    final current = _applied ?? ceilFps;
    final next = desired < current
        ? desired // warming: cut now
        : math.min(desired, current + 1); // cooling: ramp up gently
    _applied = next.clamp(minFps, ceilFps);
    return _applied!;
  }
}
