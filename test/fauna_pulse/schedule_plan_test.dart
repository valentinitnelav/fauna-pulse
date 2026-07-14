// Tests for SchedulePlan — the pure planner behind scheduled recording.
//
// The planner is clock-injected (every query takes `now`), so these tests
// need no timers or mocking: they walk a fictional run through its phases
// and check the planned state and transition times at each moment.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/schedule_window.dart';
import 'package:fauna_pulse/fauna_pulse/session/schedule_plan.dart';

void main() {
  // The owner's example: 06:00–10:00 and 15:00–20:00, for 2 days.
  const morning = ScheduleWindow(6 * 60, 10 * 60);
  const afternoon = ScheduleWindow(15 * 60, 20 * 60);

  DateTime day1(int hour, [int minute = 0]) =>
      DateTime(2026, 7, 13, hour, minute);
  DateTime day2(int hour, [int minute = 0]) =>
      DateTime(2026, 7, 14, hour, minute);

  SchedulePlan twoDayPlan({DateTime? startedAt}) => SchedulePlan(
    windows: const [morning, afternoon],
    days: 2,
    startedAt: startedAt ?? day1(5, 30),
  );

  test('sleeps before the first window, records inside, sleeps between', () {
    final plan = twoDayPlan(); // started 05:30, before the morning window
    expect(plan.phaseAt(day1(5, 45)), SchedulePhase.sleeping);
    expect(plan.phaseAt(day1(6)), SchedulePhase.recording);
    expect(plan.phaseAt(day1(9, 59)), SchedulePhase.recording);
    expect(plan.phaseAt(day1(10)), SchedulePhase.sleeping); // end is exclusive
    expect(plan.phaseAt(day1(12)), SchedulePhase.sleeping);
    expect(plan.phaseAt(day1(15)), SchedulePhase.recording);
  });

  test('identifies the active slot by day and window index', () {
    final plan = twoDayPlan();
    expect(plan.activeSlotAt(day1(7)), const ScheduleSlot(0, 0));
    expect(plan.activeSlotAt(day1(16)), const ScheduleSlot(0, 1));
    expect(plan.activeSlotAt(day1(12)), isNull);
    expect(plan.activeSlotAt(day2(7)), const ScheduleSlot(1, 0));
  });

  test('started mid-window: records the partial window immediately', () {
    final plan = twoDayPlan(startedAt: day1(8)); // inside the morning window
    expect(plan.phaseAt(day1(8)), SchedulePhase.recording);
    expect(plan.activeSlotAt(day1(8)), const ScheduleSlot(0, 0));
    // …and the window still ends at its normal time.
    expect(plan.nextTransitionAt(day1(8)), day1(10));
  });

  test('windows already over at start are skipped, not replayed', () {
    final plan = twoDayPlan(startedAt: day1(12)); // morning already gone
    expect(plan.phaseAt(day1(12)), SchedulePhase.sleeping);
    expect(plan.nextSlotAt(day1(12)), const ScheduleSlot(0, 1)); // 15:00 next
  });

  test('rolls over to the next day and finishes after the last window', () {
    final plan = twoDayPlan();
    // Overnight between day 1 and day 2.
    expect(plan.phaseAt(day1(23)), SchedulePhase.sleeping);
    expect(plan.nextSlotAt(day1(23)), const ScheduleSlot(1, 0));
    expect(plan.nextTransitionAt(day1(23)), day2(6));
    // Day 2 afternoon window is the last of the run.
    expect(plan.phaseAt(day2(19)), SchedulePhase.recording);
    expect(plan.phaseAt(day2(20)), SchedulePhase.finished);
    expect(plan.nextTransitionAt(day2(20)), isNull);
  });

  test('a run started after everything is immediately finished', () {
    final plan = SchedulePlan(
      windows: const [morning],
      days: 1,
      startedAt: day1(11), // morning window already over, days = 1
    );
    expect(plan.phaseAt(day1(11)), SchedulePhase.finished);
    expect(plan.nextSlotAt(day1(11)), isNull);
  });

  test('nextTransitionAt is the window end while recording', () {
    final plan = twoDayPlan();
    expect(plan.nextTransitionAt(day1(7)), day1(10));
    expect(plan.nextTransitionAt(day1(12)), day1(15));
  });

  test('slot wall-clock times come from the start day calendar', () {
    final plan = twoDayPlan();
    expect(plan.startOf(const ScheduleSlot(0, 0)), day1(6));
    expect(plan.endOf(const ScheduleSlot(0, 1)), day1(20));
    expect(plan.startOf(const ScheduleSlot(1, 1)), day2(15));
  });

  test('windows are sorted by start time regardless of input order', () {
    final plan = SchedulePlan(
      windows: const [afternoon, morning], // deliberately reversed
      days: 1,
      startedAt: day1(5),
    );
    expect(plan.startOf(const ScheduleSlot(0, 0)), day1(6));
    expect(plan.startOf(const ScheduleSlot(0, 1)), day1(15));
  });

  test('three windows a day all get their turn', () {
    const midday = ScheduleWindow(11 * 60, 13 * 60);
    final plan = SchedulePlan(
      windows: const [morning, midday, afternoon],
      days: 1,
      startedAt: day1(5),
    );
    expect(plan.activeSlotAt(day1(12)), const ScheduleSlot(0, 1));
    expect(plan.phaseAt(day1(13, 30)), SchedulePhase.sleeping);
    expect(plan.nextTransitionAt(day1(13, 30)), day1(15));
    expect(plan.phaseAt(day1(20)), SchedulePhase.finished);
  });

  test('a query before startedAt plans sleep toward the first window', () {
    final plan = twoDayPlan(startedAt: day1(5, 30));
    // E.g. a clock correction jumping backwards: no active slot, next is the
    // day-1 morning window — the run self-heals instead of crashing.
    expect(plan.phaseAt(day1(4)), SchedulePhase.sleeping);
    expect(plan.nextTransitionAt(day1(4)), day1(6));
  });

  test('day rollover across a month boundary', () {
    final plan = SchedulePlan(
      windows: const [morning],
      days: 2,
      startedAt: DateTime(2026, 7, 31, 12), // morning already past
    );
    expect(plan.phaseAt(DateTime(2026, 7, 31, 13)), SchedulePhase.sleeping);
    expect(
      plan.nextTransitionAt(DateTime(2026, 7, 31, 13)),
      DateTime(2026, 8, 1, 6),
    );
    expect(plan.phaseAt(DateTime(2026, 8, 1, 7)), SchedulePhase.recording);
    expect(plan.phaseAt(DateTime(2026, 8, 1, 10)), SchedulePhase.finished);
  });
}
