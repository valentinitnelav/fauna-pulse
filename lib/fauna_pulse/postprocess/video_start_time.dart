// FaunaPulse (round 227): best guess of when a video clip started filming.
//
// A clip's start time turns its frame time stamps into clock times (visit
// times, activity by hour of day), so every source is logged with the time.
// Sources, most trusted first:
//  1. the session log: a `video_clip` record written at import or recording;
//  2. the file name: stock camera apps name the file when filming STARTS, in
//     the phone's local time (VID_20260924_155954.mp4, 20260924_155954.mp4);
//     Pixel phones use UTC (PXL_20260924_135954123.mp4);
//  3. the time stored inside the file minus the clip length: Android phones
//     store when filming STOPPED (checked on a Xiaomi clip in round 226),
//     but a video editor stores when it saved the file (a trimmed copy kept
//     its trim day, months after filming), so the name wins over it;
//  4. only a date in the name (WhatsApp: VID-20260924-WA0005.mp4 keeps the
//     day the video was SENT, not filmed): a weak guess at noon;
//  5. the file's modification time minus the clip length: weak, because a
//     copy or download resets it (imports are copies, so this is usually
//     the import time).
// Weak guesses are flagged so the import screen asks the user to check.
//
// Round 306: each guess's note says what the file name and the stored time
// gave, so the import screen shows what was tried before any change; names
// like "Screen Recording 2026-09-24 at 15.59.54.mov" (date " at " time) are
// read with their time.
//
// Round 395 (owner): names with a two-digit year (260612120338, as some
// camera traps write them) are read too. The import uses Android's file
// chooser, because the photo picker hands over only a number as name.

/// A clip start time and where it came from.
class VideoStartGuess {
  final int epochMs;

  /// Machine label, logged as `start_time_source`: session_log, file_name,
  /// metadata, file_name_date, file_time (see the file comment).
  final String source;

  /// True when the time is likely off (only the day known, a copy's time,
  /// or two sources that disagree): the user should check it.
  final bool weak;

  /// One or two plain-language sentences for the import screen: what the
  /// file name and the stored time gave (round 306).
  final String note;

  const VideoStartGuess(this.epochMs, this.source, {this.weak = false, this.note = ''});
}

/// Two sources further apart than this are reported as a disagreement
/// (a phone set to another time zone, or a renamed file).
const kStartSourcesAgreeMs = 2 * 60 * 1000;

// Date and time with optional separators: 20260924_155954, 20260924155954,
// 2026-09-24-15-59-54, 2026-09-24 15.59.54, 2026-09-24 at 15:59:54. Not
// preceded by another digit. Not followed by AM/PM: a 12-hour time (macOS
// "at 11.59.54 PM") would be read 12 hours off, so such names give only the
// day.
final _dateTime = RegExp(
  r'(?<!\d)(20\d\d)[-_]?(\d\d)[-_]?(\d\d)(?:[-_ T]| at )?(\d\d)[-_.:]?(\d\d)[-_.:]?(\d\d)(?!\s?[AaPp]\.?[Mm]\b)',
);
// Two-digit year: exactly 12 digits, or 6 + 6 (260612120338, 260612_120338);
// read only when no four-digit form is in the name.
final _shortDateTime = RegExp(r'(?<!\d)(\d\d)(\d\d)(\d\d)[-_]?(\d\d)(\d\d)(\d\d)(?!\d)');
final _dateOnly = RegExp(r'(?<!\d)(20\d\d)[-_]?(\d\d)[-_]?(\d\d)(?!\d)');

/// The start time a file name spells out, or null when it has none.
/// [dateOnly] names (messengers) come back at local noon.
({DateTime time, bool dateOnly})? startFromFileName(String fileName, {DateTime? now}) {
  final name = fileName.split('/').last;
  final latest = (now ?? DateTime.now()).add(const Duration(days: 1));
  DateTime? build(List<int> v, {required bool utc}) {
    final t = utc ? DateTime.utc(v[0], v[1], v[2], v[3], v[4], v[5]) : DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
    // DateTime rolls invalid values over (month 13, 30 February): reject those.
    final valid = t.year == v[0] && t.month == v[1] && t.day == v[2] && t.hour == v[3] && t.minute == v[4] && t.second == v[5];
    return valid && !t.isAfter(latest) ? t : null;
  }

  for (final m in _dateTime.allMatches(name)) {
    final t = build([for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)], utc: name.startsWith('PXL_'));
    if (t != null) return (time: t, dateOnly: false);
  }
  for (final m in _shortDateTime.allMatches(name)) {
    final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    final t = build([2000 + v[0], ...v.skip(1)], utc: false);
    if (t != null) return (time: t, dateOnly: false);
  }
  for (final m in _dateOnly.allMatches(name)) {
    final t = build([int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!), 12, 0, 0], utc: false);
    if (t != null) return (time: t, dateOnly: true);
  }
  return null;
}

