// Security checks for user-supplied detection model files.
//
// Everything here runs only while a model is imported or downloaded. None of
// these checks run in the camera, inference, tracking, or recording hot paths.

import 'dart:io';

import '../logging/device_storage.dart';

/// Maximum accepted TFLite weight size.
///
/// Change this constant if future TFLite detectors legitimately exceed
/// 30 MiB. Current bundled weights are about 2.5-4.7 MiB.
const int kMaxTfliteModelBytes = 30 * 1024 * 1024;

/// QNN context ONNX exports can be larger than equivalent TFLite weights.
/// Change this separately without weakening the normal TFLite limit.
const int kMaxQnnModelBytes = 256 * 1024 * 1024;

const int _modelStorageReserveBytes = 5 * 1024 * 1024;
const int _maxModelFileNameLength = 128;
final RegExp _safeModelBaseName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
final RegExp _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

/// True for the two model formats the Android runtime can execute.
bool isSupportedModelFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.tflite') || lower.endsWith('_qnn.onnx');
}

bool isQnnModelPath(String path) => path.toLowerCase().endsWith('_qnn.onnx');

int maxModelBytesForName(String name) =>
    isQnnModelPath(name) ? kMaxQnnModelBytes : kMaxTfliteModelBytes;

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

String modelSizeLimitMessage(String name) {
  final mib = maxModelBytesForName(name) ~/ (1024 * 1024);
  return 'The model is larger than the $mib MiB limit. '
      'The limit is documented in model_file_security.dart.';
}

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
Future<void> validateModelFile(File file, String name) async {
  final length = await file.length();
  if (length <= 0) throw Exception('The model file is empty.');
  if (length > maxModelBytesForName(name)) {
    throw Exception(modelSizeLimitMessage(name));
  }
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
Future<File> copyAndValidateModel(File source, File target, String name) async {
  final sourceBytes = await source.length();
  if (sourceBytes <= 0) throw Exception('The selected model file is empty.');
  if (sourceBytes > maxModelBytesForName(name)) {
    throw Exception(modelSizeLimitMessage(name));
  }
  await ensureModelStorageAvailable(target.parent.path, sourceBytes);

  final part = File('${target.path}.part');
  if (await part.exists()) await part.delete();
  try {
    var copied = 0;
    final sink = part.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        copied += chunk.length;
        if (copied > maxModelBytesForName(name)) {
          throw Exception(modelSizeLimitMessage(name));
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    await validateModelFile(part, name);
    if (await target.exists()) await target.delete();
    return await part.rename(target.path);
  } catch (_) {
    if (await part.exists()) await part.delete();
    rethrow;
  }
}
