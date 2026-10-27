// Round 300: importing a FaunaLapse photo session (its "Pack" zips) as a FaunaPulse session.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  // Round 327: a zip that someone made by hand is user input. These are the ways such a zip
  // could fill the phone storage or the memory; FaunaLapse's own zips never do any of them.
  group('hand-made zips', () {
    String photoLine(String file, int ms) => jsonEncode({
      'event': 'photo',
      'time': DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String(),
      'file': file,
    });
    final t0 = DateTime.parse('2026-10-06T00:03:50.154+0200').millisecondsSinceEpoch;

    test('a photo named by many lines of the record is written once', () async {
      final log = [_log(), for (var i = 0; i < 50; i++) photoLine('20261006_000350_154.jpg', t0 + 1000 * (i + 10))];
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', log.join('\n')),
        _jpg('$_folder/20261006_000350_154.jpg'),
        _jpg('$_folder/20261006_000352_152.jpg'),
      ]);
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.photos, 2);
      expect(Directory('${root.path}/$_folder/roi_frames').listSync(), hasLength(2));
    });

    test('an entry that unpacks to more than the zip states is left out', () async {
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _jpg('$_folder/20261006_000350_154.jpg'),
        _jpg('$_folder/20261006_000352_152.jpg'),
      ]);
      z.writeAsBytesSync(_patchCentral(z.readAsBytesSync(), '$_folder/20261006_000352_152.jpg', size: 10));
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.photos, 1);
      expect(r.damagedPhotos, 1);
    });

    test('a photo whose header claims more than the pixel limit is left out', () async {
      final huge = img.encodeJpg(img.Image(width: 32, height: 32));
      final sof = [for (var i = 0; i + 1 < huge.length; i++) if (huge[i] == 0xFF && huge[i + 1] == 0xC0) i].first;
      for (final at in [sof + 5, sof + 7]) {
        huge[at] = 30000 >> 8;
        huge[at + 1] = 30000 & 0xff;
      }
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _jpg('$_folder/20261006_000350_154.jpg'),
        ArchiveFile.bytes('$_folder/20261006_000352_152.jpg', huge),
      ]);
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.photos, 1);
      expect(r.damagedPhotos, 1);
    });

    test('a site photo whose path is also a folder is left out, the rest imports', () async {
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _jpg('$_folder/20261006_000350_154.jpg'),
        _jpg('$_folder/site_photos/a'),
        _jpg('$_folder/site_photos/a/b.jpg'),
      ]);
      final r = await importFaunaLapseZips([z.path], root);
      expect((r.photos, r.sitePhotos, r.damagedSitePhotos), (1, 1, 1));
    });

    test('an entry that is not a photo is left out', () async {
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _jpg('$_folder/20261006_000350_154.jpg'),
        ArchiveFile.bytes('$_folder/20261006_000352_152.jpg', List.filled(4096, 0)),
      ]);
      final r = await importFaunaLapseZips([z.path], root);
      expect((r.photos, r.damagedPhotos), (1, 1));
    });

    test('a record above the size limit is refused before it is unpacked', () async {
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _jpg('$_folder/20261006_000350_154.jpg'),
      ]);
      z.writeAsBytesSync(_patchCentral(z.readAsBytesSync(), '$_folder/session.jsonl', size: 300 << 20));
      await expectLater(
        importFaunaLapseZips([z.path], root),
        throwsA(isA<FaunaLapseImportError>().having((e) => e.message, 'message', contains('too large to import'))),
      );
      expect(Directory('${root.path}/$_folder').existsSync(), isFalse);
    });

    test('a record or site photo that does not match its checksum is not used', () async {
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _jpg('$_folder/20261006_000350_154.jpg'),
        _jpg('$_folder/site_photos/20261005_185000_000.jpg'),
      ]);
      final good = z.readAsBytesSync();
      z.writeAsBytesSync(_patchCentral(Uint8List.fromList(good), '$_folder/site_photos/20261005_185000_000.jpg', crc: 1));
      final r = await importFaunaLapseZips([z.path], root);
      expect((r.photos, r.sitePhotos, r.damagedSitePhotos), (1, 0, 1));
      expect(Directory('${root.path}/$_folder/site_photos').listSync(), isEmpty);
      Directory('${root.path}/$_folder').deleteSync(recursive: true);
      z.writeAsBytesSync(_patchCentral(Uint8List.fromList(good), '$_folder/session.jsonl', crc: 1));
      await expectLater(
        importFaunaLapseZips([z.path], root),
        throwsA(isA<FaunaLapseImportError>().having((e) => e.message, 'message', contains('damaged'))),
      );
    });

    test('a negative stated size cannot slip past the free-storage check', () async {
      // A zip64 size of 2^64 - 64 GiB reads as -64 GiB; added to the need, it hid the photos.
      final z = File('${tmp.path}/neg.zip')
        ..writeAsBytesSync(_streamedZip64(
          {
            '$_folder/session.jsonl': utf8.encode(_log()),
            '$_folder/20261006_000350_154.jpg': List.filled(1 << 20, 0),
            '$_folder/site_photos/neg.jpg': List.filled(16, 0),
          },
          statedSize64: {'$_folder/site_photos/neg.jpg': -(64 << 30)},
        ));
      await expectLater(
        importFaunaLapseZips([z.path], root, freeBytes: 30 << 20),
        throwsA(isA<FaunaLapseImportError>().having((e) => e.message, 'message', contains('Not enough free storage'))),
      );
      final r = await importFaunaLapseZips([z.path], root);
      expect((r.sitePhotos, r.damagedSitePhotos), (0, 1));
    });

    test('an import that does not fit the free storage is refused before writing', () async {
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _jpg('$_folder/20261006_000350_154.jpg'),
      ]);
      await expectLater(
        importFaunaLapseZips([z.path], root, freeBytes: 40 << 20),
        throwsA(isA<FaunaLapseImportError>().having((e) => e.message, 'message', contains('Not enough free storage'))),
      );
      expect(root.listSync(), isEmpty);
      expect((await importFaunaLapseZips([z.path], root, freeBytes: 60 << 20)).photos, 1);
    });

    test('a record line longer than any FaunaLapse line is refused before it is read', () async {
      // One line of 1 MB of "[": the JSON reader would build a list for every bracket (a
      // 63 MB line used 3.3 GB).
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', '${_log()}\n${'[' * (1 << 20)}\n'),
        _jpg('$_folder/20261006_000350_154.jpg'),
      ]);
      await expectLater(
        importFaunaLapseZips([z.path], root),
        throwsA(isA<FaunaLapseImportError>().having((e) => e.message, 'message', contains('line over'))),
      );
    });

    test('a zip written as a stream with 64-bit sizes (zip64) imports every photo', () async {
      final z = File('${tmp.path}/stream64.zip')
        ..writeAsBytesSync(_streamedZip64({
          '$_folder/session.jsonl': utf8.encode(_log()),
          '$_folder/20261006_000350_154.jpg': img.encodeJpg(img.Image(width: 32, height: 32)),
          '$_folder/20261006_000352_152.jpg': img.encodeJpg(img.Image(width: 32, height: 32)),
        }));
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.photos, 2);
      expect(r.damagedPhotos, 0);
    });

    test('the session folder name is cleaned like a typed session name', () async {
      const odd = ' .odd"name';
      final z = _zip(tmp, 'a.zip', [
        ArchiveFile.string('$odd/session.jsonl', _log()),
        _jpg('$odd/20261006_000350_154.jpg'),
      ]);
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.folder, '_odd_name');
      expect(r.photos, 1);
      final start = jsonDecode(File('${root.path}/_odd_name/session.jsonl').readAsLinesSync().first) as Map;
      expect((start['faunalapse'] as Map)['folder'], odd);
      expect((start['config'] as Map)['folderName'], '_odd_name');
    });
  });
}

