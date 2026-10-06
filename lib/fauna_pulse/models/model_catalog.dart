// FaunaPulse — the catalog of detection models the user can choose from.
//
// Since round 268 only imported models appear in the picker: files the user
// downloaded (AI models screen catalogue or a link) or imported with the file
// picker, kept in the app's private internal models folder. The "official"
// (YOLO26 test model) and "bundled" (assets inside the app) sources remain as
// values because sessions and device checks still name asset paths, but the
// picker no longer lists them (owner decision: no model ships with the app).
// Round 275: files come in through models/model_import.dart, which checks
// that a .tflite file is a detection model before it is put here.
//
// Accepted file formats (round 150, see docs/MODEL_CONVERSION.md): `.tflite`
// (any precision — the normal case) and `*_qnn.onnx` (an Ultralytics Snapdragon
// NPU export the native layer runs via ONNX Runtime; Snapdragon phones only).
// Plain `.onnx` files are deliberately NOT accepted — the native layer would
// reject them at load time, so filtering them here keeps broken entries out of
// the picker.
//
// "Runtime scanning" means the imported list is read from disk every time the
// settings sheet opens, so a newly-added model shows up without rebuilding the app.
//
// Terms used once:
//   * precision — how the model's numbers are stored: "int8" (8-bit integers,
//     small/fast, CPU-friendly), "fp16" (16-bit floats, GPU-friendly), or "fp32"
//     (32-bit floats, most accurate, slowest). Read from the file name.
//   * imgsz / input resolution — the square pixel size the model expects as input
//     (e.g. 640). Read from the model's embedded metadata when present.

import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import '../logging/app_error_hooks.dart';
import 'bundled_models.dart';

import 'model_file_security.dart';
export 'model_file_security.dart';

enum ModelSource { official, bundled, imported }

/// One selectable model plus whatever we could learn about it cheaply.
class ModelEntry {
  /// The value stored in [SessionConfig.modelPath]: an official id ("yolo26n"),
  /// a Flutter asset path, or an absolute file path on the device.
  final String id;

  /// File (or official id) name shown to the user, in full — no shortening.
  final String name;

  final ModelSource source;

  /// "int8" / "fp16" / "fp32" parsed from the file name, or null if unknown.
  final String? precision;

  /// Input resolution in pixels (the square side), read from metadata, or null.
  final int? inputSize;

  /// Detector task from metadata ("detect", "segment", ...) or null.
  final String? task;

  /// Class names from metadata (what the detector finds, e.g. "animal"),
  /// empty when the file carries none. Shown on the AI models screen (r267).
  final List<String> labels;

  const ModelEntry({
    required this.id,
    required this.name,
    required this.source,
    this.precision,
    this.inputSize,
    this.task,
    this.labels = const [],
  });

  /// Full, human-readable label for the dropdown: full file name, then the
  /// precision and input resolution when known, then where it came from.
  String get label {
    final tags = <String>[?precision, if (inputSize != null) '${inputSize}px'];
    final meta = tags.isEmpty ? '' : ' — ${tags.join(', ')}';
    final origin = switch (source) {
      ModelSource.official => '',
      ModelSource.bundled => ' (bundled)',
      ModelSource.imported => ' (imported)',
    };
    return '$name$meta$origin';
  }
}

class ModelCatalog {
  /// Local development entry. YOLO26 is not shown in release builds and its
  /// weight is removed from release APKs (round 194); keeping this entry for
  /// debug builds lets the project owner continue general detector tests.
  static const officialModels = {
    kLocalYolo26ModelId: 'YOLO26 nano (local test model)',
  };

  // Configs that saved a pre-r119 placeholder id (yolo26s/m/l/x) load as the
  // current MDV6 default; the migration lives in SessionConfig.fromJson.

  static const bundledIds = {kLocalYolo26ModelId};

  /// Parent folder for both top-level and custom bundled model assets.
  static const bundledModelsDir = 'assets/models/';

  static final _channel = ChannelConfig.createSingleImageChannel();

  static bool _legacyModelMigrationAttempted = false;

