// Stress test (2026-10-20): importing FaunaLapse "Pack" zips with hostile or broken content.
// Checks that a zip can never write outside the new session folder, that a failed import
// leaves nothing behind (a half-made folder blocks the next try with "already here"), and
// that broken input gives a plain-language FaunaLapseImportError instead of a raw Dart error.
// Cases marked skip: 'BUG: ...' show real bugs; run with --run-skipped to see them fail.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/faunalapse_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _folder = '1DFFC454_20261006_000345_photo';

Map<String, dynamic> _start({Object? settings, Object? field, Object? time}) => {
  'event': 'session_start',
  'time': time ?? '2026-10-06T00:03:45.210+0200',
  'field': field ??
      {
        'phone_maker': 'samsung',
        'phone_model': 'SM-M127F',
        'location': {'latitude': 51.333168, 'longitude': 12.410124, 'source': 'gps', 'coordinate_uncertainty_m': 9},
      },
  'settings': settings ?? {'mode': 'photo', 'photo_step_s': 2, 'burst_s': 60, 'break_min': 5, 'saved_side_px': 1280, 'run_min': 60},
  'app_version': '0.1.0-alpha.1',
};

String _photoName(int i) => 'p_${i.toString().padLeft(5, '0')}.jpg';

/// A FaunaLapse record with [photos] photos, 2 s apart, named by [_photoName].
String _log({Map<String, dynamic>? start, int photos = 2, List<Map<String, dynamic>> extra = const []}) {
  final t0 = DateTime.parse('2026-10-06T00:03:50.154+0200');
  return [
    start ?? _start(),
    {'event': 'burst_start', 'time': '2026-10-06T00:03:47.150+0200'},
    for (var i = 0; i < photos; i++)
      {
        'event': 'photo',
        'time': t0.add(Duration(seconds: 2 * i)).toUtc().toIso8601String(),
        'file': _photoName(i),
        'saved_side_px': 1280,
      },
    ...extra,
    {'event': 'session_end', 'time': '2026-10-06T01:03:50.000+0200', 'reason': 'schedule finished'},
  ].map(jsonEncode).join('\n');
}

/// Small fake photo bytes: the import copies bytes, it never decodes the JPEG.
// A real (tiny) JPEG: since round 327 the import leaves out entries that are not JPEG photos.
ArchiveFile _photo(String name, int i) => ArchiveFile.bytes(
  name,
  img.encodeJpg(img.fill(img.Image(width: 8, height: 8), color: img.ColorRgb8(i & 0xFF, (i >> 8) & 0xFF, 0))),
);

File _zip(Directory dir, String name, List<ArchiveFile> files) {
  final a = Archive();
  for (final f in files) {
    a.add(f);
  }
  return File('${dir.path}/$name')..writeAsBytesSync(ZipEncoder().encode(a));
}

/// Every file under [dir] (relative paths), sorted.
List<String> _tree(Directory dir) =>
    [for (final e in dir.listSync(recursive: true, followLinks: false)) if (e is File) e.path.substring(dir.path.length + 1)]..sort();

