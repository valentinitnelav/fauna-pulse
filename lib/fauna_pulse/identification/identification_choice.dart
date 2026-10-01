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
    model = models.where((f) => f.path == model?.path).firstOrNull ?? models.firstOrNull;
    _fitPack();
  }

  /// The name lists made for the chosen model: only these are offered, and
  /// without one the model cannot identify.
  List<File> get modelPacks => listsFor(model, packs, headers);

  Map<String, dynamic>? get packHeader => pack == null ? null : headers[pack!.path];

  /// A fixed-class classifier's list (round 266), not a label pack.
  bool get isClassList => packHeader?['kind'] == 'classes';

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
