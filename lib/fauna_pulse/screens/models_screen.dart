// FaunaPulse (round 267): one screen for every model file, "Download & import
// models" since round 271 (owner: "AI models" was too vague): home screen menu,
// and a "Download & import models…" link next to every model list.
//
// Two kinds of model, named for what they do (owner decision, round 267):
//   • Detection models find animals in a picture and draw boxes: live in a
//     session, or afterwards ("Find animals in photos / videos"). ModelCatalog.
//   • Identification models name what is inside a box ("Identify
//     organisms"), choosing from a name list (.fpack): a label pack for
//     BioCLIP, or the class list of a fixed-class classifier such as
//     insectDCT (same file name as its model). IdentificationAssets.
// The user downloads, imports and deletes files here; the screens that run a
// model only choose one.
//
// Round 268: no model ships with the app, so the screen leads with what can
// be downloaded (assets/model_downloads.json, ModelDownloads): a title, one
// plain line on what each model is for, the size, one tap. Two icons only
// (owner): corner-framed circle = detection, microscope = identification. A name list
// brings its model along when the model is not on the phone yet. Files on
// the phone whose name is in the catalogue show its title and line too.
// Importing a file and downloading from a link stay for the user's own models.
//
// Round 271 (owner): each identification model is listed with its name lists
// under it (IdentificationAssets.listBelongsTo), a model without one is
// flagged (it cannot identify; Identify will not start), and deleting the
// only detection model, or a model's last name list, says what stops working.
//
// Round 275 (owner): every file is listed by its file name, alphabetically,
// with its details in a card behind an ⓘ (the list was cluttered, and a
// catalogue title for some files but not for others was confusing). One
// "Import model files…" and one "Download from a link…" take every kind:
// the app checks what each file is (models/model_import.dart) and asks
// before replacing a file already on the phone. A file kept with the wrong
// kind (imported before this round) is flagged.
//
// Round 276 (owner): the card shows the licence and source of every model in
// the app's list (assets/model_downloads.json, format 3), also of files that
// are not offered, found by the first part of the file name (the naming rule,
// tool/model_downloads/README.md); "not known" otherwise.
//
// Round 277 (owner): a short credits note at the top says who made the models,
// that FaunaPulse only adapted them for phones, that each keeps its creators'
// licence, and asks to cite the original model from its source (a link in the
// card; the list has no citations, which change and which the authors keep).
//
// Round 279 (owner, after deleting every model one by one): "Delete all
// detection models…" and "Delete all identification models…" under their
// lists, pressing and holding a file selects several to delete at once (as on
// the Sessions screen), and deleting an identification model deletes its
// name lists too (not only a classifier's class list), except a list another
// model on the phone can still use.
//
// Round 288 (owner): Detection models and Identification models each sit in
// a panel of their own colour (ModelKindPanel, as on the "What do you want to
// watch?" pages); the icons of the files to download take that colour.
//
// Round 289 (owner: after importing BioCLIP 2's image model under another file
// name, BioCLIP 2 was still offered, and its name lists read like more
// models): a name list counts any file of its model on the phone (idModelFor),
// and the lists still to download sit under that model ("Name lists to
// download for it"), each with the list icon. The text at the top of the panel
// says what a name list is, and why a short list gives better names.
//
// Round 314 (owner): each label pack to download shows its file name and size
// in its own row, so the ⓘ card of its model no longer repeats the lists (a
// classifier's class list, downloaded with it in one row, stays in the card).
// A line at the top says the files come from the FaunaPulse collection on
// Hugging Face, where they can also be downloaded on a computer.
//
// Round 317 (owner, chose the options shown as sketches): each kind is ONE
// list by file name, files on the phone and files to download together, each
// file with a green "On this phone" tick or a Download button (the ⓘ and
// delete buttons alone did not say clearly that a model is ready, and the two
// lists had two orders). An identification model with name lists has its own
// Download button and two numbered steps (the model once, then the lists for
// the user's region and animals); a list's Download still brings the model
// along when it is missing. Name lists on the phone whose model is offered sit
// under that model, so it can be downloaded (before, such a model was never
// offered). The note at the top no longer says who made the models (true today,
// not once own models come) and the Hugging Face link moved next to Import:
// at the top it invited users to download there, past the buttons below.
//
// Round 322 (owner): a name list no longer offered (a replaced version, the
// 32-family demo) keeps its catalogue details and shows its note under the
// file (grey, or amber for a warning). The ⓘ card of a name list links its
// model card on Hugging Face, which says how the list was made and lists newer
// versions (owner: the name rules in full were too much for the card).
// Round 324 (owner): the same link on the cards of detection and
// identification models, on the phone or to download, as their last row; it
// and the link to all models show a name, not the address.

import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePickerStatus;
import 'package:flutter/material.dart';

import '../identification/identification_assets.dart';
import '../identification/identification_store.dart' show modelIdOf, modelKey, stemOf;
import '../identification/label_pack.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../models/model_catalog.dart';
import '../models/model_downloads.dart';
import '../models/model_file_kind.dart';
import '../models/model_import.dart';
import '../widgets/download_files_dialog.dart';
import '../widgets/download_model_dialog.dart';
import '../widgets/external_link.dart';
import '../widgets/setting_help.dart' show helperTextStyle;
import '../widgets/home_button.dart';
import '../widgets/model_kind_panel.dart';
import '../widgets/selection_app_bar.dart';
import '../widgets/dialog_title.dart';

/// Opens the Download & import models screen; the caller re-reads its own
/// model list after.
Future<void> openModelsScreen(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const ModelsScreen()));

/// The link to this screen placed next to every model list.
Widget manageModelsButton({required VoidCallback? onPressed}) => TextButton.icon(
  onPressed: onPressed,
  icon: const Icon(Icons.download, size: 18),
  label: const Text('Download & import models…'),
);

/// Shown where a model is needed but none is on the phone (round 268): live
/// detection, Find animals in photos / videos, Identify organisms.
class NoModelNotice extends StatelessWidget {
  final bool identification;
  final VoidCallback? onGet;

