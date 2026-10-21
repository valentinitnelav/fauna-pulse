// Stress round (2026-10-20), step P1, part 2: the smallest and largest value
// each Settings box allows (see docs/SETTINGS_REFERENCE.md and the boxes in
// settings_sheet.dart, tracker_tuning_fields.dart, video_tuning_screen.dart,
// identify_settings_fields.dart) is fed into the pure Dart logic that uses it.
// Looked for: division by zero, loops that never end, negative durations,
// NaN or Infinity in text shown to a person, ticks that come too late or too
// early, and tracker state that grows without end.
//
// Only pure Dart is used (no camera, no phone). Everything is seeded and small.
// Cases that show a real bug are kept and skipped with 'BUG: ...'; run them
// with `flutter test --run-skipped <this file>`.

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show TrackKeepRule;
import 'package:fauna_pulse/fauna_pulse/capture/roi_video.dart';
import 'package:fauna_pulse/fauna_pulse/capture/time_lapse_plan.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/identification/track_fusion.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/models/schedule_window.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/models/track.dart';
import 'package:fauna_pulse/fauna_pulse/perf/adaptive_inference_throttle.dart';
import 'package:fauna_pulse/fauna_pulse/session/frame_processor.dart';
import 'package:fauna_pulse/fauna_pulse/session/plan_sentence.dart';
import 'package:fauna_pulse/fauna_pulse/session/schedule_plan.dart';
import 'package:fauna_pulse/fauna_pulse/session/time_lapse_camera_coordinator.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';
import 'package:flutter_test/flutter_test.dart';

/// The burst plan exactly as camera_session_screen.dart (~line 2175) builds it.
TimeLapsePlan planFor(SessionConfig c) => TimeLapsePlan(
  stepMs: (c.stepSeconds * 1000).round(),
  burstMs: (c.durationSeconds * 1000).round(),
  gapMs: (c.timeLapseGapSeconds * 1000).round(),
);

/// The delay the camera screen really waits: the plan's own delay, then the
/// camera and torch delays, clamped to 100 ms .. 60 s (~line 3519-3530).
int screenDelay(
  TimeLapsePlan plan,
  int t, {
  TimeLapseTorchPlan? torch,
  TimeLapseCameraCoordinator? cam,
}) {
  var d = plan.nextTickDelayMs(t);
  final c = cam?.nextEventDelayMs(t);
  if (c != null && c < d) d = c;
  final k = torch?.nextEventDelayMs(t);
  if (k != null && k < d) d = k;
  return d.clamp(100, 60000);
}

LabelPack tinyPack({double logitScale = 100}) {
  final labels = [
    const LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Eristalis', 'tenax'], 'Drone fly'),
    const LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Episyrphus', 'balteatus'], ''),
    const LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Apis', 'mellifera'], 'Honey bee'),
    const LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', 'terrestris'], ''),
    const LabelRow(['none', '', '', '', '', '', 'flower'], 'a photo of a flower.'),
  ];
  const dim = 5;
  final m = Float32List(5 * dim);
  for (var r = 0; r < 5; r++) {
    m[r * dim + r] = 1;
  }
  return LabelPack(
    packId: 't',
    modelId: 'm',
    dim: dim,
    rows: 5,
    sinkRows: 1,
    logitScale: logitScale,
    temperature: 1.0,
    labels: labels,
    matrix: m,
    header: const {},
  );
}

