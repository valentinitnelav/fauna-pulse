import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 24, 18);
  final local = DateTime(2026, 9, 24, 15, 59, 54);

  group('startFromFileName', () {
    test('reads the stock camera patterns in local time', () {
      for (final name in [
        'VID_20260924_155954.mp4', // Xiaomi, most Android phones
        '20260924_155954.mp4', // Samsung
        'VID20260924155954.mp4', // OnePlus
        'Screenrecorder-2026-09-24-15-59-54-123.mp4',
        'video_2026-09-24_15-59-54.mp4', // Telegram
      ]) {
        final r = startFromFileName(name, now: now);
        expect(r?.time, local, reason: name);
        expect(r?.dateOnly, isFalse, reason: name);
      }
    });

    test('reads "date at time" names, with dots or colons in the time (round 306)', () {
      for (final name in [
        'Screen Recording 2026-09-24 at 15.59.54.mov', // macOS
        'clip 2026-09-24 at 15:59:54.mp4',
        'clip 2026-09-24 15:59:54.mp4',
        'VID_20260924_155954 Ammophila.mp4', // a word after the time, not AM/PM
      ]) {
        final r = startFromFileName(name, now: now);
        expect(r?.time, local, reason: name);
        expect(r?.dateOnly, isFalse, reason: name);
      }
      // A valid day with an impossible or future time gives the day only.
      for (final (name, day) in [
        ('Screen Recording 2026-09-24 at 25.00.00.mov', 24), // hour 25
        ('Screen Recording 2026-09-25 at 20.00.00.mov', 25), // after now plus one day
      ]) {
        final r = startFromFileName(name, now: now);
        expect(r?.time, DateTime(2026, 9, day, 12), reason: name);
        expect(r?.dateOnly, isTrue, reason: name);
      }
    });

    test('12-hour times (AM/PM) are not read: the day only', () {
      for (final name in [
        'Screen Recording 2026-09-24 at 11.59.54 PM.mov',
        'Screen Recording 2026-09-24 at 11.59.54\u202fPM.mov', // macOS puts a narrow space before PM
        'Screen Recording 2026-09-24 at 12.30.00 AM.mov',
      ]) {
        final r = startFromFileName(name, now: now);
        expect(r?.time, DateTime(2026, 9, 24, 12), reason: name);
        expect(r?.dateOnly, isTrue, reason: name);
      }
    });

    test('Pixel names are UTC', () {
      final r = startFromFileName('PXL_20260924_135954123.mp4', now: now)!;
      expect(r.time, DateTime.utc(2026, 9, 24, 13, 59, 54));
    });

    test('WhatsApp names give only the day, at noon', () {
      final r = startFromFileName('VID-20260924-WA0005.mp4', now: now)!;
      expect(r.dateOnly, isTrue);
      expect(r.time, DateTime(2026, 9, 24, 12));
    });

    test('two-digit years: 12 digits or 6 + 6, only valid and not in the future (round 395)', () {
      // A camera trap's clip, trimmed later (the owner's feedback file).
      expect(
        startFromFileName('VIDT05B01680_260612120338 - Trim.mp4', now: now),
        (time: DateTime(2026, 6, 12, 12, 3, 38), dateOnly: false),
      );
      expect(startFromFileName('cam2_260612_120338.mp4', now: now)!.time, DateTime(2026, 6, 12, 12, 3, 38));
      expect(startFromFileName('1000071485.mp4', now: now), isNull); // the photo picker's number
      expect(startFromFileName('123456789012.mp4', now: now), isNull); // month 34
      expect(startFromFileName('cam_270101120000.mp4', now: now), isNull); // next year
      expect(startFromFileName('x1260612120338.mp4', now: now), isNull); // 13 digits
    });

    test('rejects impossible and future dates and plain numbers', () {
      expect(startFromFileName('VID_20261340_155954.mp4', now: now), isNull); // month 13
      expect(startFromFileName('VID_20260230_120000.mp4', now: now), isNull); // 30 February
      expect(startFromFileName('VID_20270101_120000.mp4', now: now), isNull); // next year
      expect(startFromFileName('IMG_1234.MOV', now: now), isNull);
    });
  });

  group('guessClipStart', () {
    test('the owner\'s Xiaomi clip: name and stored stop time agree', () {
      // Named 15:59:54, stored 16:00:25 local, 30.36 s long (round 226 check).
      final g = guessClipStart(
        fileName: 'VID_20260924_155954.mp4',
        storedMs: DateTime(2026, 9, 24, 16, 0, 25).millisecondsSinceEpoch,
        durationMs: 30360,
        now: now,
      );
      expect(g.source, 'file_name');
      expect(g.weak, isFalse);
      expect(g.epochMs, local.millisecondsSinceEpoch);
    });

    test('name and stored time far apart: keep the name, flag it', () {
      final g = guessClipStart(
        fileName: 'VID_20260924_155954.mp4',
        storedMs: local.add(const Duration(hours: 2, seconds: 30)).millisecondsSinceEpoch,
        durationMs: 30000,
        now: now,
      );
      expect(g.source, 'file_name');
      expect(g.weak, isTrue);
      expect(
        g.note,
        'From the file name: 2026-09-24 15:59:54. The time stored in the video gives 2026-09-24 17:59:54, '
        '2.0 h apart. Check the time (another time zone?).',
      );
    });

    test('an edited video: the name wins, the note says why the stored time is off (round 395)', () {
      // Stored 2026-11-10 12:25:56 (the day it was trimmed), 9.3 s long.
      final g = guessClipStart(
        fileName: 'VIDT05B01680_260612120338 - Trim.mp4',
        storedMs: DateTime(2026, 11, 10, 12, 25, 56).millisecondsSinceEpoch,
        durationMs: 9301,
        now: DateTime(2026, 11, 23),
      );
      expect((g.source, g.weak), ('file_name', true));
      expect(g.epochMs, DateTime(2026, 6, 12, 12, 3, 38).millisecondsSinceEpoch);
      expect(
        g.note,
        'From the file name: 2026-06-12 12:03:38. The time stored in the video gives 2026-11-10 12:25:46, '
        '151 days apart. An edited video (for example a trimmed one) stores when it was edited. Check the time.',
      );
    });

    test('the note says what the file name and the stored time gave (round 306)', () {
      String note(String name, {int? storedMs}) =>
          guessClipStart(fileName: name, storedMs: storedMs, durationMs: 30000, fileModifiedMs: 9, now: now).note;
      final stop = DateTime(2026, 9, 24, 16, 0, 24).millisecondsSinceEpoch;
      expect(note('VID_20260924_155954.mp4'), 'From the file name: 2026-09-24 15:59:54.');
      expect(
        note('VID_20260924_155954.mp4', storedMs: stop),
        'From the file name: 2026-09-24 15:59:54. The time stored in the video agrees.',
      );
      expect(
        note('IMG_1234.mp4', storedMs: stop),
        'The file name holds no date. From the time stored in the video (2026-09-24 16:00:24) minus the clip '
        'length. Phone cameras store when filming stopped; an edited video (for example a trimmed one) stores '
        'when it was edited.',
      );
      expect(
        note('VID-20260924-WA0005.mp4', storedMs: stop),
        startsWith('Only the day is read from the file name. From'),
      );
      expect(
        note('Screen Recording 2026-09-24 at 11.59.54 PM.mov', storedMs: stop),
        startsWith('Only the day is read from the file name. From'),
      );
      expect(
        note('VID-20260924-WA0005.mp4'),
        allOf(startsWith('Only the day is read from the file name ('), contains('noon')),
      );
      expect(
        note('clip.mp4'),
        'The file name holds no date; the video stores no time either, so this is when the file was copied '
        'into the app. Please set the time it was filmed.',
      );
      // A date the checks threw out (a camera clock set wrong) is not "no date".
      expect(
        note('VID_20270101_120000.mp4'),
        startsWith('The date in the file name is impossible or in the future; the video stores no time either'),
      );
      expect(
        note('Screen Recording 2026-02-30 at 12.00.00.mov', storedMs: stop),
        startsWith('The date in the file name is impossible or in the future. From the time stored'),
      );
    });

    test('no date in the name: stored stop time minus the clip length', () {
      final g = guessClipStart(fileName: 'IMG_1234.MOV', storedMs: 100000, durationMs: 30000, fileModifiedMs: 9, now: now);
      expect((g.epochMs, g.source, g.weak), (70000, 'metadata', false));
    });

    test('WhatsApp copy (no stored time): the day only, weak', () {
      final g = guessClipStart(fileName: 'VID-20260924-WA0005.mp4', durationMs: 30000, fileModifiedMs: 9, now: now);
      expect((g.source, g.weak), ('file_name_date', true));
      expect(g.epochMs, DateTime(2026, 9, 24, 12).millisecondsSinceEpoch);
    });

    test('nothing known: file time minus the clip length, weak', () {
      final g = guessClipStart(fileName: 'clip.mp4', durationMs: 30000, fileModifiedMs: 100000, now: now);
      expect((g.epochMs, g.source, g.weak), (70000, 'file_time', true));
    });

    test('the session log wins over everything', () {
      final g = guessClipStart(fileName: 'VID_20260924_155954.mp4', loggedMs: 42, storedMs: 100000, now: now);
      expect((g.epochMs, g.source), (42, 'session_log'));
    });
  });

  group('layOutClips', () {
    test('weakly timed clips of one day play one after the other', () {
      ClipStart wa(String n) => ClipStart(n, 10000, guessClipStart(fileName: n, durationMs: 10000, now: now));
      final out = layOutClips([wa('VID-20260924-WA0007.mp4'), wa('VID-20260924-WA0005.mp4'), wa('VID-20260924-WA0006.mp4')]);
      final noon = DateTime(2026, 9, 24, 12).millisecondsSinceEpoch;
      expect(out.map((c) => c.name), ['VID-20260924-WA0005.mp4', 'VID-20260924-WA0006.mp4', 'VID-20260924-WA0007.mp4']);
      expect(out.map((c) => c.startMs - noon), [0, 10000, 20000]);
      expect(out.map((c) => c.source), ['file_name_date', 'after_previous', 'after_previous']);
    });

    test('a clip the user set never moves (round 395)', () {
      ClipStart wa(String n, {int? setMs}) => ClipStart(
        n,
        10000,
        guessClipStart(fileName: n, durationMs: 10000, now: now),
        startMs: setMs,
        source: setMs == null ? null : 'user',
      );
      final noon = DateTime(2026, 9, 24, 12).millisecondsSinceEpoch;
      final out = layOutClips([wa('VID-20260924-WA0005.mp4'), wa('VID-20260924-WA0006.mp4', setMs: noon + 5000)]);
      expect(out.map((c) => c.startMs - noon), [0, 5000]);
      expect(out.map((c) => c.source), ['file_name_date', 'user']);
    });

    test('well-timed overlapping clips (two cameras) keep their times', () {
      ClipStart cam(String n) => ClipStart(n, 60000, guessClipStart(fileName: n, durationMs: 60000, now: now));
      final out = layOutClips([cam('VID_20260924_155954.mp4'), cam('20260924_160010.mp4')]);
      expect(out[1].startMs - out[0].startMs, 16000);
      expect(out.map((c) => c.source), ['file_name', 'file_name']);
    });
  });
}