  const NoModelNotice({super.key, required this.identification, required this.onGet});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          identification
              ? 'No identification model on this phone yet. It names what the detection model found.'
              : 'No detection model on this phone yet. Get one that finds the animals you watch.',
          style: const TextStyle(color: Colors.amber, fontSize: 13),
        ),
        const SizedBox(height: 6),
        FilledButton.tonalIcon(
          onPressed: onGet,
          icon: const Icon(Icons.download, size: 18),
          label: Text(identification ? 'Get an identification model…' : 'Get a detection model…'),
        ),
      ],
    );
  }
}

/// Everything the screen lists, read in one go (injectable for tests).
class ModelsInventory {
  final List<ModelEntry> detectors;
  final List<File> idModels;
  final List<File> nameLists;

  /// Header of each name list by path (missing when unreadable).
  final Map<String, Map<String, dynamic>> headers;

  /// File size by path (imported files only).
  final Map<String, int> sizes;

  /// "Storage free: 12.4 GB", or '' when unknown.
  final String storage;

  /// What can be downloaded.
  final ModelDownloads downloads;

  /// Files kept with one kind whose content is another (round 275), by
  /// path: what they really are.
  final Map<String, ModelFileKind> wrongKind;

  const ModelsInventory({
    this.detectors = const [],
    this.idModels = const [],
    this.nameLists = const [],
    this.headers = const {},
    this.sizes = const {},
    this.storage = '',
    this.downloads = const ModelDownloads(),
    this.wrongKind = const {},
  });

  /// The name lists on the phone made for the identification model [model].
  List<File> listsOf(File model) => [
    for (final l in nameLists)
      if (IdentificationAssets.listBelongsTo(l, headers[l.path], model)) l,
  ];

  /// Name lists whose model is not on the phone.
  List<File> get orphanLists => [
    for (final l in nameLists)
      if (!idModels.any((m) => IdentificationAssets.listBelongsTo(l, headers[l.path], m))) l,
  ];

  /// The identification model on the phone that the name lists of [d] work
  /// with: its own file or, for BioCLIP (label packs), any file of the same
  /// model, such as one imported under another name. Null when none is on
  /// the phone.
  File? idModelFor(ModelDownload d) {
    final own = idModels.where((f) => f.path.split('/').last == d.file?.name).firstOrNull;
    if (own != null || d.nameLists.any((l) => l.classList)) return own;
    return idModels.where((f) => modelKey(modelIdOf(f.path)) == modelKey(d.id)).firstOrNull;
  }

  /// File names on the phone (a catalogue file counts as present by name).
  Set<String> get onPhone => {
    for (final m in detectors) m.name,
    for (final f in [...idModels, ...nameLists]) f.path.split('/').last,
  };

  static Future<ModelsInventory> scan() async {
    final detectors = await ModelCatalog.build();
    final idModels = await IdentificationAssets.listModels();
    final nameLists = await IdentificationAssets.listPacks();
    final headers = <String, Map<String, dynamic>>{};
    for (final f in nameLists) {
      try {
        headers[f.path] = await LabelPack.readHeader(f);
      } catch (e) {
        logSwallowed('models_pack_header', e);
      }
    }
    final sizes = <String, int>{};
    for (final f in [
      for (final m in detectors)
        if (m.source == ModelSource.imported) File(m.id),
      ...idModels,
      ...nameLists,
    ]) {
      try {
        sizes[f.path] = await f.length();
      } catch (e) {
        logSwallowed('models_size', e);
      }
    }
    final wrongKind = <String, ModelFileKind>{};
    Future<void> check(String path, ModelFileKind listedAs) async {
      try {
        final kind = await modelFileKind(File(path), path.split('/').last);
        if (kind != listedAs) wrongKind[path] = kind;
      } catch (e) {
        logSwallowed('models_kind_check', e);
      }
    }

    for (final m in detectors) {
      if (m.source == ModelSource.imported) await check(m.id, ModelFileKind.detection);
    }
    for (final f in idModels) {
      await check(f.path, ModelFileKind.identification);
    }
    return ModelsInventory(
      detectors: detectors,
      idModels: idModels,
      nameLists: nameLists,
      headers: headers,
      sizes: sizes,
      storage: (await DeviceStorage.read()).label,
      downloads: await ModelDownloads.load(),
      wrongKind: wrongKind,
    );
  }
}

/// Picks files and imports them (injectable for tests).
typedef ModelFilesImporter =
    Future<ModelImportReport> Function({
      required ReplaceQuestion replace,
      void Function(FilePickerStatus)? onFileLoading,
      void Function(ModelImportProgress)? onProgress,
    });

/// Deletes model files by path and returns the names it removed (any kind:
/// they are plain files in the app's folders).
Future<List<String>> deleteModelFiles(List<String> paths) =>
    IdentificationAssets.deleteFiles([for (final p in paths) File(p)]);

class ModelsScreen extends StatefulWidget {
  final Future<ModelsInventory> Function() scan;
  final CatalogueFileDownloader download;
  final ModelFilesImporter importFiles;
  final LinkDownloader linkDownload;
  final Future<List<ModelFileKind>> Function(String name) onPhoneAs;
  final Future<List<String>> Function(List<String> paths) deleteFiles;

  const ModelsScreen({
    super.key,
    this.scan = ModelsInventory.scan,
    this.download = downloadCatalogueFileForReal,
    this.importFiles = ModelImport.pickAndImport,
    this.linkDownload = ModelImport.download,
    this.onPhoneAs = ModelImport.onPhoneAs,
    this.deleteFiles = deleteModelFiles,
  });

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  static const _intro =
      'Two kinds of models run on this phone, without internet. A detection model finds animals '
      'and draws a box around each one: live in a session, or afterwards with "Find animals in '
      'photos" or "Find animals in videos". An identification model then names what is inside each '
      'box ("Identify organisms"). You choose which one to use on the screen that runs it.';

  static const _about =
      'The models are adapted (converted to smaller files) to run on a phone. Each model keeps the '
      'licence given by the people who made it: tap ⓘ next to a model to see its licence and source '
      '(the source says how to cite the model if you publish results). The files are kept on Hugging '
      'Face; each Download button below gets its file from there, so you do not need to visit the site.';

