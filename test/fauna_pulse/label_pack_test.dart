// Tests for the label-pack reader (round 208): the cross-language fixture
// written by tool/bioclip_export/fpack.py, half-float decoding, taxonomy keys.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';

void main() {
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

  test('rejects files without the magic', () {
    expect(() => LabelPack.parseBytes(File('pubspec.yaml').readAsBytesSync()), throwsFormatException);
  });
}
