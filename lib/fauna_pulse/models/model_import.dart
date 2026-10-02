// FaunaPulse (round 275): one way in for every model file the user brings,
// imported from the phone or downloaded from a link. Each file is checked
// (models/model_file_kind.dart) and put where its kind lives: detection
// models with ModelCatalog, identification models and name lists with
// IdentificationAssets. Before, each kind had its own Import button, and a
// classifier imported with the detection button became a "detection model".
//
// A file whose name is already on the phone is not replaced without asking
// (owner: importing a model listed as "On this phone" gave no warning).
// To bring all the models of a folder, the user selects them all in the file
// chooser (owner decision: no folder chooser, since Android 11 and newer does
// not allow choosing the Download folder itself).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../identification/identification_assets.dart';
import '../logging/app_error_hooks.dart';
import 'file_download.dart';
import 'model_catalog.dart';
import 'model_file_kind.dart';

export 'model_file_kind.dart' show ModelFileKind;

/// Asked when [name] is already on this phone as a [kind]: true replaces it.
/// [filesLeft]: how many chosen files come after this one (the question can
/// then offer the same answer for the others).
typedef ReplaceQuestion = Future<bool> Function(String name, ModelFileKind kind, int filesLeft);

class ModelImportReport {
  final List<(String, ModelFileKind)> imported;

  /// Already on this phone and kept (not replaced).
  final List<String> kept;
  final List<String> rejected;

  const ModelImportReport({this.imported = const [], this.kept = const [], this.rejected = const []});

  bool get isEmpty => imported.isEmpty && kept.isEmpty && rejected.isEmpty;

  /// The imported file names of [kind].
  List<String> namesOf(ModelFileKind kind) => [
    for (final (name, k) in imported)
      if (k == kind) name,
  ];
}

class ModelImport {
  /// A safe name of a file the app can use: a detection model (.tflite,
  /// *_qnn.onnx), an identification model (.tflite) or a name list (.fpack).
  static bool isSafeName(String name) =>
      isSafeModelBaseName(name) || isSafeIdentificationFileName(name, ext: '.fpack');

  /// Where a [kind] named [name] is kept.
  static Future<File> target(ModelFileKind kind, String name) async => switch (kind) {
    ModelFileKind.detection => safeModelTarget(await ModelCatalog.modelsDir(), name),
    ModelFileKind.identification => File('${(await IdentificationAssets.modelsDir()).path}/$name'),
    ModelFileKind.nameList => File('${(await IdentificationAssets.packsDir()).path}/$name'),
  };

  /// The size cap of a [kind]: null keeps the detection model limits.
  static int? maxBytes(ModelFileKind kind) =>
      kind == ModelFileKind.detection ? null : kMaxIdentificationFileBytes;

  /// The kinds a file named [name] is already on the phone as. Asked before
  /// a link download, when only the name is known: a .tflite file can be
  /// either kind of model.
  static Future<List<ModelFileKind>> onPhoneAs(String name) async {
    final lower = name.toLowerCase();
    final kinds = lower.endsWith('.fpack')
        ? [ModelFileKind.nameList]
        : isQnnModelPath(lower)
        ? [ModelFileKind.detection]
        : [ModelFileKind.detection, ModelFileKind.identification];
    return [
      for (final k in kinds)
        if (await (await target(k, name)).exists()) k,
    ];
  }

  /// Opens the file chooser (many files at once) and imports the chosen
  /// files. [onFileLoading] reports when the chooser starts copying (slow
  /// for a 1 GB model); its own cache copies are removed afterwards.
  static Future<ModelImportReport> pickAndImport({
    required ReplaceQuestion replace,
    void Function(FilePickerStatus)? onFileLoading,
  }) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, onFileLoading: onFileLoading);
    if (result == null) return const ModelImportReport();
    try {
      return await importFiles([for (final f in result.files) (f.name, f.path)], replace: replace);
    } finally {
      await clearFilePickerCache();
    }
  }

  /// Copies each chosen file ([name], [path]) where its kind lives, through
  /// the streamed size and structure checks. A file already on the phone is
  /// replaced only when [replace] says so.
  static Future<ModelImportReport> importFiles(
    List<(String, String?)> files, {
    required ReplaceQuestion replace,
  }) async {
    final imported = <(String, ModelFileKind)>[];
    final kept = <String>[];
    final rejected = <String>[];
    for (final (i, (name, path)) in files.indexed) {
      final display = safeModelDisplayName(name);
      if (path == null) {
        rejected.add('$display: the chosen file could not be read.');
        continue;
      }
      if (!isSafeName(name)) {
        rejected.add('$display: not a safely named model file (.tflite, *_qnn.onnx) or name list (.fpack).');
        continue;
      }
      try {
        final source = File(path);
        final kind = await modelFileKind(source, name);
        final target = await ModelImport.target(kind, name);
        if (await target.exists() && !await replace(name, kind, files.length - 1 - i)) {
          kept.add(name);
          continue;
        }
        await copyAndValidateModel(source, target, name, maxBytes: maxBytes(kind));
        imported.add((name, kind));
      } catch (e) {
        rejected.add('$display: ${plainModelError(e)}');
        logSwallowed('model_import', e);
      }
    }
    return ModelImportReport(imported: imported, kept: kept, rejected: rejected);
  }

  /// The file name a link points at when the app can use it, else null.
  static String? linkFileName(String url) => modelFileNameFromUrl(url, accept: isSafeName);

  /// Downloads the file of [url] into the app's cache, checks what it is,
  /// and moves it where its kind lives (replacing a file of the same name:
  /// the caller asked first, see [onPhoneAs]). Returns its name and kind;
  /// throws with a plain-language message on any failure.
  static Future<(String, ModelFileKind)> download(
    String url, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final name = linkFileName(url);
    if (name == null) {
      throw Exception('Use an HTTPS link to a safely named .tflite, *_qnn.onnx or .fpack file.');
    }
    // The kind, and so the size cap, is known only once the file is here:
    // the largest cap of the names' possible kinds until then.
    final cap = isQnnModelPath(name) ? maxModelBytesForName(name) : kMaxIdentificationFileBytes;
    final cache = Directory('${(await getTemporaryDirectory()).path}/link_download');
    await cache.create(recursive: true);
    late ModelFileKind kind;
    final saved = await downloadToFile(
      Uri.parse(url.trim()),
      File('${cache.path}/$name'),
      maxBytes: cap,
      tooLargeMessage: sizeLimitMessage(cap),
      validate: (part) async {
        await validateModelFile(part, name, maxBytes: cap);
        kind = await modelFileKind(part, name);
        if (kind == ModelFileKind.detection && await part.length() > maxModelBytesForName(name)) {
          throw Exception(modelSizeLimitMessage(name));
        }
      },
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    try {
      final target = await ModelImport.target(kind, name);
      if (await target.exists()) await target.delete();
      try {
        await saved.rename(target.path);
      } on FileSystemException {
        // Another storage volume: copy, then the finally below removes it.
        await copyAndValidateModel(saved, target, name, maxBytes: maxBytes(kind));
      }
    } finally {
      if (await saved.exists()) await saved.delete();
    }
    return (name, kind);
  }
}
