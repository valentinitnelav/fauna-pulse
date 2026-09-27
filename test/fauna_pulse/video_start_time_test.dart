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

    test('Pixel names are UTC', () {
      final r = startFromFileName('PXL_20260924_135954123.mp4', now: now)!;
      expect(r.time, DateTime.utc(2026, 9, 24, 13, 59, 54));
    });

    test('WhatsApp names give only the day, at noon', () {
      final r = startFromFileName('VID-20260924-WA0005.mp4', now: now)!;
      expect(r.dateOnly, isTrue);
      expect(r.time, DateTime(2026, 9, 24, 12));
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
      expect(g.note, contains('2.0 h'));
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

    test('well-timed overlapping clips (two cameras) keep their times', () {
      ClipStart cam(String n) => ClipStart(n, 60000, guessClipStart(fileName: n, durationMs: 60000, now: now));
      final out = layOutClips([cam('VID_20260924_155954.mp4'), cam('20260924_160010.mp4')]);
      expect(out[1].startMs - out[0].startMs, 16000);
      expect(out.map((c) => c.source), ['file_name', 'file_name']);
    });
  });
}
