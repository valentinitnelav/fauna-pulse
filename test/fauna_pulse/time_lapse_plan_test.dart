// Tests for TimeLapsePlan — the pure burst-schedule math behind time-lapse
// capture mode (round 97). Same clock-injection test style as
// schedule_plan_test.dart: walk "ms since recording start" through the phases
// and assert what the plan reports; no timers, no mocks.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart';
import 'package:fauna_pulse/fauna_pulse/capture/time_lapse_plan.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';

void main() {
  // A burst of 3 s (photos at 0/1/2/3 s), then a 7 s break: bursts start
  // every 10 s (r174: the configured number is the BREAK, not start-to-start).
  const plan = TimeLapsePlan(stepMs: 1000, burstMs: 3000, gapMs: 7000);

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

    test('the next burst starts one break AFTER the previous burst ends '
        '(r174 gap semantics: burst 3 s + break 7 s → starts every 10 s)', () {
      expect(plan.inBurstAt(10000), isTrue);
      expect(plan.cycleIndexAt(10000), 1);
      expect(plan.nextBurstStartAt(0), 10000);
      expect(plan.nextBurstStartAt(9999), 10000);
      expect(plan.nextBurstStartAt(10000), 20000);
    });

    // The owner's round-174 session_2 expectation: 10 s bursts with a REAL
    // 10 s break between them (under the old start-to-start semantics this
    // exact configuration silently meant "continuous" — the reported bug).
    test('equal burst and break really pause: 10 s on, 10 s off, repeat', () {
      const owner = TimeLapsePlan(stepMs: 1000, burstMs: 10000, gapMs: 10000);
      expect(owner.continuous, isFalse);
      expect(owner.inBurstAt(10000), isTrue); // burst end (inclusive)
      expect(owner.inBurstAt(10001), isFalse); // the break
      expect(owner.inBurstAt(19999), isFalse);
      expect(owner.inBurstAt(20000), isTrue); // next burst starts
      expect(owner.cycleIndexAt(20000), 1);
      expect(owner.nextTickDelayMs(11000), 9000); // sleep out the break
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

  group('continuous mode (no break → photos never stop)', () {
    const cont = TimeLapsePlan(stepMs: 500, burstMs: 5000, gapMs: 0);

    test('is detected and always in burst', () {
      expect(cont.continuous, isTrue);
      expect(cont.inBurstAt(0), isTrue);
      expect(cont.inBurstAt(123456789), isTrue);
      expect(cont.nextTickDelayMs(99999), 500);
    });

    // Round 173 regression: cycles must ADVANCE every burst duration. The
    // r97 "everything is cycle 0" definition meant the tick never re-armed
    // the capture window (it re-arms on cycle CHANGE), and the window
    // hard-stops after the photo duration — the owner's continuous session
    // took the first window's photos and then nothing.
    test('cycles advance every photo duration so the window is re-armed', () {
      expect(cont.cycleIndexAt(0), 0);
      expect(cont.cycleIndexAt(4999), 0);
      expect(cont.cycleIndexAt(5000), 1);
      expect(cont.cycleIndexAt(123456789), 123456789 ~/ 5000);
      expect(cont.nextBurstStartAt(0), 5000);
      expect(cont.nextBurstStartAt(5000), 10000);
    });

    test('a normal plan is not continuous', () {
      expect(plan.continuous, isFalse);
    });

    // The owner's round-173 field configuration end-to-end: step 1 s,
    // duration 100 s, interval 5 s. Simulates the camera screen's tick
    // contract (re-arm the scheduler window on every cycle change, then ask
    // for the due photo) against the REAL scheduler window and asserts one
    // photo per second far past the first window's end.
    test('plan + scheduler window: photos keep flowing past the first '
        'photo duration (owner bug, r173)', () {
      const owner = TimeLapsePlan(
        stepMs: 1000,
        burstMs: 100000,
        gapMs: 0, // was "repeat every 5 s" <= duration, i.e. continuous
      );
      final s = RoiCaptureScheduler(
        framesDir: Directory('${Directory.systemTemp.path}/tl_plan_test'),
        sessionToken: 'S',
        stepMs: 1000,
        durationMs: 100000,
        mode: RoiCaptureMode.fast,
        targetPx: 640,
        fastCaptureFn: () async => null,
        highResCaptureFn: () async => null,
        roiProvider: () => Roi.defaultRoi,
        streamDims: () => (1280, 960),
        highResDims: () => (0, 0),
      );
      const baseMs = 1700000000000;
      var lastCycle = -1;
      var photos = 0;
      for (var t = 0; t <= 305000; t += 1000) {
        if (!owner.inBurstAt(t)) continue;
        final cycle = owner.cycleIndexAt(t);
        if (cycle != lastCycle) {
          lastCycle = cycle;
          s.resetMotionWindow();
        }
        if (s.evaluateMotion(baseMs + t) != null) photos++;
      }
      // One photo per 1 s tick over 305 s — the unfixed code stopped at 101.
      expect(photos, 306);
    });
  });

  // Round 180: the nocturnal torch schedule — LED on from a lead before each
  // burst through the burst's (inclusive) end, off in the break.
  group('TimeLapseTorchPlan', () {
    // Bursts every 10 s (3 s burst + 7 s break); torch lead 2 s → torch on
    // over [8000, 13000] of each 10 s cycle (and [0, 3000] for burst 0,
    // which starts with the recording and structurally gets no lead).
    const torch = TimeLapseTorchPlan(plan: plan, leadMs: 2000);

    test('on through the burst, including its inclusive end', () {
      expect(torch.shouldBeOnAt(0), isTrue);
      expect(torch.shouldBeOnAt(3000), isTrue); // burst end (inclusive)
      expect(torch.shouldBeOnAt(3001), isFalse); // OFF edge
    });

    test('off mid-break, back on a lead before the next burst', () {
      expect(torch.shouldBeOnAt(5000), isFalse);
      expect(torch.shouldBeOnAt(7999), isFalse);
      expect(torch.shouldBeOnAt(8000), isTrue); // lead window opens
      expect(torch.shouldBeOnAt(9999), isTrue);
      expect(torch.shouldBeOnAt(10000), isTrue); // burst 1 starts
    });

    test('the first burst gets no lead (recording starts in-burst)', () {
      expect(torch.alwaysOn, isFalse);
      expect(torch.shouldBeOnAt(-500), isTrue); // clock skew = start
    });

    test('continuous plan means the torch never turns off', () {
      const cont = TimeLapsePlan(stepMs: 500, burstMs: 5000, gapMs: 0);
      const t = TimeLapseTorchPlan(plan: cont, leadMs: 2000);
      expect(t.alwaysOn, isTrue);
      expect(t.shouldBeOnAt(123456), isTrue);
      expect(t.nextEventDelayMs(123456), isNull);
    });

    test('a lead covering the whole break means always on too', () {
      const t = TimeLapseTorchPlan(plan: plan, leadMs: 7000);
      expect(t.alwaysOn, isTrue);
      expect(t.shouldBeOnAt(5000), isTrue); // mid-break
    });

    group('nextEventDelayMs (extra tick deadlines at the flip edges)', () {
      test('in burst: lands one ms past the inclusive burst end', () {
        expect(torch.nextEventDelayMs(0), 3001);
        expect(torch.nextEventDelayMs(2500), 501);
        // A tick exactly on the inclusive end must not spin (floor ≥ 1).
        expect(torch.nextEventDelayMs(3000), 1);
      });

      test('in the dark break: lands at the torch-on moment', () {
        expect(torch.nextEventDelayMs(3001), 4999);
        expect(torch.nextEventDelayMs(7000), 1000);
      });

      test('inside the lead window: null (the plan\'s own next-burst delay '
          'is the next flip-relevant tick)', () {
        expect(torch.nextEventDelayMs(8000), isNull);
        expect(torch.nextEventDelayMs(9500), isNull);
      });
    });
  });
}
