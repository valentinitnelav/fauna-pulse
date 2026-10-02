// FaunaPulse (round 278): what the home screen's step 1 ("AI models") says,
// counted from the file names only: the home screen opens often, and
// inspecting every model or reading every name list header (megabytes of
// names) would slow it down.
//
// Also "Use them from now on" of the "What do you want to watch?" page: the
// downloaded files become the choice of the camera, of Find animals (photos
// and videos) and of Identify, as if the user had chosen each on its screen.

import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';

import '../identification/identification_assets.dart';
import '../identification/identification_store.dart' show modelIdOf, modelKey, stemOf;
import '../logging/app_error_hooks.dart';
import 'model_catalog.dart';
import 'model_choice_keys.dart';
import 'session_config.dart';

/// How many models of each kind are on the phone.
class ModelsOnPhone {
  /// Detection models (they find the animals).
  final int detectors;

  /// Identification models that have a name list (they name the animals).
  final int namers;

  const ModelsOnPhone({this.detectors = 0, this.namers = 0});

  bool get none => detectors == 0 && namers == 0;

  static Future<ModelsOnPhone> count() async {
    try {
      final dir = await ModelCatalog.modelsDir();
      final detectors = dir.listSync().whereType<File>().where((f) => isSupportedModelFileName(f.path)).length;
      final models = await IdentificationAssets.listModels();
      final packs = await IdentificationAssets.listPacks();
      return ModelsOnPhone(detectors: detectors, namers: namersOf(models, packs));
    } catch (e) {
      logSwallowed('models_on_phone', e);
      return const ModelsOnPhone();
    }
  }

  /// How many of the identification [models] have a name list in [packs],
  /// by file name only (no header read, unlike the Identify screen): a class
  /// list by the model's own name, a label pack by the first part of the name
  /// (the naming rule; older names such as bioclip2_… and bioclip-2_… alike).
  /// A renamed list is not counted here but still works on Identify.
  static int namersOf(List<File> models, List<File> packs) => models
      .where(
        (m) => packs.any(
          (p) => stemOf(p.path) == stemOf(m.path) || modelKey(modelIdOf(p.path)) == modelKey(modelIdOf(m.path)),
        ),
      )
      .length;

  /// "3 to find animals, 2 to name them".
  String get summary {
    String n(int k) => k == 0 ? 'none' : '$k';
    return 'On this phone: ${n(detectors)} to find animals, ${n(namers)} to name them.';
  }
}

/// The names of the model files on the phone (a file of the download list
/// counts as present by its name, as on Download & import models).
Future<Set<String>> modelFileNamesOnPhone() async {
  try {
    final dir = await ModelCatalog.modelsDir();
    return {
      for (final f in dir.listSync().whereType<File>())
        if (isSupportedModelFileName(f.path)) f.path.split('/').last,
      for (final f in [...await IdentificationAssets.listModels(), ...await IdentificationAssets.listPacks()])
        f.path.split('/').last,
    };
  } catch (e) {
    logSwallowed('model_names_on_phone', e);
    return const {};
  }
}

/// Makes the detection model file [detector] the model of the camera and of
/// Find animals, and the identification model [idModel] with its name list
/// [nameList] the choice of Identify (file names; each when given).
Future<void> useModels({String? detector, String? idModel, String? nameList}) async {
  final prefs = await SharedPreferences.getInstance();
  if (detector != null) {
    final entry = await ModelCatalog.entryOf(File('${(await ModelCatalog.modelsDir()).path}/$detector'));
    final config = await SessionConfig.load();
    await config
        .copyWith(modelPath: entry.id, task: YOLOTaskParsing.tryParse(entry.task) ?? config.task)
        .save();
    await prefs.setString(kAnalysisModelPref, entry.id);
    await prefs.setString(kVideoAnalysisModelPref, entry.id);
  }
  if (idModel != null && nameList != null) {
    await prefs.setString(kIdentifyModelPref, idModel);
    await prefs.setString(kIdentifyPackPref, nameList);
  }
}