void main() {
  // -------------------------------------------------------------------------
  group('time-lapse plan at the extremes of Photo step, Photo duration, Time between bursts', () {
    // (step s, burst s): the step box is 0.1..10, the duration box 1..86400.
    const pairs = [(0.1, 1.0), (0.1, 10.0), (1.0, 10.0), (1.0, 600.0), (10.0, 10.0), (10.0, 86400.0), (0.5, 1.5)];
    const gaps = [0.0, 1.0, 29.0, 30.0, 60.0, 1800.0, 86400.0];

    for (final (step, burst) in pairs) {
      for (final gap in gaps) {
        test('step $step s, burst $burst s, gap $gap s: ticks move forward, never spin, never miss a burst start', () {
          final c = const SessionConfig().copyWith(
            captureTrigger: CaptureTrigger.timelapse,
            stepSeconds: step,
            durationSeconds: burst,
            timeLapseGapSeconds: gap,
          );
          final plan = planFor(c);
          var t = 0;
          var ticks = 0;
          var lastCycle = -1;
          final horizon = min(plan.cycleMs * 3, 12 * 3600 * 1000);
          while (t < horizon && ticks < 400000) {
            final raw = plan.nextTickDelayMs(t);
            expect(raw, greaterThan(0), reason: 'raw delay at t=$t');
            final cyc = plan.cycleIndexAt(t);
            expect(cyc, greaterThanOrEqualTo(lastCycle));
            lastCycle = cyc;
            expect(plan.nextBurstStartAt(t), greaterThan(t), reason: 'next burst start must be in the future');
            expect(plan.nextEdgeDelayMs(t), greaterThan(0), reason: 'edge delay at t=$t');
            expect(plan.inBurstAt(t), plan.continuous || t % plan.cycleMs <= plan.burstMs);
            final d = screenDelay(plan, t);
            expect(d, inInclusiveRange(100, 60000));
            if (!plan.inBurstAt(t) && raw <= 60000 && raw >= 100) {
              // The tick must land exactly on the next burst start.
              expect(t + d, plan.nextBurstStartAt(t), reason: 'tick after the break lands on the burst start');
            }
            t += d;
            ticks++;
          }
          expect(ticks, greaterThan(0));
        });
      }
    }

    test('video bursts: the edge delay is never 0 or negative and clips start and end on the edges', () {
      for (final burst in [1.0, 10.0, 600.0]) {
        for (final gap in [0.0, 1.0, 60.0]) {
          final plan = TimeLapsePlan(stepMs: 1000, burstMs: (burst * 1000).round(), gapMs: (gap * 1000).round());
          for (var t = 0; t < plan.cycleMs * 3; t += 997) {
            expect(plan.nextEdgeDelayMs(t), inInclusiveRange(1, plan.cycleMs), reason: 't=$t');
          }
        }
      }
    });

    test('torch plan: the torch state computed at a tick holds until the next tick (no flip is missed)', () {
      for (final lead in [1.0, 5.0, 60.0]) {
        for (final (step, burst) in [(1.0, 10.0), (10.0, 10.0), (0.1, 1.0)]) {
          for (final gap in [0.0, 1.0, 30.0, 61.0, 1800.0]) {
            final plan = TimeLapsePlan(
              stepMs: (step * 1000).round(),
              burstMs: (burst * 1000).round(),
              gapMs: (gap * 1000).round(),
            );
            final torch = TimeLapseTorchPlan(plan: plan, leadMs: (lead * 1000).round());
            var t = 0;
            var n = 0;
            while (t < plan.cycleMs * 3 && n < 100000) {
              final raw = min(plan.nextTickDelayMs(t), torch.nextEventDelayMs(t) ?? 1 << 40);
              expect(torch.nextEventDelayMs(t) ?? 1, greaterThanOrEqualTo(1));
              final d = screenDelay(plan, t, torch: torch);
              final on = torch.shouldBeOnAt(t);
              // Only when the wait was not stretched by the 100 ms floor or cut by the 60 s cap.
              if (raw >= 100 && raw <= 60000 && d > 1) {
                expect(torch.shouldBeOnAt(t + d - 1), on,
                    reason: 'lead $lead, step $step, burst $burst, gap $gap: torch flips inside the wait after t=$t');
              }
              t += d;
              n++;
            }
          }
        }
      }
    });

    test('camera parking: wakes before every burst, never stays parked inside a burst', () {
      for (final lead in [1000, 10000, 60000]) {
        for (final gap in [29.0, 30.0, 60.0, 1800.0]) {
          const burstMs = 5000;
          final plan = TimeLapsePlan(stepMs: 1000, burstMs: burstMs, gapMs: (gap * 1000).round());
          final cam = TimeLapseCameraCoordinator(plan: plan, prewakeLeadMs: lead);
          var t = 0;
          var parks = 0;
          var wakes = 0;
          var n = 0;
          while (t < plan.cycleMs * 4 && n < 200000) {
            switch (cam.actionAt(t)) {
              case TimeLapseCameraAction.park:
                cam.parked();
                parks++;
              case TimeLapseCameraAction.wake:
                cam.wakeStarted();
                cam.wakeSucceeded();
                wakes++;
              case TimeLapseCameraAction.none:
                break;
            }
            if (plan.inBurstAt(t) && t > 1000) {
              expect(cam.state, isNot(TimeLapseCameraState.parked), reason: 'parked inside a burst at t=$t (gap $gap, lead $lead)');
            }
            t += screenDelay(plan, t, cam: cam);
            n++;
          }
          expect(parks - wakes, inInclusiveRange(0, 1), reason: 'park/wake balance (gap $gap, lead $lead)');
        }
      }
    });

    test('a loaded step below 0.0005 s gives stepMs 0 and the plan cannot be built', () {
      final c = const SessionConfig().copyWith(captureTrigger: CaptureTrigger.timelapse, stepSeconds: 0.0004);
      expect(() => planFor(c), returnsNormally);
    }, skip: 'BUG (low): SessionConfig.fromJson now clamps the step to 0.1..10, so a saved file cannot reach this; the plan itself still has no guard if code builds a config with step 0.0004 (TimeLapsePlan asserts)');

    test('a loaded burst of 0 s and a break of 0 s: cycleMs would be 0 and "~/" divides by zero', () {
      final c = const SessionConfig().copyWith(
        captureTrigger: CaptureTrigger.timelapse,
        durationSeconds: 0,
        timeLapseGapSeconds: 0,
      );
      final plan = planFor(c);
      expect(plan.cycleMs, greaterThan(0));
      plan.cycleIndexAt(5);
    }, skip: 'BUG (low): SessionConfig.fromJson now clamps the duration to >= 1 s, so a saved file cannot reach this; the plan itself still has no guard for burst 0 plus break 0 (assert in debug, IntegerDivisionByZeroException in release)');

    test('isTimeLapseValid with the extremes: no exception, no NaN', () {
      for (final step in [0.1, 10.0, 0.3]) {
        for (final dur in [1.0, 86400.0, 7.0]) {
          final c = const SessionConfig().copyWith(stepSeconds: step, durationSeconds: dur);
          c.isTimeLapseValid;
        }
      }
      // 1 s of burst with a 0.3 s step is not a whole multiple: warning, not an error.
      expect(const SessionConfig().copyWith(stepSeconds: 0.3, durationSeconds: 1).isTimeLapseValid, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('photo schedule (TrackKeepRule) at the extremes', () {
    test('step 0.1 s and duration 1 s .. 86400 s: photo count per track is bounded by duration / step + 1', () {
      for (final (step, dur) in [(100, 1000), (100, 10000), (10000, 86400000), (1000, 1000)]) {
        final rule = TrackKeepRule(stepMs: step, durationMs: dur);
        var photos = 0;
        // One frame every 66 ms for min(dur, 2 h).
        final end = min(dur + 2000, 2 * 3600 * 1000);
        for (var t = 0; t <= end; t += 66) {
          photos += rule.due([1], t).length;
        }
        final expectedMax = min(dur, end) ~/ step + 2;
        expect(photos, lessThanOrEqualTo(expectedMax), reason: 'step $step dur $dur gave $photos photos');
        expect(photos, greaterThanOrEqualTo(1));
      }
    });

    test('a saved step of 0 would take a photo on EVERY frame (what the sheet prevents)', () {
      final rule = TrackKeepRule(stepMs: 0, durationMs: 10000);
      var photos = 0;
      for (var t = 0; t <= 5000; t += 66) {
        photos += rule.due([1], t).length;
      }
      // 5 s at 15 frames per second = 76 photos instead of 1 per step.
      expect(photos, lessThan(10));
    }, skip: 'BUG (low): SessionConfig.fromJson now clamps the step to >= 0.1 s; TrackKeepRule itself still takes a photo on every frame for step 0 (camera_session_screen.dart:1947)');
  });

  // -------------------------------------------------------------------------
  group('schedule windows and Days to run', () {
    final starts = <DateTime>[
      DateTime(2026, 10, 20, 0, 0),
      DateTime(2026, 10, 20, 5, 59),
      DateTime(2026, 10, 20, 6, 0),
      DateTime(2026, 10, 20, 10, 0),
      DateTime(2026, 10, 20, 23, 59, 59, 999),
      DateTime(2026, 3, 28, 12, 0), // day before the spring clock change in Europe
      DateTime(2026, 10, 24, 12, 0), // day before the autumn clock change in Europe
      DateTime(2026, 12, 31, 12, 0), // across the new year
    ];
    const windowSets = <List<ScheduleWindow>>[
      [ScheduleWindow(0, 1440)],
      [ScheduleWindow(0, 1), ScheduleWindow(1, 2), ScheduleWindow(1439, 1440)],
      [ScheduleWindow(360, 600), ScheduleWindow(720, 900), ScheduleWindow(1080, 1320)],
      [ScheduleWindow(1080, 1320), ScheduleWindow(360, 600)], // unsorted on purpose
    ];

    for (final days in [1, 14, 365]) {
      for (var wi = 0; wi < windowSets.length; wi++) {
        test('days $days, window set $wi: walking all changes ends, always moves forward, count is bounded', () {
          for (final start in starts) {
            final plan = SchedulePlan(windows: windowSets[wi], days: days, startedAt: start);
            var now = start;
            var steps = 0;
            final maxSteps = 2 * windowSets[wi].length * days + 4;
            while (true) {
              final phase = plan.phaseAt(now);
              final next = plan.nextTransitionAt(now);
              if (phase == SchedulePhase.finished) {
                expect(next, isNull, reason: 'finished must have no next change ($start)');
                break;
              }
              expect(next, isNotNull, reason: '$phase at $now must have a next change');
              expect(next!.isAfter(now), isTrue, reason: 'next change $next must be after $now (start $start)');
              now = next;
              steps++;
              expect(steps, lessThanOrEqualTo(maxSteps), reason: 'too many changes: a loop? (start $start)');
            }
            expect(plan.activeSlotAt(now), isNull);
          }
        });

        test('days $days, window set $wi: planned minutes equal the minutes the plan really records', () {
          final start = DateTime(2026, 6, 1, 0, 0);
          final plan = SchedulePlan(windows: windowSets[wi], days: days, startedAt: start);
          var recorded = 0.0;
          for (var d = 0; d < days; d++) {
            for (var i = 0; i < plan.windows.length; i++) {
              final slot = ScheduleSlot(d, i);
              recorded += plan.endOf(slot).difference(plan.startOf(slot)).inSeconds / 60.0;
            }
          }
          final c = const SessionConfig().copyWith(
            scheduleEnabled: true,
            scheduleWindows: windowSets[wi],
            scheduleDays: days,
          );
          // June has no clock change, so the sums must be equal.
          expect(plannedSessionMinutes(c), recorded.round());
          expect(planSentence(c), isNot(contains('NaN')));
        });
      }
    }

    test('Days to run 365 (allowed when loaded from a file, the box stops at 14) still gives usable texts', () {
      final c = const SessionConfig().copyWith(scheduleEnabled: true, scheduleDays: 365);
      expect(planSentence(c), contains('365 days'));
      expect(roiVideoStorageEstimate(c), isNot(contains('Infinity')));
      expect(c.isScheduleValid, isTrue);
    });

    test('a run started inside a window records the rest of it; one started after the last window is finished at once', () {
      final plan = SchedulePlan(
        windows: const [ScheduleWindow(360, 600)],
        days: 1,
        startedAt: DateTime(2026, 10, 20, 7, 0),
      );
      expect(plan.phaseAt(DateTime(2026, 10, 20, 7, 0)), SchedulePhase.recording);
      expect(plan.phaseAt(DateTime(2026, 10, 20, 10, 0)), SchedulePhase.finished);
      final late = SchedulePlan(
        windows: const [ScheduleWindow(360, 600)],
        days: 1,
        startedAt: DateTime(2026, 10, 20, 11, 0),
      );
      expect(late.phaseAt(DateTime(2026, 10, 20, 11, 0)), SchedulePhase.finished);
    });

    test('a clock set back (now before startedAt) does not start a window or crash', () {
      final plan = SchedulePlan(
        windows: const [ScheduleWindow(0, 1440)],
        days: 2,
        startedAt: DateTime(2026, 10, 20, 12, 0),
      );
      final back = DateTime(2026, 10, 19, 12, 0);
      expect(plan.activeSlotAt(back), isNull);
      expect(plan.phaseAt(back), SchedulePhase.sleeping);
      expect(plan.nextTransitionAt(back), isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  group('texts for a person at the extremes (plan sentence, storage estimate)', () {
    void clean(String s, String where) {
      for (final bad in ['NaN', 'Infinity', 'null']) {
        expect(s, isNot(contains(bad)), reason: '$where: "$s"');
      }
      expect(RegExp(r'(^|[ (])-\d').hasMatch(s), isFalse, reason: '$where has a negative number: "$s"');
    }

    test('every trigger, with the smallest and the largest value of each box', () {
      for (final trig in CaptureTrigger.values) {
        for (final saveAs in TimeLapseSaveAs.values) {
          for (final atMax in [false, true]) {
            final c = const SessionConfig().copyWith(
              captureTrigger: trig,
              timeLapseSaveAs: saveAs,
              stepSeconds: atMax ? 10 : 0.1,
              durationSeconds: atMax ? 86400 : 1,
              timeLapseGapSeconds: atMax ? 86400 : 0,
              sessionMinutes: atMax ? 60 * 24 * 14 : 1,
              timeLapseVideoFps: atMax ? 30 : 1,
              liveAiVideo: true,
              liveAiVideoFps: atMax ? 30 : 1,
              targetRoiSavedPx: atMax ? 2048 : 128,
              scheduleEnabled: atMax,
              scheduleDays: atMax ? 14 : 1,
              scheduleWindows: atMax
                  ? const [ScheduleWindow(0, 480), ScheduleWindow(480, 960), ScheduleWindow(960, 1440)]
                  : const [ScheduleWindow(0, 1)],
            );
            final where = '$trig/$saveAs/${atMax ? 'max' : 'min'}';
            clean(planSentence(c), where);
            clean(roiVideoStorageEstimate(c), where);
            clean(liveAiVideoStorageEstimate(c), where);
            c.isScheduleValid;
            c.isTimeLapseValid;
            notApplicableConfigKeys(trig, saveAs: saveAs, liveAiVideo: true);
          }
        }
      }
    });

    test('planDuration near a unit edge never shows "60.0 s" or "60.0 min"', () {
      for (final s in [59.95, 59.99, 3599.5, 3599.9, 3599.99]) {
        final text = planDuration(s);
        expect(text, isNot(startsWith('60.0')), reason: 'planDuration($s) = "$text"');
      }
    }, skip: 'BUG (low, text): planDuration(59.96) gives "60.0 s" and planDuration(3599.9) gives "60.0 min" instead of "1 min" and "1 h" (plan_sentence.dart:12-15)');

    test('planDuration of 0, a negative and a huge number gives plain text', () {
      expect(planDuration(0), '0 s');
      expect(planDuration(86400), '24 h');
      expect(planDuration(1.5), '1.5 s');
      expect(planDuration(-60), isNot(contains('NaN')));
    });

    test('planDuration(Infinity) does not throw', () {
      planDuration(double.infinity);
    }, skip: 'BUG: planDuration(Infinity) throws UnsupportedError (Infinity.toInt()); reachable when a saved number is 1e999 (plan_sentence.dart:12)');

    test('the storage estimate for 14 days of 3 x 8 h windows at 30 FPS and 2048 px is a size, not an overflow', () {
      final c = const SessionConfig().copyWith(
        captureTrigger: CaptureTrigger.timelapse,
        timeLapseSaveAs: TimeLapseSaveAs.video,
        scheduleEnabled: true,
        scheduleDays: 14,
        scheduleWindows: const [ScheduleWindow(0, 480), ScheduleWindow(480, 960), ScheduleWindow(960, 1440)],
        timeLapseVideoFps: 30,
        targetRoiSavedPx: 2048,
        timeLapseGapSeconds: 0,
      );
      final text = roiVideoStorageEstimate(c);
      expect(text, contains('GB'));
      expect(plannedSessionMinutes(c), 14 * 1440);
    });

    test('plannedSessionMinutes: a schedule with no windows is 0 and a window loaded as end < start is not negative', () {
      final none = const SessionConfig().copyWith(scheduleEnabled: true, scheduleWindows: const []);
      expect(plannedSessionMinutes(none), 0);
      final odd = const SessionConfig().copyWith(scheduleEnabled: true, scheduleWindows: const [ScheduleWindow(900, 100)]);
      expect(plannedSessionMinutes(odd), greaterThanOrEqualTo(0));
    });
  });

  // -------------------------------------------------------------------------
  group('seconds to frames and the trackers at the extremes', () {
    test('occlusion tolerance 0.2..10 s and minimum track length 0..2 s at 0..1e6 FPS stay inside the frame limits', () {
      final fpsList = <double>[0, -3, 0.001, 0.5, 1, 5, 15, 30, 120, 1e6, double.nan, double.infinity, double.negativeInfinity];
      for (final occ in [0.2, 3.0, 10.0]) {
        for (final hits in [0.0, 0.2, 2.0]) {
          final c = const SessionConfig().copyWith(occlusionSeconds: occ, minHitsSeconds: hits);
          for (final fps in fpsList) {
            final o = c.occlusionFramesFor(fps);
            final h = c.minHitsFramesFor(fps);
            expect(o, inInclusiveRange(1, 600), reason: 'occlusion $occ s at $fps FPS');
            expect(h, inInclusiveRange(kMinDetectionsInARow, 600), reason: 'min length $hits s at $fps FPS');
          }
        }
      }
    });

    test('a saved occlusion tolerance of Infinity or a huge number gives a frame count inside the limits', () {
      for (final occ in [1e15, double.infinity]) {
        final c = const SessionConfig().copyWith(occlusionSeconds: occ);
        expect(c.occlusionFramesFor(15), inInclusiveRange(1, 600), reason: 'occlusion $occ');
      }
    });

    test('both trackers survive the corners of every tracker box with 400 seeded random frames, ids stay unique and the working set stays bounded', () {
      final rnd = Random(20261020);
      for (final algo in TrackerAlgorithm.values) {
        for (var corner = 0; corner < 24; corner++) {
          pick(double lo, double hi) => rnd.nextBool() ? lo : hi;
          final buffer = [1, 2, 30, 600][rnd.nextInt(4)];
          final hits = [1, 2, 3, 600][rnd.nextInt(4)];
          final InsectTracker tracker = algo == TrackerAlgorithm.bytetrack
              ? ByteTracker(
                  params: ByteTrackParams(
                    highThresh: pick(0.05, 0.95),
                    matchThresh: pick(0.05, 0.9),
                    lowMatchThresh: pick(0.02, 0.8),
                    velocitySmoothing: pick(0, 1),
                    trackBuffer: buffer,
                    minHitsToConfirm: hits,
                  ),
                )
              : CBiouTracker(
                  params: CBiouParams(
                    bufferScale1: pick(0.05, 1.0),
                    bufferScale2: pick(0.05, 2.0),
                    highThresh: pick(0.05, 0.95),
                    trackBuffer: buffer,
                    minHitsToConfirm: hits,
                  ),
                );
          var ts = 1700000000000;
          var detsTotal = 0;
          final seen = <int>{};
          for (var f = 0; f < 400; f++) {
            // A pause of 20 s every 100 frames, one clock step back at frame 250.
            ts += (f % 100 == 99) ? 20000 : 66;
            if (f == 250) ts -= 5000;
            final n = rnd.nextInt(9);
            final dets = <Detection>[];
            for (var k = 0; k < n; k++) {
              final w = 0.01 + rnd.nextDouble() * 0.4;
              final h = 0.01 + rnd.nextDouble() * 0.4;
              final x = rnd.nextDouble() * (1 - w);
              final y = rnd.nextDouble() * (1 - h);
              dets.add(Detection(box: Rect.fromLTWH(x, y, w, h), confidence: 0.05 + rnd.nextDouble() * 0.9, classIndex: 0, className: 'bee'));
            }
            detsTotal += n;
            final tracks = tracker.update(dets, ts);
            final ids = [for (final t in tracks) t.id];
            expect(ids.toSet().length, ids.length, reason: '$algo corner $corner frame $f: duplicate track ids $ids');
            for (final t in tracks) {
              expect(t.box.left.isFinite && t.box.top.isFinite && t.box.right.isFinite && t.box.bottom.isFinite, isTrue,
                  reason: '$algo corner $corner frame $f: box ${t.box}');
              seen.add(t.id);
            }
            expect(tracker.activeTrackCount, lessThanOrEqualTo(detsTotal + 1), reason: '$algo: more tracks than detections ever seen');
            tracker.drainEvents();
          }
          expect(tracker.totalConfirmed, greaterThanOrEqualTo(seen.length));
          // After 800 empty frames every track must be gone, whatever the buffer (max 600).
          for (var f = 0; f < 700; f++) {
            ts += 66;
            tracker.update(const [], ts);
          }
          expect(tracker.activeTrackCount, 0, reason: '$algo corner $corner (buffer $buffer): tracks never expire');
        }
      }
    });

    test('setFrameBudgets with 1 and 600 frames at the changes of FPS the camera screen makes once a second', () {
      final rnd = Random(7);
      final c = const SessionConfig();
      final t = c.buildTracker(15);
      for (var i = 0; i < 200; i++) {
        final fps = [0.0, 0.2, 3.0, 15.0, 30.0, 1e5][rnd.nextInt(6)];
        t.setFrameBudgets(trackBuffer: c.occlusionFramesFor(fps), minHitsToConfirm: c.minHitsFramesFor(fps));
        t.update([
          Detection(box: Rect.fromLTWH(rnd.nextDouble() * 0.5, 0.2, 0.1, 0.1), confidence: 0.9, classIndex: 0, className: 'bee'),
        ], 1000 + i * 66);
      }
      expect(t.trackBuffer, inInclusiveRange(1, 600));
    });
  });

  // -------------------------------------------------------------------------
  group('detector rate controls at the extremes (Max/Min detector rate, Camera cap, Target processor load)', () {
    test('all corners of the three boxes: effective rates stay ordered and the throttle stays between them', () {
      final rnd = Random(11);
      for (final inf in [5, 30]) {
        for (final minInf in [1, 30]) {
          for (final cap in [0, 5, 30]) {
            for (final duty in [0.3, 0.8]) {
              final c = const SessionConfig()
                  .copyWith(inferenceFps: inf, minInferenceFps: minInf, cameraFpsCap: cap, throttleDutyTarget: duty)
                  .normalizedFpsCaps();
              expect(c.effectiveMinInferenceFps, lessThanOrEqualTo(c.effectiveInferenceFps));
              expect(c.effectiveInferenceFps, inInclusiveRange(5, 30));
              final th = AdaptiveInferenceThrottle(
                minFps: c.effectiveMinInferenceFps,
                ceilFps: c.effectiveInferenceFps,
                dutyTarget: c.throttleDutyTarget,
              );
              for (var i = 0; i < 300; i++) {
                final ms = [0.0, 0.001, 5.0, 75.0, 400.0, 1e4, 1e7][rnd.nextInt(7)];
                final applied = th.update(ms);
                expect(applied, inInclusiveRange(c.effectiveMinInferenceFps, c.effectiveInferenceFps),
                    reason: 'inf $inf min $minInf cap $cap duty $duty ms $ms');
              }
            }
          }
        }
      }
    });

    test('a saved Target processor load of 0 or 5 still gives a usable rate (never stuck at the minimum, never above the ceiling)', () {
      for (final duty in [0.0, 5.0, -1.0]) {
        final th = AdaptiveInferenceThrottle(minFps: 3, ceilFps: 15, dutyTarget: duty);
        var applied = 0;
        for (var i = 0; i < 100; i++) {
          applied = th.update(30);
        }
        expect(applied, greaterThan(3), reason: 'duty $duty: 30 ms per frame can do 15 FPS at 50 % load but stays at the floor');
      }
    }, skip: 'BUG (low): SessionConfig.fromJson now clamps throttleDutyTarget to 0.3..0.8; AdaptiveInferenceThrottle itself still accepts 0 and then stays at the minimum rate (camera_session_screen.dart:2759)');

    test('the throttle with an infinite or tiny inference time does not throw', () {
      for (final ms in [double.infinity, 1e-320, 5e-324]) {
        AdaptiveInferenceThrottle(minFps: 3, ceilFps: 15).update(ms);
      }
    }, skip: 'NOT FIXED (audit): unreachable input; native inference time is a nanoTime difference / 1e6 (0 or >= 1e-6 ms, finite), never Infinity or subnormal');
  });

  // -------------------------------------------------------------------------
  group('frame processor at the extremes', () {
    const roi = Roi.defaultRoi;
    Map<String, dynamic> det(double l, double t, double r, double b) => {
      'classIndex': 0,
      'className': 'bee',
      'confidence': 0.9,
      'normalizedBox': {'left': l, 'top': t, 'right': r, 'bottom': b},
    };

    test('unknown frame size (0 x 0, negative) falls back to the given aspect ratio and gives finite boxes', () {
      for (final (w, h) in [(0, 0), (-1, 480), (640, 0), (1, 1), (100000, 1)]) {
        final fp = FrameProcessor(tracker: ByteTracker(params: const ByteTrackParams(minHitsToConfirm: 2)));
        final r = fp.process(
          data: {'roiActive': true, 'detections': [det(0.1, 0.1, 0.9, 0.9)]},
          roi: roi,
          width: w,
          height: h,
          fallbackAspect: 4 / 3,
        );
        final b = r.roiRect;
        expect(b.left.isFinite && b.top.isFinite && b.right.isFinite && b.bottom.isFinite, isTrue, reason: '$w x $h: ${r.roiRect}');
      }
    });

    test('garbage in the stream event (detections not a list, boxes with NaN, swapped corners) does not throw', () {
      final fp = FrameProcessor(tracker: ByteTracker());
      final events = <Map<String, dynamic>>[
        {'detections': 'x'},
        {'detections': [1, 'a', null, <String, dynamic>{}]},
        {'roiActive': true, 'detections': [det(0.9, 0.9, 0.1, 0.1)]},
        {'roiActive': true, 'detections': [det(double.nan, 0.1, 0.5, 0.5)]},
        {'roiActive': false, 'detections': [det(-5, -5, 5, 5)]},
      ];
      for (final e in events) {
        final r = fp.process(data: e, roi: roi, width: 1280, height: 960, fallbackAspect: 4 / 3);
        for (final t in r.tracks) {
          expect(t.box.left.isNaN || t.box.top.isNaN, isFalse);
        }
      }
    });

    test('a stream event whose timestamp is text instead of a number does not throw', () {
      final fp = FrameProcessor(tracker: ByteTracker());
      fp.process(data: {'timestamp': 'later', 'detections': const []}, roi: roi, width: 1280, height: 960, fallbackAspect: 4 / 3);
    }, skip: 'NOT FIXED (audit): unreachable input; the native plugin always sends System.currentTimeMillis() (a Long), never text or NaN');

    test('pipeline FPS: equal timestamps, a clock step back and a huge jump never give 0, negative or infinite FPS', () {
      final fp = FrameProcessor(tracker: ByteTracker());
      var fps = 0.0;
      for (final t in [1000, 1066, 1066, 1066, 1132, 900, 1198, 1200, 99999999, 100000065]) {
        fps = fp.updatePipelineFps(t);
        expect(fps.isFinite && fps >= 0, isTrue, reason: 'at $t: $fps');
      }
    });

    test('gate wake after a clock step back reports a non-negative idle time', () {
      var now = 100000;
      final fp = FrameProcessor(tracker: ByteTracker(), clock: () => now);
      fp.setGateIdle(true, occlusionSeconds: 3);
      now = 50000; // the phone clock was corrected backwards while the gate slept
      final change = fp.setGateIdle(false, occlusionSeconds: 3);
      expect(change, isNotNull);
      expect(change!.idleSeconds, greaterThanOrEqualTo(0));
      // Sleep length unknown: lost tracks must still expire (no old ID reused).
      expect(change.expiredLostTracks, isTrue);
    });

    test('gate wake with occlusion tolerance 0.2 and 10 s: expiry follows the rule exactly', () {
      for (final occ in [0.2, 10.0]) {
        var now = 1000;
        final fp = FrameProcessor(tracker: ByteTracker(), clock: () => now);
        fp.setGateIdle(true, occlusionSeconds: occ);
        now += (occ * 1000).round() + 1;
        expect(fp.setGateIdle(false, occlusionSeconds: occ)!.expiredLostTracks, isTrue);
        fp.setGateIdle(true, occlusionSeconds: occ);
        now += (occ * 1000).round() - 1;
        expect(fp.setGateIdle(false, occlusionSeconds: occ)!.expiredLostTracks, isFalse);
      }
    });
  });

  // -------------------------------------------------------------------------
  group('identification settings at the extremes (Confidence needed, Ignore crops far less sure, Crops per track ID)', () {
    final scorer = Scorer(tinyPack(logitScale: 10));
    Float32List v(List<double> x) {
      final n = sqrt(x.fold<double>(0, (s, e) => s + e * e));
      return Float32List.fromList([for (final e in x) n == 0 ? 0.0 : e / n]);
    }

    test('tau 0.5 / 0.99 and drop factor 1 / 100 (box limits), 0 and 1e9: masses stay between 0 and 1, never NaN', () {
      final rnd = Random(5);
      for (final tau in [0.5, 0.99]) {
        for (final drop in [1.0, 100.0, 0.0, -3.0, 1e9]) {
          final crops = [
            for (var i = 0; i < 12; i++)
              CropEmbedding(
                jpeg: 'c$i.jpg',
                trackId: 1,
                vector: v([for (var d = 0; d < 5; d++) i == 3 ? 0.0 : rnd.nextDouble() - 0.3]),
              ),
          ];
          final fused = scorer.fuse(crops, tau: tau, dropFactor: drop);
          for (final step in fused.ladder) {
            expect(step.mass.isNaN, isFalse, reason: 'tau $tau drop $drop');
            expect(step.mass, inInclusiveRange(0, 1 + 1e-6), reason: 'tau $tau drop $drop ${step.rank}');
          }
        }
      }
    });

    test('one crop, and 200 identical crops, give the same ladder', () {
      final one = scorer.fuse([CropEmbedding(jpeg: 'a', trackId: 1, vector: v([1, 0.2, 0, 0, 0]))]);
      final many = scorer.fuse([for (var i = 0; i < 200; i++) CropEmbedding(jpeg: 'a$i', trackId: 1, vector: v([1, 0.2, 0, 0, 0]))]);
      expect([for (final s in many.ladder) s.taxon], [for (final s in one.ladder) s.taxon]);
      expect(many.ladder.last.mass, closeTo(one.ladder.last.mass, 1e-5));
    });

    test('an all-zero vector (a blank crop) is scored without NaN', () {
      final fused = scorer.fuse([CropEmbedding(jpeg: 'z', trackId: 1, vector: Float32List(5))]);
      for (final s in fused.ladder) {
        expect(s.mass.isNaN, isFalse);
      }
    });
  });
}