  /// Where the files to download are published (round 314).
  static const kModelsCollectionUrl = 'https://huggingface.co/collections/Valen-Peregrine/faunapulse';

  static const _sourceHelp =
      'The files offered above are also on Hugging Face (where name lists are called "label packs"). '
      'On a computer, you can download them there, copy them to the phone and add them with '
      '"Import model files…":';

  static const _namesHelp =
      'An identification model names each animal by choosing from a name list. A classifier such '
      'as insectDCT has one fixed list, which comes with it. BioCLIP can use different lists (on '
      'Hugging Face they are called "label packs"): choose the one for your region and the animals '
      'you watch. BioCLIP only gives names that are on the list, so a list that fits gives better '
      'names: with a list of every animal in the world, it could give a hoverfly in Europe the name '
      'of a wasp from Australia.';

  static const _ownHelp =
      'Model files you already have (for example in Download), or a link to one: detection models, '
      'identification models and name lists. The app checks what each file is and puts it in its '
      'place. How to convert models for the phone: github.com/valentinitnelav/fauna-pulse (docs '
      'folder).';

  static const _selectAllHint =
      'You can choose many files at once: to add every model file of a folder, press and hold one '
      'file in the file chooser, then choose "Select all".';

  ModelsInventory? _inv;

  /// Shown while an import copies files; buttons are disabled meanwhile.
  String? _busy;

  /// How far the file being imported is (null: not known, a moving bar),
  /// and "0.3 GB of 1.2 GB".
  double? _busyFraction;
  String? _busyDetail;

  /// How the last import of one file ended, shown under the button until
  /// the next import (round 319: a snack bar vanished before it was seen).
  String? _importDone;