  /// Private app-internal model storage (created if missing). Keeping parser
  /// inputs internal prevents another storage-enabled app from replacing them
  /// on Android 7-9. Import and Download remain the supported ways to add files.
  static Future<Directory> modelsDir() async {
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (e) {
      logSwallowed('models_dir_internal', e);
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/models');
    if (!await dir.exists()) await dir.create(recursive: true);
    await _migrateLegacyExternalModels(dir);
    return dir;
  }

  static Future<void> _migrateLegacyExternalModels(Directory targetDir) async {
    if (_legacyModelMigrationAttempted) return;
    _legacyModelMigrationAttempted = true;
    try {
      final legacyBase = await getExternalStorageDirectory();
      if (legacyBase == null) return;
      final legacyDir = Directory('${legacyBase.path}/models');
      if (!await legacyDir.exists() ||
          legacyDir.absolute.path == targetDir.absolute.path) {
        return;
      }
      await for (final entity in legacyDir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!isSafeModelBaseName(name)) continue;
        final target = safeModelTarget(targetDir, name);
        if (await target.exists()) continue;
        try {
          await copyAndValidateModel(entity, target, name);
        } catch (e) {
          logSwallowed('legacy_model_migration', e);
        }
      }
    } catch (e) {
      logSwallowed('legacy_models_dir', e);
    }
  }

  /// Builds the list the user chooses from: the imported (downloaded or
  /// imported) model files, scanned from disk now, with their metadata
  /// (precision / input size / task / class names). Round 268: models inside
  /// the app (bundled assets, the debug-only YOLO26 entry) are no longer
  /// listed, in debug builds too, so every phone behaves like a user's: a
  /// detector has to be downloaded or imported first (owner decision: no
  /// model ships with the app). Device checks still load asset paths directly.
  static Future<List<ModelEntry>> build() async {
    final entries = <ModelEntry>[];

    final dir = await modelsDir();
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => isSupportedModelFileName(f.path))
            .toList()
          // Alphabetical by file name, upper and lower case alike (round 275).
          ..sort((a, b) => fileNameOrder(a.path, b.path));
    for (final f in files) {
      entries.add(await entryOf(f));
    }

    return entries;
  }

  /// One model file as [build] lists it, inspected now (round 278: the
  /// "watch" page makes a downloaded file the camera's model).
  static Future<ModelEntry> entryOf(File f) async {
    final name = f.path.split('/').last;
    final meta = await _inspect(f.path);
    return ModelEntry(
      id: f.path,
      name: name,
      source: ModelSource.imported,
      precision: _precisionFromName(name),
      inputSize: _imgszFrom(meta),
      task: meta['task'] as String?,
      labels: _labelsFrom(meta),
    );
  }

  /// File names that occur more than once across the catalog (so the UI can warn
  /// the user that two different models share a name and could be confused).
  static Set<String> duplicateNames(List<ModelEntry> entries) {
    final seen = <String, int>{};
    for (final e in entries) {
      if (e.source == ModelSource.official) continue;
      seen[e.name] = (seen[e.name] ?? 0) + 1;
    }
    return seen.entries.where((e) => e.value > 1).map((e) => e.key).toSet();
  }

  /// Deletes an imported model file (only imported models can be removed).
  static Future<void> deleteImported(String filePath) async {
    try {
      final f = File(filePath);
      if (await f.exists()) await f.delete();
    } catch (e) {
      logSwallowed('model_delete', e);
    }
  }

  /// Input resolution (square side, px) for a single model path, or null when
  /// the model's metadata doesn't carry it. Applies the same official-id →
  /// local-test mapping [build] uses, so e.g. "yolo26n" (a bare id with no file
  /// on disk) resolves to its real asset before inspection. Lets screens
  /// other than the settings sheet show a model's input size without rebuilding
  /// the whole catalog.
  static Future<int?> inputSizeOf(String modelPath) async {
    final probe = bundledIds.contains(modelPath)
        ? kLocalYolo26ModelPath
        : modelPath;
    return _imgszFrom(await _inspect(probe));
  }

  static Future<Map<String, dynamic>> _inspect(String modelPath) async {
    try {
      final r = await _channel.invokeMethod('inspectModel', {
        'modelPath': modelPath,
      });
      if (r is Map) return Map<String, dynamic>.from(r);
    } catch (e) {
      // Resolution shows as unknown; common for non-YOLO .tflite files.
      logSwallowed('model_inspect', e);
    }
    return {};
  }

  static List<String> _labelsFrom(Map<String, dynamic> meta) {
    final v = meta['labels'];
    return v is List ? [for (final l in v) '$l'] : const [];
  }

  static int? _imgszFrom(Map<String, dynamic> meta) {
    final v = meta['imgsz'];
    if (v is List && v.isNotEmpty) {
      final last = v.last;
      if (last is int) return last;
      if (last is num) return last.toInt();
    }
    return null;
  }

  static String? _precisionFromName(String name) {
    final n = name.toLowerCase();
    if (n.contains('int8')) return 'int8';
    if (n.contains('float16') || n.contains('fp16') || n.contains('_half')) {
      return 'fp16';
    }
    if (n.contains('float32') || n.contains('fp32')) return 'fp32';
    return null;
  }
}

