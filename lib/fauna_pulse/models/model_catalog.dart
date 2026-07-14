// FaunaPulse — the catalog of detection models the user can choose from.
//
// Three kinds of model can appear in the picker:
//   * official  — the YOLO26 sizes the plugin can fetch/bundle (only nano ships).
//   * bundled   — custom .tflite files shipped inside the app (assets/models/custom/).
//   * imported  — custom .tflite files the user dropped onto the phone and imported
//                 at runtime (e.g. from the Downloads folder) via the file picker.
//                 These live in the app's own models folder, which is also visible
//                 over USB at Android/data/<package>/files/models/.
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

import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import '../logging/app_error_hooks.dart';

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
  /// Official YOLO26 sizes. Only nano is actually shipped in the app; the others
  /// need their .tflite added (or a custom model imported) to take effect.
  static const officialModels = {
    'yolo26n': 'YOLO26 nano — fastest (bundled)',
    'yolo26s': 'YOLO26 small (add file)',
    'yolo26m': 'YOLO26 medium (add file)',
    'yolo26l': 'YOLO26 large (add file)',
    'yolo26x': 'YOLO26 x-large — most accurate (add file)',
  };

  static const bundledIds = {'yolo26n'};

  /// Folder (inside the app bundle) holding custom detectors shipped with the app.
  /// Every `.tflite` here is offered automatically — see [_bundledCustomAssets].
  static const bundledCustomDir = 'assets/models/custom/';

  static final _channel = ChannelConfig.createSingleImageChannel();

  /// Lists every bundled custom-model asset by reading the build's AssetManifest,
  /// so any `.tflite` dropped into [bundledCustomDir] appears in the app without a
  /// code change (just rebuild). Sorted for a stable menu order.
  static Future<List<String>> _bundledCustomAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return manifest
        .listAssets()
        .where(
          (p) =>
              p.startsWith(bundledCustomDir) &&
              p.toLowerCase().endsWith('.tflite'),
        )
        .toList()
      ..sort();
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

    for (final asset in await _bundledCustomAssets()) {
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
            .where((f) => f.path.toLowerCase().endsWith('.tflite'))
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

    for (final entry in officialModels.entries) {
      final id = entry.key;
      final isBundled = bundledIds.contains(id);
      // Only the bundled nano is on the device, so only it can be inspected for
      // input size/task. Inspect it via its real asset file (the detection export
      // is the int8 file under assets/models/), not the bare "yolo26n" id — the
      // bare id can't be located on disk, so it would read back as "unknown".
      final meta = isBundled
          ? await _inspect('assets/models/${id}_int8.tflite')
          : const <String, dynamic>{};
      entries.add(
        ModelEntry(
          id: id,
          name: entry.value,
          source: ModelSource.official,
          precision: isBundled ? 'int8' : null,
          inputSize: _imgszFrom(meta),
          task: meta['task'] as String?,
        ),
      );
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

  /// Opens the system file picker so the user can choose one or more .tflite
  /// models from anywhere on the phone (Downloads, a folder they pick, etc.) and
  /// copies them into the app's models folder. Returns how many were imported.
  static Future<int> importModels() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return 0;
    final dir = await modelsDir();
    var imported = 0;
    for (final picked in result.files) {
      final path = picked.path;
      if (path == null) continue;
      if (!path.toLowerCase().endsWith('.tflite')) continue;
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
  /// bundled-asset mapping [build] uses, so e.g. "yolo26n" (a bare id with no
  /// file on disk) resolves to its real asset before inspection. Lets screens
  /// other than the settings sheet show a model's input size without rebuilding
  /// the whole catalog.
  static Future<int?> inputSizeOf(String modelPath) async {
    final probe = bundledIds.contains(modelPath)
        ? 'assets/models/${modelPath}_int8.tflite'
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
