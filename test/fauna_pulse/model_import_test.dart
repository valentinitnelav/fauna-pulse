// Round 275: one import for every model file (model_import.dart): each file
// goes where its kind lives, a file already on the phone is replaced only
// when the user says so, files the app cannot use are refused with the
// reason, and the link dialog's names.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/model_import.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_file_kind_test.dart' show fakeTflite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;
  late Directory src;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('model_import');
    src = Directory('${tmp.path}/picked')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => '${tmp.path}/app',
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    tmp.deleteSync(recursive: true);
  });

  (String, String) pick(String name, List<int> bytes) {
    File('${src.path}/$name').writeAsBytesSync(bytes);
    return (name, '${src.path}/$name');
  }

  final detector = fakeTflite([[1, 640, 640, 3]], [[1, 5, 8400]]);
  final classifier = fakeTflite([[1, 3, 224, 224]], [[1, 164]]);
  final pack = File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync();

  test('each file goes where its kind lives; the others are refused with the reason', () async {
    final asked = <String>[];
    final r = await ModelImport.importFiles(
      [
        pick('my_bees_640.tflite', detector),
        pick('insectdct-cls-v7_eff2s_fp16.tflite', classifier),
        pick('tiny_pack.fpack', pack),
        pick('text_tower.tflite', fakeTflite([[1, 77]], [[1, 768]])),
        pick('my model.tflite', detector),
        ('lost.tflite', null),
      ],
      replace: (name, kind, filesLeft) async {
        asked.add(name);
        return true;
      },
    );
    expect(r.imported, [
      ('my_bees_640.tflite', ModelFileKind.detection),
      ('insectdct-cls-v7_eff2s_fp16.tflite', ModelFileKind.identification),
      ('tiny_pack.fpack', ModelFileKind.nameList),
    ]);
    expect(asked, isEmpty, reason: 'nothing was on the phone');
    expect(File('${tmp.path}/app/models/my_bees_640.tflite').existsSync(), isTrue);
    expect(File('${tmp.path}/app/identification/models/insectdct-cls-v7_eff2s_fp16.tflite').existsSync(), isTrue);
    expect(File('${tmp.path}/app/identification/packs/tiny_pack.fpack').existsSync(), isTrue);
    expect(File('${tmp.path}/app/models/insectdct-cls-v7_eff2s_fp16.tflite').existsSync(), isFalse);
    expect(r.rejected, hasLength(3));
    expect(r.rejected[0], startsWith('text_tower.tflite: not a model for pictures'));
    expect(r.rejected[1], startsWith('my model.tflite: not a safely named model file'));
    expect(r.rejected[2], 'lost.tflite: the chosen file could not be read.');
    expect(r.namesOf(ModelFileKind.detection), ['my_bees_640.tflite']);
    expect(r.namesOf(ModelFileKind.identification), ['insectdct-cls-v7_eff2s_fp16.tflite']);
    expect(r.namesOf(ModelFileKind.nameList), ['tiny_pack.fpack']);
  });

  test('a file already on the phone is replaced only when the user says so', () async {
    await ModelImport.importFiles([pick('my_bees_640.tflite', detector)], replace: (_, _, _) async => true);
    final onPhone = File('${tmp.path}/app/models/my_bees_640.tflite');
    final newer = fakeTflite([[1, 320, 320, 3]], [[1, 6, 2100]]);
    final asked = <(String, ModelFileKind, int)>[];
    final kept = await ModelImport.importFiles(
      [pick('my_bees_640.tflite', newer), pick('other.tflite', detector)],
      replace: (name, kind, filesLeft) async {
        asked.add((name, kind, filesLeft));
        return false;
      },
    );
    expect(asked, [('my_bees_640.tflite', ModelFileKind.detection, 1)], reason: 'one more file after it');
    expect(kept.imported, [('other.tflite', ModelFileKind.detection)]);
    expect(kept.kept, ['my_bees_640.tflite']);
    expect(onPhone.readAsBytesSync(), detector);
    final replaced = await ModelImport.importFiles([pick('my_bees_640.tflite', newer)], replace: (_, _, _) async => true);
    expect(replaced.imported.single.$1, 'my_bees_640.tflite');
    expect(onPhone.readAsBytesSync(), newer);
  });

  test('before a link download: where a name is on the phone already', () async {
    await ModelImport.importFiles(
      [pick('det.tflite', detector), pick('cls.tflite', classifier), pick('tiny_pack.fpack', pack)],
      replace: (_, _, _) async => true,
    );
    expect(await ModelImport.onPhoneAs('det.tflite'), [ModelFileKind.detection]);
    expect(await ModelImport.onPhoneAs('cls.tflite'), [ModelFileKind.identification]);
    expect(await ModelImport.onPhoneAs('tiny_pack.fpack'), [ModelFileKind.nameList]);
    expect(await ModelImport.onPhoneAs('other.tflite'), isEmpty);
  });

  test('links to every kind of file the app can use', () {
    expect(ModelImport.linkFileName('https://host/r/bioclip2_flower_visitors_32fam_v1.fpack'), 'bioclip2_flower_visitors_32fam_v1.fpack');
    expect(ModelImport.linkFileName('https://host/r/insectdct-cls-v7_eff2s_fp16.tflite?x=1'), 'insectdct-cls-v7_eff2s_fp16.tflite');
    expect(ModelImport.linkFileName('https://host/r/m_qnn.onnx'), 'm_qnn.onnx');
    expect(ModelImport.linkFileName('https://host/r/m.onnx'), isNull);
    expect(ModelImport.linkFileName('http://host/r/m.fpack'), isNull);
    expect(ModelImport.linkFileName('https://host/r/%2e%2e%2fx.fpack'), isNull);
  });
}
