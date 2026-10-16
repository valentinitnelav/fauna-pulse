// FaunaPulse (round 314): when the models moved to Hugging Face, the app's
// download list (assets/model_downloads.json) took the names of the published
// files (the naming rule of fauna-pulse-models). A file downloaded before
// under its old name counted as "not on the phone": the "What do you want to
// watch?" pages said "Download and use" for a model the phone had, and the
// old file sat under "Other models on this phone" (owner, round 314).
//
// At start the app gives such files their new name (the same file: same
// size) and changes the saved choices that name them (camera, Find animals,
// Identify, the remembered choice of each answer). The insectDCT class list
// from before names its model by the old file name inside the file, so
// Identify could not use it with the renamed model: it is deleted (14 kB),
// and Download & import models offers the new one. A session analysed
// before keeps the old names: a stopped video run can still be continued
// (currentModelPath), and stored identification vectors get the new name
// when Identify looks for them (IdentificationPaths).

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_error_hooks.dart';
import 'model_choice_keys.dart';

/// Old file name → new file name and the file's size in bytes.
const kFormerModelNames = <String, (String, int)>{
  'MDV6-yolov10-c_int8_256.tflite': ('mdv6-yolov10c_256_w8a32.tflite', 2548785),
  'insectdct-v8-s_640_fp16.tflite': ('insectdct-v8s_640_fp16.tflite', 19206825),
  'insectdct-cls-v7_eff2s_fp16.tflite': ('insectdct-cls-v7-eff2s_224_fp16.tflite', 43853456),
  'bioclip-2_image_fp16_4d.tflite': ('bioclip-2_224_fp16.tflite', 609466720),
  'bioclip2_pollinator_orders_europe_v1.fpack': ('bioclip-2_pollinator-orders-europe_v1.fpack', 57479207),
  'bioclip2_flower_visitors_32fam_v1.fpack': ('bioclip-2_flower-visitors-32fam_v1.fpack', 62754369),
  'bioclip-25_image_fp16.tflite': ('bioclip-2.5_224_fp16.tflite', 1266232624),
  'bioclip25_pollinator_orders_europe_v1.fpack': ('bioclip-2.5_pollinator-orders-europe_v1.fpack', 74339217),
  'bioclip25_flower_visitors_32fam_v1.fpack': ('bioclip-2.5_flower-visitors-32fam_v1.fpack', 80131038),
};

/// [path] (a model file's path or name) with the new name when its file
/// name is an old one, for comparing with what a session recorded before.
String currentModelPath(String path) {
  final i = path.lastIndexOf('/');
  final now = kFormerModelNames[path.substring(i + 1)];
  return now == null ? path : '${path.substring(0, i + 1)}${now.$1}';
}

/// The insectDCT class list from before (name, size in bytes) and the old
/// name of its model.
const kFormerClassList = ('insectdct-cls-v7_eff2s_fp16.fpack', 13737, 'insectdct-cls-v7_eff2s_fp16.tflite');

/// Renames the files in [dirs] that have an old name of [names] and its size,
/// unless the new name is taken, and deletes the old class list
/// ([kFormerClassList]) once its model has no file under the old name.
/// Returns old name → new name of the renamed files.
Map<String, String> renameFormerFiles(
  List<Directory> dirs, {
  Map<String, (String, int)> names = kFormerModelNames,
  (String, int, String) classList = kFormerClassList,
}) {
  final renamed = <String, String>{};
  for (final dir in dirs) {
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(followLinks: false).whereType<File>()) {
      final old = f.uri.pathSegments.last;
      final (newName, bytes) = names[old] ?? ('', -1);
      final target = File('${dir.path}/$newName');
      if (newName.isEmpty || f.lengthSync() != bytes || target.existsSync()) continue;
      f.renameSync(target.path);
      renamed[old] = newName;
    }
  }
  final (listName, listBytes, oldModel) = classList;
  final oldModelLeft = dirs.any((d) => File('${d.path}/$oldModel').existsSync());
  for (final dir in dirs) {
    final list = File('${dir.path}/$listName');
    if (!oldModelLeft && list.existsSync() && list.lengthSync() == listBytes) list.deleteSync();
  }
  return renamed;
}

/// The saved choices that hold model file names or paths.
bool _holdsModelNames(String key) =>
    key == kSessionConfigPref ||
    key == kAnalysisModelPref ||
    key == kVideoAnalysisModelPref ||
    key == kIdentifyModelPref ||
    key == kIdentifyPackPref ||
    key.startsWith(kWatchChoicePrefPrefix);

/// Writes the new names of [renamed] (old → new) into the saved choices.
Future<void> renameInSavedChoices(SharedPreferences prefs, Map<String, String> renamed) async {
  String fix(String s) => renamed.entries.fold(s, (t, e) => t.replaceAll(e.key, e.value));
  for (final key in prefs.getKeys().where(_holdsModelNames)) {
    final value = prefs.get(key);
    if (value is String && fix(value) != value) await prefs.setString(key, fix(value));
    if (value is List) {
      final list = value.cast<String>();
      final fixed = list.map(fix).toList();
      if (fixed.join('\n') != list.join('\n')) await prefs.setStringList(key, fixed);
    }
  }
}

/// Run once at start, before any screen reads the files or the choices.
Future<void> renameFormerModelFiles() async {
  try {
    final base = (await getApplicationSupportDirectory()).path;
    final renamed = renameFormerFiles([
      Directory('$base/models'),
      Directory('$base/identification/models'),
      Directory('$base/identification/packs'),
    ]);
    if (renamed.isNotEmpty) await renameInSavedChoices(await SharedPreferences.getInstance(), renamed);
  } catch (e) {
    logSwallowed('former_model_names', e);
  }
}
