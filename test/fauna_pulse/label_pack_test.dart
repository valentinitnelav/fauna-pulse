// Tests for the label-pack reader (round 208): the cross-language fixture
// written by fpack.py (fauna-pulse-models, bioclip_export/), half-float decoding, taxonomy keys;
// round 266: class lists of fixed-class classifiers (tiny_classes.fpack).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';

/// A label pack of [labels] with one f32 number per row and the extra header [blocks].
Uint8List _packWith(List<List<String>> labels, Map<String, dynamic> blocks) {
  final hdr = utf8.encode(jsonEncode({'dim': 1, 'rows': labels.length, 'dtype': 'f32', 'labels': labels, ...blocks}));
  return (BytesBuilder()
        ..add('FPK1'.codeUnits)
        ..add((ByteData(4)..setUint32(0, hdr.length, Endian.little)).buffer.asUint8List())
        ..add(hdr)
        ..add(Float32List.fromList(List.filled(labels.length, 1.0)).buffer.asUint8List()))
      .takeBytes();
}

void main() {
  // Round 377: the orders and families of a pack's names, for the choice by hand.
  group('round 377: orders and families', () {
    LabelRow row(String order, String family, [String genus = 'Genus', String species = 'species']) =>
        LabelRow(['Animalia', 'Chordata', 'Aves', order, family, genus, species], '');
    final taxa = PackTaxa.of([
      row('Passeriformes', 'Turdidae'), // 0
      row('Passeriformes', 'Paridae'), // 1
      row('Accipitriformes', 'Accipitridae'), // 2
      row('Passeriformes', 'Turdidae', '', ''), // 3: answered only down to family (a name-rules row)
      row('Passeriformes', '', 'Genus', 'species'), // 4: no family: counts for its order only
      row('', 'Accipitridae'), // 5: no order: counts for neither, although the family is named
      const LabelRow(['Animalia', '', 'Aves', 'Passeriformes', 'Paridae', 'Parus', 'major'], ''), // 6: a gap higher up
      const LabelRow(['none', '', '', '', '', '', 'flower'], 'a photo of a flower.'), // 7: "none of these"
    ]);
    List<int> rowsOf(Uint8List bits) => [for (var r = 0; r < 8; r++) if (PackRegions.hasRow(bits, r)) r];

    test('names in alphabetical order, each family under its order', () {
      expect(taxa.orders, ['Accipitriformes', 'Passeriformes']);
      expect(taxa.families, ['Accipitridae', 'Paridae', 'Turdidae']);
      expect([for (final o in taxa.familyOrder) taxa.orders[o]], ['Accipitriformes', 'Passeriformes', 'Passeriformes']);
      expect(taxa.contains('Paridae'), isTrue);
      expect(taxa.contains('Passeriformes'), isTrue);
      expect(taxa.contains('Aves'), isFalse, reason: 'only orders and families');
      expect(taxa.contains(''), isFalse);
    });

    test('a row counts down to the rank above its first empty slot', () {
      expect(rowsOf(taxa.rowBits(['Turdidae'])), [0, 3], reason: 'a row answered down to family counts for its family');
      expect(rowsOf(taxa.rowBits(['Passeriformes'])), [0, 1, 3, 4], reason: 'a row without a family counts for its order');
      expect(rowsOf(taxa.rowBits(['Accipitridae'])), [2], reason: 'a row without an order counts for no family');
      expect(rowsOf(taxa.rowBits(['Paridae'])), [1], reason: 'a gap above the order: the row counts for nothing here');
      // An order and a family of another order: both, each row once. Unknown names add nothing.
      expect(rowsOf(taxa.rowBits(['Accipitriformes', 'Paridae', 'Strigidae'])), [1, 2]);
      expect(rowsOf(taxa.rowBits(const [])), isEmpty);
      expect(rowsOf(taxa.rowBits([...taxa.orders, ...taxa.families])), [0, 1, 2, 3, 4], reason: 'never a "none of these" row');
    });

    test('names per order and family, in the whole pack or among some rows', () {
      final all = taxa.counts();
      expect([all.orders, all.families], [[1, 4], [1, 1, 2]]);
      final some = taxa.counts(Uint8List.fromList([0x0B])); // rows 0, 1 and 3
      expect([some.orders, some.families], [[0, 3], [0, 1, 2]]);
    });

    test('a name list\'s header brings them along; a class list has none', () async {
      final header = await LabelPack.readHeader(File('test/fauna_pulse/fixtures/tiny_pack_regions.fpack'));
      final fromHeader = header[kPackTaxaKey] as PackTaxa;
      expect(header.containsKey('labels'), isFalse);
      final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack_regions.fpack').readAsBytesSync());
      final fromPack = PackTaxa.of(pack.labels);
      expect(fromHeader.orders, ['Araneae', 'Diptera', 'Hymenoptera']);
      expect(fromHeader.families, ['Apidae', 'Syrphidae', 'Thomisidae']);
      expect(fromHeader.rowOrder, fromPack.rowOrder);
      expect(fromHeader.rowFamily, fromPack.rowFamily);
      expect(fromHeader.rowOrder.last, -1, reason: 'the "none of these" row');
      expect((await LabelPack.readHeader(File('test/fauna_pulse/fixtures/tiny_classes.fpack'))).containsKey(kPackTaxaKey), isFalse);
    });

    test('labels of a wrong shape: the header is read, without orders and families', () async {
      final bytes = _packWith([
        ['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Genus', 'species', ''],
      ], {});
      final hlen = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
      final header = jsonDecode(utf8.decode(bytes.sublist(8, 8 + hlen))) as Map<String, dynamic>;
      header['labels'] = ['not a list'];
      final hdr = utf8.encode(jsonEncode(header));
      final dir = Directory.systemTemp.createTempSync('fp_taxa');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/odd.fpack')
        ..writeAsBytesSync([...bytes.sublist(0, 4), ...(ByteData(4)..setUint32(0, hdr.length, Endian.little)).buffer.asUint8List(), ...hdr, ...bytes.sublist(8 + hlen)]);
      expect((await LabelPack.readHeader(file)).containsKey(kPackTaxaKey), isFalse);
      expect(() => LabelPack.parseBytes(file.readAsBytesSync()), throwsFormatException);
    });
  });

  // Round 372: the blocks of the `_v3` packs, read from the fixture fpack.py writes
  // (fauna-pulse-models, `_write_regions_fixture`: tiny_pack with made-up country lists).
  group('round 372: GBIF keys and country lists', () {
    final fixture = File('test/fauna_pulse/fixtures/tiny_pack_regions.fpack');
    final tenRows = [
      for (var i = 0; i < 10; i++) ['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Genus', 'species', ''],
    ];

    test('the fixture: a key and a name per row, bits per country, neighbours', () {
      final pack = LabelPack.parseBytes(fixture.readAsBytesSync());
      expect(pack.gbifKeys, ['3B7X4', '6FY28', 'FN46', 'MFWK', '43P3V', '']);
      expect(pack.gbifSpecies.first, 'Eristalis tenax');
      expect(pack.gbifSpecies.last, '', reason: 'the sink row has no key');
      final regions = pack.regions!;
      expect(regions.countries.keys, unorderedEquals(['AT', 'DE', 'MT']));
      expect(regions.countries['DE']!.names, 4);
      expect(regions.countries['DE']!.namesInCountry, 5);
      expect(regions.withNeighbours('DE'), ['DE', 'AT']);
      expect(regions.withNeighbours('MT'), ['MT'], reason: 'no neighbours listed');
      expect(regions.withNeighbours('XX'), isEmpty, reason: 'a country the pack does not know');
      // The writer's own answer: the rows of a country with its neighbours.
      final union = (pack.header['test_union'] as Map).cast<String, dynamic>();
      for (final code in union.keys) {
        final bits = regions.rowBits(regions.withNeighbours(code));
        expect([for (var r = 0; r < pack.rows; r++) if (PackRegions.hasRow(bits, r)) r], union[code], reason: code);
        expect(PackRegions.countRows(bits), (union[code] as List).length);
      }
      expect(PackRegions.countRows(regions.rowBits(['MT', 'XX'])), 1);
      // The same rows, names and vectors as the plain fixture.
      final plain = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
      expect(pack.matrix, plain.matrix);
      expect([for (final l in pack.labels) l.keyAt(6)], [for (final l in plain.labels) l.keyAt(6)]);
    });

    test('the bits are read least significant bit first', () {
      // fpack.py's example: rows {0, 9} of a 10-row pack are "AQI=".
      final regions = PackRegions.tryParse({
        'countries': {
          'DE': {'rows': 'AQI=', 'names': 2, 'names_in_country': 2},
        },
      }, 10)!;
      final bits = regions.rowBits(['DE']);
      expect([for (var r = 0; r < 10; r++) if (PackRegions.hasRow(bits, r)) r], [0, 9]);
      // Bits past the last row (here rows 10 to 15) are dropped.
      final stray = PackRegions.tryParse({
        'countries': {
          'DE': {'rows': base64.encode([0x01, 0xFE]), 'names': 2, 'names_in_country': 2},
        },
      }, 10)!;
      expect(PackRegions.countRows(stray.rowBits(['DE'])), 2);
    });

    test('the loaded pack and a worker\'s copy do not carry the blocks as header text', () {
      final pack = LabelPack.parseBytes(fixture.readAsBytesSync());
      expect((pack.header['gbif'] as Map).keys, ['source']);
      expect((pack.header['regions'] as Map).containsKey('countries'), isFalse);
      expect((pack.header['regions'] as Map).containsKey('neighbours'), isFalse);
      expect((pack.header['regions'] as Map)['min_occurrences'], 3);
      final worker = pack.forWorker();
      expect(worker.header, isEmpty);
      expect(worker.gbifKeys, isEmpty);
      expect(worker.regions, isNull);
      expect(worker.matrix, isEmpty);
      expect(worker.labels, same(pack.labels));
      expect(worker.logitScale, pack.logitScale);
    });

    test('readHeader keeps the country lists and drops the per-name keys', () async {
      final hdr = await LabelPack.readHeader(fixture);
      expect((hdr['gbif'] as Map).keys, ['source']);
      expect(PackRegions.tryParse(hdr['regions'], hdr['rows'] as int)!.countries.length, 3);
    });

    test('a pack without the blocks has none', () {
      final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
      expect(pack.gbifKeys, isEmpty);
      expect(pack.gbifSpecies, isEmpty);
      expect(pack.regions, isNull);
    });

    test('a key of digits only stays text, also when another tool wrote it as a number', () {
      final labels = tenRows.sublist(0, 3);
      final pack = LabelPack.parseBytes(
        _packWith(labels, {
          'gbif': {
            'species_key': ['78358', 78358, null],
            'species': ['Genus a', 'Genus b', null],
          },
        }),
      );
      expect(pack.gbifKeys, ['78358', '78358', '']);
      expect(pack.gbifSpecies, ['Genus a', 'Genus b', '']);
    });

    test('damaged blocks are left out and the pack still loads', () {
      Map<String, dynamic> country(Object? rows, {Object? names = 1}) => {
        'countries': {
          'DE': {'rows': rows, 'names': names, 'names_in_country': 1},
        },
      };
      final good = base64.encode([0x01, 0x02]);
      expect(PackRegions.tryParse(country(good), 10), isNotNull);
      final bad = <Object?>[
        null,
        'text',
        [1, 2],
        <String, dynamic>{},
        {'countries': <String, dynamic>{}},
        {'countries': 'DE'},
        {'countries': {'DE': 'x'}},
        country('not base64 !!'),
        country(base64.encode([0x01])), // too few bytes for 10 rows
        country(base64.encode([0x01, 0x02, 0x03])), // too many
        country(7),
        country(good, names: 'many'),
      ];
      for (final block in bad) {
        expect(PackRegions.tryParse(block, 10), isNull, reason: '$block');
        final pack = LabelPack.parseBytes(_packWith(tenRows, {'regions': block, 'gbif': block}));
        expect(pack.rows, 10, reason: '$block');
        expect(pack.regions, isNull);
        expect(pack.gbifKeys, isEmpty);
      }
      // Neighbours of the wrong shape are skipped; the country lists stay.
      final odd = PackRegions.tryParse({...country(good), 'neighbours': {'DE': 'AT', 'AT': [1, 'DE']}}, 10)!;
      expect(odd.withNeighbours('DE'), ['DE']);
      // Keys without names, or one list of the wrong length: neither is kept.
      for (final gbif in [
        {'species_key': List.filled(10, 'K')},
        {'species_key': List.filled(9, 'K'), 'species': List.filled(10, 'n')},
        {'species_key': 'K', 'species': 3},
      ]) {
        final pack = LabelPack.parseBytes(_packWith(tenRows, {'gbif': gbif}));
        expect(pack.gbifKeys, isEmpty, reason: '$gbif');
        expect(pack.gbifSpecies, isEmpty, reason: '$gbif');
      }
    });
  });

  test('round 359: dotsIntoMany equals dotsInto bit for bit, eights and the leftovers', () {
    final rnd = math.Random(7);
    const dim = 768, rows = 37;
    final matrix = Float32List(rows * dim);
    for (var i = 0; i < matrix.length; i++) {
      matrix[i] = rnd.nextDouble() * 2 - 1;
    }
    final pack = LabelPack(
      packId: 'p',
      modelId: 'm',
      dim: dim,
      rows: rows,
      sinkRows: 0,
      logitScale: 1,
      temperature: 1,
      labels: const [],
      matrix: matrix,
      header: const {},
    );
    // 21 vectors: two blocks of eight and five leftovers; one of them a view into a larger array.
    final big = Float32List(3 * dim);
    for (var i = 0; i < big.length; i++) {
      big[i] = rnd.nextDouble() * 2 - 1;
    }
    final vectors = [
      for (var k = 0; k < 20; k++) Float32List.fromList([for (var i = 0; i < dim; i++) rnd.nextDouble() * 2 - 1]),
      Float32List.sublistView(big, dim, 2 * dim),
    ];
    final many = [for (var k = 0; k < vectors.length; k++) Float64List(rows)];
    pack.dotsIntoMany(vectors, many);
    for (var k = 0; k < vectors.length; k++) {
      final one = Float64List(rows);
      pack.dotsInto(vectors[k], one);
      expect(many[k], equals(one), reason: 'vector $k');
      for (var r = 0; r < rows; r++) {
        expect(many[k][r], closeTo(pack.dot(vectors[k], r), 1e-4));
      }
    }
  });

  test('halfToFloat decodes common values', () {
    expect(halfToFloat(0x3C00), 1.0);
    expect(halfToFloat(0xBC00), -1.0);
    expect(halfToFloat(0x3800), 0.5);
    expect(halfToFloat(0x0000), 0.0);
    expect(halfToFloat(0x0001), closeTo(5.96e-8, 1e-9)); // smallest subnormal
    expect(halfToFloat(0x7BFF), closeTo(65504, 0.1)); // largest finite
  });

  test('reads the Python-written fixture (values, labels, sink row)', () {
    final bytes = File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync();
    final pack = LabelPack.parseBytes(bytes);
    expect(pack.rows, 6);
    expect(pack.dim, 4);
    expect(pack.sinkRows, 1);
    expect(pack.packId, 'tiny-test');
    expect(pack.logitScale, 100.0);
    // First row as printed by fpack.py after f16 round-trip.
    expect(pack.matrix[0], closeTo(0.001257, 1e-5));
    expect(pack.matrix[1], closeTo(0.305176, 1e-5));
    expect(pack.matrix[2], closeTo(-0.280029, 1e-5));
    expect(pack.matrix[3], closeTo(-0.910156, 1e-5));
    // Rows are unit vectors (within f16 rounding).
    for (var r = 0; r < pack.rows; r++) {
      var n = 0.0;
      for (var d = 0; d < pack.dim; d++) {
        n += pack.matrix[r * pack.dim + d] * pack.matrix[r * pack.dim + d];
      }
      expect(n, closeTo(1.0, 2e-3));
    }
    expect(pack.labels[0].speciesName, 'Eristalis tenax');
    expect(pack.labels[0].common, 'Drone fly');
    expect(pack.labels[0].keyAt(4), 'Animalia|Arthropoda|Insecta|Diptera|Syrphidae');
    expect(pack.labels[5].isSink, isTrue);
    expect(pack.labels[5].speciesName, 'flower');
    expect(pack.header.containsKey('labels'), isFalse);
  });

  test('readHeader returns the header without labels', () async {
    final hdr = await LabelPack.readHeader(File('test/fauna_pulse/fixtures/tiny_pack.fpack'));
    expect(hdr['rows'], 6);
    expect(hdr['dtype'], 'f16');
    expect(hdr.containsKey('labels'), isFalse);
  });

  test('reads a class list (round 266): no vectors, heads, own class names, rows above species', () {
    final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_classes.fpack').readAsBytesSync());
    expect(pack.isClassList, isTrue);
    expect(pack.rows, 4);
    expect(pack.dim, 7); // the model's output length: 3 + 4
    expect(pack.headSizes, [3, 4]);
    expect(pack.headIndex, [0, 0, 0, 1, 1, 2, 2, 3]);
    expect(pack.classNames, ['Syrphidae', 'Eristalis tenax', 'Apis mellifera', 'Vegetation']);
    expect(pack.matrix, isEmpty);
    expect(pack.logitScale, 1.0);
    expect(pack.labels[0].speciesName, 'Syrphidae'); // a family-level class shows its family
    expect(pack.labels[1].speciesName, 'Eristalis tenax');
    expect(pack.labels[3].isSink, isTrue);
    expect(pack.labels[3].speciesName, 'Vegetation');
    expect(pack.header.containsKey('labels'), isFalse);
    // A BioCLIP pack is no class list.
    expect(LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync()).isClassList, isFalse);
  });

  test('a class list whose heads do not add up to its size is refused', () {
    final hdr = utf8.encode(jsonEncode({
      'kind': 'classes', 'dim': 5, 'rows': 1, 'dtype': 'none',
      'labels': [['Animalia', '', '', '', '', '', '', '']],
      'classes': ['x'], 'heads': [{'size': 3}], 'head_index': [[0]],
    }));
    final bytes = BytesBuilder()
      ..add(ascii.encode('FPK1'))
      ..add((ByteData(4)..setUint32(0, hdr.length, Endian.little)).buffer.asUint8List())
      ..add(hdr);
    expect(() => LabelPack.parseBytes(bytes.toBytes()), throwsFormatException);
  });

  test('rejects files without the magic', () {
    expect(() => LabelPack.parseBytes(File('pubspec.yaml').readAsBytesSync()), throwsFormatException);
  });

  // Round 327: jsonDecode builds one list per "[", so a header of brackets used gigabytes
  // (1.46 GB for 16 MB). Real headers hold one short list per name (about 110 bytes each).
  test('a header of nested or tightly packed brackets is refused before decoding', () {
    Uint8List pack(String header) {
      final hdr = utf8.encode(header);
      return (BytesBuilder()
            ..add('FPK1'.codeUnits)
            ..add((ByteData(4)..setUint32(0, hdr.length, Endian.little)).buffer.asUint8List())
            ..add(hdr))
          .takeBytes();
    }

    expect(() => LabelPack.parseBytes(pack('[' * 100000)), throwsFormatException);
    final wide = '{"dim":0,"rows":0,"labels":[],"x":[${List.filled(200000, '[]').join(',')}]}';
    expect(() => LabelPack.parseBytes(pack(wide)), throwsFormatException);
    // Brackets inside names are text, not structure.
    final named = '{"dim":0,"rows":1,"labels":[["a","b","${'[' * 5000}"]]}';
    expect(LabelPack.parseBytes(pack(named)).rows, 1);
  });

  // Round 327: the header is read whole each time the AI models screen opens (since round 372 in
  // a helper isolate), so a hand-made file with a huge header would cost that memory and time at
  // every listing; real headers are a few MB.
  test('a header above 16 MB is refused before it is read', () async {
    final hdr = utf8.encode(jsonEncode({'dim': 0, 'rows': 0, 'labels': [], 'pad': 'a' * (17 << 20)}));
    final f = File('${Directory.systemTemp.createTempSync('fpack').path}/big.fpack')
      ..writeAsBytesSync(
        (BytesBuilder()
              ..add('FPK1'.codeUnits)
              ..add((ByteData(4)..setUint32(0, hdr.length, Endian.little)).buffer.asUint8List())
              ..add(hdr))
            .takeBytes(),
      );
    try {
      await expectLater(LabelPack.readHeader(f), throwsFormatException);
    } finally {
      f.parent.deleteSync(recursive: true);
    }
  });
}
