// Security checks for user-supplied model files and name lists.
//
// Everything here runs only while a model is imported or downloaded. None of
// these checks run in the camera, inference, tracking, or recording hot paths.

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';

/// The largest file the app accepts: every detection model, identification
/// model and name list (round 314: one limit for all). 2 GiB is a ceiling the
/// app sets. An .onnx file cannot be larger, and the Kotlin code that reads a
/// model's labels and input size maps the whole file into memory as one
/// block, which Java's file mapping allows only up to 2 GiB. (A .tflite file
/// can be larger if its weights are stored after the FlatBuffer, as some
/// large language models do, but no detector or identification model the
/// app offers does this.) Detectors no longer have a smaller limit: none ships
/// inside the app (they are downloaded or imported) and they can run live or
/// afterwards on a recorded video, so a large detector is a choice of speed.
const int kMaxModelFileBytes = 2 * 1024 * 1024 * 1024;

const int _modelStorageReserveBytes = 5 * 1024 * 1024;
const int _maxModelFileNameLength = 128;
final RegExp _safeModelBaseName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
final RegExp _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

/// Deletes the file picker's cache copies after an import (round 267): the
/// picker copies every picked file into the app's cache first, and an
/// identification model is up to 1.3 GB.
Future<void> clearFilePickerCache() async {
  try {
    await FilePicker.platform.clearTemporaryFiles();
  } catch (e) {
    logSwallowed('picker_cache_clear', e);
  }
}

/// True for the two model formats the Android runtime can execute.
bool isSupportedModelFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.tflite') || lower.endsWith('_qnn.onnx');
}

bool isQnnModelPath(String path) => path.toLowerCase().endsWith('_qnn.onnx');

/// Alphabetical order of two files by name, upper and lower case alike
/// (round 275: every model list is sorted this way).
int fileNameOrder(String a, String b) {
  final x = a.split('/').last;
  final y = b.split('/').last;
  final c = x.toLowerCase().compareTo(y.toLowerCase());
  return c != 0 ? c : x.compareTo(y);
}

bool isValidSha256(String value) => _sha256Hex.hasMatch(value);

/// A base name only, never a path. This rejects decoded %2F separators,
/// traversal, control characters, spaces, and unusual shell-like punctuation.
bool isSafeModelBaseName(String name) {
  if (name.isEmpty || name.length > _maxModelFileNameLength) return false;
  if (name.contains('..') || !_safeModelBaseName.hasMatch(name)) return false;
  return isSupportedModelFileName(name);
}

/// A bounded harmless label for explaining a rejected picker entry.
String safeModelDisplayName(String name) {
  final clean = name.replaceAll(_controlCharacters, '?');
  if (clean.isEmpty) return 'Selected file';
  return clean.length <= 80 ? clean : '${clean.substring(0, 77)}...';
}

/// Resolves a validated name and checks containment again as defense in depth.
File safeModelTarget(Directory directory, String name) {
  if (!isSafeModelBaseName(name)) {
    throw Exception('Unsafe or unsupported model file name.');
  }
  final root = directory.absolute;
  final target = File('${root.path}${Platform.pathSeparator}$name').absolute;
  if (target.parent.path != root.path) {
    throw Exception('The model destination escaped the private model folder.');
  }
  return target;
}

/// The plain-language refusal of a file above [maxBytes] ("2.0 GB").
String sizeLimitMessage([int maxBytes = kMaxModelFileBytes]) =>
    'The file is larger than ${formatBytes(maxBytes)}, the largest model '
    'file or name list the app can use.';

String plainModelError(Object error) =>
    '$error'.replaceFirst('Exception: ', '');

/// A redirect may be relative, so resolve every hop against the previous URL.
bool redirectChainStaysHttps(Uri original, List<RedirectInfo> redirects) {
  if (!original.isScheme('https')) return false;
  var current = original;
  for (final redirect in redirects) {
    current = current.resolveUri(redirect.location);
    if (!current.isScheme('https')) return false;
  }
  return true;
}

Future<void> ensureModelStorageAvailable(String path, int incomingBytes) async {
  final reading = await DeviceStorage.read(path: path);
  final free = reading.freeBytes;
  if (free != null && free < incomingBytes + _modelStorageReserveBytes) {
    throw Exception(
      'Not enough free storage for this model. Keep at least 5 MiB free '
      'after the import.',
    );
  }
}

/// Lightweight structural validation before a file becomes selectable.
///
/// TFLite FlatBuffers carry the ASCII identifier TFL3 at bytes 4-7. QNN ONNX
/// is protobuf and has no equally stable magic value, so its protection is the
/// strict name, non-empty file, size ceiling, private storage, and native
/// metadata bounds.
///
/// [maxBytes] is [kMaxModelFileBytes] for every kind of file; tests pass a
/// small one.
Future<void> validateModelFile(
  File file,
  String name, {
  int maxBytes = kMaxModelFileBytes,
}) async {
  final length = await file.length();
  if (length <= 0) throw Exception('The model file is empty.');
  if (length > maxBytes) throw Exception(sizeLimitMessage(maxBytes));
  if (!name.toLowerCase().endsWith('.tflite')) return;

  final input = await file.open();
  try {
    final header = await input.read(8);
    final valid =
        header.length == 8 &&
        header[4] == 0x54 &&
        header[5] == 0x46 &&
        header[6] == 0x4c &&
        header[7] == 0x33;
    if (!valid) {
      throw Exception('This file does not contain a valid TFLite TFL3 header.');
    }
  } finally {
    await input.close();
  }
}

/// Streams through a temporary file, so rejected or interrupted imports never
/// replace an existing usable model with a partial file.
Future<File> copyAndValidateModel(
  File source,
  File target,
  String name, {
  int maxBytes = kMaxModelFileBytes,
}) async {
  final sourceBytes = await source.length();
  if (sourceBytes <= 0) throw Exception('The selected model file is empty.');
  if (sourceBytes > maxBytes) throw Exception(sizeLimitMessage(maxBytes));
  await ensureModelStorageAvailable(target.parent.path, sourceBytes);

  final part = File('${target.path}.part');
  if (await part.exists()) await part.delete();
  try {
    var copied = 0;
    final sink = part.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        copied += chunk.length;
        if (copied > maxBytes) throw Exception(sizeLimitMessage(maxBytes));
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    await validateModelFile(part, name, maxBytes: maxBytes);
    if (await target.exists()) await target.delete();
    return await part.rename(target.path);
  } catch (_) {
    if (await part.exists()) await part.delete();
    rethrow;
  }
}
