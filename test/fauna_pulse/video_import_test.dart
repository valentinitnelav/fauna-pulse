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

  test('a start the user set is logged with what was read; the other clip keeps its own (round 395)', () async {
    final dir = await importVideos(
      sessionsDir: sessions,
      sessionName: 'wa',
      clips: [clip('VID-20260924-WA0006.mp4', durationMs: 10000), clip('VID-20260924-WA0005.mp4', durationMs: 10000)],
      setMs: {0: DateTime(2026, 9, 24, 9).millisecondsSinceEpoch},
    );
    final recs = records(dir);
    final clips = recs.where((r) => r['type'] == 'video_clip').toList();
    final nine = DateTime(2026, 9, 24, 9).millisecondsSinceEpoch;
    final noon = DateTime(2026, 9, 24, 12).millisecondsSinceEpoch;
    expect(clips.map((r) => r['original_name']), ['VID-20260924-WA0006.mp4', 'VID-20260924-WA0005.mp4']);
    expect(clips.map((r) => r['start_epoch_ms']), [nine, noon]);
    expect(clips.map((r) => r['start_time_source']), ['user', 'file_name_date']);
    expect(clips.first['start_time_guess_source'], 'file_name_date');
    expect(clips.first['start_time_guess_ms'], noon);
    expect(clips.first.containsKey('start_time_weak'), isFalse);
    expect(clips.last['start_time_weak'], isTrue);
    expect(recs.first['video']['starts_set_by_user'], 1);
    expect(recs.first['time_ms'], nine);
  });

  test("the owner's three clips: setting one start moves no other clip into the future (round 395)", () {
    // One clip with an editor's stored time, two with only the copy time.
    final copied = DateTime(2026, 11, 22, 19, 47).millisecondsSinceEpoch;
    ImportClip c(String name, int durationMs, {int? storedMs}) => ImportClip(
      path: '${cache.path}/$name',
      name: name,
      sizeBytes: 1,
      info: VideoInfo(durationMs: durationMs, creationEpochMs: storedMs),
      guess: guessClipStart(
        fileName: name,
        storedMs: storedMs,
        durationMs: durationMs,
        fileModifiedMs: copied,
        now: DateTime(2026, 11, 22, 19, 48),
      ),
    );
    final clips = [
      c('VIDT05B01680_260612120338 - Trim.mp4', 9301, storedMs: DateTime(2026, 11, 10, 12, 25, 56).millisecondsSinceEpoch),
      c('14112024_ipomoea_video34.mp4', 360360),
      c('Pumpkin1080_square_realtime.mp4', 38372),
    ];
    Map<int, int> starts(List<ClipStart> plan) => {for (final p in plan) p.index: p.startMs};
    final read = starts(planImport(clips));
    expect(read[0], DateTime(2026, 6, 12, 12, 3, 38).millisecondsSinceEpoch); // from the name
    final set = DateTime(2026, 11, 22, 19, 44).millisecondsSinceEpoch;
    final after = starts(planImport(clips, setMs: {0: set}));
    expect(after, {0: set, 1: read[1], 2: read[2]});
    expect(after.values.every((ms) => ms <= copied), isTrue);
  });

  // Round 252: MP4 boxes are a 4-byte big-endian size, then a 4-letter type.
  List<int> box(String type, int payload) => [
    ...[24, 16, 8, 0].map((b) => ((payload + 8) >> b) & 0xff),
    ...type.codeUnits,
    ...List.filled(payload, 0),
  ];

  test('fragmented MP4s are found by their moof boxes', () {
    File write(String name, List<int> bytes) => File('${tmp.path}/$name')..writeAsBytesSync(bytes);
    expect(isFragmentedMp4(write('frag.mp4', [...box('ftyp', 8), ...box('moov', 16), ...box('moof', 8), ...box('mdat', 32)])), isTrue);
    expect(isFragmentedMp4(write('plain.mp4', [...box('ftyp', 8), ...box('mdat', 32), ...box('moov', 16)])), isFalse);
    expect(isFragmentedMp4(write('other.mkv', [0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0])), isFalse);
    // Round 327: the check stops after 10,000 boxes. A hand-made file of millions of empty
    // boxes would freeze the import screen for minutes; real files reach moov or moof within a few.
    final many = [...box('ftyp', 8), for (var i = 0; i < 10000; i++) ...box('free', 0), ...box('moof', 8)];
    expect(isFragmentedMp4(write('many.mp4', many)), isFalse);
    expect(isFragmentedMp4(write('few.mp4', [...box('ftyp', 8), for (var i = 0; i < 100; i++) ...box('free', 0), ...box('moof', 8)])), isTrue);
  });

  test('a fragmented clip is rewritten into videos/ and logged as such', () async {
    final c = clip('Pollinators (1080p, h264).mp4');
    final frag = ImportClip(path: c.path, name: c.name, sizeBytes: c.sizeBytes, info: c.info, guess: c.guess, fragmented: true);
    final calls = <(String, String)>[];
    final dir = await importVideos(
      sessionsDir: sessions,
      sessionName: 'yt',
      clips: [frag, clip('VID_20260924_155954.mp4')],
      remux: (src, dst) async {
        calls.add((src, dst));
        File(dst).writeAsStringSync('rewritten, a little longer');
        return {'bytes': File(dst).lengthSync(), 'elapsedMs': 7, 'maxPtsErrorUs': 439, 'droppedTracks': <String>[]};
      },
    );
    expect(calls, hasLength(1)); // only the fragmented clip
    expect(calls.single.$2, endsWith('/videos/Pollinators__1080p__h264_.mp4.part'));
    expect(File('${dir.path}/videos/Pollinators__1080p__h264_.mp4').readAsStringSync(), 'rewritten, a little longer');
    expect(Directory('${dir.path}/videos').listSync().where((f) => f.path.endsWith('.part')), isEmpty);
    expect(cache.listSync(), isEmpty); // the picker's copy is gone
    final recs = records(dir);
    final yt = recs.firstWhere((r) => r['original_name'] == 'Pollinators (1080p, h264).mp4');
    expect(yt['rewritten_from'], 'fragmented_mp4');
    expect(yt['size_bytes'], 26);
    expect(yt['original_size_bytes'], c.sizeBytes);
    expect(yt['rewrite_ms'], 7);
    expect(yt['rewrite_max_time_error_us'], 439);
    expect(yt.containsKey('rewrite_dropped_tracks'), isFalse);
    final plain = recs.firstWhere((r) => r['original_name'] == 'VID_20260924_155954.mp4');
    expect(plain.containsKey('rewritten_from'), isFalse);
  });

  test('a failed rewrite fails the import and leaves no clip file', () async {
    final c = clip('frag.mp4');
    final frag = ImportClip(path: c.path, name: c.name, sizeBytes: c.sizeBytes, info: c.info, guess: c.guess, fragmented: true);
    await expectLater(
      importVideos(sessionsDir: sessions, sessionName: 'bad', clips: [frag], remux: (_, _) async => throw StateError('frame times moved')),
      throwsA(
        isA<ImportRewriteFailed>().having(
          (e) => '$e',
          'message',
          allOf(contains('"frag.mp4" could not'), contains('frame times moved'), contains('ffmpeg -i "frag.mp4" -c copy "frag plain.mp4"')),
        ),
      ),
    );
    expect(Directory('${sessions.path}/bad').existsSync(), isFalse); // no half session
    expect(File(c.path).existsSync(), isTrue); // the picked copy stays until the picker cache is cleared
  });

  test('files the analysis cannot read are flagged', () {
    expect(clip('a.avi').problem, contains('Not a supported'));
    expect(clip('a.mp4').problem, isNull);
  });

  test('default name uses the import day (round 395)', () {
    expect(defaultImportName(DateTime(2026, 9, 4, 23)), 'video_20260904');
  });

  test('saved names: spaces and signs become _, a repeated name gets _2', () {
    final plan = planImport([clip('my clip (1).mp4', dir: 'a'), clip('my clip (1).mp4', dir: 'b'), clip('ok.mp4')]);
    expect(clipFileNames(plan).values.toSet(), {'my_clip__1_.mp4', 'my_clip__1__2.mp4', 'ok.mp4'});
  });

  test('saved names: a picked name that looks like a numbered one is never given twice (round 403)', () {
    // In plan order a.mp4 three times, then a_2.mp4, whose own name the second a.mp4 took.
    final plan = planImport([
      clip('a.mp4', dir: 'x'),
      clip('a.mp4', dir: 'y'),
      clip('a_2.mp4'),
      clip('a.mp4', dir: 'z'),
    ]);
    expect(clipFileNames(plan).values.toSet(), {'a.mp4', 'a_2.mp4', 'a_3.mp4', 'a_2_2.mp4'});
  });

  test('the session folder: a taken name gets the next free number, as the import uses it (round 403)', () {
    final sessions = Directory('${cache.path}/sessions');
    expect(freeSessionDir(sessions, 'trip').path, '${sessions.path}/trip');
    Directory('${sessions.path}/trip').createSync(recursive: true);
    Directory('${sessions.path}/trip_2').createSync();
    expect(freeSessionDir(sessions, ' trip ').path, '${sessions.path}/trip_3');
    expect(freeSessionDir(sessions, 'my trip!').path, '${sessions.path}/my trip_');
    expect(freeSessionDir(sessions, '').path, '${sessions.path}/video');
  });
}
