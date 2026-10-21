// Round 319 part 3 (A2, phone check P1R step e): a scheduled window skipped
// for low free storage is tried again on each schedule tick (at most 60 s
// apart) until the window ends, and starts when space is freed. The sleep
// cover still said 'Scheduled run finishing…' during the last window (and
// 'Next recording: <next window>' during an earlier one), as it only looked
// for the next window to start.

import 'package:fauna_pulse/fauna_pulse/models/schedule_window.dart';
import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:fauna_pulse/fauna_pulse/session/schedule_plan.dart';
import 'package:flutter_test/flutter_test.dart';

const _note = 'Window not started: 106.4 MB free, less than 200 MB (Settings, Keep free storage).';

void main() {
  // One window 12:52-12:58 on one day, as on the phone.
  final oneWindow = SchedulePlan(
    windows: const [ScheduleWindow(12 * 60 + 52, 12 * 60 + 58)],
    days: 1,
    startedAt: DateTime(2026, 10, 21, 12, 49),
  );

  test('last window skipped for storage: waiting for storage until its end', () {
    final text = sleepStatusText(
      plan: oneWindow,
      now: DateTime(2026, 10, 21, 12, 53),
      sessionsDone: 0,
      storageSkipNote: _note,
      storageSkipSlot: const ScheduleSlot(0, 0),
    );
    expect(text, '$_note\nFree some storage: this window still starts if space is freed before 12:58.');
    expect(text, isNot(contains('finishing')));
  });

  test('earlier window skipped for storage: not the next window yet', () {
    final plan = SchedulePlan(
      windows: const [ScheduleWindow(6 * 60, 8 * 60), ScheduleWindow(17 * 60, 19 * 60)],
      days: 2,
      startedAt: DateTime(2026, 10, 21, 5),
    );
    final text = sleepStatusText(
      plan: plan,
      now: DateTime(2026, 10, 21, 7, 10),
      sessionsDone: 0,
      storageSkipNote: _note,
      storageSkipSlot: const ScheduleSlot(0, 0),
    );
    expect(text, '$_note\nFree some storage: this window still starts if space is freed before 08:00.');
    expect(text, isNot(contains('Next recording')));
  });

  test('open window not yet tried (or camera retried): recording starts soon', () {
    final text = sleepStatusText(plan: oneWindow, now: DateTime(2026, 10, 21, 12, 52, 10), sessionsDone: 0);
    expect(text, 'Recording starts soon (this window ends at 12:58).');
  });

  test('between windows and at the end: as before', () {
    final plan = SchedulePlan(
      windows: const [ScheduleWindow(6 * 60, 8 * 60), ScheduleWindow(17 * 60, 19 * 60)],
      days: 2,
      startedAt: DateTime(2026, 10, 21, 5),
    );
    expect(
      sleepStatusText(plan: plan, now: DateTime(2026, 10, 21, 9), sessionsDone: 1),
      'Scheduled sleep (day 1 of 2)\nNext recording: 17:00\n1 session recorded so far',
    );
    expect(
      sleepStatusText(
        plan: plan,
        now: DateTime(2026, 10, 21, 20),
        sessionsDone: 1,
        storageSkipNote: _note,
        storageSkipSlot: const ScheduleSlot(0, 1),
      ),
      '$_note\nScheduled sleep (day 2 of 2)\nNext recording: tomorrow 06:00\n1 session recorded so far',
    );
    expect(
      sleepStatusText(plan: oneWindow, now: DateTime(2026, 10, 21, 12, 58, 30), sessionsDone: 1),
      'Scheduled run finishing…',
    );
  });
}
