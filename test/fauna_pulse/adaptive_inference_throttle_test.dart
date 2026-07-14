// Tests for the auto thermal-aware inference throttle: it should cut the rate
// fast when inference time rises (heat), ramp back up slowly when it recovers,
// and always stay within [minFps, ceilFps].

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/perf/adaptive_inference_throttle.dart';

void main() {
  AdaptiveInferenceThrottle make() => AdaptiveInferenceThrottle(
    minFps: 3,
    ceilFps: 15,
    dutyTarget: 0.5,
    // No smoothing lag, so a single update reflects the latest inf time and the
    // assertions are exact.
    smoothing: 1.0,
  );

  test('cool inference settles at the duty-implied rate', () {
    final t = make();
    // 0.5 * 1000 / 75 = 6.67 -> floor 6.
    expect(t.update(75), 6);
  });

  test('a heat spike drops the rate immediately (to the floor if needed)', () {
    final t = make();
    t.update(75); // settle at 6
    // 0.5 * 1000 / 285 = 1.75 -> floor 1 -> clamped to minFps 3.
    expect(t.update(285), 3);
  });

  test('recovery ramps up at most +1 fps per update', () {
    final t = make();
    t.update(75); // 6
    t.update(285); // dropped to 3 (floor)
    // inf recovers to 75 (desired 6), but rise is capped at +1 per call.
    expect(t.update(75), 4);
    expect(t.update(75), 5);
    expect(t.update(75), 6);
    expect(t.update(75), 6); // holds at the duty target
  });

  test('clamps to the ceiling when the model is very fast', () {
    final t = make();
    // 0.5 * 1000 / 10 = 50 -> clamped to ceilFps 15. Starts at ceil, so stays.
    expect(t.update(10), 15);
  });

  test('a lower duty target yields a lower steady rate', () {
    final t = AdaptiveInferenceThrottle(
      minFps: 1,
      ceilFps: 15,
      dutyTarget: 0.3,
      smoothing: 1.0,
    );
    // 0.3 * 1000 / 75 = 4.0 -> 4.
    expect(t.update(75), 4);
  });
}
