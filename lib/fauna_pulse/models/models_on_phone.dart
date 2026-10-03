// FaunaPulse (round 278): what the home screen's step 1 ("AI models") says,
// counted from the file names only: the home screen opens often, and
// inspecting every model or reading every name list header (megabytes of
// names) would slow it down.
//
// Also the button of the "What do you want to watch?" page: the downloaded
// files become the choice of the camera, of Find animals (photos and videos)
// and of Identify, as if the user had chosen each on its screen.
//
// Round 279 (owner: make it clear on the home screen that things were set up
// for the user): currentModelChoice reads that choice back, by file name.
// Round 280 (owner): "Not now" for naming clears Identify's choice, so the
// home screen and Identify agree that nothing names the animals.
// Round 281 (owner: models already on the phone, such as one's own trained
// detector, could not be chosen on those pages): ModelFilesOnPhone lists the
// files by kind, with each identification model's name lists by name.
// Round 286 (owner): each answer remembers its own models (watchChoices), so
// a tap on its tile can switch back to them.

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

  /// How many of the identification [models] have a name list in [packs]
  /// ([namingPairs]).
  static int namersOf(List<File> models, List<File> packs) =>
      namingPairs(models.map((f) => f.path.split('/').last), packs.map((f) => f.path.split('/').last))
          .map((p) => p.$1)
          .toSet()
          .length;

  /// "3 to find animals, 2 to name them".
  String get summary {
    String n(int k) => k == 0 ? 'none' : '$k';
    return 'On this phone: ${n(detectors)} to find animals, ${n(namers)} to name them.';
  }
}

/// The identification [models] each with every name list of [lists] that
/// goes with it, as file names sorted by name, by file name only (no header
/// read, unlike the Identify screen): a class list by the model's own name
/// (and with no other model), a label pack by the first part of the name
/// (the naming rule; older names such as bioclip2_… and bioclip-2_… alike).
/// A renamed list is not found here but still works on Identify.
List<(String, String)> namingPairs(Iterable<String> models, Iterable<String> lists) {
  final ms = [...models]..sort();
  final ls = [...lists]..sort();
  final stems = {for (final m in ms) stemOf(m)};
  return [
    for (final m in ms)
      for (final l in ls)
        if (stemOf(l) == stemOf(m) || (!stems.contains(stemOf(l)) && modelKey(modelIdOf(l)) == modelKey(modelIdOf(m))))
          (m, l),
  ];
}

/// The model files on the phone by kind, as file names (a file of the
/// download list counts as present by its name, as on Download & import
/// models).
class ModelFilesOnPhone {
  final Set<String> detectors;
  final Set<String> idModels;
  final Set<String> nameLists;

  const ModelFilesOnPhone({this.detectors = const {}, this.idModels = const {}, this.nameLists = const {}});

  Set<String> get all => {...detectors, ...idModels, ...nameLists};

  bool has(String name) => detectors.contains(name) || idModels.contains(name) || nameLists.contains(name);

  /// Each identification model with each of its name lists ([namingPairs]).
  List<(String, String)> get namings => namingPairs(idModels, nameLists);

  static Future<ModelFilesOnPhone> load() async {
    Set<String> names(Iterable<File> files) => {for (final f in files) f.path.split('/').last};
    try {
      final dir = await ModelCatalog.modelsDir();
      return ModelFilesOnPhone(
        detectors: names(dir.listSync().whereType<File>().where((f) => isSupportedModelFileName(f.path))),
        idModels: names(await IdentificationAssets.listModels()),
        nameLists: names(await IdentificationAssets.listPacks()),
      );
    } catch (e) {
      logSwallowed('model_names_on_phone', e);
      return const ModelFilesOnPhone();
    }
  }
}

/// The models chosen for new sessions and for Identify, as file names.
typedef ModelChoice = ({String? detector, String? idModel, String? nameList});

/// The camera's detection model and Identify's model and name list, each
/// null when none is chosen or its file is not on the phone ([onPhone], the
/// file names) any more.
Future<ModelChoice> currentModelChoice(Set<String> onPhone) async {
  try {
    String? present(String? path) {
      final name = path?.split('/').last;
      return name != null && onPhone.contains(name) ? name : null;
    }

    final config = await SessionConfig.load();
    final prefs = await SharedPreferences.getInstance();
    final idModel = present(prefs.getString(kIdentifyModelPref));
    final nameList = present(prefs.getString(kIdentifyPackPref));
    final both = idModel != null && nameList != null;
    return (
      detector: present(config.modelPath),
      idModel: both ? idModel : null,
      nameList: both ? nameList : null,
    );
  } catch (e) {
    logSwallowed('model_choice', e);
    return (detector: null, idModel: null, nameList: null);
  }
}

/// Said wherever no identification model is chosen (home step 1, the
/// "What do you want to watch?" pages).
const kNoNamingNote = 'animals are found and counted, not named';

/// Identify's choice: the identification model [idModel] with its name list
/// [nameList] (file names), or none when either is null.
Future<void> saveNamingChoice(String? idModel, String? nameList) async {
  final prefs = await SharedPreferences.getInstance();
  if (idModel != null && nameList != null) {
    await prefs.setString(kIdentifyModelPref, idModel);
    await prefs.setString(kIdentifyPackPref, nameList);
  } else {
    await prefs.remove(kIdentifyModelPref);
    await prefs.remove(kIdentifyPackPref);
  }
}

/// The choice of a "What do you want to watch?" page: makes the detection
/// model file [detector] (when given) the model of the camera and of Find
/// animals, and the identification model [idModel] with its name list
/// [nameList] the choice of Identify, or no identification model ("Not now").
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
  await saveNamingChoice(idModel, nameList);
}

/// The models used last for the answer [useId] to "What do you want to
/// watch?" (round 286), so tapping that answer again brings them back.
String _watchChoiceKey(String useId) => 'watch_choice_$useId';

Future<void> rememberWatchChoice(String useId, ModelChoice c) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_watchChoiceKey(useId), [c.detector ?? '', c.idModel ?? '', c.nameList ?? '']);
}

/// The models used last for each answer of [useIds] that has some.
Future<Map<String, ModelChoice>> watchChoices(Iterable<String> useIds) async {
  final prefs = await SharedPreferences.getInstance();
  String? name(String s) => s.isEmpty ? null : s;
  return {
    for (final id in useIds)
      if (prefs.getStringList(_watchChoiceKey(id)) case [final d, final m, final l])
        id: (detector: name(d), idModel: name(m), nameList: name(l)),
  };
}
