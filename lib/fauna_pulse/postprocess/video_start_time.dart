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
//     store when filming STOPPED (checked on a Xiaomi clip in round 226);
//  4. only a date in the name (WhatsApp: VID-20260924-WA0005.mp4 keeps the
//     day the video was SENT, not filmed): a weak guess at noon;
//  5. the file's modification time minus the clip length: weak, because a
//     copy or download resets it (imports are copies, so this is usually
//     the import time).
// Weak guesses are flagged so the import screen asks the user to check.

/// A clip start time and where it came from.
class VideoStartGuess {
  final int epochMs;

  /// Machine label, logged as `start_time_source`: session_log, file_name,
  /// metadata, file_name_date, file_time (see the file comment).
  final String source;

  /// True when the time is likely off (only the day known, a copy's time,
  /// or two sources that disagree): the user should check it.
  final bool weak;

  /// One plain-language sentence for the import screen.
  final String note;

  const VideoStartGuess(this.epochMs, this.source, {this.weak = false, this.note = ''});
}

/// Two sources further apart than this are reported as a disagreement
/// (a phone set to another time zone, or a renamed file).
const kStartSourcesAgreeMs = 2 * 60 * 1000;

// Date and time with optional separators: 20260924_155954, 20260924155954,
// 2026-09-24-15-59-54, 2026-09-24 15.59.54. Not preceded by another digit.
final _dateTime = RegExp(r'(?<!\d)(20\d\d)[-_]?(\d\d)[-_]?(\d\d)[-_ T]?(\d\d)[-_.]?(\d\d)[-_.]?(\d\d)');
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
      return VideoStartGuess(
        ms,
        'file_name',
        weak: true,
        note: 'The file name and the time stored in the file differ by '
            '${_gap(fromStored - ms)}. Check the time (another time zone?).',
      );
    }
    return VideoStartGuess(ms, 'file_name', note: 'From the file name.');
  }
  if (fromStored != null) {
    return VideoStartGuess(fromStored, 'metadata', note: 'From the time stored in the file.');
  }
  if (fromName != null) {
    return VideoStartGuess(
      fromName.time.millisecondsSinceEpoch,
      'file_name_date',
      weak: true,
      note: 'Only the day is known (messengers such as WhatsApp keep the day '
          'the video was sent). Please set the time it was filmed.',
    );
  }
  return VideoStartGuess(
    (fileModifiedMs ?? (now ?? DateTime.now()).millisecondsSinceEpoch) - length,
    'file_time',
    weak: true,
    note: 'The file does not say when it was filmed; this is when it was '
        'last saved or copied. Please set the time it was filmed.',
  );
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
}

/// Orders clips by start (then name) and moves a weakly timed clip that
/// would overlap the one before it to that clip's end (source
/// `after_previous`), so e.g. three WhatsApp clips of one day play one after
/// the other instead of all at noon. Well-timed clips never move: an overlap
/// between them is real (two cameras) and stays visible.
List<ClipStart> layOutClips(List<ClipStart> clips) {
  final sorted = [...clips]
    ..sort((a, b) {
      final c = a.startMs.compareTo(b.startMs);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
  final out = <ClipStart>[];
  for (final c in sorted) {
    final prev = out.lastOrNull;
    if (prev != null && c.guess.weak && c.startMs < prev.endMs) {
      out.add(ClipStart(c.name, c.durationMs, c.guess, index: c.index, startMs: prev.endMs, source: 'after_previous'));
    } else {
      out.add(c);
    }
  }
  return out;
}

String _gap(int ms) {
  final m = (ms.abs() / 60000).round();
  return m >= 90 ? '${(m / 60).toStringAsFixed(1)} h' : '$m min';
}
