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
// licence and source; only entries with a `file` are offered
// for download. Format 3: one `models` array; every entry and every name list
// says what it is in `kind`, with the words the screens use:
// "detection_model" / "identification_model", and for the name lists of an
// identification model ("name_lists") "class_list" (a classifier's fixed
// classes) / "label_pack" (BioCLIP's names). Both name lists are .fpack files
// (FaunaPulse pack, fpack.py in fauna-pulse-models). A file on the phone finds its entry by the
// naming rule (tool/model_downloads/README.md): the part before its first
// "_" is the entry's `id` (`flatbug-s_1024_fp16.tflite` → `flatbug-s`), or
// by the exact name of the offered file.
//
// Round 277 (owner): no "how to cite" field. A citation changes (a preprint
// becomes a journal paper) and the authors keep theirs up to date at the
// source, so the card shows the source and the screen asks to cite from there.
//
// Round 278 (owner): `uses`, the answers to the home screen's "What do you
// want to watch?" (pollinators on flowers, insects on a flat surface, mammals
// and birds), each with the models suggested for it: detection models by
// `id`, identification models with the name list to use. Kept in the list so
// the suggestions change without new code.
//
// Round 322 (owner): `former_name_lists`, the name lists no longer offered
// (replaced by a new version, or the 32-family demo). They are never offered
// or suggested, but a file on the phone keeps its title, licence and source,
// and shows its `note` (grey) or `warning` (amber) line; without the entry its
// card would say "not known, ask whoever made it" about our own file.

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

  /// Former name lists only (round 322): one line for the users who have the
  /// file, as a plain note or as a warning.
  final String? note;
  final String? warning;

  const NameListDownload(
    this.title,
    this.file, {
    this.classList = false,
    this.licence = '',
    this.source = '',
    this.note,
    this.warning,
  });
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

  /// The model file offered for download; null when the model is known
  /// (details for its files on the phone) but not offered (round 276).
  final DownloadFile? file;

  /// Identification models only (`name_lists`).
  final List<NameListDownload> nameLists;

  /// Name lists no longer offered (`former_name_lists`, round 322): known
  /// for the files on the phone, never offered or suggested.
  final List<NameListDownload> formerNameLists;

  const ModelDownload({
    required this.id,
    required this.identification,
    required this.title,
    required this.purpose,
    this.note,
    required this.licence,
    required this.source,
    this.file,
    this.nameLists = const [],
    this.formerNameLists = const [],
  });

  /// Offered for download.
  bool get offered => file != null;
}

/// An identification model with the name list it uses.
typedef NamingDownload = (ModelDownload model, NameListDownload list);

/// One answer to "What do you want to watch?" (round 278).
class WatchUse {
  final String id;

  /// Which drawing the tile shows (widgets/watch_tiles.dart).
  final String icon;
  final String title;

  /// One sentence on where to put the phone.
  final String setup;

  /// Suggested detection models, in the order to suggest them (the first
  /// is the page's suggestion).
  final List<ModelDownload> find;

  /// Suggested identification models with their name list, in the order to
  /// suggest them (the first is the page's suggestion).
  final List<NamingDownload> name;

  const WatchUse({
    required this.id,
    required this.icon,
    required this.title,
    required this.setup,
    required this.find,
    this.name = const [],
  });
}

class ModelDownloads {
  /// Every known model of each kind; [offers] are the ones to download.
  final List<ModelDownload> detectors;
  final List<ModelDownload> identification;

  /// The answers to "What do you want to watch?" (round 278).
  final List<WatchUse> uses;