/// [zip] with the unpacked [size] that its central directory states for [name] changed (the
/// import reads the size there), or the [crc] in both of its headers.
Uint8List _patchCentral(Uint8List zip, String name, {int? size, int? crc}) {
  final b = ByteData.sublistView(zip);
  final want = utf8.encode(name);
  for (var i = 0; crc != null && i + 30 <= zip.length; i++) {
    if (b.getUint32(i, Endian.little) != 0x04034b50) continue;
    final n = b.getUint16(i + 26, Endian.little);
    if (n == want.length && String.fromCharCodes(zip.sublist(i + 30, i + 30 + n)) == name) {
      b.setUint32(i + 14, crc, Endian.little);
    }
  }
  for (var i = 0; i + 46 <= zip.length; i++) {
    if (b.getUint32(i, Endian.little) != 0x02014b50) continue;
    final n = b.getUint16(i + 28, Endian.little);
    if (n == want.length && String.fromCharCodes(zip.sublist(i + 46, i + 46 + n)) == name) {
      if (crc != null) b.setUint32(i + 16, crc, Endian.little);
      if (size != null) b.setUint32(i + 24, size, Endian.little);
      return zip;
    }
  }
  throw StateError('no central directory entry for $name');
}

/// A zip as tools write it to a stream with 64-bit sizes (Python's zipfile with zip64, for
/// example): stored entries, sizes unknown in the local header (0xFFFFFFFF plus a zip64 extra
/// field) and given after the data in a descriptor with 8-byte sizes; the central directory
/// holds the real sizes, or for a name in [statedSize64] that 64-bit size in its own zip64
/// field (as a hand-made zip could state any size).
Uint8List _streamedZip64(Map<String, List<int>> files, {Map<String, int> statedSize64 = const {}}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  ByteData le(int n) => ByteData(n);
  for (final MapEntry(key: name, value: data) in files.entries) {
    final offset = out.length;
    final crc = getCrc32(data);
    final nameBytes = utf8.encode(name);
    final local = le(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 45, Endian.little)
      ..setUint16(6, 0x0008, Endian.little) // sizes follow the data
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 20, Endian.little)
      ..setUint32(18, 0xffffffff, Endian.little)
      ..setUint32(22, 0xffffffff, Endian.little);
    final extra = le(20)
      ..setUint16(0, 1, Endian.little)
      ..setUint16(2, 16, Endian.little);
    final descriptor = le(24)
      ..setUint32(0, 0x08074b50, Endian.little)
      ..setUint32(4, crc, Endian.little)
      ..setUint64(8, data.length, Endian.little)
      ..setUint64(16, data.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(nameBytes)
      ..add(extra.buffer.asUint8List())
      ..add(data)
      ..add(descriptor.buffer.asUint8List());
    final stated = statedSize64[name];
    final cd = le(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 45, Endian.little)
      ..setUint16(6, 45, Endian.little)
      ..setUint16(8, 0x0008, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, stated == null ? data.length : 0xffffffff, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint16(30, stated == null ? 0 : 12, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(cd.buffer.asUint8List())
      ..add(nameBytes);
    if (stated != null) {
      central.add(
        (le(12)
              ..setUint16(0, 1, Endian.little)
              ..setUint16(2, 8, Endian.little)
              ..setInt64(4, stated, Endian.little))
            .buffer
            .asUint8List(),
      );
    }
  }
  final cdOffset = out.length;
  final cdBytes = central.takeBytes();
  final end = le(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, cdBytes.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  return (out
        ..add(cdBytes)
        ..add(end.buffer.asUint8List()))
      .takeBytes();
}
