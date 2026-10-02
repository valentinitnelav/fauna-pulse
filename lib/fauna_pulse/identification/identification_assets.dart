// FaunaPulse (round 208): identification files (embedding models, label
// packs) in private storage, plus the job's persisted settings.
//
// Both file kinds are produced on a PC (tool/bioclip_export/) and brought to
// the phone by the user, or downloaded from the catalogue. Since round 275
// one import for every model file (models/model_import.dart) checks what a
// file is and copies it here, with the same streamed checks as detector
// models (safe name, size cap, structural header) and a separate, much
// larger cap because an image tower is 0.3 to 1.3 GB.

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_error_hooks.dart';
import '../models/model_file_security.dart' show fileNameOrder;
import '../models/model_choice_keys.dart';
import 'crop_worker.dart' show kDefaultCropMargin;
import 'identification_store.dart' show modelIdOf, modelKey, stemOf;
import 'label_pack.dart' show isClassListHeader;
import '../logging/thermal_pause.dart' show kDefaultPauseTempC;

/// Cap for one identification file (image tower or label pack). BioCLIP 2.5
/// fp16 is 1.26 GB; a worldwide arthropod pack ~0.6 GB. TFLite itself stops
/// at 2 GB.
const int kMaxIdentificationFileBytes = 2 * 1024 * 1024 * 1024;

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
  ///   (`bioclip-2_flower-visitors-32fam_v1` ↔ `bioclip-2_224_fp16`).
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

  IdentifyPrefs({
    this.modelName,
    this.packName,
    this.useGpu = true,
    this.cpuThreads = 0,
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
  });

  static const _kModel = kIdentifyModelPref;
  static const _kPack = kIdentifyPackPref;
  static const _kGpu = 'identify_use_gpu';
  static const _kThreads = 'identify_cpu_threads';
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

  /// Per-model measured speed (ms per crop) from the last run on this phone,
  /// for the pre-flight time estimate.
  static String msPerCropKey(String modelName) =>
      'identify_ms_per_crop_${modelName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';

  static Future<IdentifyPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    return IdentifyPrefs(
      modelName: p.getString(_kModel),
      packName: p.getString(_kPack),
      useGpu: p.getBool(_kGpu) ?? true,
      cpuThreads: p.getInt(_kThreads) ?? 0,
      margin: p.getDouble(_kMargin) ?? kDefaultCropMargin,
      squareCrops: p.getBool(_kSquare) ?? true,
      minCropPx: p.getInt(_kMinPx) ?? 48,
      maxCropsPerTrack: p.getInt(_kMaxCrops) ?? 10,
      tau: p.getDouble(_kTau) ?? 0.6,
      noneThreshold: p.getDouble(_kNone) ?? 0.5,
      thermalLimitC: p.getDouble(_kThermal) ?? kDefaultPauseTempC,
      targetRank: p.getString(_kRank) ?? 'family',
      mergeVisits: p.getBool(_kMerge) ?? false,
      mergeGapS: p.getDouble(_kMergeGap) ?? 3,
      mergeSizeTol: p.getDouble(_kMergeSize) ?? 0.5,
      mergeMinCos: p.getDouble(_kMergeCos) ?? 0.85,
      flagMinDurationS: p.getDouble(_kFlagDur) ?? 2,
      flagMinDetections: p.getInt(_kFlagDet) ?? 3,
      flagMinDetConf: p.getDouble(_kFlagConf) ?? 0.2,
      flagMinOrderP: p.getDouble(_kFlagOrderP) ?? 0.5,
      dropFactor: p.getDouble(_kDrop) ?? 10,
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
  }

  /// Echoed into the identify_start record and the summary rows.
  Map<String, dynamic> toJson() => {
    'model': modelName,
    'pack': packName,
    'use_gpu': useGpu,
    'cpu_threads': cpuThreads,
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
  };
}

/// Why the GPU was not used, for the Identify screen (round 242): the native
/// reason, plus what to do when the GPU could not compile the model, the
/// usual cause being a BioCLIP file exported before round 242 (its attention
/// layers use tensors the phone's GPU cannot run).
String gpuNoteText(String note) => note.contains('Failed to compile')
    ? '$note. The usual cause is a BioCLIP file whose attention layers use 5-dimensional '
          'tensors, which phone GPUs cannot run; export the model again with tool/bioclip_export '
          '(4-dimensional attention, see IDENTIFICATION.md)'
    : note;
