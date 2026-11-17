// FaunaPulse (round 274): which identification model and name list a run
// uses, shared by "Identify organisms" and the "Also identify them" switch of
// the Find screens (the widget: screens/identification_choice_fields.dart).
//
// Moved out of identification_screen.dart, rules unchanged: a classifier
// takes its class list (same file name, round 266); a model is offered only
// the name lists made for it (IdentificationAssets.listBelongsTo, round 271);
// the choice is remembered in IdentifyPrefs (identify_model / identify_pack).
import 'dart:io';

import '../logging/app_error_hooks.dart';
import 'identification_assets.dart';
import 'identification_store.dart' show stemOf;
import 'label_pack.dart';

class IdentificationChoice {
  List<File> models;
  List<File> packs;

  /// Header of every name list by path (round 271).
  Map<String, Map<String, dynamic>> headers;
  File? model;
  File? pack;

  IdentificationChoice({
    this.models = const [],
    this.packs = const [],
    this.headers = const {},
    this.model,
    this.pack,
  });

  /// [modelName] and [packName] (IdentifyPrefs) when they are on the phone,
  /// else the first model and its first list; a classifier's class list
  /// always goes with it.
  factory IdentificationChoice.fromFiles(
    List<File> models,
    List<File> packs,
    Map<String, Map<String, dynamic>> headers, {
    String? modelName,
    String? packName,
  }) {
    final c = IdentificationChoice(models: models, packs: packs, headers: headers, model: _pick(models, modelName));
    c.pack = classListFor(c.model, packs) ?? _pick(c.modelPacks, packName);
    return c;
  }

  /// Reads the models and name lists on the phone (identification/ in the
  /// app's files) and picks as [IdentificationChoice.fromFiles].
  static Future<IdentificationChoice> load({String? modelName, String? packName}) async {
    final models = await IdentificationAssets.listModels();
    final packs = await IdentificationAssets.listPacks();
    return IdentificationChoice.fromFiles(
      models,
      packs,
      await readHeaders(packs),
      modelName: modelName,
      packName: packName,
    );
  }

  /// Reads the files again (after Download & import models): a chosen file
  /// that was deleted falls back to the first one, and a model's class list
  /// is chosen with it.
  Future<void> reload() async {
    models = await IdentificationAssets.listModels();
    packs = await IdentificationAssets.listPacks();
    headers = await readHeaders(packs);
    _regions.clear();
    model = models.where((f) => f.path == model?.path).firstOrNull ?? models.firstOrNull;
    _fitPack();
  }

  /// The name lists made for the chosen model: only these are offered, and
  /// without one the model cannot identify.
  List<File> get modelPacks => listsFor(model, packs, headers);

  Map<String, dynamic>? get packHeader => pack == null ? null : headers[pack!.path];

  /// Round 373: the chosen name list's country lists (null: it has none), decoded once per
  /// file and kept, because a page rebuilds often and the lists are a megabyte of text.
  PackRegions? get packRegions {
    final p = pack, h = packHeader;
    if (p == null || h == null || isClassListHeader(h)) return null;
    return _regions.putIfAbsent(p.path, () => PackRegions.tryParse(h['regions'], (h['rows'] as num?)?.toInt() ?? 0));
  }

  final _regions = <String, PackRegions?>{};

  /// Round 379: the list made for the chosen model that holds the most names GBIF lists for
  /// [country], with that number; null when the chosen list holds as many or more. A country
  /// near a continent border has most of its names in the neighbouring continent's list (in
  /// the Asia list Indonesia has 4,665 names, in the Oceania list 2,191). Read from the header
  /// map as it is, without decoding every list's country lists.
  ({File file, int names})? listWithMoreNamesOf(String country) {
    int namesIn(File p) {
      final regions = headers[p.path]?['regions'];
      final countries = regions is Map ? regions['countries'] : null;
      final entry = countries is Map ? countries[country] : null;
      final n = entry is Map ? entry['names'] : null;
      return n is int ? n : 0;
    }

    final chosen = pack == null ? 0 : namesIn(pack!);
    ({File file, int names})? best;
    for (final p in modelPacks) {
      final n = namesIn(p);
      if (n > chosen && n > (best?.names ?? 0)) best = (file: p, names: n);
    }
    return best;
  }

  /// Round 377: the chosen name list's orders and families (null for a class list).
  PackTaxa? get packTaxa {
    final taxa = packHeader?[kPackTaxaKey];
    return taxa is PackTaxa ? taxa : null;
  }

  /// A fixed-class classifier's list (round 266), not a label pack.
  bool get isClassList => isClassListHeader(packHeader);

  /// A model and a name list made for it are chosen: a run can identify.
  bool get ready => model != null && pack != null;

  /// Some model on the phone has a name list made for it.
  bool get anyUsable => models.any((m) => listsFor(m, packs, headers).isNotEmpty);

  /// Chooses [m] and the list that goes with it: its class list, else the
  /// chosen list when it fits [m], else its first list, else none.
  void selectModel(File m) {
    model = m;
    _fitPack();
  }

  void selectPack(File? p) => pack = p;

  void _fitPack() {
    final lists = modelPacks;
    pack = classListFor(model, lists) ?? lists.where((f) => f.path == pack?.path).firstOrNull ?? lists.firstOrNull;
  }

  /// Remembers the choice for the next run (and for "Identify organisms").
  Future<void> save([IdentifyPrefs? prefs]) async {
    final p = prefs ?? await IdentifyPrefs.load();
    p.modelName = model?.path.split('/').last;
    p.packName = pack?.path.split('/').last;
    await p.save();
  }

  static File? _pick(List<File> files, String? name) {
    if (files.isEmpty) return null;
    for (final f in files) {
      if (name != null && f.path.endsWith('/$name')) return f;
    }
    return files.first;
  }

  /// Round 266: a fixed-class classifier (e.g. insectDCT) comes with its
  /// class list under the same file name (`x.tflite` + `x.fpack`).
  static File? classListFor(File? model, List<File> packs) {
    if (model == null) return null;
    final stem = stemOf(model.path.split('/').last);
    for (final p in packs) {
      if (stemOf(p.path.split('/').last) == stem) return p;
    }
    return null;
  }

  static Future<Map<String, Map<String, dynamic>>> readHeaders(List<File> packs) async {
    final headers = <String, Map<String, dynamic>>{};
    for (final p in packs) {
      try {
        headers[p.path] = await LabelPack.readHeader(p);
      } catch (e) {
        logSwallowed('identify_pack_header', e);
      }
    }
    return headers;
  }

  /// The name lists made for [model] (round 271).
  static List<File> listsFor(File? model, List<File> packs, Map<String, Map<String, dynamic>> headers) =>
      model == null
      ? const []
      : [for (final p in packs) if (IdentificationAssets.listBelongsTo(p, headers[p.path], model)) p];
}
