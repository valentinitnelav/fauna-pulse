// Tests for TimeLapseCameraCoordinator (round 163, perf review E3): the pure
// park/wake decision logic for turning the camera off between time-lapse
// bursts. All times are "ms since recording start", like TimeLapsePlan's own
// tests; the async platform outcomes are reported via the transition methods.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/capture/time_lapse_plan.dart';
import 'package:fauna_pulse/fauna_pulse/session/time_lapse_camera_coordinator.dart';

void main() {
  // The default field setup: 10 s bursts every 30 min — the sparse time-lapse
  // parking is for. Idle gap 1790 s >> the 30 s minimum.
  TimeLapseCameraCoordinator sparse() => TimeLapseCameraCoordinator(
    plan: const TimeLapsePlan(
      stepMs: 1000,
      burstMs: 10000,
      intervalMs: 1800000,
    ),
  );

  group('parkingPossible', () {
    test('true for sparse plans (10 s burst / 30 min interval)', () {
      expect(sparse().parkingPossible, true);
    });

    test('false for continuous time-lapse (interval ≤ burst)', () {
      final c = TimeLapseCameraCoordinator(
        plan: const TimeLapsePlan(
          stepMs: 1000,
          burstMs: 60000,
          intervalMs: 60000,
        ),
      );
      expect(c.parkingPossible, false);
      // And it never asks to park.
      expect(c.actionAt(120000), TimeLapseCameraAction.none);
    });

    test('false when the idle gap is under 30 s', () {
      // 40 s burst every 60 s: 20 s gaps — parking would be churn.
      final c = TimeLapseCameraCoordinator(
        plan: const TimeLapsePlan(
          stepMs: 1000,
          burstMs: 40000,
          intervalMs: 60000,
        ),
      );
      expect(c.parkingPossible, false);
      expect(c.actionAt(45000), TimeLapseCameraAction.none);
    });

    test('exactly 30 s of idle qualifies', () {
      final c = TimeLapseCameraCoordinator(
        plan: const TimeLapsePlan(
          stepMs: 1000,
          burstMs: 30000,
          intervalMs: 60000,
        ),
      );
      expect(c.parkingPossible, true);
    });
  });

  group('running → park', () {
    test('no park during a burst', () {
      expect(sparse().actionAt(5000), TimeLapseCameraAction.none);
    });

    test('parks right after the burst ends', () {
      expect(sparse().actionAt(11000), TimeLapseCameraAction.park);
    });

    test('parks in a later cycle too', () {
      // 1800–1810 s is cycle 1's burst; 1815 s is just past it.
      expect(sparse().actionAt(1815000), TimeLapseCameraAction.park);
    });

    test('no park when a late tick lands within minParkMs of the prewake', () {
      final c = sparse();
      // Prewake for the next burst (t=1800 s) is at 1790 s. At 1785 s only
      // 5 s of parking remain (< minParkMs 10 s) — unbind/rebind churn.
      expect(c.actionAt(1785000), TimeLapseCameraAction.none);
      // At 1779 s exactly 11 s remain — still worth it.
      expect(c.actionAt(1779000), TimeLapseCameraAction.park);
    });
  });

  group('parked → wake', () {
    TimeLapseCameraCoordinator parked() {
      final c = sparse();
      expect(c.actionAt(11000), TimeLapseCameraAction.park);
      c.parked();
      return c;
    }

    test('stays parked until the prewake moment', () {
      final c = parked();
      expect(c.state, TimeLapseCameraState.parked);
      expect(c.actionAt(1000000), TimeLapseCameraAction.none);
      // Prewake for the t=1800 s burst is at 1790 s.
      expect(c.actionAt(1789999), TimeLapseCameraAction.none);
      expect(c.actionAt(1790000), TimeLapseCameraAction.wake);
    });

    test('a doze-late tick inside the burst wakes immediately', () {
      final c = parked();
      // Tick lands at 1803 s — already 3 s into the burst.
      expect(c.actionAt(1803000), TimeLapseCameraAction.wake);
    });

    test('while parked the coordinator supplies the prewake deadline', () {
      final c = parked();
      // At t=100 s the prewake (1790 s) is 1690 s away.
      expect(c.nextEventDelayMs(100000), 1690000);
      // Running/others: the plan's own cadence suffices.
      expect(sparse().nextEventDelayMs(100000), null);
    });

    test('watchdog suppression covers parked and warming only', () {
      final c = parked();
      expect(c.cameraIntentionallyDown, true);
      expect(c.framesUsable, false);
      c.wakeStarted();
      expect(c.cameraIntentionallyDown, true);
      expect(c.framesUsable, false);
      c.wakeSucceeded();
      expect(c.cameraIntentionallyDown, false);
      expect(c.framesUsable, true);
    });
  });

  group('warming and outcomes', () {
    test('no decisions while a wake is mid-flight', () {
      final c = sparse();
      c.parked();
      c.wakeStarted();
      expect(c.actionAt(1790000), TimeLapseCameraAction.none);
      expect(c.actionAt(1803000), TimeLapseCameraAction.none);
    });

    test('a successful wake returns to running and can park again', () {
      final c = sparse();
      c.parked();
      c.wakeStarted();
      c.wakeSucceeded();
      expect(c.state, TimeLapseCameraState.running);
      // After cycle 1's burst (1800–1810 s) it parks again.
      expect(c.actionAt(1815000), TimeLapseCameraAction.park);
    });

    test('a failed wake disables parking for the rest of the session', () {
      final c = sparse();
      c.parked();
      c.wakeStarted();
      c.disableParking();
      expect(c.state, TimeLapseCameraState.fallbackBound);
      // Camera left bound: frames usable, watchdog active again.
      expect(c.framesUsable, true);
      expect(c.cameraIntentionallyDown, false);
      // And it never parks again, however inviting the gap.
      expect(c.actionAt(1815000), TimeLapseCameraAction.none);
      expect(c.actionAt(3620000), TimeLapseCameraAction.none);
    });
  });
}
