// FaunaPulse (round 208): identification files (embedding models, label
// packs) in private storage, plus the job's persisted settings.
//
// Both file kinds are produced on a PC (fauna-pulse-models, bioclip_export/) and brought to
// the phone by the user, or downloaded from the catalogue. Since round 275
// one import for every model file (models/model_import.dart) checks what a
// file is and copies it here, with the same streamed checks as detector
// models (safe name, size limit, structural header). One size limit covers
// every kind of file since round 314 (kMaxModelFileBytes, 2 GiB, in
// models/model_file_security.dart); an image tower is 0.3 to 1.3 GB.

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_error_hooks.dart';
import '../models/model_file_security.dart' show fileNameOrder;
import '../models/model_choice_keys.dart';
import '../models/saved_prefs.dart';
import 'crop_worker.dart' show kDefaultCropMargin;
import 'identification_store.dart' show modelIdOf, modelKey, stemOf;
import 'label_pack.dart' show isClassListHeader, kRankNames;
import 'name_list_region.dart';
import '../logging/thermal_pause.dart' show kDefaultPauseTempC;

final RegExp _safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// True for a plain, safe base name with the expected extension.
bool isSafeIdentificationFileName(String name, {required String ext}) =>
    !name.contains('..') &&
    _safeName.hasMatch(name) &&
    name.toLowerCase().endsWith(ext);

class IdentificationAssets {
  static Future<Directory> _sub(String name) async {
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (e) {
      logSwallowed('identification_dir', e);
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/identification/$name');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> modelsDir() => _sub('models');
  static Future<Directory> packsDir() => _sub('packs');

  static Future<List<File>> listModels() => _list(await_(modelsDir()), '.tflite');
  static Future<List<File>> listPacks() => _list(await_(packsDir()), '.fpack');

  static Future<Directory> await_(Future<Directory> d) => d;

  static Future<List<File>> _list(Future<Directory> dirF, String ext) async {
    final dir = await dirF;
    final out = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && e.path.toLowerCase().endsWith(ext)) out.add(e);
    }
    // Alphabetical by file name, upper and lower case alike (round 275).
    out.sort((a, b) => fileNameOrder(a.path, b.path));
    return out;
  }

  /// The class lists in [packs] that belong to [model] (same file name, see
  /// the Identify screen's pairing): they are deleted with it.
  static List<File> classListsOf(File model, List<File> packs) {
    final stem = stemOf(model.path);
    return [for (final p in packs) if (stemOf(p.path) == stem) p];
  }

  /// Round 271: whether the name list [list] (its [header], null when
  /// unreadable) belongs to the model file [model], so the two are shown
  /// together and Identify offers only matching lists.
  /// - A class list has the model's file name (round 266), and only that.
  /// - A label pack (round 276, the naming rule `<model>_<list>_v<n>`)
  ///   belongs to every model file with the same first part
  ///   (`bioclip-2_pollinator-orders-europe_v2` ↔ `bioclip-2_224_fp16`).
  /// - Otherwise the pack's header names its model in `model_id` (files
  ///   named before the rule, or renamed: `bioclip-2.5` ↔
  ///   `bioclip-25_image_fp16.tflite`).
  /// Model ids are compared with [modelKey].
  static bool listBelongsTo(File list, Map<String, dynamic>? header, File model) {
    if (stemOf(list.path) == stemOf(model.path)) return true;
    if (header == null || isClassListHeader(header)) return false;
    final key = modelKey(modelIdOf(model.path));
    if (modelKey(modelIdOf(list.path)) == key) return true;
    final id = header['model_id'];
    return id is String && modelKey(id) == key;
  }

  /// Deletes [files] (an identification model and its class lists, or one
  /// name list) and returns the names it removed (round 267).
  static Future<List<String>> deleteFiles(List<File> files) async {
    final deleted = <String>[];
    for (final f in files) {
      try {
        if (await f.exists()) await f.delete();
        deleted.add(f.path.split('/').last);
      } catch (e) {
        logSwallowed('identification_delete', e);
      }
    }
    return deleted;
  }
}

