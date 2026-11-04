// Round 348 (perf review H4c): the embeddings .bin is read as a typed view of the file bytes,
// not an element-wise copy; both paths give the same values.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('identification_store_test'));
  tearDown(() async => tmp.delete(recursive: true));

  test('readEmbeddingRows: the view and the copy give the same values; a torn row is left out; a short file is refused', () {
    const rows = 3, dim = 5;
    final values = Float32List.fromList([for (var i = 0; i < rows * dim; i++) i * 0.25 - 1.5]);
    final f = File('${tmp.path}/e.bin')..writeAsBytesSync(vectorBytes(values));
    expect(readEmbeddingRows(f, rows, dim), equals(values));
    expect(readEmbeddingRows(f, rows, dim, forceCopy: true), equals(values));
    // A row torn at the end of the file (3 of 20 bytes) is not part of any record.
    f.writeAsBytesSync([...vectorBytes(values), 1, 2, 3]);
    final view = readEmbeddingRows(f, rows, dim);
    expect(view, equals(values));
    expect(view.offsetInBytes % 16, 0, reason: 'rows start aligned, so the four-lane dot product applies');
    expect(() => readEmbeddingRows(f, rows + 1, dim), throwsStateError);
    expect(() => readEmbeddingRows(f, rows + 1, dim, forceCopy: true), throwsStateError);
  });
}