/// The model file name a download URL points at (query string ignored), or
/// null when it is not an HTTPS URL with a safe supported base name. Uri
/// pathSegments are decoded, so this also rejects encoded traversal/separators.
/// [accept] (round 275) widens the names, e.g. to name lists for the link
/// dialog of Download & import models.
String? modelFileNameFromUrl(String url, {bool Function(String name) accept = isSafeModelBaseName}) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) {
    return null;
  }
  if (uri.pathSegments.isEmpty) return null;
  final name = uri.pathSegments.last;
  if (!accept(name)) return null;
  return name;
}

/// True when [name] (a file name or path) is a model file the app can run:
/// a `.tflite` (any precision) or an Ultralytics QNN context-binary export
/// (`*_qnn.onnx` — Snapdragon NPU only). Plain `.onnx` files are rejected;
/// the native layer cannot run them (docs/MODEL_CONVERSION.md explains why
/// and how to convert instead).

/// Filters and sorts bundled model assets for the current build type. This is
/// public only so the manifest-based release policy can be unit-tested without
/// building an APK.
List<String> visibleBundledModelAssets(
  Iterable<String> assets, {
  bool releaseMode = kReleaseMode,
  Set<String> releaseBundledModelPaths = const {},
}) {
  final visible = assets.where(
    (p) =>
        p.startsWith(ModelCatalog.bundledModelsDir) &&
        isSupportedModelFileName(p) &&
        (releaseMode
            ? releaseBundledModelPaths.contains(p)
            : p != kLocalYolo26ModelPath),
  );
  return visible.toList()..sort();
}

/// How the camera screen recovers after a model failed to load (round 151).
/// [revertToPath] is what `SessionConfig.modelPath` should point at again;
/// [toBundledDefault] is true when nothing was running natively (a failed
/// initial load), so the recovery falls back to the release's bundled MDV6
/// model instead of a previously loaded model.
class ModelLoadRecovery {
  /// The model to go back to; '' = none (the camera runs without one).
  final String revertToPath;
  const ModelLoadRecovery(this.revertToPath);
}

/// Compares two model references by file name, mapping an official bundled id
/// (e.g. "yolo26n") to its real asset file, because native reports RESOLVED
/// paths (flutter_assets/..., absolute) while the config may hold the bare id.
bool sameModelFile(String a, String b) {
  String canonical(String p) {
    final name = p.split('/').last.toLowerCase();
    if (ModelCatalog.bundledIds.contains(name)) return '${name}_int8.tflite';
    return name;
  }

  return canonical(a) == canonical(b);
}

/// Decides the recovery after [failedPath] failed to load, or null when the
/// failure is stale (the config no longer points at the failed model, e.g.
/// the user already picked another one). When a different model is still
/// loaded natively ([loadedModelPath]), revert to it; otherwise to no model
/// (round 270: none ships with the app, so there is no built-in fallback; the
/// camera keeps running without one).
ModelLoadRecovery? modelLoadRecovery({
  required String failedPath,
  required String currentConfigPath,
  required String loadedModelPath,
}) {
  if (!sameModelFile(failedPath, currentConfigPath)) return null;
  if (loadedModelPath.isNotEmpty &&
      !sameModelFile(loadedModelPath, currentConfigPath)) {
    return ModelLoadRecovery(loadedModelPath);
  }
  return const ModelLoadRecovery('');
}

/// A plain-language extra line for known cryptic load errors, or '' when none
/// applies. The QNN case: context binaries are precompiled for ONE Hexagon NPU
/// generation (the file's min_arch), so on any other chip ONNX Runtime fails
/// with an opaque ORT_INVALID_GRAPH / "Error code: 5005".
String modelLoadHint(String failedPath, String reason) {
  final r = reason.toLowerCase();
  // Round 299: the normal build leaves the NPU runtime out (Predictor.create
  // then names the missing onnxruntime-android-qnn dependency).
  if (isQnnModelPath(failedPath) && r.contains('onnxruntime-android-qnn')) {
    return 'This *_qnn.onnx model needs the Snapdragon NPU edition of '
        'FaunaPulse; this edition leaves the NPU runtime out to stay small. '
        'Use a .tflite model instead.';
  }
  if (isQnnModelPath(failedPath) &&
      (r.contains('ort') || r.contains('qnn') || r.contains('5005'))) {
    return 'This *_qnn.onnx model was built for a different Snapdragon NPU '
        'generation and cannot run on this phone.';
  }
  return '';
}
