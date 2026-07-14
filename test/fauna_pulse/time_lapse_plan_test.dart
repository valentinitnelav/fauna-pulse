// Tests for TimeLapsePlan — the pure burst-schedule math behind time-lapse
// capture mode (round 97). Same clock-injection test style as
// schedule_plan_test.dart: walk "ms since recording start" through the phases
// and assert what the plan reports; no timers, no mocks.

import 'package:flutter_test/flutter_test.dart';
import 'package:pollinator_monitor/pollinator/capture/time_lapse_plan.dart';

void main() {
  // A burst of 3 s (photos at 0/1/2/3 s), repeated every 10 s start-to-start.
  const plan = TimeLapsePlan(stepMs: 1000, burstMs: 3000, intervalMs: 10000);

  group('TimeLapsePlan burst phases', () {
    test('the first burst starts with the recording', () {
      expect(plan.inBurstAt(0), isTrue);
      expect(plan.cycleIndexAt(0), 0);
    });

    test('a burst lasts exactly the photo duration (inclusive edge, matching '
        'the scheduler window\'s exclusive > durationMs cutoff)', () {
      expect(plan.inBurstAt(3000), isTrue);
      expect(plan.inBurstAt(3001), isFalse);
      expect(plan.inBurstAt(9999), isFalse);
    });

    test('the next burst starts exactly one interval after the previous '
        'START (start-to-start, independent of burst length)', () {
      expect(plan.inBurstAt(10000), isTrue);
      expect(plan.cycleIndexAt(10000), 1);
      expect(plan.nextBurstStartAt(0), 10000);
      expect(plan.nextBurstStartAt(9999), 10000);
      expect(plan.nextBurstStartAt(10000), 20000);
    });

    test('negative time (clock skew) is treated as the recording start', () {
      expect(plan.inBurstAt(-500), isTrue);
      expect(plan.cycleIndexAt(-500), 0);
    });
  });

  group('TimeLapsePlan tick delays', () {
    test('inside a burst the timer sleeps one step', () {
      expect(plan.nextTickDelayMs(0), 1000);
      expect(plan.nextTickDelayMs(2000), 1000);
    });

    test('between bursts the timer sleeps until the next burst', () {
      expect(plan.nextTickDelayMs(3500), 6500);
      expect(plan.nextTickDelayMs(9000), 1000);
    });

    test('never returns a non-positive delay (edge tick cannot spin)', () {
      // t = 10000 is a burst start: inBurst, so one step.
      expect(plan.nextTickDelayMs(10000), 1000);
    });
  });

  group('continuous mode (interval ≤ duration → photos never stop)', () {
    const cont = TimeLapsePlan(stepMs: 500, burstMs: 5000, intervalMs: 5000);

    test('is detected and always in burst, always cycle 0', () {
      expect(cont.continuous, isTrue);
      expect(cont.inBurstAt(0), isTrue);
      expect(cont.inBurstAt(123456789), isTrue);
      expect(cont.cycleIndexAt(123456789), 0);
      expect(cont.nextTickDelayMs(99999), 500);
    });

    test('a normal plan is not continuous', () {
      expect(plan.continuous, isFalse);
    });
  });
}
