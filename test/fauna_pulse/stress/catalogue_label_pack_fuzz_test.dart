// Stress run, step P2: seeded mutation fuzzing of ModelDownloads.parse (the
// model list, assets/model_downloads.json) and of LabelPack.parseBytes /
// readHeader (.fpack name lists). Rule: no hang, no huge allocation, only a
// clear error type; never an uncaught TypeError / RangeError. A case that
// shows a real bug is kept and marked skip: 'BUG: ...'.
//
// Memory: header numbers are still capped in every mutated header (rows * dim
// at most 1e6) so a future regression cannot make this run ask for gigabytes.
// LabelPack now checks dim and the file length before it allocates
// Float32List(rows * dim); the last test covers huge and negative dim.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fuzz_helpers.dart';

Uint8List _pack(Map<String, dynamic> header, [List<int> body = const []]) {
  final h = utf8.encode(jsonEncode(header));
  final len = ByteData(4)..setUint32(0, h.length, Endian.little);
  return Uint8List.fromList([...'FPK1'.codeUnits, ...len.buffer.asUint8List(), ...h, ...body]);
}

/// Splits a pack file into its header map and the bytes after the header.
(Map<String, dynamic>, Uint8List) _split(Uint8List bytes) {
  final hlen = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
  final header = jsonDecode(utf8.decode(bytes.sublist(8, 8 + hlen))) as Map<String, dynamic>;
  return (header, Uint8List.sublistView(bytes, 8 + hlen));
}

/// A mutated header is run only when it cannot ask for much memory.
bool _smallHeader(Object? decoded) {
  if (decoded is! Map) return true;
  num? n(Object? v) => v is num ? v : null;
  final dim = n(decoded['dim']), rows = n(decoded['rows']);
  for (final v in [dim, rows]) {
    if (v != null && (!v.isFinite || v.abs() > 1e6)) return false;
  }
  if (dim != null && rows != null && (dim * rows).abs() > 1e6) return false;
  final heads = decoded['heads'];
  if (heads is List) {
    for (final h in heads) {
      if (h is Map) {
        final s = n(h['size']);
        if (s != null && (!s.isFinite || s.abs() > 1e6)) return false;
      }
    }
  }
  return true;
}