  const ModelDownloads({this.detectors = const [], this.identification = const [], this.uses = const []});

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
    // base_url is only needed for a file without its own 'url'; a missing or
    // wrong base_url fails just those entries (in file()), not the whole list.
    final rawBase = j['base_url'];
    final base = rawBase is String ? Uri.tryParse(rawBase) : null;
    DownloadFile file(Map<String, dynamic> f) {
      final name = f['name'] as String;
      final Uri url;
      if (f['url'] is String) {
        url = Uri.parse(f['url'] as String);
      } else if (base != null) {
        url = base.resolve(Uri.encodeComponent(name));
      } else {
        throw FormatException('no url and no usable base_url for $name');
      }
      // An empty host ('https:///x') still has the https scheme; without the
      // host check such a typo would be offered and only fail at download.
      if (!url.isScheme('https') || url.host.isEmpty) throw FormatException('not an HTTPS link with a host: $url');
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
    // A wrong type here or at 'uses' is logged and read as an empty list
    // instead of throwing, matching how single entries are skipped below.
    List topList(String key) {
      final v = j[key];
      if (v is List) return v;
      if (v != null) logSwallowed('model_downloads_top', '$key is not a list');
      return const [];
    }

    for (final raw in topList('models')) {
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
        List<NameListDownload> lists(String key) => [
          for (final l in (e[key] as List? ?? const []))
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
              note: l['note'] as String?,
              warning: l['warning'] as String?,
            ),
        ];
        final offeredLists = lists('name_lists'), formerLists = lists('former_name_lists');
        final allLists = [...offeredLists, ...formerLists];
        final safe = isId
            ? (model == null || isSafeIdentificationFileName(model.name, ext: '.tflite')) &&
                  allLists.every((l) => isSafeIdentificationFileName(l.file.name, ext: '.fpack'))
            : (model == null || isSafeModelBaseName(model.name)) && allLists.isEmpty;
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
            file: model,
            nameLists: offeredLists,
            formerNameLists: formerLists,
          ),
        );
      } catch (e) {
        logSwallowed('model_downloads_entry', e);
      }
    }
    return ModelDownloads(
      detectors: detectors,
      identification: identification,
      uses: _parseUses(topList('uses'), detectors, identification),
    );
  }

  /// `uses` (round 278). A suggestion naming a model that is not offered, or
  /// a list that model does not have, is left out (logged); a use left with
  /// no detection model is skipped.
  static List<WatchUse> _parseUses(List raw, List<ModelDownload> detectors, List<ModelDownload> identification) {
    ModelDownload? offered(List<ModelDownload> all, String id) =>
        all.where((d) => d.offered && modelKey(d.id) == modelKey(id)).firstOrNull;
    final uses = <WatchUse>[];
    for (final u in raw) {
      try {
        final e = u as Map<String, dynamic>;
        final id = e['id'] as String;
        final find = <ModelDownload>[];
        for (final m in (e['find'] as List? ?? const [])) {
          final d = offered(detectors, m as String);
          if (d != null) {
            find.add(d);
          } else {
            logSwallowed('model_downloads_use', 'no offered detection model $m in use $id');
          }
        }
        final name = <NamingDownload>[];
        for (final n in (e['name'] as List? ?? const [])) {
          final m = (n as Map<String, dynamic>)['model'] as String;
          final d = offered(identification, m);
          final listName = n['list'] as String?;
          // A classifier has one list (its classes): it may be left out.
          final list = d?.nameLists
              .where((l) => listName == null ? d.nameLists.length == 1 : l.file.name == listName)
              .firstOrNull;
          if (d != null && list != null) {
            name.add((d, list));
          } else {
            logSwallowed('model_downloads_use', 'no offered identification model $m with list $listName in use $id');
          }
        }
        if (find.isEmpty) throw FormatException('no detection model offered for use $id');
        uses.add(
          WatchUse(
            id: id,
            icon: e['icon'] as String? ?? id,
            title: e['title'] as String,
            setup: e['setup'] as String? ?? '',
            find: find,
            name: name,
          ),
        );
      } catch (e) {
        logSwallowed('model_downloads_use', e);
      }
    }
    return uses;
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

  /// The catalogue name list [fileName] (a name or a path), with its model;
  /// also a list no longer offered (round 322).
  (ModelDownload, NameListDownload)? listFor(String fileName) {
    final name = fileName.split('/').last;
    for (final d in identification) {
      for (final l in [...d.nameLists, ...d.formerNameLists]) {
        if (l.file.name == name) return (d, l);
      }
    }
    return null;
  }
}

/// Downloads one catalogue file into the folder its kind lives in, with the
/// same checks as an import (structure, size limit) plus its checksum.
Future<File> downloadCatalogueFile(
  DownloadFile f, {
  required bool identification,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
  bool Function()? isCancelled,
}) async {
  final File target;
  if (!identification) {
    target = safeModelTarget(await ModelCatalog.modelsDir(), f.name);
  } else {
    final dir = f.isNameList ? await IdentificationAssets.packsDir() : await IdentificationAssets.modelsDir();
    target = File('${dir.path}/${f.name}');
  }
  return downloadToFile(
    f.url,
    target,
    validate: (part) async {
      await validateModelFile(part, f.name);
      if (f.isNameList) await LabelPack.readHeader(part);
    },
    expectedSha256: f.sha256,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}