/// Persisted settings of the identification job (shared_preferences
/// `identify_*`, like the analysis screen's `analysis_*`; NOT SessionConfig,
/// which is the recording's own settings block).
class IdentifyPrefs {
  String? modelName;
  String? packName;
  bool useGpu;
  int cpuThreads;
  // Round 360: isolates for the scoring step (0 = automatic, see IdentificationJob.scoringWorkers).
  int scoringWorkers;
  double margin;
  // Round 262: false = crop the box shape (stretched to the model's square).
  bool squareCrops;
  int minCropPx;
  int maxCropsPerTrack;
  double tau;
  double noneThreshold;
  double thermalLimitC;
  String targetRank;
  // Round 210: opt-in joining of consecutive track ids into one visit.
  bool mergeVisits;
  double mergeGapS;
  // Round 212: merge guards + "suspect visit" flag thresholds.
  double mergeSizeTol;
  double mergeMinCos;
  double flagMinDurationS;
  int flagMinDetections;
  double flagMinDetConf;
  double flagMinOrderP;
  // Round 219: leave out crops far less certain than the surest one.
  double dropFactor;
  // Round 373 (name_list_region.dart): which names of a name list with country lists a run
  // chooses from, and for which country ('' = the country of the session's position).
  String nameListScope;
  String nameListCountry;
  // Round 376: the countries of "Countries I choose" (two-letter codes); kept, unused, while
  // "Names from" says something else.
  List<String> nameListChosenCountries;
  // Round 377: the orders and families a run is narrowed to, by name; empty = all. Names
  // the chosen name list does not have are not used (they were chosen for another list).
  List<String> nameListChosenTaxa;

  IdentifyPrefs({
    this.modelName,
    this.packName,
    this.useGpu = true,
    this.cpuThreads = 0,
    this.scoringWorkers = 0,
    this.margin = kDefaultCropMargin,
    this.squareCrops = true,
    this.minCropPx = 48,
    this.maxCropsPerTrack = 10,
    this.tau = 0.6,
    this.noneThreshold = 0.5,
    this.thermalLimitC = kDefaultPauseTempC,
    this.targetRank = 'family',
    this.mergeVisits = false,
    this.mergeGapS = 3,
    this.mergeSizeTol = 0.5,
    this.mergeMinCos = 0.85,
    this.flagMinDurationS = 2,
    this.flagMinDetections = 3,
    this.flagMinDetConf = 0.2,
    this.flagMinOrderP = 0.5,
    this.dropFactor = 10,
    this.nameListScope = kScopeNeighbours,
    this.nameListCountry = '',
    this.nameListChosenCountries = const [],
    this.nameListChosenTaxa = const [],
  });

  static const _kModel = kIdentifyModelPref;
  static const _kPack = kIdentifyPackPref;
  static const _kGpu = 'identify_use_gpu';
  static const _kThreads = 'identify_cpu_threads';
  static const _kWorkers = 'identify_scoring_workers';
  static const _kMargin = 'identify_margin';
  static const _kSquare = 'identify_square_crops';
  static const _kMinPx = 'identify_min_crop_px';
  static const _kMaxCrops = 'identify_max_crops_per_track';
  static const _kTau = 'identify_tau';
  static const _kNone = 'identify_none_threshold';
  static const _kThermal = 'identify_thermal_limit_c';
  static const _kRank = 'identify_target_rank';
  static const _kMerge = 'identify_merge_visits';
  static const _kMergeGap = 'identify_merge_gap_s';
  static const _kMergeSize = 'identify_merge_size_tol';
  static const _kMergeCos = 'identify_merge_min_cos';
  static const _kFlagDur = 'identify_flag_min_duration_s';
  static const _kFlagDet = 'identify_flag_min_detections';
  static const _kFlagConf = 'identify_flag_min_det_conf';
  static const _kFlagOrderP = 'identify_flag_min_order_p';
  static const _kDrop = 'identify_drop_factor';
  static const _kListScope = 'identify_name_list_scope';
  static const _kListCountry = 'identify_name_list_country';
  static const _kListCountries = 'identify_name_list_chosen_countries';
  static const _kListTaxa = 'identify_name_list_chosen_taxa';