void main() {
  late Directory tmp;
  late Uint8List tinyPack;
  late Uint8List tinyClasses;
  late String catalogue;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fuzz_catalogue_pack');
    tinyPack = File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync();
    tinyClasses = File('test/fauna_pulse/fixtures/tiny_classes.fpack').readAsBytesSync();
    catalogue = File('assets/model_downloads.json').readAsStringSync();
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ModelDownloads.parse', () {
    test('the shipped list parses (sanity)', () {
      final c = ModelDownloads.parse(catalogue);
      expect(c.detectors, isNotEmpty);
      expect(c.identification, isNotEmpty);
      expect(c.uses, isNotEmpty);
    });

    test('byte-level damage: FormatException or a catalogue, never another error', () {
      final report = FuzzReport();
      final bytes = Uint8List.fromList(utf8.encode(catalogue));
      for (final (name, b) in byteMutants(bytes, Random(21), perKind: 40)) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          ModelDownloads.parse(utf8.decode(b, allowMalformed: true));
        } catch (e) {
          err = e;
        }
        report.add(name, err, sw.elapsed, ok: (e) => e is FormatException);
      }
      expect(report.slowest, lessThan(const Duration(seconds: 5)), reason: '$report');
      expect(report.clean, isTrue, reason: '$report');
    });

    test('one missing or wrong "base_url" does not empty the catalogue when every file has its own url', () {
      final j = jsonDecode(catalogue) as Map<String, dynamic>;
      final all = ModelDownloads.parse(catalogue);
      final offered = all.detectorOffers.length + all.identificationOffers.length;
      expect(offered, greaterThan(0));
      for (final change in <(String, Object?)>[('missing', null), ('number', 5), ('empty', ''), ('not https', 'ftp://x/')]) {
        final copy = Map<String, dynamic>.of(j);
        if (change.$2 == null) {
          copy.remove('base_url');
        } else {
          copy['base_url'] = change.$2;
        }
        late ModelDownloads c;
        try {
          c = ModelDownloads.parse(jsonEncode(copy));
        } catch (e) {
          fail('base_url ${change.$1}: parse threw ${e.runtimeType} ($e): the whole catalogue is lost');
        }
        expect(c.detectorOffers.length + c.identificationOffers.length, offered, reason: 'base_url ${change.$1}');
      }
    });

    test('wrong JSON types anywhere in the list: one or two bad values cost at most their own models', () {
      final all = ModelDownloads.parse(catalogue);
      final total = all.detectors.length + all.identification.length;
      final report = FuzzReport();
      final one = jsonEncode(jsonDecode(catalogue));
      for (final (name, lines) in typeMutants([one], Random(22), count: 500)) {
        final sw = Stopwatch()..start();
        Object? err;
        try {
          final c = ModelDownloads.parse(lines.single);
          final left = c.detectors.length + c.identification.length;
          // A mutation touches one or two places: it may cost those models (and a use), not the rest.
          if (left < total - 2) err = StateError('$left of $total models left');
        } catch (e) {
          err = e;
        }
        // Replacing the whole file or the 'models' list itself leaves nothing to keep: an
        // empty catalogue (or, for a file that is not a JSON object, an error that load()
        // logs) is the expected result there.
        if (name.contains('whole record :=') || name.startsWith('line 0, models :=')) continue;
        report.add(name, err, sw.elapsed);
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('unsafe file names and links are skipped, never offered', () {
      String entry(String id, Map<String, dynamic> file, {String kind = 'detection_model'}) => jsonEncode({
        'id': id,
        'kind': kind,
        'title': 't',
        'purpose': 'p',
        'file': file,
      });
      final bad = <Map<String, dynamic>>[
        {'name': '../evil.tflite', 'url': 'https://x.org/a'},
        {'name': '/abs/evil.tflite', 'url': 'https://x.org/a'},
        {'name': 'a/b.tflite', 'url': 'https://x.org/a'},
        {'name': 'a\\b.tflite', 'url': 'https://x.org/a'},
        {'name': 'x.tflite\u0000.png', 'url': 'https://x.org/a'},
        {'name': 'x.tflite\n', 'url': 'https://x.org/a'},
        {'name': '${'a' * 5000}.tflite', 'url': 'https://x.org/a'},
        {'name': 'ok.tflite', 'url': 'http://x.org/a'},
        {'name': 'ok.tflite', 'url': 'file:///etc/passwd'},
        {'name': 'ok.tflite', 'url': 'javascript:alert(1)'},
        {'name': 'ok.tflite', 'url': ''},
        {'name': 'ok.tflite', 'url': 'https://[::1'},
        {'name': 'ok.tflite', 'url': '%%%'},
        {'name': '', 'url': 'https://x.org/a'},
        {'name': 'ok.exe', 'url': 'https://x.org/a'},
      ];
      final entries = [for (var i = 0; i < bad.length; i++) entry('bad$i', bad[i])];
      final good = entry('good', {'name': 'good.tflite', 'bytes': 10, 'sha256': 'ab', 'url': 'https://x.org/good.tflite'});
      final text = '{"format":3,"base_url":"https://x.org/","models":[${[...entries, good].join(',')}]}';
      final c = ModelDownloads.parse(text);
      expect(c.detectors.map((d) => d.id).toList(), ['good'], reason: 'only the safe entry survives');
    });

    test('a link without a host name is skipped', () {
      final text = jsonEncode({
        'format': 3,
        'base_url': 'https://x.org/',
        'models': [
          {
            'id': 'nohost',
            'kind': 'detection_model',
            'title': 't',
            'purpose': 'p',
            'file': {'name': 'ok.tflite', 'url': 'https:///nohost'},
          },
        ],
      });
      expect(ModelDownloads.parse(text).detectors, isEmpty);
    });

    test('repeated ids, huge numbers and odd fields do not crash the parse', () {
      final text = jsonEncode({
        'format': 3,
        'base_url': 'https://x.org/dl/',
        'models': [
          {'id': 'a', 'kind': 'detection_model', 'title': 't', 'purpose': 'p', 'file': {'name': 'a.tflite', 'bytes': 1e30}},
          {'id': 'A', 'kind': 'detection_model', 'title': 't', 'purpose': 'p'},
          {'id': 'b', 'kind': 'detection_model', 'title': 't', 'purpose': 'p', 'file': {'name': 'b.tflite', 'bytes': -5, 'sha256': 7}},
          {'id': 'c', 'kind': 'identification_model', 'title': 't', 'purpose': 'p', 'name_lists': 'none'},
          5,
          null,
          [],
        ],
        'uses': [5, null, {'id': 'u', 'title': 't', 'find': ['a']}],
      });
      expect(() => ModelDownloads.parse(text), returnsNormally);
    });
  });

  group('LabelPack.parseBytes and readHeader', () {
    Future<Object?> headerOf(Uint8List bytes) async {
      final f = File('${tmp.path}/h.fpack')..writeAsBytesSync(bytes);
      try {
        await LabelPack.readHeader(f);
        return null;
      } catch (e) {
        return e;
      }
    }

    test('both fixtures read (sanity)', () {
      expect(LabelPack.parseBytes(tinyPack).rows, 6);
      expect(LabelPack.parseBytes(tinyClasses).isClassList, isTrue);
    });

    test('byte-level damage: only a FormatException', () async {
      final report = FuzzReport();
      final headerReport = FuzzReport();
      var seed = 30;
      for (final source in [tinyPack, tinyClasses]) {
        for (final (name, b) in byteMutants(source, Random(seed++), perKind: 40)) {
          final (header, _) = (() {
            // The header of a byte-damaged file may now ask for much: skip those few.
            try {
              return _split(Uint8List.fromList(b));
            } catch (_) {
              return (<String, dynamic>{}, Uint8List(0));
            }
          })();
          if (!_smallHeader(header)) continue;
          final sw = Stopwatch()..start();
          Object? err;
          try {
            LabelPack.parseBytes(Uint8List.fromList(b));
          } catch (e) {
            err = e;
          }
          report.add(name, err, sw.elapsed, ok: (e) => e is FormatException);
          final sw2 = Stopwatch()..start();
          headerReport.add(name, await headerOf(Uint8List.fromList(b)), sw2.elapsed, ok: (e) => e is FormatException);
        }
      }
      expect(report.slowest, lessThan(const Duration(seconds: 5)), reason: '$report');
      expect(report.clean, isTrue, reason: 'parseBytes: $report');
      expect(headerReport.clean, isTrue, reason: 'readHeader: $headerReport');
    });

    test('wrong JSON types in one header field: only a FormatException', () {
      final report = FuzzReport();
      var seed = 40;
      for (final source in [tinyPack, tinyClasses]) {
        final (header, body) = _split(source);
        for (final (name, lines) in typeMutants([jsonEncode(header)], Random(seed++), count: 400)) {
          final mutated = jsonDecode(lines.single);
          if (!_smallHeader(mutated)) continue;
          final sw = Stopwatch()..start();
          Object? err;
          try {
            final h = utf8.encode(lines.single);
            final len = ByteData(4)..setUint32(0, h.length, Endian.little);
            LabelPack.parseBytes(Uint8List.fromList([...'FPK1'.codeUnits, ...len.buffer.asUint8List(), ...h, ...body]));
          } catch (e) {
            err = e;
          }
          report.add(name, err, sw.elapsed, ok: (e) => e is FormatException);
        }
      }
      expect(report.clean, isTrue, reason: '$report');
    });

    test('a negative dim is a FormatException, not a RangeError from Float32List', () {
      final bytes = _pack({
        'dim': -1,
        'rows': 1,
        'dtype': 'f32',
        'labels': [
          ['a', '', '', '', '', '', '', 'x'],
        ],
      }, Uint8List(16));
      expect(() => LabelPack.parseBytes(bytes), throwsA(isA<FormatException>()));
    });

    test('a header that readHeader accepts can be loaded, or readHeader refuses it', () async {
      // Import (model_file_kind.dart ~52) and download (model_downloads.dart ~349) only call readHeader.
      final bytes = _pack({}, const []);
      final err = await headerOf(bytes);
      if (err == null) {
        expect(() => LabelPack.parseBytes(bytes), returnsNormally, reason: 'readHeader accepted a pack that parseBytes cannot read');
      }
    });

    test('readHeader: a file cut anywhere gives a FormatException', () async {
      final b = _pack({'dim': 1, 'rows': 0, 'labels': <Object?>[]});
      final bad = <int, Object?>{};
      for (final cut in [0, 1, 3, 4, 5, 6, 7, 8, 9, b.length - 1]) {
        final err = await headerOf(Uint8List.sublistView(b, 0, cut));
        if (err is! FormatException) bad[cut] = err;
      }
      expect(bad, isEmpty, reason: 'cut at byte -> error: $bad');
    });

    test('readHeader: a header length larger than the file is a FormatException', () async {
      // hlen = 4 GiB - 1 on a 10-byte file. Checked in a scratch script under ulimit -v: it neither
      // allocates 4 GiB (peak 177 MB) nor hangs; it returns the map {} (reads what is there).
      final f = Uint8List.fromList([...'FPK1'.codeUnits, 255, 255, 255, 255, 123, 125]);
      final err = await headerOf(f);
      expect(err, isA<FormatException>(), reason: 'header length larger than the file: $err');
    });

    test('a header that claims a huge or negative dim is rejected without allocating', () async {
      // LabelPack._checkedHeader caps dim and checks the file length before
      // parseBytes allocates `Float32List(rows * dim)`. Before that fix, rows = 1 in a
      // 100-byte file gave (address space capped to 7 GB with ulimit -v):
      //   dim=-1          -> RangeError
      //   dim=100000000   -> allocates 400 MB, then FormatException "matrix is truncated"
      //   dim=2147483648  -> OutOfMemoryError "Exhausted heap space, trying to allocate 8589934624 bytes"
      // Safe to run always now: every case is refused from the header alone. readHeader
      // (import and download) must refuse them too, so a bad file never reaches the list.
      for (final dim in [-1, 100000000, 2147483648]) {
        final bytes = _pack({
          'dim': dim,
          'rows': 1,
          'dtype': 'f32',
          'labels': [
            ['a', '', '', '', '', '', '', 'x'],
          ],
        }, Uint8List(16));
        expect(() => LabelPack.parseBytes(bytes), throwsA(isA<FormatException>()), reason: 'dim $dim');
        expect(await headerOf(bytes), isA<FormatException>(), reason: 'readHeader, dim $dim');
      }
    });
  });
}
