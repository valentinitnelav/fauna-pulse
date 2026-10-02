// FaunaPulse (round 277): the Sessions screen's search, filters and order
// (owner: filter sessions by time, length, name, recording mode, imported
// video, "Find animals" run, organisms identified). Kept apart from the
// screen so the rules are tested without widgets.

import 'past_sessions.dart';

enum DateFilter {
  any('Any time'),
  today('Today'),
  last7Days('Last 7 days'),
  last30Days('Last 30 days'),
  range('Choose dates…');

  final String label;
  const DateFilter(this.label);
}

enum LengthFilter {
  any('Any length'),
  under10Min('Under 10 min'),
  tenTo60Min('10 to 60 min'),
  over1Hour('Over 1 hour');

  final String label;
  const LengthFilter(this.label);
}

enum SessionSort {
  newest('Newest first'),
  oldest('Oldest first'),
  longest('Longest first'),
  largest('Largest first');

  final String label;
  const SessionSort(this.label);
}

/// An active filter as a chip: its text and the filter without it.
typedef FilterChipItem = ({String label, SessionFilter without});

class SessionFilter {
  /// Part of the session name, any case.
  final String query;
  final DateFilter date;

  /// [DateFilter.range] only: the first and the last calendar day, both
  /// included.
  final DateTime? from;
  final DateTime? to;
  final LengthFilter length;

  /// Empty = every kind.
  final Set<RecordingKind> kinds;

  /// "Find animals" ran afterwards.
  final bool findDone;
  final bool identified;

  const SessionFilter({
    this.query = '',
    this.date = DateFilter.any,
    this.from,
    this.to,
    this.length = LengthFilter.any,
    this.kinds = const {},
    this.findDone = false,
    this.identified = false,
  });

  SessionFilter copyWith({
    String? query,
    DateFilter? date,
    DateTime? from,
    DateTime? to,
    LengthFilter? length,
    Set<RecordingKind>? kinds,
    bool? findDone,
    bool? identified,
  }) => SessionFilter(
    query: query ?? this.query,
    date: date ?? this.date,
    from: from ?? this.from,
    to: to ?? this.to,
    length: length ?? this.length,
    kinds: kinds ?? this.kinds,
    findDone: findDone ?? this.findDone,
    identified: identified ?? this.identified,
  );

  /// The same search with no filter from the panel.
  SessionFilter get panelCleared => SessionFilter(query: query);

  /// How many filters of the panel are set (the search is not counted).
  int get panelCount => chips().length;

  bool get isEmpty => query.trim().isEmpty && panelCount == 0;

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The text of the date filter ("Last 7 days", "2026-09-01 to 2026-09-30").
  String get dateLabel => date == DateFilter.range && from != null && to != null
      ? (_day(from!) == _day(to!) ? _day(from!) : '${_day(from!)} to ${_day(to!)}')
      : date.label;

  /// The filters of the panel that are set, as removable chips.
  List<FilterChipItem> chips() => [
    if (date != DateFilter.any) (label: dateLabel, without: _withoutDate()),
    if (length != LengthFilter.any) (label: length.label, without: copyWith(length: LengthFilter.any)),
    if (kinds.isNotEmpty)
      (
        label: [for (final k in RecordingKind.values) if (kinds.contains(k)) k.label].join(', '),
        without: copyWith(kinds: const {}),
      ),
    if (findDone) (label: 'Find animals done', without: copyWith(findDone: false)),
    if (identified) (label: 'Identified', without: copyWith(identified: false)),
  ];

  SessionFilter _withoutDate() => SessionFilter(
    query: query,
    length: length,
    kinds: kinds,
    findDone: findDone,
    identified: identified,
  );

  /// Whether [s] passes every filter; [now] gives "today".
  bool matches(PastSession s, DateTime now) {
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty && !s.name.toLowerCase().contains(q)) return false;
    // Calendar days (not 24-hour steps), so a clock change does not shift them.
    DateTime dayStart(int daysBack) => DateTime(now.year, now.month, now.day - daysBack);
    final first = switch (date) {
      DateFilter.any => null,
      DateFilter.today => dayStart(0),
      DateFilter.last7Days => dayStart(6),
      DateFilter.last30Days => dayStart(29),
      DateFilter.range => from == null ? null : DateTime(from!.year, from!.month, from!.day),
    };
    if (first != null && s.start.isBefore(first)) return false;
    if (date == DateFilter.range && to != null && !s.start.isBefore(DateTime(to!.year, to!.month, to!.day + 1))) {
      return false;
    }
    if (length != LengthFilter.any) {
      // A session without an end record has no length: only "Any length".
      final secs = s.duration?.inSeconds;
      if (secs == null) return false;
      final ok = switch (length) {
        LengthFilter.any => true,
        LengthFilter.under10Min => secs < 600,
        LengthFilter.tenTo60Min => secs >= 600 && secs <= 3600,
        LengthFilter.over1Hour => secs > 3600,
      };
      if (!ok) return false;
    }
    if (kinds.isNotEmpty && !kinds.contains(s.kind)) return false;
    if (findDone && !s.hasAnalysis) return false;
    if (identified && !s.hasIdentification) return false;
    return true;
  }

  /// The sessions of [all] that pass, in [sort] order (ties: newest first).
  List<PastSession> apply(List<PastSession> all, SessionSort sort, DateTime now) {
    int newestFirst(PastSession a, PastSession b) => b.start.compareTo(a.start);
    final shown = [for (final s in all) if (matches(s, now)) s];
    shown.sort(switch (sort) {
      SessionSort.newest => newestFirst,
      SessionSort.oldest => (a, b) => a.start.compareTo(b.start),
      // Sessions without a length go last.
      SessionSort.longest => (a, b) {
        final c = (b.duration ?? const Duration(milliseconds: -1)).compareTo(
          a.duration ?? const Duration(milliseconds: -1),
        );
        return c != 0 ? c : newestFirst(a, b);
      },
      SessionSort.largest => (a, b) {
        final c = b.sizeBytes.compareTo(a.sizeBytes);
        return c != 0 ? c : newestFirst(a, b);
      },
    });
    return shown;
  }
}
