// Round 300: importing a FaunaLapse photo session (its "Pack" zips) as a FaunaPulse session.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/faunalapse_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _folder = '1DFFC454_20261006_000345_photo';

String _log({String mode = 'photo'}) => [
  {
    'event': 'session_start',
    'time': '2026-10-06T00:03:45.210+0200',
    'field': {
      'phone_maker': 'samsung', 'phone_model': 'SM-M127F', 'site': 'Some site', 'plant': 'Geranium sp.',
      'custom': {'Choices': 'Choice 1'},
      'location': {'latitude': 51.333168, 'longitude': 12.410124, 'datum': 'WGS 84', 'source': 'gps',
        'coordinate_uncertainty_m': 9, 'fix_time': '2026-10-05T18:50:20.000+0200'},
      'site_photos': ['20261005_185000_000.jpg'],
    },
    'settings': {'mode': mode, 'photo_step_s': 2, 'burst_s': 60, 'break_min': 5, 'saved_side_px': 1280, 'run_min': 60},
    'phone_state': {'airplane_mode': true},
    'app_version': '0.1.0-alpha.1',
  },
  {'event': 'burst_start', 'time': '2026-10-06T00:03:47.150+0200'},
  {'event': 'photo', 'time': '2026-10-06T00:03:50.154+0200', 'file': '20261006_000350_154.jpg', 'saved_side_px': 1280},
  {'event': 'photo', 'time': '2026-10-06T00:03:52.152+0200', 'file': '20261006_000352_152.jpg', 'saved_side_px': 1280},
  {'event': 'photo', 'time': '2026-10-06T00:03:54.152+0200', 'file': '20261006_000354_152.jpg', 'error': 'disk full'},
  {'event': 'session_end', 'time': '2026-10-06T01:03:50.000+0200', 'reason': 'schedule finished'},
].map(jsonEncode).join('\n');

ArchiveFile _jpg(String name) =>
    ArchiveFile.bytes(name, img.encodeJpg(img.Image(width: 32, height: 32)));

File _zip(Directory dir, String name, List<ArchiveFile> files) {
  final a = Archive();
  for (final f in files) {
    a.add(f);
  }
  return File('${dir.path}/$name')..writeAsBytesSync(ZipEncoder().encode(a));
}

void main() {
  late Directory tmp;
  late Directory root;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fl_import');
    root = Directory('${tmp.path}/sessions')..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the record: start, photos (errors dropped) and end', () {
    final log = parseFaunaLapseLog(const LineSplitter().convert(_log()))!;
    expect(log.photos.map((p) => p.file), ['20261006_000350_154.jpg', '20261006_000352_152.jpg']);
    expect(log.photos.first.burst, 0);
    expect(log.isVideo, isFalse);
    expect(log.endMs, DateTime.parse('2026-10-06T01:03:50.000+0200').millisecondsSinceEpoch);
    expect(parseFaunaLapseLog(['{"type":"start_of_session"}']), isNull);
    final config = faunaLapseConfig(log, _folder);
    expect(config.stepSeconds, 2);
    expect(config.timeLapseGapSeconds, 300);
    expect(config.targetRoiSavedPx, 1280);
    expect(faunaLapseLocation(log.start)!['accuracy_m'], 9.0);
  });

  test('two part zips become one time-lapse session that FaunaPulse reads', () async {
    final z1 = _zip(tmp, '$_folder.zip', [
      ArchiveFile.string('$_folder/session.jsonl', _log()),
      _jpg('$_folder/20261006_000350_154.jpg'),
      _jpg('$_folder/site_photos/20261005_185000_000.jpg'),
    ]);
    final z2 = _zip(tmp, '${_folder}_part2.zip', [_jpg('$_folder/20261006_000352_152.jpg')]);
    final r = await importFaunaLapseZips([z1.path, z2.path], root);
    expect(r.folder, _folder);
    expect(r.photos, 2);
    expect(r.missingPhotos, 0);
    expect(r.sitePhotos, 1);
    final dir = Directory('${root.path}/$_folder');
    expect(File('${dir.path}/faunalapse_session.jsonl').existsSync(), isTrue);
    expect(File('${dir.path}/site_photos/20261005_185000_000.jpg').existsSync(), isTrue);
    final recs = [for (final l in File('${dir.path}/session.jsonl').readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
    final start = recs.first;
    expect(start['type'], 'start_of_session');
    expect(start['source'], 'faunalapse');
    expect(start['time_ms'], DateTime.parse('2026-10-06T00:03:45.210+0200').millisecondsSinceEpoch);
    expect((start['field'] as Map)['plant'], 'Geranium sp.');
    expect((start['location'] as Map)['lat'], 51.333168);
    final caps = recs.where((r) => r['type'] == 'timelapse_capture').toList();
    expect(caps, hasLength(2));
    expect(File('${dir.path}/roi_frames/${caps.first['jpeg']}').existsSync(), isTrue);
    expect(caps.first['captured_at_ms'], DateTime.parse('2026-10-06T00:03:50.154+0200').millisecondsSinceEpoch);
    expect(recs.last['type'], 'end_of_session');
    expect(recs.last['ended_normally'], isTrue);

    final listed = await scanPastSessions(root: root);
    expect(listed.single.kind, RecordingKind.timeLapse);
    final index = await SessionLogIndex.build(File('${dir.path}/session.jsonl'));
    expect(index.photoOrder, hasLength(2));
  });

  test('missing photos are counted; video sessions and repeats are refused', () async {
    final z = _zip(tmp, 'a.zip', [ArchiveFile.string('$_folder/session.jsonl', _log())]);
    final r = await importFaunaLapseZips([z.path], root);
    expect(r.photos, 0);
    expect(r.missingPhotos, 2);
    await expectLater(importFaunaLapseZips([z.path], root), throwsA(isA<FaunaLapseImportError>()));
    final v = _zip(tmp, 'v.zip', [ArchiveFile.string('X_video/session.jsonl', _log(mode: 'video'))]);
    await expectLater(
      importFaunaLapseZips([v.path], root),
      throwsA(isA<FaunaLapseImportError>().having((e) => e.message, 'message', contains('Import videos'))),
    );
    final none = _zip(tmp, 'n.zip', [_jpg('x.jpg')]);
    await expectLater(importFaunaLapseZips([none.path], root), throwsA(isA<FaunaLapseImportError>()));
  });
}
