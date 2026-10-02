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
//
// Round 276 (owner): the list names EVERY model the project knows, with its
// licence, source and how to cite it; only entries with a `file` are offered
// for download. Format 3: one `models` array; every entry and every name list
// says what it is in `kind`, with the words the screens use:
// "detection_model" / "identification_model", and for the name lists of an
// identification model ("name_lists") "class_list" (a classifier's fixed
// classes) / "label_pack" (BioCLIP's names). Both name lists are .fpack files
// (FaunaPulse pack, tool/bioclip_export/fpack.py). A file on the phone finds its entry by the
// naming rule (tool/model_downloads/README.md): the part before its first
// "_" is the entry's `id` (`flatbug-s_1024_fp16.tflite` → `flatbug-s`), or
// by the exact name of the offered file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../identification/identification_assets.dart';
import '../identification/identification_store.dart' show modelIdOf, modelKey;
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

  /// A classifier's class list (`"kind": "class_list"`), else a label pack.
  final bool classList;

  /// The names' own licence and source when they differ from the model's
  /// (round 276; e.g. the TreeOfLife embeddings, CC0).
  final String licence;
  final String source;

  const NameListDownload(this.title, this.file, {this.classList = false, this.licence = '', this.source = ''});
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

  /// How to cite the model (round 276), '' when not given.
  final String cite;

  /// The model file offered for download; null when the model is known
  /// (details for its files on the phone) but not offered (round 276).
  final DownloadFile? file;

  /// Identification models only (`name_lists`).
  final List<NameListDownload> nameLists;

  const ModelDownload({
    required this.id,
    required this.identification,
    required this.title,
    required this.purpose,
    this.note,
    required this.licence,
    required this.source,
    this.cite = '',
    this.file,
    this.nameLists = const [],
  });

  /// Offered for download.
  bool get offered => file != null;
}

class ModelDownloads {
  /// Every known model of each kind; [offers] are the ones to download.
  final List<ModelDownload> detectors;
  final List<ModelDownload> identification;

  const ModelDownloads({this.detectors = const [], this.identification = const []});

  List<ModelDownload> get detectorOffers => [for (final d in detectors) if (d.offered) d];
  List<ModelDownload> get identificationOffers => [for (final d in identification) if (d.offered) d];

  static Future<ModelDownloads> load() async {
    try {
      return parse(await rootBundle.loadString(kModelDownloadsAsset));
    } catch (e) {
      logSwallowed('model_downloads_load', e);
      return const ModelDownloads();
    }
  }

  /// Parses the catalogue; an entry with a missing field, an unsafe file
  /// name or a repeated `id` is skipped (logged), so one typo cannot hide
  /// the others.
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

    final ids = <String>{};
    final detectors = <ModelDownload>[];
    final identification = <ModelDownload>[];
    for (final raw in (j['models'] as List? ?? const [])) {
      try {
        final e = raw as Map<String, dynamic>;
        final id = e['id'] as String;
        final isId = switch (e['kind']) {
          'detection_model' => false,
          'identification_model' => true,
          _ => throw FormatException('unknown kind ${e['kind']} of $id'),
        };
        if (!ids.add(modelKey(id))) throw FormatException('repeated id $id');
        final model = e['file'] is Map ? file(e['file'] as Map<String, dynamic>) : null;
        final lists = [
          for (final l in (e['name_lists'] as List? ?? const []))
            NameListDownload(
              l['title'] as String,
              file(l['file'] as Map<String, dynamic>),
              classList: switch (l['kind']) {
                'class_list' => true,
                'label_pack' => false,
                _ => throw FormatException('unknown name list kind ${l['kind']} in $id'),
              },
              licence: l['licence'] as String? ?? '',
              source: l['source'] as String? ?? '',
            ),
        ];
        final safe = isId
            ? (model == null || isSafeIdentificationFileName(model.name, ext: '.tflite')) &&
                  lists.every((l) => isSafeIdentificationFileName(l.file.name, ext: '.fpack'))
            : (model == null || isSafeModelBaseName(model.name)) && lists.isEmpty;
        if (!safe) throw FormatException('unsafe file name in $id');
        (isId ? identification : detectors).add(
          ModelDownload(
            id: id,
            identification: isId,
            title: e['title'] as String,
            purpose: e['purpose'] as String,
            note: e['note'] as String?,
            licence: e['licence'] as String? ?? '',
            source: e['source'] as String? ?? '',
            cite: e['cite'] as String? ?? '',
            file: model,
            nameLists: lists,
          ),
        );
      } catch (e) {
        logSwallowed('model_downloads_entry', e);
      }
    }
    return ModelDownloads(detectors: detectors, identification: identification);
  }

  /// The entry of the model file [fileName] (a name or a path): the one
  /// that offers exactly this file, else the one whose `id` is the file's
  /// first part (round 276, compared with [modelKey]).
  ModelDownload? modelFor(String fileName) {
    final name = fileName.split('/').last;
    final all = [...detectors, ...identification];
    for (final d in all) {
      if (d.file?.name == name) return d;
    }
    final key = modelKey(modelIdOf(name));
    for (final d in all) {
      if (modelKey(d.id) == key) return d;
    }
    return null;
  }

  /// The catalogue name list [fileName] (a name or a path), with its model.
  (ModelDownload, NameListDownload)? listFor(String fileName) {
    final name = fileName.split('/').last;
    for (final d in identification) {
      for (final l in d.nameLists) {
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
