import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoInfo;

void main() {
  late Directory tmp, cache, sessions;
  final now = DateTime(2026, 9, 24, 18);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('video_import_test');
    cache = Directory('${tmp.path}/cache')..createSync();
    sessions = Directory('${tmp.path}/sessions')..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ImportClip clip(String name, {int durationMs = 30000, int? storedMs, String? dir}) {
    final f = File('${cache.path}/${dir ?? ''}${dir == null ? '' : '/'}$name')
      ..createSync(recursive: true)
      ..writeAsStringSync('video $name');
    final info = VideoInfo(durationMs: durationMs, width: 1920, height: 1080, mime: 'video/avc', frameCount: 900, creationEpochMs: storedMs);
    return ImportClip(
      path: f.path,
      name: name,
      sizeBytes: f.lengthSync(),
      info: info,
      guess: guessClipStart(fileName: name, storedMs: storedMs, durationMs: durationMs, fileModifiedMs: 1, now: now),
    );
  }

  List<Map<String, dynamic>> records(Directory d) => File('${d.path}/session.jsonl')
      .readAsLinesSync()
      .map((l) => (jsonDecode(l) as Map).cast<String, dynamic>())
      .toList();

  test('moves the clips in and logs start, one record per clip, and a clean end', () async {
    final dir = await importVideos(
      sessionsDir: sessions,
      sessionName: 'Meadow 1',
      clips: [clip('VID_20260924_160100.mp4'), clip('VID_20260924_155954.mp4')],
      startExtras: {'app_version': '1.0'},
    );
    expect(dir.path.split('/').last, 'Meadow 1');
    expect(VideoDetector.clipsOf(dir).map((f) => f.path.split('/').last), ['VID_20260924_155954.mp4', 'VID_20260924_160100.mp4']);
    expect(cache.listSync(), isEmpty); // moved, not copied

    final recs = records(dir);
    expect(recs.map((r) => r['type']), ['start_of_session', 'video_clip', 'video_clip', 'end_of_session']);
    final t0 = DateTime(2026, 9, 24, 15, 59, 54).millisecondsSinceEpoch;
    expect(recs[0]['time_ms'], t0);
    expect(recs[0]['source'], 'imported_video');
    expect(recs[0]['app_version'], '1.0');
    expect(recs[0]['video']['clips'], 2);
    expect(recs[1]['file'], 'videos/VID_20260924_155954.mp4');
    expect(recs[1]['start_time_source'], 'file_name');
    expect(recs[3]['time_ms'], DateTime(2026, 9, 24, 16, 1, 30).millisecondsSinceEpoch);
    expect(recs[3]['ended_normally'], isTrue);

    // The analysis pass reads these start times back.
    expect(await VideoDetector.clipStartsFromLog(dir), {'VID_20260924_155954.mp4': t0, 'VID_20260924_160100.mp4': t0 + 66000});
  });

  test('a taken session name gets a suffix; clashing and odd file names are made safe', () async {
    Directory('${sessions.path}/trip').createSync();
    final dir = await importVideos(
      sessionsDir: sessions,
      sessionName: 'trip',
      clips: [clip('my clip (1).mp4', dir: 'a'), clip('my clip (1).mp4', dir: 'b')],
    );
    expect(dir.path.split('/').last, 'trip_2');
    final names = records(dir).where((r) => r['type'] == 'video_clip').map((r) => r['file']).toList();
    expect(names, ['videos/my_clip__1_.mp4', 'videos/my_clip__1__2.mp4']);
    expect(names.every((n) => File('${dir.path}/$n').existsSync()), isTrue);
  });

  test('a corrected start shifts every clip and is logged as the user\'s', () async {
    final dir = await importVideos(
      sessionsDir: sessions,
      sessionName: 'wa',
      clips: [clip('VID-20260924-WA0006.mp4', durationMs: 10000), clip('VID-20260924-WA0005.mp4', durationMs: 10000)],
      shiftMs: -3 * 3600 * 1000, // noon guess → 09:00
    );
    final clips = records(dir).where((r) => r['type'] == 'video_clip').toList();
    final nine = DateTime(2026, 9, 24, 9).millisecondsSinceEpoch;
    expect(clips.map((r) => r['start_epoch_ms']), [nine, nine + 10000]);
    expect(clips.map((r) => r['start_time_source']), ['user', 'user']);
    expect(clips.map((r) => r['start_time_guess_source']), ['file_name_date', 'file_name_date']);
    expect(clips.first['start_time_shift_ms'], -3 * 3600 * 1000);
  });

  test('files the analysis cannot read are flagged', () {
    expect(clip('a.avi').problem, contains('Not a supported'));
    expect(clip('a.mp4').problem, isNull);
  });

  test('default name uses the first clip\'s day', () {
    expect(defaultImportName(DateTime(2026, 9, 4, 23).millisecondsSinceEpoch), 'video_20260904');
  });
}
