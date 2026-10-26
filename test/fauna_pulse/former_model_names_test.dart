// Round 314: files downloaded before the models moved to Hugging Face get the
// names of the download list at start, and the saved choices follow them.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/models/former_model_names.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_choice_keys.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late Directory models, packs;
  setUp(() {
    root = Directory.systemTemp.createTempSync('former_names');
    models = Directory('${root.path}/models')..createSync();
    packs = Directory('${root.path}/packs')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  File file(Directory d, String name, int bytes) => File('${d.path}/$name')..writeAsBytesSync(List.filled(bytes, 1));
  List<String> names(Directory d) => d.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  const table = {
    'old_model.tflite': ('new-model_224_fp16.tflite', 10),
    'old_list_v1.fpack': ('new-model_list_v1.fpack', 5),
  };

  test('every new name is a file of the download list, with the same size', () {
    final list = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
    final files = {
      for (final d in [...list.detectors, ...list.identification])
        if (d.file case final f?) f.name: f.bytes,
      // The v1 label packs are no longer offered (round 322) but stay known.
      for (final d in [...list.detectors, ...list.identification])
        for (final l in [...d.nameLists, ...d.formerNameLists]) l.file.name: l.file.bytes,
    };
    for (final MapEntry(key: old, value: (name, bytes)) in kFormerModelNames.entries) {
      expect(files[name], bytes, reason: '$old → $name');
    }
    expect(files.containsKey(kFormerClassList.$1), isFalse, reason: 'the old class list is not offered');
  });

  test('renames a file with an old name and its size, keeps the rest', () {
    file(models, 'old_model.tflite', 10);
    file(packs, 'old_list_v1.fpack', 5);
    file(models, 'my_own.tflite', 10);
    final renamed = renameFormerFiles([models, packs], names: table, classList: ('x.fpack', 1, 'x.tflite'));
    expect(renamed, {'old_model.tflite': 'new-model_224_fp16.tflite', 'old_list_v1.fpack': 'new-model_list_v1.fpack'});
    expect(names(models), ['my_own.tflite', 'new-model_224_fp16.tflite']);
    expect(names(packs), ['new-model_list_v1.fpack']);
  });

  test('another size, or the new name already taken: nothing renamed', () {
    file(models, 'old_model.tflite', 11);
    file(packs, 'old_list_v1.fpack', 5);
    file(packs, 'new-model_list_v1.fpack', 5);
    expect(renameFormerFiles([models, packs], names: table, classList: ('x.fpack', 1, 'x.tflite')), isEmpty);
    expect(names(models), ['old_model.tflite']);
    expect(names(packs), ['new-model_list_v1.fpack', 'old_list_v1.fpack']);
  });

  test('the old class list goes once its model has the new name, not before', () {
    file(packs, 'cls_old.fpack', 3);
    file(models, 'cls_old.tflite', 7);
    const renames = {'cls_old.tflite': ('cls-new_224_fp16.tflite', 7)};
    renameFormerFiles([models, packs], names: {}, classList: ('cls_old.fpack', 3, 'cls_old.tflite'));
    expect(names(packs), ['cls_old.fpack'], reason: 'its model still has the old name');
    renameFormerFiles([models, packs], names: renames, classList: ('cls_old.fpack', 4, 'cls_old.tflite'));
    expect(names(models), ['cls-new_224_fp16.tflite']);
    expect(names(packs), ['cls_old.fpack'], reason: 'another size: not the published list');
    renameFormerFiles([models, packs], names: renames, classList: ('cls_old.fpack', 3, 'cls_old.tflite'));
    expect(names(packs), isEmpty);
  });

  test('the saved choices follow the new names; other settings stay', () async {
    SharedPreferences.setMockInitialValues({
      kSessionConfigPref: jsonEncode({'modelPath': '/data/x/models/old_model.tflite', 'note': 'old_model.tflite'}),
      kAnalysisModelPref: '/data/x/models/old_model.tflite',
      kVideoAnalysisModelPref: '/data/x/models/my_own.tflite',
      kIdentifyModelPref: 'old_model.tflite',
      kIdentifyPackPref: 'old_list_v1.fpack',
      '${kWatchChoicePrefPrefix}pollinators': ['old_model.tflite', 'old_model.tflite', 'old_list_v1.fpack'],
      'field_note': 'old_model.tflite',
    });
    final prefs = await SharedPreferences.getInstance();
    await renameInSavedChoices(prefs, {for (final e in table.entries) e.key: e.value.$1});
    expect(jsonDecode(prefs.getString(kSessionConfigPref)!)['modelPath'], '/data/x/models/new-model_224_fp16.tflite');
    expect(prefs.getString(kAnalysisModelPref), '/data/x/models/new-model_224_fp16.tflite');
    expect(prefs.getString(kVideoAnalysisModelPref), '/data/x/models/my_own.tflite');
    expect(prefs.getString(kIdentifyModelPref), 'new-model_224_fp16.tflite');
    expect(prefs.getString(kIdentifyPackPref), 'new-model_list_v1.fpack');
    expect(prefs.getStringList('${kWatchChoicePrefPrefix}pollinators'),
        ['new-model_224_fp16.tflite', 'new-model_224_fp16.tflite', 'new-model_list_v1.fpack']);
    expect(prefs.getString('field_note'), 'old_model.tflite', reason: 'not a saved choice');
  });

  test('a stopped video run made with the old name can be continued', () {
    expect(currentModelPath('/data/x/models/MDV6-yolov10-c_int8_256.tflite'), '/data/x/models/mdv6-yolov10c_256_w8a32.tflite');
    expect(currentModelPath('insectdct-v8-s_640_fp16.tflite'), 'insectdct-v8s_640_fp16.tflite');
    expect(currentModelPath('/data/x/models/my_own.tflite'), '/data/x/models/my_own.tflite');
    final settings = {'model': '/m/insectdct-v8-s_640_fp16.tflite', 'confidence': 0.25, 'iou': 0.5};
    final resume = VideoResume.parse([jsonEncode({'type': 'video_run_start', 'settings': settings})]);
    expect(jsonEncode(resume.settings), jsonEncode({...settings, 'model': '/m/insectdct-v8s_640_fp16.tflite'}),
        reason: 'same keys in the same order, as the run compares them');
  });

  test("a session's identification vectors under the old model name are found under the new one", () {
    final paths = IdentificationPaths(root)..dir.createSync();
    File('${paths.dir.path}/embeddings_bioclip-2_image_fp16_4d.jsonl').writeAsStringSync('{}\n');
    File('${paths.dir.path}/embeddings_bioclip-2_image_fp16_4d.bin').writeAsBytesSync([1, 2, 3, 4]);
    expect(paths.embeddingsJsonl('bioclip-2_224_fp16').readAsStringSync(), '{}\n');
    expect(paths.embeddingsBin('bioclip-2_224_fp16').lengthSync(), 4);
    expect(names(paths.dir), ['embeddings_bioclip-2_224_fp16.bin', 'embeddings_bioclip-2_224_fp16.jsonl']);
    // Vectors under the new name already: the old ones are left alone.
    File('${paths.dir.path}/embeddings_bioclip-25_image_fp16.jsonl').writeAsStringSync('old');
    File('${paths.dir.path}/embeddings_bioclip-2.5_224_fp16.jsonl').writeAsStringSync('new');
    expect(paths.embeddingsJsonl('bioclip-2.5_224_fp16').readAsStringSync(), 'new');
    expect(File('${paths.dir.path}/embeddings_bioclip-25_image_fp16.jsonl').existsSync(), isTrue);
  });
}
