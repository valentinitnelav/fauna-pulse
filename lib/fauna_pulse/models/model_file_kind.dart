// FaunaPulse (round 275): what a model file is, read from the file itself,
// so an imported or downloaded file goes where it belongs and a classifier
// cannot end up among the detection models (owner: "how would we make sure a
// user doesn't confuse a detector with a classifier since they are both
// tflite files").
//
// A .tflite file is a FlatBuffer (tensorflow/lite/schema/schema.fbs). Only
// the shapes of its main graph's input and output tensors are read: a few
// small reads, also in a 1.3 GB file.
//   • Detection model: the first output is a table of boxes, 3 numbers deep:
//     [1, 4 + classes, candidates] (e.g. [1, 5, 8400]), or [1, 300, 6] for
//     end-to-end exports such as MegaDetector V6.
//   • Identification model: every output is one row of numbers per picture,
//     [1, n]: the class scores of a classifier (insectDCT [1, 164]) or the
//     BioCLIP embedding ([1, 768]).
//   • Both take a picture: a 4-number input, [1, H, W, 3] or [1, 3, H, W].
// The rule holds for the 33 model files of the project (checked round 275).
// A name list (.fpack) is recognised by its header, and an Ultralytics
// Snapdragon NPU export (*_qnn.onnx) is always a detection model.

import 'dart:io';
import 'dart:typed_data';

import '../identification/label_pack.dart';
import 'model_file_security.dart' show isQnnModelPath;

enum ModelFileKind {
  detection('detection model'),
  identification('identification model'),
  nameList('name list');

  final String label;
  const ModelFileKind(this.label);

  /// "a detection model", "an identification model", "a name list".
  String get withArticle => '${this == identification ? 'an' : 'a'} $label';
}

/// The input and output tensor shapes of a .tflite file's main graph.
class TfliteShapes {
  final List<List<int>> inputs;
  final List<List<int>> outputs;
  const TfliteShapes(this.inputs, this.outputs);
}

/// What [file] (named [name]) is. Throws an Exception with a plain reason
/// when the app cannot use it.
Future<ModelFileKind> modelFileKind(File file, String name) async {
  final lower = name.toLowerCase();
  if (lower.endsWith('.fpack')) {
    try {
      await LabelPack.readHeader(file);
    } catch (_) {
      throw Exception('not a name list made for this app.');
    }
    return ModelFileKind.nameList;
  }
  if (isQnnModelPath(lower)) return ModelFileKind.detection;
  if (!lower.endsWith('.tflite')) {
    throw Exception('not a model file (.tflite) or a name list (.fpack).');
  }
  final TfliteShapes shapes;
  try {
    shapes = await readTfliteShapes(file);
  } catch (_) {
    throw Exception('could not be read as a TFLite model.');
  }
  return kindFromShapes(shapes);
}

/// The rule above; throws an Exception with a plain reason.
ModelFileKind kindFromShapes(TfliteShapes s) {
  final input = s.inputs.isEmpty ? const <int>[] : s.inputs.first;
  if (input.length != 4 || (input[1] != 3 && input[3] != 3)) {
    throw Exception('not a model for pictures (its input is not a colour picture).');
  }
  if (s.outputs.isNotEmpty && s.outputs.first.length == 3) return ModelFileKind.detection;
  if (s.outputs.isNotEmpty && s.outputs.every((o) => o.length == 2)) return ModelFileKind.identification;
  throw Exception(
    'gives neither boxes (a detection model) nor one answer per picture (an identification model).',
  );
}

/// Reads [TfliteShapes] from [file]; throws a FormatException when it is not
/// a readable TFLite FlatBuffer.
Future<TfliteShapes> readTfliteShapes(File file) async {
  final r = _FlatReader(await file.open(), await file.length());
  try {
    if (String.fromCharCodes([for (var i = 4; i < 8; i++) await r.byte(i)]) != 'TFL3') {
      throw const FormatException('no TFL3 identifier');
    }
    // Model: field 2 = subgraphs. SubGraph: 0 = tensors, 1 = inputs,
    // 2 = outputs. Tensor: 0 = shape.
    final model = await r.deref(0);
    final subgraphs = await r.vector(model, 2);
    if (subgraphs == null || await r.length(subgraphs) == 0) {
      throw const FormatException('no graph');
    }
    final graph = await r.tableAt(subgraphs, 0);
    final tensors = await r.vector(graph, 0);
    if (tensors == null) throw const FormatException('no tensors');
    final count = await r.length(tensors);
    Future<List<int>> shape(int index) async {
      if (index < 0 || index >= count) throw const FormatException('tensor index outside the graph');
      return r.ints(await r.vector(await r.tableAt(tensors, index), 0));
    }

    return TfliteShapes(
      [for (final i in await r.ints(await r.vector(graph, 1))) await shape(i)],
      [for (final i in await r.ints(await r.vector(graph, 2))) await shape(i)],
    );
  } finally {
    await r.close();
  }
}

/// Little-endian FlatBuffer reads at file positions, through 4 KB pages.
class _FlatReader {
  final RandomAccessFile _f;
  final int _length;
  final _pages = <int, Uint8List>{};
  static const _pageSize = 4096;

  _FlatReader(this._f, this._length);

  Future<void> close() => _f.close();

  Future<int> byte(int pos) async {
    if (pos < 0 || pos >= _length) throw const FormatException('offset outside the file');
    final page = pos ~/ _pageSize;
    var bytes = _pages[page];
    if (bytes == null) {
      await _f.setPosition(page * _pageSize);
      bytes = _pages[page] = await _f.read(_pageSize);
    }
    return bytes[pos - page * _pageSize];
  }

  Future<int> _uint(int pos, int n) async {
    var v = 0;
    for (var i = n - 1; i >= 0; i--) {
      v = (v << 8) | await byte(pos + i);
    }
    return v;
  }

  Future<int> u16(int pos) => _uint(pos, 2);
  Future<int> u32(int pos) => _uint(pos, 4);
  Future<int> i32(int pos) async => (await u32(pos)).toSigned(32);

  /// The table or vector that the offset at [pos] points to.
  Future<int> deref(int pos) async => pos + await u32(pos);

  /// Where [field] of the table at [table] is stored; null when absent.
  Future<int?> field(int table, int field) async {
    final vtable = table - await i32(table);
    final at = 4 + 2 * field;
    if (at + 2 > await u16(vtable)) return null;
    final offset = await u16(vtable + at);
    return offset == 0 ? null : table + offset;
  }

  /// The vector in [field] of [table]; null when absent.
  Future<int?> vector(int table, int field) async {
    final at = await this.field(table, field);
    return at == null ? null : deref(at);
  }

  Future<int> length(int vector) async {
    final n = await u32(vector);
    if (n > 1 << 20) throw const FormatException('vector too long');
    return n;
  }

  /// The table at index [i] of a vector of tables.
  Future<int> tableAt(int vector, int i) => deref(vector + 4 + 4 * i);

  /// A vector of 32-bit numbers (empty when absent).
  Future<List<int>> ints(int? vector) async {
    if (vector == null) return const [];
    final n = await length(vector);
    return [for (var i = 0; i < n; i++) await i32(vector + 4 + 4 * i)];
  }
}
