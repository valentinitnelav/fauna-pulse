// Pollinator Monitor — planner for scheduled recording runs.
//
// Pure Dart, no timers, no I/O: given the daily windows, the number of days
// and the moment the run was started, it answers "what should the app be
// doing at time X, and when does that change next". The camera screen drives
// it with real timers and reconciles the actual state (recording / sleeping)
// against the planned phase on every tick. Because every answer is
// recomputed from the wall clock passed in — never from accumulated
// counters — timer drift, OS doze gaps and clock corrections self-heal:
// the next tick simply lands in the right phase.
//
// Times are local wall-clock: a slot's start/end is built from calendar
// components (`DateTime(y, m, d + day, h, m)`), so "06:00 on day 2" means
// 06:00 by the phone's clock even across a DST change — which is what a
// field schedule ("when the sun is up") intends.

import '../models/schedule_window.dart';

/// What a scheduled run should be doing at a given moment.
enum SchedulePhase {
  /// Between windows (or before the first one): camera off, screen dark.
  sleeping,

  /// Inside a window: a recording session should be active.
  recording,

  /// Past the end of the last window of the last day: the run is over.
  finished,
}

/// One concrete recording slot of the run: [day] 0-based from the start day,
/// [windowIndex] into the sorted daily windows list.
class ScheduleSlot {
  final int day;
  final int windowIndex;

  const ScheduleSlot(this.day, this.windowIndex);

  @override
  bool operator ==(Object other) =>
      other is ScheduleSlot &&
      other.day == day &&
      other.windowIndex == windowIndex;

  @override
  int get hashCode => Object.hash(day, windowIndex);

  @override
  String toString() => 'ScheduleSlot(day $day, window $windowIndex)';
}

class SchedulePlan {
  /// Daily windows, sorted by start and non-overlapping (the config loader
  /// sorts; [SessionConfig.isScheduleValid] is checked before a run starts).
  final List<ScheduleWindow> windows;

  /// Total days the run covers (1 = the start day only).
  final int days;

  /// When the user started the run. Day 0 is this moment's calendar date;
  /// windows of day 0 that were already fully over at this moment are
  /// skipped (a run started at noon doesn't try to record the morning).
  final DateTime startedAt;

  SchedulePlan({
    required List<ScheduleWindow> windows,
    required this.days,
    required this.startedAt,
  }) : windows = List.unmodifiable(
         [...windows]..sort((a, b) => a.startMinute.compareTo(b.startMinute)),
       ) {
    assert(this.windows.isNotEmpty && days >= 1);
  }

  /// Wall-clock start of [slot]. Built from calendar components so day
  /// arithmetic follows the local calendar (see file header).
  DateTime startOf(ScheduleSlot slot) => _at(slot.day, windows[slot.windowIndex].startMinute);

  /// Wall-clock end of [slot] (exclusive — recording stops at this moment).
  DateTime endOf(ScheduleSlot slot) => _at(slot.day, windows[slot.windowIndex].endMinute);

  DateTime _at(int day, int minuteOfDay) => DateTime(
    startedAt.year,
    startedAt.month,
    startedAt.day + day,
    minuteOfDay ~/ 60,
    minuteOfDay % 60,
  );

  /// The slot whose window contains [now], or null when none does. A moment
  /// before [startedAt] never has an active slot (the run hadn't begun).
  ScheduleSlot? activeSlotAt(DateTime now) {
    if (now.isBefore(startedAt)) return null;
    final day = _dayIndexOf(now);
    if (day < 0 || day >= days) return null;
    for (var i = 0; i < windows.length; i++) {
      final slot = ScheduleSlot(day, i);
      if (!now.isBefore(startOf(slot)) && now.isBefore(endOf(slot))) {
        return slot;
      }
    }
    return null;
  }

  /// The next slot that *starts* after [now], or null when the run has no
  /// further windows. (An active slot is not "next" — see [activeSlotAt].)
  ScheduleSlot? nextSlotAt(DateTime now) {
    final fromDay = _dayIndexOf(now);
    for (var day = fromDay < 0 ? 0 : fromDay; day < days; day++) {
      for (var i = 0; i < windows.length; i++) {
        final slot = ScheduleSlot(day, i);
        if (startOf(slot).isAfter(now)) return slot;
      }
    }
    return null;
  }

  /// What the run should be doing at [now].
  SchedulePhase phaseAt(DateTime now) {
    if (activeSlotAt(now) != null) return SchedulePhase.recording;
    return nextSlotAt(now) == null
        ? SchedulePhase.finished
        : SchedulePhase.sleeping;
  }

  /// The next moment the phase changes: the active window's end while
  /// recording, otherwise the next window's start. Null once finished.
  DateTime? nextTransitionAt(DateTime now) {
    final active = activeSlotAt(now);
    if (active != null) return endOf(active);
    final next = nextSlotAt(now);
    return next == null ? null : startOf(next);
  }

  /// Calendar days between [startedAt]'s date and [now]'s date (can be
  /// negative before the start day, or >= [days] after the run).
  int _dayIndexOf(DateTime now) {
    // The dates are rebuilt in UTC (which has no DST) so their difference is
    // an exact multiple of 24 h; subtracting local midnights straddling a DST
    // change yields 23/25 h, which inDays would truncate to the wrong index.
    final startDate = DateTime.utc(
      startedAt.year,
      startedAt.month,
      startedAt.day,
    );
    final nowDate = DateTime.utc(now.year, now.month, now.day);
    return nowDate.difference(startDate).inDays;
  }
}