/// Best start guess for one clip. [storedMs] is the time stored in the file
/// (`VideoInfo.creationEpochMs`, the STOP time on Android phones).
VideoStartGuess guessClipStart({
  required String fileName,
  int? loggedMs,
  int? storedMs,
  int? durationMs,
  int? fileModifiedMs,
  DateTime? now,
}) {
  if (loggedMs != null) return VideoStartGuess(loggedMs, 'session_log');
  final length = durationMs ?? 0;
  final fromStored = storedMs == null ? null : storedMs - length;
  final fromName = startFromFileName(fileName, now: now);
  if (fromName != null && !fromName.dateOnly) {
    final ms = fromName.time.millisecondsSinceEpoch;
    if (fromStored != null && (fromStored - ms).abs() > kStartSourcesAgreeMs) {
      // Time zones differ by at most 14 h; a larger gap is usually an edit.
      final why = (fromStored - ms).abs() <= 14 * 3600 * 1000
          ? 'Check the time (another time zone?).'
          : 'An edited video (for example a trimmed one) stores when it was edited. Check the time.';
      return VideoStartGuess(
        ms,
        'file_name',
        weak: true,
        note: 'From the file name: ${_stamp(ms)}. The time stored in the video gives ${_stamp(fromStored)}, '
            '${_gap(fromStored - ms)} apart. $why',
      );
    }
    final agrees = fromStored == null ? '' : ' The time stored in the video agrees.';
    return VideoStartGuess(ms, 'file_name', note: 'From the file name: ${_stamp(ms)}.$agrees');
  }
  if (fromStored != null) {
    return VideoStartGuess(
      fromStored,
      'metadata',
      note: '${_nameGave(fileName, fromName)}. From the time stored in the video (${_stamp(storedMs!)}) minus '
          'the clip length. Phone cameras store when filming stopped; an edited video (for example a trimmed '
          'one) stores when it was edited.',
    );
  }
  if (fromName != null) {
    return VideoStartGuess(
      fromName.time.millisecondsSinceEpoch,
      'file_name_date',
      weak: true,
      note: 'Only the day is read from the file name (messengers such as WhatsApp keep the day the video was sent) '
          'and the video stores no time, so noon is shown. Please set the time it was filmed.',
    );
  }
  return VideoStartGuess(
    (fileModifiedMs ?? (now ?? DateTime.now()).millisecondsSinceEpoch) - length,
    'file_time',
    weak: true,
    note: '${_nameGave(fileName, null)}; the video stores no time either, so this is when the file was '
        'copied into the app. Please set the time it was filmed.',
  );
}

/// What the file name gave when it gave no full time, for the notes (no
/// final full stop).
String _nameGave(String fileName, ({DateTime time, bool dateOnly})? fromName) {
  if (fromName != null) return 'Only the day is read from the file name';
  final name = fileName.split('/').last;
  // A date the checks threw out, e.g. from a camera clock set wrong.
  return _dateTime.hasMatch(name) || _dateOnly.hasMatch(name)
      ? 'The date in the file name is impossible or in the future'
      : 'The file name holds no date';
}

/// One clip for [layOutClips]: its name, length and start guess; [index]
/// is the caller's position of the clip (names can repeat).
class ClipStart {
  final String name;
  final int durationMs;
  final VideoStartGuess guess;
  final int index;

  /// Final start after [layOutClips]; [source] says why when it moved.
  final int startMs;
  final String source;

  ClipStart(this.name, this.durationMs, this.guess, {this.index = 0, int? startMs, String? source})
    : startMs = startMs ?? guess.epochMs,
      source = source ?? guess.source;

  int get endMs => startMs + durationMs;

  /// Still on an uncertain guess (not placed, not set by the user).
  bool get movable => guess.weak && source == guess.source;
}

/// Orders clips by start (then name) and moves a weakly timed clip that
/// would overlap the one before it to that clip's end (source
/// `after_previous`), so e.g. three WhatsApp clips of one day play one after
/// the other instead of all at noon. Well-timed clips and clips the user set
/// never move: an overlap between them is real (two cameras) and stays
/// visible.
List<ClipStart> layOutClips(List<ClipStart> clips) {
  final sorted = [...clips]
    ..sort((a, b) {
      final c = a.startMs.compareTo(b.startMs);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
  final out = <ClipStart>[];
  // The latest end so far, not the previous clip's: a short clip the user
  // set can sit inside a long one.
  int? end;
  for (final c in sorted) {
    if (end != null && c.movable && c.startMs < end) {
      out.add(ClipStart(c.name, c.durationMs, c.guess, index: c.index, startMs: end, source: 'after_previous'));
    } else {
      out.add(c);
    }
    if (end == null || out.last.endMs > end) end = out.last.endMs;
  }
  return out;
}

/// Local "2026-09-24 15:59:54", as the import screen shows times.
String _stamp(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _gap(int ms) {
  final m = (ms.abs() / 60000).round();
  if (m < 90) return '$m min';
  if (m < 48 * 60) return '${(m / 60).toStringAsFixed(1)} h';
  return '${(m / 1440).round()} days';
}
