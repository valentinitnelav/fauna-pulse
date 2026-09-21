// FaunaPulse (round 208): identification files (embedding models, label
// packs) in private storage, plus the job's persisted settings.
//
// Both file kinds are produced on a PC (tool/bioclip_export/) and brought to
// the phone by the user; Import copies them through the same streamed
// checks as detector models (safe name, size cap, structural header), with
// a separate, much larger cap because an image tower is 0.3 to 1.3 GB.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_error_hooks.dart';
import '../models/model_file_security.dart';
import 'label_pack.dart';

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

class ImportOutcome {
  final List<String> imported;
  final List<String> rejected;
  const ImportOutcome(this.imported, this.rejected);
}

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
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Opens the file picker and copies validated `.tflite` (models) or
  /// `.fpack` (packs) files into private storage.
  static Future<ImportOutcome> importFiles({required bool packs}) async {
    final ext = packs ? '.fpack' : '.tflite';
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return const ImportOutcome([], []);
    final dir = packs ? await packsDir() : await modelsDir();
    final imported = <String>[];
    final rejected = <String>[];
    for (final picked in result.files) {
      final display = safeModelDisplayName(picked.name);
      final path = picked.path;
      if (path == null) {
        rejected.add('$display: the selected file could not be read.');
        continue;
      }
      if (!isSafeIdentificationFileName(picked.name, ext: ext)) {
        rejected.add('$display: expected a safely named $ext file.');
        continue;
      }
      final target = File('${dir.path}/${picked.name}');
      try {
        await copyAndValidateModel(
          File(path),
          target,
          picked.name,
          maxBytes: kMaxIdentificationFileBytes,
        );
        if (packs) {
          // Structural check: magic + parseable header.
          try {
            await LabelPack.readHeader(target);
          } catch (e) {
            await target.delete();
            rethrow;
          }
        }
        imported.add(picked.name);
      } catch (e) {
        rejected.add('$display: ${plainModelError(e)}');
        logSwallowed('identification_import', e);
      }
    }
    return ImportOutcome(imported, rejected);
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
  int minCropPx;
  int maxCropsPerTrack;
  double tau;
  double noneThreshold;
  double thermalLimitC;
  String targetRank;
  // Round 210: opt-in joining of consecutive track ids into one visit.
  bool mergeVisits;
  double mergeGapS;

  IdentifyPrefs({
    this.modelName,
    this.packName,
    this.useGpu = true,
    this.cpuThreads = 0,
    this.margin = 0.15,
    this.minCropPx = 48,
    this.maxCropsPerTrack = 10,
    this.tau = 0.8,
    this.noneThreshold = 0.5,
    this.thermalLimitC = 40,
    this.targetRank = 'family',
    this.mergeVisits = false,
    this.mergeGapS = 5,
  });

  static const _kModel = 'identify_model';
  static const _kPack = 'identify_pack';
  static const _kGpu = 'identify_use_gpu';
  static const _kThreads = 'identify_cpu_threads';
  static const _kMargin = 'identify_margin';
  static const _kMinPx = 'identify_min_crop_px';
  static const _kMaxCrops = 'identify_max_crops_per_track';
  static const _kTau = 'identify_tau';
  static const _kNone = 'identify_none_threshold';
  static const _kThermal = 'identify_thermal_limit_c';
  static const _kRank = 'identify_target_rank';
  static const _kMerge = 'identify_merge_visits';
  static const _kMergeGap = 'identify_merge_gap_s';

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
      margin: p.getDouble(_kMargin) ?? 0.15,
      minCropPx: p.getInt(_kMinPx) ?? 48,
      maxCropsPerTrack: p.getInt(_kMaxCrops) ?? 10,
      tau: p.getDouble(_kTau) ?? 0.8,
      noneThreshold: p.getDouble(_kNone) ?? 0.5,
      thermalLimitC: p.getDouble(_kThermal) ?? 40,
      targetRank: p.getString(_kRank) ?? 'family',
      mergeVisits: p.getBool(_kMerge) ?? false,
      mergeGapS: p.getDouble(_kMergeGap) ?? 5,
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
    await p.setInt(_kMinPx, minCropPx);
    await p.setInt(_kMaxCrops, maxCropsPerTrack);
    await p.setDouble(_kTau, tau);
    await p.setDouble(_kNone, noneThreshold);
    await p.setDouble(_kThermal, thermalLimitC);
    await p.setString(_kRank, targetRank);
    await p.setBool(_kMerge, mergeVisits);
    await p.setDouble(_kMergeGap, mergeGapS);
  }

  /// Echoed into the identify_start record and the summary rows.
  Map<String, dynamic> toJson() => {
    'model': modelName,
    'pack': packName,
    'use_gpu': useGpu,
    'cpu_threads': cpuThreads,
    'margin': margin,
    'min_crop_px': minCropPx,
    'max_crops_per_track': maxCropsPerTrack,
    'tau': tau,
    'none_threshold': noneThreshold,
    'thermal_limit_c': thermalLimitC,
    'target_rank': targetRank,
    'merge_visits': mergeVisits,
    'merge_gap_s': mergeGapS,
  };
}