  /// A saved "Names from" value this app version knows, else the default.
  static String _scope(Object? saved) => saved is String && kNameListScopes.contains(saved) ? saved : kScopeNeighbours;

  /// A saved country code (two capital letters), else '' (the session's country).
  static String _country(Object? saved) => saved is String && RegExp(r'^[A-Z]{2}$').hasMatch(saved) ? saved : '';

  /// The saved country codes among [saved], each once, sorted; anything else is left out.
  static List<String> _countries(Object? saved) =>
      {if (saved is List) for (final c in saved) _country(c)}.where((c) => c.isNotEmpty).toList()..sort();

  /// The saved order and family names among [saved], each once, sorted.
  static List<String> _taxa(Object? saved) =>
      {if (saved is List) ...saved.whereType<String>().where((t) => t.isNotEmpty)}.toList()..sort();

  /// Per-model measured speed (ms per crop) from the last run on this phone,
  /// for the pre-flight time estimate.
  static String msPerCropKey(String modelName) =>
      'identify_ms_per_crop_${modelName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';

  /// Ranges = the boxes in identify_settings_fields.dart (keep in sync); see saved_prefs.dart.
  static Future<IdentifyPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    final d = IdentifyPrefs();
    final rank = p.stringOrNull(_kRank);
    return IdentifyPrefs(
      modelName: p.stringOrNull(_kModel),
      packName: p.stringOrNull(_kPack),
      useGpu: p.boolOr(_kGpu, d.useGpu),
      cpuThreads: p.intIn(_kThreads, d.cpuThreads, 0, 8),
      scoringWorkers: p.intIn(_kWorkers, d.scoringWorkers, 0, 8),
      margin: p.doubleIn(_kMargin, d.margin, 0, 0.5),
      squareCrops: p.boolOr(_kSquare, d.squareCrops),
      minCropPx: p.intIn(_kMinPx, d.minCropPx, 16, 512),
      maxCropsPerTrack: p.intIn(_kMaxCrops, d.maxCropsPerTrack, 0, 100),
      tau: p.doubleIn(_kTau, d.tau, 0.5, 0.99),
      noneThreshold: p.doubleIn(_kNone, d.noneThreshold, 0.1, 0.9),
      thermalLimitC: p.doubleIn(_kThermal, d.thermalLimitC, 35, 45),
      // The rank menu offers order to species; another value would trip its assertion.
      targetRank: kRankNames.skip(3).contains(rank) ? rank! : d.targetRank,
      mergeVisits: p.boolOr(_kMerge, d.mergeVisits),
      mergeGapS: p.doubleIn(_kMergeGap, d.mergeGapS, 0.5, 120),
      mergeSizeTol: p.doubleIn(_kMergeSize, d.mergeSizeTol, 0, 1),
      mergeMinCos: p.doubleIn(_kMergeCos, d.mergeMinCos, 0.5, 0.99),
      flagMinDurationS: p.doubleIn(_kFlagDur, d.flagMinDurationS, 0, 60),
      flagMinDetections: p.intIn(_kFlagDet, d.flagMinDetections, 0, 100),
      flagMinDetConf: p.doubleIn(_kFlagConf, d.flagMinDetConf, 0, 1),
      flagMinOrderP: p.doubleIn(_kFlagOrderP, d.flagMinOrderP, 0, 1),
      dropFactor: p.doubleIn(_kDrop, d.dropFactor, 1, 100),
      nameListScope: _scope(p.get(_kListScope)),
      nameListCountry: _country(p.get(_kListCountry)),
      nameListChosenCountries: _countries(p.get(_kListCountries)),
      nameListChosenTaxa: _taxa(p.get(_kListTaxa)),
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    if (modelName != null) {
      await p.setString(_kModel, modelName!);
    } else {
      await p.remove(_kModel);
    }
    if (packName != null) {
      await p.setString(_kPack, packName!);
    } else {
      await p.remove(_kPack);
    }
    await p.setBool(_kGpu, useGpu);
    await p.setInt(_kThreads, cpuThreads);
    await p.setInt(_kWorkers, scoringWorkers);
    await p.setDouble(_kMargin, margin);
    await p.setBool(_kSquare, squareCrops);
    await p.setInt(_kMinPx, minCropPx);
    await p.setInt(_kMaxCrops, maxCropsPerTrack);
    await p.setDouble(_kTau, tau);
    await p.setDouble(_kNone, noneThreshold);
    await p.setDouble(_kThermal, thermalLimitC);
    await p.setString(_kRank, targetRank);
    await p.setBool(_kMerge, mergeVisits);
    await p.setDouble(_kMergeGap, mergeGapS);
    await p.setDouble(_kMergeSize, mergeSizeTol);
    await p.setDouble(_kMergeCos, mergeMinCos);
    await p.setDouble(_kFlagDur, flagMinDurationS);
    await p.setInt(_kFlagDet, flagMinDetections);
    await p.setDouble(_kFlagConf, flagMinDetConf);
    await p.setDouble(_kFlagOrderP, flagMinOrderP);
    await p.setDouble(_kDrop, dropFactor);
    await p.setString(_kListScope, nameListScope);
    await p.setString(_kListCountry, nameListCountry);
    await p.setStringList(_kListCountries, nameListChosenCountries);
    await p.setStringList(_kListTaxa, nameListChosenTaxa);
  }