void main() {
  late Directory tmp; // holds base/ (sessions + a sibling) and zips/
  late Directory base;
  late Directory root;
  late Directory zips;
  late File canary;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fl_import_stress');
    base = Directory('${tmp.path}/base')..createSync();
    root = Directory('${base.path}/sessions')..createSync();
    zips = Directory('${tmp.path}/zips')..createSync();
    canary = File('${base.path}/sibling/keep.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('untouched');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Asserts that nothing outside `sessions/<_folder>/` changed: only the zips we wrote,
  /// the canary, and the files inside the new session folder exist.
  void expectNothingOutsideSession(List<String> zipNames) {
    final outside = _tree(tmp).where((p) => !p.startsWith('base/sessions/$_folder/')).toList();
    expect(
      outside,
      unorderedEquals(['base/sibling/keep.txt', for (final z in zipNames) 'zips/$z']),
      reason: 'sibling/keep.txt now holds "${canary.readAsStringSync()}"',
    );
    expect(canary.readAsStringSync(), 'untouched');
  }

  group('zip paths cannot escape the session folder', () {
    test('site_photos entries with ../ stay inside the new session folder', () async {
      final names = [
        '$_folder/site_photos/../../../evil1.txt', // dir/site_photos/../../.. = base/
        '$_folder/site_photos/../../../../evil2.txt', // = tmp/
        '$_folder/site_photos/../../../sibling/keep.txt', // overwrite a sibling's file
        '$_folder/site_photos/sub/../../../../evil3.txt',
      ];
      final z = _zip(zips, 'a.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _photo('$_folder/${_photoName(0)}', 0),
        _photo('$_folder/${_photoName(1)}', 1),
        for (final n in names) ArchiveFile.string(n, 'EVIL'),
      ]);
      // The zip really holds the ../ names (the encoder did not clean them).
      final decoded = ZipDecoder().decodeBytes(z.readAsBytesSync()).files.map((f) => f.name).toList();
      expect(decoded, containsAll(names));
      try {
        await importFaunaLapseZips([z.path], root);
      } on FaunaLapseImportError {
        // Refusing the zip is a fine answer too; writing outside is not.
      }
      expectNothingOutsideSession(['a.zip']);
    });

    test('absolute paths, backslashes and a ../ photo name in the log write nothing outside', () async {
      final z = _zip(zips, 'b.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log(extra: [
          {'event': 'photo', 'time': '2026-10-06T00:10:00.000+0200', 'file': '../../sibling/keep.txt'},
        ])),
        _photo('$_folder/${_photoName(0)}', 0),
        _photo('$_folder/${_photoName(1)}', 1),
        ArchiveFile.string('/${tmp.path}/base/abs_evil.txt', 'EVIL'),
        ArchiveFile.string('$_folder/site_photos//abs_evil2.txt', 'EVIL'),
        ArchiveFile.string('$_folder\\site_photos\\..\\..\\..\\bs_evil.txt', 'EVIL'),
        ArchiveFile.string('$_folder/site_photos/..\\..\\..\\bs_evil2.txt', 'EVIL'),
      ]);
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.photos, 2);
      expectNothingOutsideSession(['b.zip']);
    });

    // Round 327: the folder name is cleaned like a typed session name, and a name without a
    // letter or digit becomes "faunalapse", so these import under a plain name.
    test('a session folder named .. or . gets a plain name and writes nothing outside it', () async {
      for (final (f, clean) in [('..', 'faunalapse'), ('.', 'faunalapse')]) {
        final z = _zip(zips, 'dots.zip', [
          ArchiveFile.string('$f/session.jsonl', _log()),
          _photo('$f/${_photoName(0)}', 0),
          ArchiveFile.string('$f/site_photos/x.jpg', 'X'),
        ]);
        final r = await importFaunaLapseZips([z.path], root);
        expect(r.folder, clean);
        final outside = _tree(tmp).where((p) => !p.startsWith('base/sessions/$clean/')).toList();
        expect(outside, unorderedEquals(['base/sibling/keep.txt', 'zips/dots.zip']));
        expect(canary.readAsStringSync(), 'untouched');
        Directory('${root.path}/$clean').deleteSync(recursive: true);
      }
    });
  });

  group('a failed import leaves no half-made session folder', () {
    // Each case: a record that passes the first checks but breaks later. After the failure
    // the sessions folder must be empty, so the corrected zip imports on the second try.
    final cases = <String, Map<String, dynamic>>{
      'settings.photo_step_s as text': _start(settings: {'mode': 'photo', 'photo_step_s': '2', 'burst_s': 60}),
      'settings.run_min as text': _start(settings: {'mode': 'photo', 'run_min': '60'}),
      'settings.saved_side_px as text': _start(settings: {'mode': 'photo', 'saved_side_px': '1280'}),
      'field as text': _start(field: 'Some site'),
      'field.location.latitude as text': _start(field: {
        'location': {'latitude': '51.3', 'longitude': 12.4},
      }),
      'start time as a number': _start(time: 20261006),
    };
    for (final c in cases.entries) {
      test('${c.key}: no folder left behind, the fixed zip then imports', () async {
        final bad = _zip(zips, 'bad.zip', [
          ArchiveFile.string('$_folder/session.jsonl', _log(start: c.value)),
          _photo('$_folder/${_photoName(0)}', 0),
        ]);
        Object? error;
        try {
          await importFaunaLapseZips([bad.path], root);
        } catch (e) {
          error = e;
        }
        expect(error, isNotNull, reason: 'the broken record was imported without complaint');
        // The session list must not trip over whatever was left.
        await scanPastSessions(root: root);
        expect(Directory('${root.path}/$_folder').existsSync(), isFalse, reason: 'half-made folder left after $error');
        final good = _zip(zips, 'good.zip', [
          ArchiveFile.string('$_folder/session.jsonl', _log()),
          _photo('$_folder/${_photoName(0)}', 0),
        ]);
        final r = await importFaunaLapseZips([good.path], root);
        expect(r.photos, 1);
      });
    }

    for (final c in cases.entries) {
      test('${c.key}: the user gets a plain FaunaLapseImportError', () async {
        final bad = _zip(zips, 'bad.zip', [ArchiveFile.string('$_folder/session.jsonl', _log(start: c.value))]);
        await expectLater(importFaunaLapseZips([bad.path], root), throwsA(isA<FaunaLapseImportError>()));
      });
    }
  });

  group('broken records', () {
    // The photo is kept (it is real data); only its size value, which is not a number, is dropped.
    test('saved_side_px as text on one photo line keeps the photo, drops only the size', () {
      final lines = const LineSplitter().convert(_log(extra: [
        {'event': 'photo', 'time': '2026-10-06T00:10:00.000+0200', 'file': 'bad.jpg', 'saved_side_px': '1280'},
      ]));
      final log = parseFaunaLapseLog(lines);
      expect(log, isNotNull);
      expect(log!.photos.map((p) => p.file), [_photoName(0), _photoName(1), 'bad.jpg']);
      expect(log.photos.map((p) => p.savedPx), [1280, 1280, null]);
    });

    test('settings as text is refused with a plain message', () async {
      final z = _zip(zips, 's.zip', [ArchiveFile.string('$_folder/session.jsonl', _log(start: _start(settings: 'photo')))]);
      await expectLater(importFaunaLapseZips([z.path], root), throwsA(isA<FaunaLapseImportError>()));
      expect(root.listSync(), isEmpty);
    });

    test('a session.jsonl that is not UTF-8 is refused with a plain message', () async {
      final z = _zip(zips, 'u.zip', [ArchiveFile.bytes('$_folder/session.jsonl', Uint8List.fromList([0xC3, 0x28, 0xFF, 0xFE]))]);
      await expectLater(importFaunaLapseZips([z.path], root), throwsA(isA<FaunaLapseImportError>()));
    });

    test('the record without a session_start, or with a cut-off last line', () async {
      final noStart = _zip(zips, 'n.zip', [
        ArchiveFile.string('$_folder/session.jsonl', '{"event":"photo","time":"2026-10-06T00:03:50.154+0200","file":"a.jpg"}'),
      ]);
      await expectLater(importFaunaLapseZips([noStart.path], root), throwsA(isA<FaunaLapseImportError>()));
      expect(root.listSync(), isEmpty);
      final cut = _zip(zips, 'c.zip', [
        ArchiveFile.string('$_folder/session.jsonl', '${_log()}\n{"event":"photo","time":"2026-10-'),
        _photo('$_folder/${_photoName(0)}', 0),
        _photo('$_folder/${_photoName(1)}', 1),
      ]);
      final r = await importFaunaLapseZips([cut.path], root);
      expect(r.photos, 2);
    });
  });

  group('photo names', () {
    test('two photos taken in the same millisecond both survive', () async {
      final z = _zip(zips, 'same.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log(photos: 0, extra: [
          {'event': 'photo', 'time': '2026-10-06T00:03:50.154+0200', 'file': 'a.jpg'},
          {'event': 'photo', 'time': '2026-10-06T00:03:50.154+0200', 'file': 'b.jpg'},
        ])),
        _photo('$_folder/a.jpg', 1),
        _photo('$_folder/b.jpg', 2),
      ]);
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.photos, 2);
      final files = Directory('${root.path}/$_folder/roi_frames').listSync();
      expect(files, hasLength(2), reason: 'one photo overwrote the other');
    });

    test('the repeated hour at the end of summer time keeps both photos', () async {
      // Find the autumn clock change of 2026 in the local time zone (none in UTC).
      DateTime? fold;
      for (var t = DateTime.utc(2026, 7); t.isBefore(DateTime.utc(2027)); t = t.add(const Duration(hours: 1))) {
        final a = t.toLocal().timeZoneOffset;
        final b = t.add(const Duration(hours: 1)).toLocal().timeZoneOffset;
        if (b < a) {
          fold = t;
          break;
        }
      }
      if (fold == null) {
        markTestSkipped('no summer time in this time zone');
        return;
      }
      // fold is the last UTC hour before the change: fold+30 min and fold+90 min show the
      // same wall-clock time on the phone, one hour apart in reality.
      final t1 = fold.add(const Duration(minutes: 30));
      final t2 = fold.add(const Duration(minutes: 90));
      expect(t1.toLocal().hour, t2.toLocal().hour);
      final z = _zip(zips, 'dst.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log(photos: 0, extra: [
          {'event': 'photo', 'time': t1.toIso8601String(), 'file': 'a.jpg'},
          {'event': 'photo', 'time': t2.toIso8601String(), 'file': 'b.jpg'},
        ])),
        _photo('$_folder/a.jpg', 1),
        _photo('$_folder/b.jpg', 2),
      ]);
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.photos, 2);
      expect(Directory('${root.path}/$_folder/roi_frames').listSync(), hasLength(2));
    });
  });

  group('odd zips', () {
    test('an empty file, an empty zip, random bytes and a cut zip give a plain error', () async {
      final rnd = Random(42);
      final empty = File('${zips.path}/empty.zip')..writeAsBytesSync(const []);
      final emptyZip = File('${zips.path}/empty_archive.zip')..writeAsBytesSync(ZipEncoder().encode(Archive()));
      final noise = File('${zips.path}/noise.zip')..writeAsBytesSync([for (var i = 0; i < 4096; i++) rnd.nextInt(256)]);
      final good = _zip(zips, 'good.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log()),
        _photo('$_folder/${_photoName(0)}', 0),
      ]);
      final bytes = good.readAsBytesSync();
      final cut = File('${zips.path}/cut.zip')..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      for (final f in [empty, emptyZip, noise, cut]) {
        await expectLater(importFaunaLapseZips([f.path], root), throwsA(isA<FaunaLapseImportError>()), reason: f.path);
        expect(root.listSync(), isEmpty, reason: f.path);
      }
    });

    test('a zip without the session record is refused, even with photos', () async {
      final z = _zip(zips, 'nolog.zip', [
        _photo('$_folder/${_photoName(0)}', 0),
        ArchiveFile.string('$_folder/site_photos/s.jpg', 'S'),
        ArchiveFile.string('$_folder/sub/session.jsonl', _log()), // too deep: not the record
      ]);
      await expectLater(importFaunaLapseZips([z.path], root), throwsA(isA<FaunaLapseImportError>()));
      expect(root.listSync(), isEmpty);
    });

    test('random byte flips never escape, never hang and fail with a plain error', () async {
      final rnd = Random(7);
      final good = _zip(zips, 'good.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log(photos: 3)),
        for (var i = 0; i < 3; i++) _photo('$_folder/${_photoName(i)}', i),
        ArchiveFile.string('$_folder/site_photos/s.jpg', 'S' * 200),
      ]);
      final bytes = good.readAsBytesSync();
      final raw = <String>[];
      for (var round = 0; round < 40; round++) {
        final b = Uint8List.fromList(bytes);
        for (var k = 0; k < 3; k++) {
          b[rnd.nextInt(b.length)] = rnd.nextInt(256);
        }
        final f = File('${zips.path}/flip.zip')..writeAsBytesSync(b);
        try {
          await importFaunaLapseZips([f.path], root).timeout(const Duration(seconds: 5));
        } on FaunaLapseImportError {
          // fine
        } catch (e, st) {
          final here = st.toString().split('\n').firstWhere((l) => l.contains('fauna_pulse/'), orElse: () => '?');
          raw.add('round $round: ${e.runtimeType} at ${here.trim()}${root.listSync().isEmpty ? '' : ' (half-made folder left)'}');
        }
        for (final d in root.listSync()) {
          d.deleteSync(recursive: true);
        }
        final outside = _tree(tmp).where((p) => !p.startsWith('base/sessions/')).toList();
        expect(outside, unorderedEquals(['base/sibling/keep.txt', 'zips/good.zip', 'zips/flip.zip']));
      }
      expect(raw, isEmpty, reason: 'raw errors instead of a plain message');
    });

    test('a damaged photo inside the zip is noticed, not copied silently', () async {
      // Stored (not compressed) so a flipped byte changes the photo but not the zip layout.
      final marker = Uint8List.fromList([for (var i = 0; i < 64; i++) 0x41 + (i % 26)]);
      final z = _zip(zips, 'crc.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log(photos: 1)),
        ArchiveFile.bytes('$_folder/${_photoName(0)}', marker)..compression = CompressionType.none,
      ]);
      final b = z.readAsBytesSync();
      var at = -1;
      for (var i = 0; i + marker.length <= b.length && at < 0; i++) {
        var same = true;
        for (var k = 0; k < marker.length && same; k++) {
          same = b[i + k] == marker[k];
        }
        if (same) at = i;
      }
      expect(at, greaterThanOrEqualTo(0), reason: 'photo bytes not found stored in the zip');
      b[at + 10] ^= 0xFF; // the zip's CRC for this photo no longer matches
      z.writeAsBytesSync(b);
      FaunaLapseImportResult? r;
      try {
        r = await importFaunaLapseZips([z.path], root);
      } on FaunaLapseImportError {
        return; // refused: fine
      }
      // Imported: the damaged photo must at least be left out (counted missing), not copied.
      final copied = Directory('${root.path}/$_folder/roi_frames').listSync().whereType<File>().toList();
      expect(r.photos == 0 || copied.every((f) => f.readAsBytesSync().length != marker.length || f.readAsBytesSync()[10] == marker[10]), isTrue,
          reason: 'a photo with a wrong CRC was copied without any warning');
      expect(r.damagedPhotos, 1);
    });

    test('2000 photos import with distinct names and correct counts', () async {
      const n = 2000;
      final z = _zip(zips, 'big.zip', [
        ArchiveFile.string('$_folder/session.jsonl', _log(photos: n)),
        for (var i = 0; i < n; i++) _photo('$_folder/${_photoName(i)}', i),
      ]);
      final sw = Stopwatch()..start();
      final r = await importFaunaLapseZips([z.path], root);
      expect(r.photos, n);
      expect(r.missingPhotos, 0);
      expect(Directory('${root.path}/$_folder/roi_frames').listSync(), hasLength(n));
      final recs = File('${root.path}/$_folder/session.jsonl').readAsLinesSync();
      expect(recs.where((l) => l.contains('"timelapse_capture"')), hasLength(n));
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    });
  });
}
