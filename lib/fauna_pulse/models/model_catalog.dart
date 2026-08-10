// FaunaPulse — the catalog of detection models the user can choose from.
//
// Three kinds of model can appear in the picker:
//   * official  — the local YOLO26 test model (debug builds only).
//   * bundled   — custom model files shipped inside the app (assets/models/custom/).
//   * imported  — custom model files the user dropped onto the phone and imported
//                 at runtime (e.g. from the Downloads folder) via the file picker.
//                 These live in the app's own models folder, which is also visible
//                 over USB at Android/data/<package>/files/models/.
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
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import '../logging/app_error_hooks.dart';
import 'bundled_models.dart';

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

  const ModelEntry({
    required this.id,
    required this.name,
    required this.source,
    this.precision,
    this.inputSize,
    this.task,
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

  /// Lists bundled model assets by reading Flutter's AssetManifest. Debug builds
  /// expose all local weights (with YOLO26 kept as its special official entry).
  /// Release builds read the same text allowlist used by the Android asset copy.
  static Future<List<String>> _bundledAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    var releaseBundledModelPaths = const <String>{};
    if (kReleaseMode) {
      try {
        releaseBundledModelPaths = parseBundledModelsManifest(
          await rootBundle.loadString(kBundledModelsManifestPath),
        );
      } catch (e) {
        // A malformed/missing manifest yields no bundled picker entries. The
        // release build already prints a warning explaining how to fix it.
        logSwallowed('bundled_models_manifest', e);
      }
    }
    return visibleBundledModelAssets(
      manifest.listAssets(),
      releaseBundledModelPaths: releaseBundledModelPaths,
    );
  }

  /// The app's own models folder (created if missing). Imported models are
  /// copied here; it is browsable over USB for drag-and-drop too.
  static Future<Directory> modelsDir() async {
    Directory base;
    try {
      base =
          (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    } catch (e) {
      // Models land in the internal dir instead (not browsable over USB).
      logSwallowed('models_dir_external', e);
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/models');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Builds the full list: bundled custom models, then imported ones (scanned
  /// from disk now), then the official sizes. Metadata (precision / input size /
  /// task) is read for the custom models; official ids are left un-inspected so
  /// we never trigger a model download just to populate the menu.
  static Future<List<ModelEntry>> build() async {
    final entries = <ModelEntry>[];

    for (final asset in await _bundledAssets()) {
      final name = asset.split('/').last;
      final meta = await _inspect(asset);
      entries.add(
        ModelEntry(
          id: asset,
          name: name,
          source: ModelSource.bundled,
          precision: _precisionFromName(name),
          inputSize: _imgszFrom(meta),
          task: meta['task'] as String?,
        ),
      );
    }

    final dir = await modelsDir();
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => isSupportedModelFileName(f.path))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = f.path.split('/').last;
      final meta = await _inspect(f.path);
      entries.add(
        ModelEntry(
          id: f.path,
          name: name,
          source: ModelSource.imported,
          precision: _precisionFromName(name),
          inputSize: _imgszFrom(meta),
          task: meta['task'] as String?,
        ),
      );
    }

    // The general-purpose YOLO26 model is retained only for the project
    // owner's local tests. Do not inspect it or offer it to release users.
    if (!kReleaseMode) {
      for (final entry in officialModels.entries) {
        final id = entry.key;
        final meta = await _inspect(kLocalYolo26ModelPath);
        entries.add(
          ModelEntry(
            id: id,
            name: entry.value,
            source: ModelSource.official,
            precision: 'int8',
            inputSize: _imgszFrom(meta),
            task: meta['task'] as String?,
          ),
        );
      }
    }

    return entries;
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

  /// Opens the system file picker so the user can choose one or more model
  /// files (.tflite or *_qnn.onnx) from anywhere on the phone (Downloads, a
  /// folder they pick, etc.) and copies them into the app's models folder.
  /// Returns how many were imported.
  static Future<int> importModels() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return 0;
    final dir = await modelsDir();
    var imported = 0;
    for (final picked in result.files) {
      final path = picked.path;
      if (path == null) continue;
      if (!isSupportedModelFileName(path)) continue;
      try {
        await File(path).copy('${dir.path}/${picked.name}');
        imported++;
      } catch (e) {
        // Skip files we can't read/copy; the rest still import.
        logSwallowed('model_import_copy', e);
      }
    }
    return imported;
  }

  /// Downloads a model file from [url] into the imported-models folder, so
  /// models published as GitHub release assets can be added without a cable.
  /// Streams into a temporary `<name>.part` file and renames only on success,
  /// so a dropped connection never leaves a half model in the picker. Reports
  /// progress via [onProgress] (total is null when the server doesn't say);
  /// [isCancelled] is checked between chunks so the dialog's Cancel button
  /// can abandon a stalled download (the partial file is deleted).
  /// Returns the saved file's path; throws with a plain-language message on
  /// any failure (the dialog shows it verbatim).
  static Future<String> downloadModel(
    String url, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final name = modelFileNameFromUrl(url);
    if (name == null) {
      throw Exception(
        'The link must point to a .tflite or *_qnn.onnx model file.',
      );
    }
    final dir = await modelsDir();
    final partFile = File('${dir.path}/$name.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      // GitHub asset links redirect to the real file host; HttpClient follows
      // redirects on GET by default.
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Download failed (HTTP ${response.statusCode}).');
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      var received = 0;
      final sink = partFile.openWrite();
      try {
        // The timeout is BETWEEN chunks: a dead connection errors out (and a
        // stalled stream would otherwise also never reach the cancel check).
        final data = response.timeout(
          const Duration(seconds: 30),
          onTimeout: (s) =>
              s.addError(Exception('Connection stalled — try again.')),
        );
        await for (final chunk in data) {
          if (isCancelled?.call() ?? false) {
            throw Exception('Download cancelled.');
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final saved = await partFile.rename('${dir.path}/$name');
      return saved.path;
    } catch (e) {
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (e2) {
        logSwallowed('model_download_cleanup', e2);
      }
      rethrow;
    } finally {
      client.close();
    }
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
/// null when the link is not an http(s) URL ending in a supported model
/// extension (`.tflite` or `_qnn.onnx`).
String? modelFileNameFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  if (uri.pathSegments.isEmpty) return null;
  final name = uri.pathSegments.last;
  if (!isSupportedModelFileName(name)) return null;
  return name;
}

/// True when [name] (a file name or path) is a model file the app can run:
/// a `.tflite` (any precision) or an Ultralytics QNN context-binary export
/// (`*_qnn.onnx` — Snapdragon NPU only). Plain `.onnx` files are rejected;
/// the native layer cannot run them (docs/MODEL_CONVERSION.md explains why
/// and how to convert instead).
bool isSupportedModelFileName(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.tflite') || n.endsWith('_qnn.onnx');
}

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

/// True when [path] is a Snapdragon-NPU QNN model (`*_qnn.onnx`). These always
/// run on the NPU — the GPU-vs-CPU engine benchmark and the CPU-thread setting
/// don't apply to them.
bool isQnnModelPath(String path) => path.toLowerCase().endsWith('_qnn.onnx');

/// How the camera screen recovers after a model failed to load (round 151).
/// [revertToPath] is what `SessionConfig.modelPath` should point at again;
/// [toBundledDefault] is true when nothing was running natively (a failed
/// initial load), so the recovery falls back to the release's bundled MDV6
/// model instead of a previously loaded model.
class ModelLoadRecovery {
  final String revertToPath;
  final bool toBundledDefault;
  const ModelLoadRecovery(this.revertToPath, this.toBundledDefault);
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
/// loaded natively ([loadedModelPath]), revert to it; otherwise fall back to
/// [bundledDefault], which always exists on the device.
ModelLoadRecovery? modelLoadRecovery({
  required String failedPath,
  required String currentConfigPath,
  required String loadedModelPath,
  String bundledDefault = kDefaultBundledModelPath,
}) {
  if (!sameModelFile(failedPath, currentConfigPath)) return null;
  if (loadedModelPath.isNotEmpty &&
      !sameModelFile(loadedModelPath, currentConfigPath)) {
    return ModelLoadRecovery(loadedModelPath, false);
  }
  return ModelLoadRecovery(bundledDefault, true);
}

/// A plain-language extra line for known cryptic load errors, or '' when none
/// applies. The QNN case: context binaries are precompiled for ONE Hexagon NPU
/// generation (the file's min_arch), so on any other chip ONNX Runtime fails
/// with an opaque ORT_INVALID_GRAPH / "Error code: 5005".
String modelLoadHint(String failedPath, String reason) {
  final r = reason.toLowerCase();
  if (isQnnModelPath(failedPath) &&
      (r.contains('ort') || r.contains('qnn') || r.contains('5005'))) {
    return 'This *_qnn.onnx model was built for a different Snapdragon NPU '
        'generation and cannot run on this phone.';
  }
  return '';
}