  /// Paths of the files selected to delete; null when not selecting.
  Set<String>? _selected;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final inv = await widget.scan();
    if (!mounted) return;
    setState(() {
      _inv = inv;
      // Deleted files leave the selection.
      final paths = _deletablePaths(inv).toSet();
      _selected?.removeWhere((p) => !paths.contains(p));
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // The picker reports when it starts copying a picked file into the app's
  // cache (slow for a 1 GB model); our own checked copy follows.
  void _onPicking(FilePickerStatus status) {
    if (!mounted) return;
    setState(() => _busy = 'Copying into the app…');
    _keepStatusInView();
  }

  final _statusKey = GlobalKey();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the line under "Import model files…" fully into view when it appears or says
  /// something new (round 319, part 3), for example when the button was at the bottom edge.
  void _keepStatusInView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _statusKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 200),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  // Our checked copy of each file (round 319: a 1.2 GB model takes about
  // 30 s, and nothing moved on the screen). Redrawn once per percent.
  void _onImportProgress(ModelImportProgress p) {
    if (!mounted) return;
    // Same verb as the picker's step before, which is the same action for the user.
    final busy = p.count > 1
        ? 'Copying ${p.name} into the app (file ${p.index + 1} of ${p.count})…'
        : 'Copying ${p.name} into the app…';
    final fraction = p.totalBytes > 0 ? p.copiedBytes / p.totalBytes : null;
    int? percent(double? f) => f == null ? null : (f * 100).floor();
    if (busy == _busy && fraction != null && percent(fraction) == percent(_busyFraction)) return;
    if (busy != _busy) _keepStatusInView();
    setState(() {
      _busy = busy;
      _busyFraction = fraction;
      // One unit for both numbers, the one of the file size.
      _busyDetail = '${formatBytes(p.copiedBytes, unitOf: p.totalBytes)} of ${formatBytes(p.totalBytes)}';
    });
  }

  /// The answer given "for the other chosen files" during this import.
  bool? _sameAnswer;

  Future<bool> _askReplace(String name, ModelFileKind kind, int filesLeft) async {
    if (_sameAnswer != null) return _sameAnswer!;
    if (!mounted) return false;
    final a = await confirmReplaceModelFile(context, name, kind, offerForAll: filesLeft > 0);
    if (a.forAll) _sameAnswer = a.replace;
    return a.replace;
  }

  /// Where a [kind] shows on this screen.
  static String _listedUnder(ModelFileKind kind) => switch (kind) {
    ModelFileKind.detection => 'listed under Detection models',
    ModelFileKind.identification => 'listed under Identification models',
    ModelFileKind.nameList => 'listed under their identification model',
  };

  /// Round 275: one import for every kind. One file: a message says what it
  /// is and where it is listed (owner). More files, or files kept or not
  /// imported: a dialog groups them by kind (a snack bar would vanish
  /// before it is read).
  Future<void> _import() async {
    _sameAnswer = null;
    setState(() => _importDone = null);
    final r = await widget.importFiles(
      replace: _askReplace,
      onFileLoading: _onPicking,
      onProgress: _onImportProgress,
    );
    if (!mounted) return;
    setState(() {
      _busy = null;
      _busyFraction = null;
      _busyDetail = null;
    });
    if (r.isEmpty) return;
    if (r.imported.length == 1 && r.kept.isEmpty && r.rejected.isEmpty) {
      final (name, kind) = r.imported.single;
      setState(() => _importDone = 'Imported $name: ${kind.withArticle}, ${_listedUnder(kind)}.');
    } else {
      await _showImportReport(r);
    }
    if (!mounted) return;
    // The new files join the list above the button and would push the button and the line under
    // it down, off the screen (round 319): while the end of the list is on the screen, they keep
    // their place instead.
    final position = _scroll.hasClients ? _scroll.position : null;
    final fromEnd = position == null ? null : position.maxScrollExtent - position.pixels;
    final toEnd = fromEnd != null && fromEnd <= position!.viewportDimension ? fromEnd : null;
    await _reload();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (toEnd == null || !_scroll.hasClients) return;
      final p = _scroll.position;
      p.jumpTo((p.maxScrollExtent - toEnd).clamp(p.minScrollExtent, p.maxScrollExtent));
      if (_importDone != null) _keepStatusInView();
    });
  }

  /// Under "Import model files…" (round 319): what the import does now, or
  /// how the last one ended. Before, the line was at the top of the screen,
  /// out of view of the button.
  Widget _importStatus() {
    final busy = _busy;
    if (busy == null) {
      return Padding(
        key: _statusKey,
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.check_circle, size: 16, color: Colors.lightGreen),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(_importDone!, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
    }
    return Padding(
      key: _statusKey,
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(busy, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: _busyFraction),
          if (_busyDetail != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_busyDetail!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Future<void> _showImportReport(ModelImportReport r) {
    Widget group(String heading, List<String> lines) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: const TextStyle(fontWeight: FontWeight.bold)),
          for (final l in lines) Padding(padding: const EdgeInsets.only(top: 2), child: Text(l)),
        ],
      ),
    );
    String plural(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: DialogTitle(
          Text(
            // Round 317: only kept files is not "Imported".
            r.rejected.isEmpty
                ? r.imported.isEmpty
                      ? 'Nothing new imported'
                      : 'Imported'
                : r.imported.isEmpty
                ? 'Not imported'
                : 'Some files were not imported',
          ),
          onClose: () => Navigator.of(ctx).pop(),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final kind in ModelFileKind.values)
                if (r.namesOf(kind).isNotEmpty)
                  group('${plural(r.namesOf(kind).length, kind.label)}, ${_listedUnder(kind)}:', r.namesOf(kind)),
              if (r.kept.isNotEmpty) group('Already on this phone, kept:', r.kept),
              if (r.rejected.isNotEmpty) group('Not imported:', r.rejected),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _downloadLink() async {
    final saved = await showDialog<(String, ModelFileKind)>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DownloadModelDialog(download: widget.linkDownload, onPhoneAs: widget.onPhoneAs),
    );
    if (saved == null || !mounted) return;
    _snack('Downloaded ${saved.$1} (${saved.$2.label}).');
    await _reload();
  }

  /// Downloads [d] (a detection model, or an identification model alone), or
  /// the name list [list] of [d] plus its model when the model is not on the
  /// phone yet.
  Future<void> _get(ModelDownload d, {NameListDownload? list}) async {
    final onPhone = _inv?.onPhone ?? const <String>{};
    final model = d.file!; // only offers have a Download button
    final withModel = d.identification ? _inv?.idModelFor(d) == null : !onPhone.contains(model.name);
    final files = [if (withModel) model, ?list?.file];
    final classList = list?.classList ?? false;
    final what = !d.identification
        ? 'The detection model.'
        : list == null
        ? d.nameLists.any((l) => onPhone.contains(l.file.name))
              ? 'Only the model: its name lists are already on this phone.'
              : 'The model. Then download one or more name lists for it.'
        : classList
        // Round 317: the class list alone when the model is still here.
        ? withModel
              ? 'The model and its class list.'
              : 'Its class list (the model is already on this phone).'
        : withModel
        ? 'The model and the name list "${list.title}".'
        : 'The name list "${list.title}".';
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DownloadFilesDialog(
        title: d.title,
        description: what,
        files: files,
        download: (f, onProgress, isCancelled) =>
            widget.download(f, d.identification, onProgress, isCancelled),
      ),
    );
    if (!mounted) return;
    if (ok != true) {
      // Cancel, Back or a failure: files that arrived before it (the model
      // before its name list) are on the phone, so the list must say so and
      // not still offer "Download" (same as the watch page).
      await _reload();
      return;
    }
    // File names, as the list shows them (round 275).
    _snack('Downloaded ${files.map((f) => f.name).join(' and ')}.');
    await _reload();
  }

  Future<bool> _confirmDelete(String name, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text('Delete ${_breakable(name)}?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: TextStyle(color: Colors.red.shade300)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// The files the user can delete: imported detection models, or
  /// identification models and name lists, or both (null).
  static List<String> _deletablePaths(ModelsInventory inv, {bool? identification}) => [
    if (identification != true)
      for (final m in inv.detectors)
        if (m.source == ModelSource.imported) m.id,
    if (identification != false)
      for (final f in [...inv.idModels, ...inv.nameLists]) f.path,
  ];

  /// What deleting [paths] removes, in list order: each identification model
  /// takes its name lists along (round 279), except a list another model
  /// that stays can still use.
  static List<String> _withLists(Set<String> paths, ModelsInventory inv) {
    final gone = {...paths};
    final staying = [
      for (final m in inv.idModels)
        if (!paths.contains(m.path)) m,
    ];
    for (final m in inv.idModels.where((m) => paths.contains(m.path))) {
      for (final l in inv.listsOf(m)) {
        if (!staying.any((s) => IdentificationAssets.listBelongsTo(l, inv.headers[l.path], s))) gone.add(l.path);
      }
    }
    return [
      for (final p in _deletablePaths(inv))
        if (gone.contains(p)) p,
    ];
  }

  /// Asks, then deletes [paths] with the name lists of the identification
  /// models among them; says what stops working (round 271). True when
  /// deleted.
  Future<bool> _delete(Set<String> paths, {String? title}) async {
    final inv = _inv;
    if (inv == null || paths.isEmpty) return false;
    final all = _withLists(paths, inv);
    final gone = all.toSet();
    final names = [for (final p in all) _nameOfPath(p)];
    final single = paths.length == 1;
    final withModel = [
      for (final p in all)
        if (!paths.contains(p)) _nameOfPath(p),
    ];
    final detectorsGone = inv.detectors.where((m) => gone.contains(m.id)).length;
    // A model left without any name list cannot identify (round 271).
    final orphaned = [
      for (final m in inv.idModels)
        if (!gone.contains(m.path) && inv.listsOf(m).isNotEmpty && inv.listsOf(m).every((l) => gone.contains(l.path)))
          _nameOf(m),
    ];
    String listed(List<String> n) =>
        (n.length <= 8 ? n : [...n.take(7), 'and ${n.length - 7} more']).map((x) => '• $x').join('\n');
    final body = [
      '${names.length == 1 ? 'The file is' : 'These files are'} removed from this phone. Sessions and '
          'identification results already made keep their results.',
      if (!single) listed(names),
      if (withModel.isNotEmpty)
        single
            ? withModel.every((l) => stemOf(l) == stemOf(names.first))
                  ? 'Its class list ${withModel.join(', ')} is deleted with it.'
                  : 'Its name ${withModel.length == 1 ? 'list ${withModel.single} is' : 'lists ${withModel.join(', ')} are'} '
                        'deleted with it: they work only with this model.'
            : 'Name lists are deleted with their model.',
      if (detectorsGone > 0 && detectorsGone == inv.detectors.length)
        '${detectorsGone == 1 ? 'It is the only detection model here.' : 'No detection model is left then.'} '
            'Without one, live detection, "Find animals in photos" and "Find animals in videos" cannot run, '
            'so new photos and videos get no boxes. Sessions that already have boxes can still be identified. '
            'Time-lapse and motion capture still work.',
      if (orphaned.isNotEmpty)
        single
            ? 'It is the only name list of ${orphaned.join(', ')}, which then cannot identify until another one '
                  'is added.'
            : '${orphaned.join(', ')} then ${orphaned.length == 1 ? 'has' : 'have'} no name list and cannot '
                  'identify until another one is added.',
    ].join('\n\n');
    if (!await _confirmDelete(title ?? (single ? names.first : '${names.length} files'), body)) return false;
    final deleted = await widget.deleteFiles(all);
    if (!mounted) return true;
    _snack(deleted.length == 1 ? 'Deleted ${deleted.single}.' : 'Deleted ${deleted.length} files.');
    await _reload();
    return true;
  }

  /// Unticking the last file ends the selection, as in Android's own apps
  /// (round 285).
  void _toggle(String path) => setState(() {
    final sel = _selected ??= {};
    if (!sel.remove(path)) sel.add(path);
    if (sel.isEmpty) _selected = null;
  });

  void _endSelecting() => setState(() => _selected = null);

  Future<void> _deleteSelected() async {
    if (await _delete({...?_selected}) && mounted) _endSelecting();
  }

  static String _nameOfPath(String p) => p.split('/').last;

  static String _nameOf(File f) => f.path.split('/').last;

  /// A file name that may break after each "_" (an invisible space there),
  /// so a long one wraps between its parts in a window's title, not inside
  /// a word ("…tflit" / "e", seen beside the X).
  static String _breakable(String name) => name.replaceAll('_', '_\u200B');

  /// 35260 → "35,260", as in the catalogue's titles.
  static String _count(Object? n) => '${n ?? '?'}'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  static String _finds(List<String> labels) => labels.length <= 12
      ? labels.join(', ')
      : '${labels.take(10).join(', ')}… (${labels.length} classes)';

  static String _onPhone(String path, ModelsInventory inv) {
    final bytes = inv.sizes[path];
    return bytes == null ? 'On this phone' : 'On this phone, ${formatBytes(bytes)}';
  }

  /// Under a file kept with the wrong kind (imported before round 275,
  /// when each kind had its own Import button).
  static String _wrongKindText(ModelFileKind actual, ModelFileKind listedAs) =>
      '⚠ This is ${actual.withArticle}, not ${listedAs.withArticle}. Delete it here and import it again: it then '
      'goes to its place.';

  Widget _section(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(subtitle, style: helperTextStyle),
      ],
    ),
  );

  Widget _subheading(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 2),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
  );

  /// Round 275 (owner): the details of a file or download sit behind an ⓘ,
  /// in a card, so the list shows names only.
  Widget _infoButton(VoidCallback onInfo, {String tooltip = 'About this file'}) => IconButton(
    icon: const Icon(Icons.info_outline, size: 20),
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    onPressed: onInfo,
  );

  /// [modelCard]: the file's model card on Hugging Face, the last row
  /// (round 324, owner: after the card's own details).
  Future<void> _showCard(IconData icon, String title, List<(String, String)> rows, {String? modelCard}) =>
      showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: DialogTitle(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 20)),
            const SizedBox(width: 10),
            Expanded(child: Text(_breakable(title), style: const TextStyle(fontSize: 17))),
          ],
        ),
        onClose: () => Navigator.of(ctx).pop(),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows)
              _cardRow(
                label,
                _isLink(value)
                    ? ExternalLinkText(value, logTag: 'model_card_link')
                    : SelectableText(value, style: const TextStyle(fontSize: 14)),
              ),
            if (modelCard != null)
              _cardRow(_modelCardHeading, ExternalLinkText(modelCard, label: _modelCardLink, logTag: 'model_card_link')),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
    ),
  );

  static Widget _cardRow(String label, Widget value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(label, style: helperTextStyle), value],
    ),
  );

  static bool _isLink(String value) => value.startsWith('https://') && !value.contains(RegExp(r'\s'));

  /// What the app's model list says about a file on the phone (round 276:
  /// every known model, found by the file's first part).
  static List<(String, String)> _catalogueRows(ModelDownload? d) => [
    if (d != null) ...[
      ('Model', d.title),
      ('Use', d.purpose),
      if (d.note != null) ('Note', d.note!),
    ],
  ];

  static const _unknownOrigin = (
    'Licence and source',
    "Not known: this file is not in the app's model list. Ask whoever made it.",
  );

  static List<(String, String)> _originRows(ModelDownload? d) => [
    if (d == null) _unknownOrigin,
    if (d != null && d.licence.isNotEmpty) ('Licence', d.licence),
    if (d != null && d.source.isNotEmpty) ('Source', d.source),
  ];

  /// The model card of a file downloaded from Hugging Face (round 322; on
  /// every card since round 324): its repository page, from the download
  /// link pinned to a commit
  /// (`https://huggingface.co/<owner>/<repo>/resolve/<commit>/<file>`). The
  /// page, not the pinned link, so it shows the card as it is now. Null for
  /// files from elsewhere, or for a model known but not offered (no link):
  /// its Source row is then the only pointer.
  static String? _modelCardUrl(DownloadFile? file) {
    final seg = file?.url.pathSegments ?? const [];
    return file?.url.host == 'huggingface.co' && seg.length > 2 && seg[2] == 'resolve'
        ? 'https://huggingface.co/${seg[0]}/${seg[1]}'
        : null;
  }

  // Round 324 (owner): the original authors first, so the row does not
  // read as if FaunaPulse made the model; the link by its name, not its
  // address.
  static const _modelCardHeading = 'Who made it, how it was adapted for FaunaPulse, newer versions';
  static const _modelCardLink = 'Model card on Hugging Face';

  static String _listKind(Map<String, dynamic>? h) => h == null
      ? 'A name list that could not be read'
      : isClassListHeader(h)
      ? 'Class list of ${h['model_id']}: ${_count(h['rows'])} classes'
      // The pack's rows include its "none of these" entries (flower,
      // leaf, ...); the names are the rest, as in the catalogue titles.
      : 'Name list for ${h['model_id']}: ${_count((h['rows'] as num? ?? 0) - (h['sink_rows'] as num? ?? 0))} names';

  /// How the model stores its numbers, from the file name. Not called
  /// "precision": to ecologists that is an accuracy score (precision and
  /// recall).
  static String _numberFormat(String precision) => switch (precision) {
    'fp16' => 'fp16 (16-bit numbers)',
    'int8' => 'int8 (8-bit whole numbers, the smallest file)',
    'fp32' => 'fp32 (32-bit numbers, the largest file)',
    _ => precision,
  };

  void _detectorCard(ModelEntry m, ModelsInventory inv) {
    final d = inv.downloads.modelFor(m.name);
    _showCard(kDetectionIcon, m.name, [
      ('Kind', 'Detection model: finds animals and draws a box around each one'),
      ..._catalogueRows(d),
      if (m.labels.isNotEmpty) ('Finds', _finds(m.labels)),
      if (m.inputSize != null) ('Input size', '${m.inputSize} px (each picture is resized to this for the model)'),
      if (m.precision != null) ('Number format', _numberFormat(m.precision!)),
      if (isQnnModelPath(m.id)) ('Runs on', 'Snapdragon NPU only'),
      (
        'File',
        switch (m.source) {
          ModelSource.bundled => 'Built into the app',
          ModelSource.official => 'Test model (development builds only)',
          ModelSource.imported => _onPhone(m.id, inv),
        },
      ),
      ..._originRows(d),
    ], modelCard: _modelCardUrl(d?.file));
  }

  void _idModelCard(File f, ModelsInventory inv) {
    final d = inv.downloads.modelFor(_nameOf(f));
    _showCard(kIdentificationIcon, _nameOf(f), [
      ('Kind', 'Identification model: names what is inside each box, choosing from a name list made for it'),
      ..._catalogueRows(d),
      // Its name lists are listed under it on the screen (round 314).
      ('File', _onPhone(f.path, inv)),
      ..._originRows(d),
    ], modelCard: _modelCardUrl(d?.file));
  }

  void _nameListCard(File f, ModelsInventory inv) {
    final offer = inv.downloads.listFor(_nameOf(f));
    final list = offer?.$2;
    final note = list?.warning ?? list?.note;
    _showCard(Icons.list_alt, _nameOf(f), [
      ('Kind', _listKind(inv.headers[f.path])),
      if (offer != null) ('Name list', '${offer.$1.title}: ${offer.$2.title}'),
      if (note != null) ('Note', note),
      ('File', _onPhone(f.path, inv)),
      // The names' own licence and source (round 276), else the model's.
      if (list != null && list.licence.isNotEmpty) ('Licence', list.licence),
      if (list != null && list.source.isNotEmpty) ('Source', list.source),
      if (list == null || list.licence.isEmpty) ..._originRows(offer?.$1),
    ], modelCard: _modelCardUrl(list?.file));
  }

  /// The card of a model to download. Its label packs have rows of their
  /// own on the screen (title, file, size), so only their licence and source
  /// are here, once when they share them.
  void _offerCard(ModelDownload d) {
    final packs = d.nameLists.where((l) => !l.classList);
    _showCard(d.identification ? kIdentificationIcon : kDetectionIcon, d.title, [
      ('Kind', d.identification ? 'Identification model' : 'Detection model'),
      ('Use', d.purpose),
      if (d.note != null) ('Note', d.note!),
      ('File', '${d.file!.name}, ${formatBytes(d.file!.bytes)}'),
      for (final l in d.nameLists)
        if (l.classList) ('Class list', '${l.title}\n${l.file.name}, ${formatBytes(l.file.bytes)}'),
      ..._originRows(d),
      for (final licence in {for (final l in packs) l.licence}..remove(''))
        ('Licence of the name lists', licence),
      for (final source in {for (final l in packs) l.source}..remove('')) ('Source of the name lists', source),
    ], modelCard: _modelCardUrl(d.file));
  }

  /// A file on the phone: its name (round 275, owner: the file name for
  /// every file, no catalogue title), the green tick (round 317), ⓘ and
  /// delete. A file the user can delete ([path]) is selected by pressing and
  /// holding it (round 279); while selecting, a box replaces the icon and the
  /// buttons.
  Widget _tile(IconData icon, String name, VoidCallback onInfo, {String? path, String? warning, String? note}) {
    final sel = _selected;
    final selecting = sel != null && path != null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      selected: selecting && sel.contains(path),
      selectedTileColor: Colors.lightBlueAccent.withValues(alpha: 0.12),
      leading: selecting
          ? Checkbox(value: sel.contains(path), onChanged: (_) => _toggle(path))
          : Icon(icon, color: Colors.white70),
      minLeadingWidth: 24,
      title: Text(name, style: selecting ? const TextStyle(color: Colors.white) : null),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OnThisPhoneLine(),
          if (note != null) Text(note, style: helperTextStyle),
          if (warning != null) Text(warning, style: const TextStyle(color: Colors.amber, fontSize: 12.5)),
        ],
      ),
      onTap: selecting ? () => _toggle(path) : null,
      onLongPress: path == null || _busy != null ? null : () => _toggle(path),
      trailing: sel != null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _infoButton(onInfo),
                if (path != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Delete',
                    visualDensity: VisualDensity.compact,
                    onPressed: _busy == null ? () => _delete({path}) : null,
                  ),
              ],
            ),
    );
  }

  /// "Delete all …" under a list of two files or more, with how to select
  /// some of them.
  List<Widget> _deleteAll(String label, String title, List<String> paths) => [
    if (paths.length >= 2 && _selected == null) ...[
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _busy == null ? () => _delete(paths.toSet(), title: title) : null,
          icon: Icon(Icons.delete_sweep_outlined, size: 18, color: Colors.red.shade300),
          label: Text(label, style: TextStyle(color: Colors.red.shade300)),
        ),
      ),
      const Text('Or press and hold a file to select several.', style: helperTextStyle),
    ],
  ];

  /// A file to download: its name, what it is and its size, the Download
  /// button; its icon in the colour of its kind.
  Widget _offerTile(IconData icon, String name, String details, VoidCallback? onInfo, VoidCallback onGet) => ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    leading: Icon(icon, color: icon == kDetectionIcon ? kDetectionColor : kIdentificationColor),
    minLeadingWidth: 24,
    // The Download button leaves the name little room: let it break after a
    // "_", not inside "tflite" (seen on a phone).
    title: Text(_breakable(name)),
    subtitle: Text(details, style: helperTextStyle),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onInfo != null) _infoButton(onInfo, tooltip: 'About this model'),
        TextButton(onPressed: _busy == null ? onGet : null, child: const Text('Download')),
      ],
    ),
  );

  /// A row under its identification model.
  static Widget _under(Widget child) => Padding(padding: const EdgeInsets.only(left: 32), child: child);

  /// Rows sorted by the file name each one shows (round 317: one order for
  /// the files on the phone and those to download).
  static List<Widget> _byFileName(List<(String, List<Widget>)> rows) => [
    for (final (_, r) in rows..sort((a, b) => fileNameOrder(a.$1, b.$1))) ...r,
  ];

  Widget _detectorTile(ModelEntry m, ModelsInventory inv) {
    final wrong = inv.wrongKind[m.id];
    return _tile(
      kDetectionIcon,
      m.name,
      () => _detectorCard(m, inv),
      path: m.source == ModelSource.imported ? m.id : null,
      warning: wrong == null ? null : _wrongKindText(wrong, ModelFileKind.detection),
    );
  }

  /// Every detection model, on the phone or to download, in one list.
  List<Widget> _detectorRows(ModelsInventory inv) {
    final onPhone = inv.onPhone;
    return _byFileName([
      for (final m in inv.detectors) (m.name, [_detectorTile(m, inv)]),
      for (final d in inv.downloads.detectorOffers)
        if (!onPhone.contains(d.file!.name))
          (
            d.file!.name,
            [
              _offerTile(
                kDetectionIcon,
                d.file!.name,
                '${d.title}, ${formatBytes(d.file!.bytes)}',
                () => _offerCard(d),
                () => _get(d),
              ),
            ],
          ),
    ]);
  }

  /// Every identification model, on the phone or to download, in one list,
  /// each with its name lists under it.
  List<Widget> _identificationRows(ModelsInventory inv) => _byFileName([
    for (final f in inv.idModels) (_nameOf(f), _idModelGroup(f, inv)),
    for (final d in inv.downloads.identificationOffers)
      if (inv.idModelFor(d) == null) (d.file!.name, _idOfferGroup(d, inv)),
  ]);

  /// The line above the name lists of a model on the phone that takes
  /// several (BioCLIP); [_idOfferGroup] numbers it as the second step.
  static const _listsLine = 'Name lists for your region and the animals you watch:';

  /// A model on the phone and its name lists, or a warning that it has none
  /// (round 271), with the lists of the app's list still to download for it
  /// (round 289) among them.
  List<Widget> _idModelGroup(File f, ModelsInventory inv) {
    final lists = inv.listsOf(f);
    final wrong = inv.wrongKind[f.path];
    final offer = inv.downloads.identificationOffers.where((d) => inv.idModelFor(d)?.path == f.path).firstOrNull;
    final onPhone = inv.onPhone;
    final more = [
      if (offer != null && wrong == null)
        for (final l in offer.nameLists)
          if (!onPhone.contains(l.file.name)) l,
    ];
    // A class list has its classifier's file name; anything else is a label
    // pack, chosen by the user.
    final labelPacks =
        lists.any((l) => stemOf(l.path) != stemOf(f.path)) || more.any((l) => !l.classList);
    return [
      _tile(
        kIdentificationIcon,
        _nameOf(f),
        () => _idModelCard(f, inv),
        path: f.path,
        warning: wrong == null ? null : _wrongKindText(wrong, ModelFileKind.identification),
      ),
      if (lists.isEmpty && wrong == null)
        _under(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '⚠ No name list: this model cannot identify. ${more.isEmpty ? 'Download or import one.' : 'Download one below.'}',
              style: const TextStyle(color: Colors.amber, fontSize: 13),
            ),
          ),
        ),
      if (labelPacks) _under(const Text(_listsLine, style: helperTextStyle)),
      ..._byFileName([
        for (final l in lists) (_nameOf(l), [_under(_nameListRow(l, inv))]),
        for (final l in more)
          (
            l.file.name,
            [_under(_offerTile(Icons.list_alt, l.file.name, _listDetails(l), null, () => _get(offer!, list: l)))],
          ),
      ]),
    ];
  }

  /// A model to download (round 317, owner): a classifier and its class list
  /// in one row; a model with name lists (BioCLIP) with its own Download
  /// button and two numbered steps, its lists under it, each on the phone or
  /// to download (a list's Download brings the model along).
  List<Widget> _idOfferGroup(ModelDownload d, ModelsInventory inv) {
    final model = d.file!;
    final classList = d.nameLists.where((l) => l.classList).firstOrNull;
    if (classList != null) {
      return [
        _offerTile(
          kIdentificationIcon,
          model.name,
          '${d.title}, ${formatBytes(model.bytes + classList.file.bytes)} with its class list',
          () => _offerCard(d),
          () => _get(d, list: classList),
        ),
      ];
    }
    final here = {for (final f in inv.nameLists) _nameOf(f): f};
    return [
      _offerTile(
        kIdentificationIcon,
        model.name,
        '1. The model, needed once: ${formatBytes(model.bytes)}',
        () => _offerCard(d),
        () => _get(d),
      ),
      if (d.nameLists.isNotEmpty) _under(const Text('2. Then the name lists for your region and the animals you watch:', style: helperTextStyle)),
      ..._byFileName([
        for (final l in d.nameLists)
          (
            l.file.name,
            [
              _under(
                here[l.file.name] != null
                    ? _nameListRow(here[l.file.name]!, inv)
                    : _offerTile(
                        Icons.list_alt,
                        l.file.name,
                        '${_listDetails(l)}, plus the model (${formatBytes(model.bytes)})',
                        null,
                        () => _get(d, list: l),
                      ),
              ),
            ],
          ),
        // Its lists no longer offered that are on the phone sit here too, so
        // a replaced version is next to its new one (round 322).
        for (final l in d.formerNameLists)
          if (here[l.file.name] case final f?) (l.file.name, [_under(_nameListRow(f, inv))]),
      ]),
    ];
  }

  /// What a name list to download holds, and its size.
  static String _listDetails(NameListDownload l) => '${l.title}\n${formatBytes(l.file.bytes)}';

  Widget _nameListRow(File f, ModelsInventory inv) {
    final list = inv.downloads.listFor(_nameOf(f))?.$2;
    return _tile(
      Icons.list_alt,
      _nameOf(f),
      () => _nameListCard(f, inv),
      path: f.path,
      note: list?.note,
      warning: list?.warning,
    );
  }

  /// Name lists whose model is neither on the phone nor offered (the label
  /// packs of an offered model sit under it; a classifier to download is one
  /// row without its class list, so a class list on the phone stays here).
  static List<File> _listsWithoutModel(ModelsInventory inv) {
    final underOffers = {
      for (final d in inv.downloads.identificationOffers)
        if (inv.idModelFor(d) == null)
          for (final l in [...d.nameLists, ...d.formerNameLists])
            if (!l.classList) l.file.name,
    };
    return [
      for (final f in inv.orphanLists)
        if (!underOffers.contains(_nameOf(f))) f,
    ];
  }

  /// While selecting: how many, Select all, Delete (as on the Sessions
  /// screen).
  PreferredSizeWidget _appBar(ModelsInventory? inv) {
    final sel = _selected;
    if (sel == null || inv == null) {
      return AppBar(title: const FitTitle('Download & import models'), actions: const [HomeButton()]);
    }
    final all = _deletablePaths(inv);
    final allSelected = all.isNotEmpty && all.every(sel.contains);
    return selectionAppBar(
      context,
      count: sel.length,
      onClose: _endSelecting,
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? 'Select none' : 'Select all',
          onPressed: () => setState(() => allSelected ? sel.clear() : sel.addAll(all)),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline, color: sel.isEmpty ? null : Colors.red.shade300),
          tooltip: 'Delete the selected files',
          onPressed: sel.isEmpty || _busy != null ? null : _deleteSelected,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final inv = _inv;
    return PopScope(
      // Back ends the selection first, as in other Android apps.
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endSelecting();
      },
      child: Scaffold(
        appBar: _appBar(inv),
        body: SafeArea(
          child: inv == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    const Text(
                      _intro,
                      style: TextStyle(fontSize: 13.5, color: Colors.white70),
                    ),
                    const SizedBox(height: 10),
                    const _AboutModelsNote(_about),
                    if (inv.storage.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(inv.storage, style: helperTextStyle),
                      ),
                    const SizedBox(height: 20),
                    ModelKindPanel(
                      identification: false,
                      title: 'Detection models',
                      subtitle: 'Find animals and draw a box around each one',
                      children: [
                        if (inv.detectors.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text(
                              'None on this phone yet: live detection, "Find animals in photos" and '
                              '"Find animals in videos" need one.',
                              style: helperTextStyle,
                            ),
                          ),
                        ..._detectorRows(inv),
                        ..._deleteAll(
                          'Delete all detection models…',
                          'all detection models',
                          _deletablePaths(inv, identification: false),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    ModelKindPanel(
                      identification: true,
                      title: 'Identification models',
                      subtitle: 'Name what is inside each box',
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(_namesHelp, style: helperTextStyle),
                        ),
                        if (inv.idModels.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('None on this phone yet: "Identify organisms" needs one.', style: helperTextStyle),
                          ),
                        ..._identificationRows(inv),
                        if (_listsWithoutModel(inv) case final orphans when orphans.isNotEmpty) ...[
                          _subheading('Name lists without their model'),
                          const Text(
                            'Their model is not on this phone, so they cannot be used yet.',
                            style: TextStyle(color: Colors.amber, fontSize: 13),
                          ),
                          for (final f in orphans) _nameListRow(f, inv),
                        ],
                        ..._deleteAll(
                          'Delete all identification models…',
                          'all identification models and name lists',
                          _deletablePaths(inv, identification: true),
                        ),
                      ],
                    ),
                    _section('Your own models', _ownHelp),
                    const SizedBox(height: 8),
                    const Text(_sourceHelp, style: helperTextStyle),
                    const ExternalLinkText(
                      kModelsCollectionUrl,
                      label: 'All models for FaunaPulse on Hugging Face',
                      logTag: 'models_collection_link',
                      fontSize: 13,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: _busy == null ? _import : null,
                      icon: const Icon(Icons.file_upload, size: 18),
                      label: const Text('Import model files…'),
                    ),
                    if (_busy != null || _importDone != null) _importStatus(),
                    const Padding(
                      padding: EdgeInsets.only(top: 4, bottom: 12),
                      child: Text(_selectAllHint, style: helperTextStyle),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _busy == null ? _downloadLink : null,
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('Download from a link…'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The note at the top of the screen (round 277; round 317: what was done
/// to the models, their licences, where the downloads come from).
class _AboutModelsNote extends StatelessWidget {
  final String text;
  const _AboutModelsNote(this.text);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
    decoration: BoxDecoration(
      border: Border.all(color: Colors.white24),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(Icons.handshake_outlined, size: 18, color: Colors.white70),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('About these models', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(text, style: const TextStyle(fontSize: 13, color: Colors.white70)),
            ],
          ),
        ),
      ],
    ),
  );
}