  /// Echoed into the identify_start record and the summary rows.
  Map<String, dynamic> toJson() => {
    'model': modelName,
    'pack': packName,
    'use_gpu': useGpu,
    'cpu_threads': cpuThreads,
    'scoring_workers': scoringWorkers,
    'margin': margin,
    'square_crops': squareCrops,
    'min_crop_px': minCropPx,
    'max_crops_per_track': maxCropsPerTrack,
    'tau': tau,
    'none_threshold': noneThreshold,
    'thermal_limit_c': thermalLimitC,
    'target_rank': targetRank,
    'merge_track_ids': mergeVisits, // "merge_visits" before round 248
    'merge_gap_s': mergeGapS,
    'merge_size_tol': mergeSizeTol,
    'merge_min_cos': mergeMinCos,
    'flag_min_duration_s': flagMinDurationS,
    'flag_min_detections': flagMinDetections,
    'flag_min_det_conf': flagMinDetConf,
    'flag_min_order_p': flagMinOrderP,
    'drop_factor': dropFactor,
    'name_list_scope': nameListScope,
    'name_list_country': nameListCountry,
    'name_list_chosen_countries': nameListChosenCountries,
    'name_list_chosen_taxa': nameListChosenTaxa,
  };
}

/// Why the GPU was not used, for the Identify screen (round 242), in plain words; the raw
/// native note goes to the log only (round 317: any other note comes from the GPU set-up
/// exception, not only 'Failed to compile'). The
/// catalogue's files are already exported for phone GPUs, so the re-export
/// advice (a BioCLIP file exported before round 242, whose attention layers
/// use tensors phone GPUs cannot run) is only for files people converted
/// themselves; the cause can also be this phone's GPU (round 317).
String gpuNoteText(String note) {
  if (note.startsWith('on the GPU blocklist')) {
    return 'The GPU failed with this model several times before on this phone, so the CPU is used: '
        'the same answers, only slower.';
  }
  if (note.contains('differed from the CPU')) {
    return 'On this phone the GPU gave different answers from the CPU on a test picture, so the CPU '
        'is used: the same answers, only slower.';
  }
  if (note.contains('GB of memory')) {
    final t = note.isEmpty ? note : note[0].toUpperCase() + note.substring(1);
    return t.endsWith('.') ? t : '$t.';
  }
  return 'This phone\'s graphics processor (GPU) cannot run this model, so the main processor (CPU) '
      'is used: the same answers, only slower. If you converted this model yourself, convert it again '
      'with the current tool (github.com/valentinitnelav/fauna-pulse, docs/IDENTIFICATION.md).';
}
