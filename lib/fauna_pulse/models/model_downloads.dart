// FaunaPulse (round 268): the models a user can download, read from
// assets/model_downloads.json (the one file the maintainer edits; no model
// ships inside the app any more, owner decision 2026-10-01).
//
// A detection model is one file. An identification model comes with name
// lists (label packs for BioCLIP, the class list of a fixed-class
// classifier): the user downloads a list and the model comes with it when it
// is not on the phone yet, so a BioCLIP model is downloaded once and shared by
// its lists. Separate files instead of one zip per model: weights barely
// compress, unpacking would need twice the space for a moment, and a zip per
// list would repeat the shared model.
//
// Sizes and checksums are written by tool/model_downloads/update_catalogue.py
// from the local files. A file counts as "on this phone" by its NAME only
// (re-exported weights change their checksum); the checksum, when given, only
// verifies a download.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../identification/identification_assets.dart';
import '../identification/label_pack.dart';
import '../logging/app_error_hooks.dart';
import 'file_download.dart';
import 'model_catalog.dart';

const kModelDownloadsAsset = 'assets/model_downloads.json';

class DownloadFile {
  final String name;
  final Uri url;
  final int bytes;

  /// Verifies the download when given (64 hex digits).
  final String? sha256;

  const DownloadFile({required this.name, required this.url, required this.bytes, this.sha256});

  bool get isNameList => name.toLowerCase().endsWith('.fpack');
}

class NameListDownload {
  final String title;
  final DownloadFile file;
  const NameListDownload(this.title, this.file);
}

class ModelDownload {
  final String id;
  final bool identification;
  final String title;

  /// One plain line: what it finds or names.
  final String purpose;

  /// Optional caveat (speed, size).
  final String? note;
  final String licence;
  final String source;

  /// The model file itself.
  final DownloadFile file;

  /// Identification models only.
  final List<NameListDownload> lists;

  const ModelDownload({
    required this.id,
    required this.identification,
    required this.title,
    required this.purpose,
    this.note,
    required this.licence,
    required this.source,
    required this.file,
    this.lists = const [],
  });
}

class ModelDownloads {
  final List<ModelDownload> detectors;
  final List<ModelDownload> identification;

  const ModelDownloads({this.detectors = const [], this.identification = const []});

  static Future<ModelDownloads> load() async {
    try {
      return parse(await rootBundle.loadString(kModelDownloadsAsset));
    } catch (e) {
      logSwallowed('model_downloads_load', e);
      return const ModelDownloads();
    }
  }

  /// Parses the catalogue; an entry with a missing field or an unsafe file
  /// name is skipped (logged), so one typo cannot hide the others.
  static ModelDownloads parse(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    final base = Uri.parse(j['base_url'] as String);
    DownloadFile file(Map<String, dynamic> f) {
      final name = f['name'] as String;
      final url = f['url'] is String ? Uri.parse(f['url'] as String) : base.resolve(Uri.encodeComponent(name));
      if (!url.isScheme('https')) throw FormatException('not an HTTPS link: $url');
      final sha = f['sha256'] as String?;
      return DownloadFile(
        name: name,
        url: url,
        bytes: (f['bytes'] as num?)?.toInt() ?? 0,
        sha256: sha != null && sha.isNotEmpty ? sha : null,
      );
    }

    List<ModelDownload> entries(String key, {required bool identification}) {
      final out = <ModelDownload>[];
      for (final raw in (j[key] as List? ?? const [])) {
        try {
          final e = raw as Map<String, dynamic>;
          final model = file(e['file'] as Map<String, dynamic>);
          final lists = [
            for (final l in (e['lists'] as List? ?? const []))
              NameListDownload(l['title'] as String, file(l['file'] as Map<String, dynamic>)),
          ];
          final safe = identification
              ? isSafeIdentificationFileName(model.name, ext: '.tflite') &&
                    lists.every((l) => isSafeIdentificationFileName(l.file.name, ext: '.fpack'))
              : isSafeModelBaseName(model.name);
          if (!safe) throw FormatException('unsafe file name in ${e['id']}');
          out.add(
            ModelDownload(
              id: e['id'] as String,
              identification: identification,
              title: e['title'] as String,
              purpose: e['purpose'] as String,
              note: e['note'] as String?,
              licence: e['licence'] as String? ?? '',
              source: e['source'] as String? ?? '',
              file: model,
              lists: lists,
            ),
          );
        } catch (e) {
          logSwallowed('model_downloads_entry', e);
        }
      }
      return out;
    }

    return ModelDownloads(
      detectors: entries('detectors', identification: false),
      identification: entries('identification', identification: true),
    );
  }

  /// The catalogue entry whose model file is [fileName] (a name or a path).
  ModelDownload? modelFor(String fileName) {
    final name = fileName.split('/').last;
    for (final d in [...detectors, ...identification]) {
      if (d.file.name == name) return d;
    }
    return null;
  }

  /// The catalogue name list [fileName] (a name or a path), with its model.
  (ModelDownload, NameListDownload)? listFor(String fileName) {
    final name = fileName.split('/').last;
    for (final d in identification) {
      for (final l in d.lists) {
        if (l.file.name == name) return (d, l);
      }
    }
    return null;
  }
}

/// Downloads one catalogue file into the folder its kind lives in, with the
/// same checks as an import (structure, size cap) plus its checksum.
Future<File> downloadCatalogueFile(
  DownloadFile f, {
  required bool identification,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
  bool Function()? isCancelled,
}) async {
  if (!identification) {
    final dir = await ModelCatalog.modelsDir();
    return downloadToFile(
      f.url,
      safeModelTarget(dir, f.name),
      maxBytes: maxModelBytesForName(f.name),
      tooLargeMessage: modelSizeLimitMessage(f.name),
      validate: (part) => validateModelFile(part, f.name),
      expectedSha256: f.sha256,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }
  final dir = f.isNameList ? await IdentificationAssets.packsDir() : await IdentificationAssets.modelsDir();
  return downloadToFile(
    f.url,
    File('${dir.path}/${f.name}'),
    maxBytes: kMaxIdentificationFileBytes,
    tooLargeMessage: sizeLimitMessage(kMaxIdentificationFileBytes),
    validate: (part) async {
      await validateModelFile(part, f.name, maxBytes: kMaxIdentificationFileBytes);
      if (f.isNameList) await LabelPack.readHeader(part);
    },
    expectedSha256: f.sha256,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}
