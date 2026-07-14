// FaunaPulse — one daily recording window for scheduled sessions.
//
// A "window" is a start/end time of day (e.g. 06:00–10:00) during which the
// app records; between windows a scheduled run sleeps (screen dark, camera
// off). Times are stored as minutes since midnight (0–1439) so they survive
// JSON round-trips without locale/format concerns.

/// One daily recording window, as minutes since local midnight.
///
/// Invariant for a *valid* window: `0 <= startMinute < endMinute <= 1440`.
/// Windows crossing midnight (start > end) are not supported — the user
/// models "20:00–06:00" as two windows on consecutive days instead.
class ScheduleWindow {
  /// Window start, minutes since midnight (e.g. 360 = 06:00).
  final int startMinute;

  /// Window end, minutes since midnight (e.g. 600 = 10:00). Exclusive: a
  /// window 360–600 records from 06:00:00 up to (not including) 10:00:00.
  final int endMinute;

  const ScheduleWindow(this.startMinute, this.endMinute);

  /// True when the times describe a usable same-day window.
  bool get isValid =>
      startMinute >= 0 && endMinute <= 24 * 60 && startMinute < endMinute;

  /// True when this window shares any minute with [other] (touching ends —
  /// one window ending exactly when the next starts — do NOT overlap).
  bool overlaps(ScheduleWindow other) =>
      startMinute < other.endMinute && other.startMinute < endMinute;

  /// "06:00–10:00" style label for settings rows and summary display.
  String get label => '$startLabel–$endLabel';

  /// "06:00" / "10:00" — the two halves of [label], for places that need
  /// them separately (time-picker buttons, the start record's schedule block).
  String get startLabel => hhmm(startMinute);
  String get endLabel => hhmm(endMinute);

  /// Formats minutes-since-midnight as "HH:MM".
  static String hhmm(int minuteOfDay) {
    final h = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
    final m = (minuteOfDay % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  Map<String, dynamic> toJson() => {'start': startMinute, 'end': endMinute};

  /// Parses one window from a saved config entry; null when malformed (the
  /// caller drops it rather than failing the whole config load).
  static ScheduleWindow? fromJson(dynamic j) {
    if (j is! Map) return null;
    final start = j['start'];
    final end = j['end'];
    if (start is! num || end is! num) return null;
    final w = ScheduleWindow(start.toInt(), end.toInt());
    return w.isValid ? w : null;
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleWindow &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute;

  @override
  int get hashCode => Object.hash(startMinute, endMinute);

  @override
  String toString() => 'ScheduleWindow($label)';
}
