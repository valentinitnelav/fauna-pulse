// Round 275: what a model file is, read from the file (model_file_kind.dart):
// the input and output shapes of a .tflite file, the detection /
// identification rule, name lists and Snapdragon NPU exports. Small TFLite
// FlatBuffers are written here; the project's real model files are checked
// too when they are on this computer (skipped elsewhere).

import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/models/model_file_kind.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal TFLite FlatBuffer: one graph whose input and output tensors
/// have [inputs] and [outputs] shapes. Laid out front to back, so every
/// offset points forward as FlatBuffers require.
Uint8List fakeTflite(List<List<int>> inputs, List<List<int>> outputs) {
  final b = <int>[];
  void u16(int v) => b.addAll([v & 0xff, (v >> 8) & 0xff]);
  void u32(int v) => b.addAll([for (var i = 0; i < 4; i++) (v >> (8 * i)) & 0xff]);
  void setU32(int at, int v) {
    for (var i = 0; i < 4; i++) {
      b[at + i] = (v >> (8 * i)) & 0xff;
    }
  }

  // A table of [n] fields where [present] ones are offsets: returns the
  // positions of those fields.
  Map<int, int> table(int n, Set<int> present) {
    final vtable = b.length;
    u16(4 + 2 * n);
    u16(4 + 4 * present.length);
    var at = 4;
    for (var f = 0; f < n; f++) {
      if (present.contains(f)) {
        u16(at);
        at += 4;
      } else {
        u16(0);
      }
    }
    final start = b.length;
    u32(start - vtable);
    final fields = <int, int>{};
    for (final f in present.toList()..sort()) {
      fields[f] = b.length;
      u32(0);
    }
    return fields;
  }

  int tableStart(Map<int, int> fields) => fields.values.reduce((a, c) => a < c ? a : c) - 4;
  void point(int at) => setU32(at, b.length - at);
  void ints(List<int> v) {
    u32(v.length);
    v.forEach(u32);
  }

  u32(0); // root offset
  b.addAll('TFL3'.codeUnits);
  final model = table(3, {2});
  setU32(0, tableStart(model));
  point(model[2]!);
  u32(1);
  final graphAt = b.length;
  u32(0);
  final graph = table(3, {0, 1, 2});
  setU32(graphAt, tableStart(graph) - graphAt);
  final shapes = [...inputs, ...outputs];
  point(graph[0]!);
  u32(shapes.length);
  final tensorAt = [for (var i = 0; i < shapes.length; i++) b.length + 4 * i];
  for (var i = 0; i < shapes.length; i++) {
    u32(0);
  }
  point(graph[1]!);
  ints([for (var i = 0; i < inputs.length; i++) i]);
  point(graph[2]!);
  ints([for (var i = 0; i < outputs.length; i++) inputs.length + i]);
  for (var i = 0; i < shapes.length; i++) {
    final t = table(1, {0});
    setU32(tensorAt[i], tableStart(t) - tensorAt[i]);
    point(t[0]!);
    ints(shapes[i]);
  }
  return Uint8List.fromList(b);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('model_kind'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String name, List<int> bytes) => File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  test('reads the input and output shapes of a TFLite file', () async {
    final f = write('m.tflite', fakeTflite([[1, 640, 640, 3]], [[1, 5, 8400]]));
    final s = await readTfliteShapes(f);
    expect(s.inputs, [[1, 640, 640, 3]]);
    expect(s.outputs, [[1, 5, 8400]]);
  });

  test('a table of boxes is a detection model; one row per picture an identification model', () async {
    Future<ModelFileKind> kind(List<List<int>> inputs, List<List<int>> outputs) =>
        modelFileKind(write('m.tflite', fakeTflite(inputs, outputs)), 'm.tflite');
    expect(await kind([[1, 640, 640, 3]], [[1, 5, 8400]]), ModelFileKind.detection, reason: 'YOLO');
    expect(await kind([[1, 256, 256, 3]], [[1, 300, 6]]), ModelFileKind.detection, reason: 'end-to-end');
    expect(await kind([[1, 3, 1024, 1024]], [[1, 5, 21504]]), ModelFileKind.detection, reason: 'channels first');
    expect(await kind([[1, 3, 224, 224]], [[1, 164]]), ModelFileKind.identification, reason: 'classifier');
    expect(await kind([[1, 3, 224, 224]], [[1, 768]]), ModelFileKind.identification, reason: 'BioCLIP');
    expect(await kind([[1, 224, 224, 3]], [[1, 10], [1, 4]]), ModelFileKind.identification, reason: 'two heads');
  });

  test('a file the app cannot use says why', () async {
    Future<void> refused(String name, List<int> bytes, String why) => expectLater(
      modelFileKind(write(name, bytes), name),
      throwsA(predicate((e) => '$e'.contains(why), why)),
    );
    await refused('text.tflite', fakeTflite([[1, 77]], [[1, 768]]), 'not a model for pictures');
    await refused('mask.tflite', fakeTflite([[1, 640, 640, 3]], [[1, 32, 160, 160]]), 'neither boxes');
    await refused('none.tflite', fakeTflite([[1, 640, 640, 3]], []), 'neither boxes');
    await refused('junk.tflite', List.filled(64, 7), 'could not be read as a TFLite model');
    final cut = fakeTflite([[1, 640, 640, 3]], [[1, 5, 8400]]);
    await refused('cut.tflite', cut.sublist(0, cut.length - 12), 'could not be read as a TFLite model');
    await refused('list.fpack', [1, 2, 3, 4, 5, 6, 7, 8], 'not a name list');
    await refused('notes.txt', [1], 'not a model file');
  });

  test('name lists by their header, NPU exports by their name', () async {
    final pack = File('test/fauna_pulse/fixtures/tiny_pack.fpack');
    expect(await modelFileKind(pack, 'tiny_pack.fpack'), ModelFileKind.nameList);
    expect(await modelFileKind(write('m_qnn.onnx', [1, 2, 3]), 'm_qnn.onnx'), ModelFileKind.detection);
  });

  // The rule on real exports (laptop only): YOLO detectors, MegaDetector V6
  // (end-to-end), flat-bug and insectDCT detectors; insectDCT classifiers and
  // the BioCLIP image tower.
  final root = Directory.current.path;
  final detectors = [
    for (final d in ['$root/../weights', '$root/tool/detector_export/out'])
      if (Directory(d).existsSync())
        ...Directory(d).listSync().whereType<File>().where((f) => f.path.endsWith('.tflite')),
  ];
  final identifiers = [
    for (final d in ['$root/tool/classifier_export/out', '$root/tool/bioclip_export/out'])
      if (Directory(d).existsSync())
        ...Directory(d).listSync().whereType<File>().where((f) => f.path.endsWith('.tflite')),
  ];
  test(
    'the project\'s own model files are recognised',
    () async {
      for (final f in detectors) {
        expect(await modelFileKind(f, f.path.split('/').last), ModelFileKind.detection, reason: f.path);
      }
      for (final f in identifiers) {
        expect(await modelFileKind(f, f.path.split('/').last), ModelFileKind.identification, reason: f.path);
      }
    },
    skip: detectors.isEmpty && identifiers.isEmpty ? 'no model files on this computer' : false,
  );
}
