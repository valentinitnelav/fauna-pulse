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

import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePickerStatus;
import 'package:flutter/material.dart';

import '../identification/identification_assets.dart';
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

const _detectionIcon = Icons.center_focus_strong_outlined;
const _identificationIcon = Icons.biotech_outlined;

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
    });

class ModelsScreen extends StatefulWidget {
  final Future<ModelsInventory> Function() scan;
  final CatalogueFileDownloader download;
  final ModelFilesImporter importFiles;
  final LinkDownloader linkDownload;
  final Future<List<ModelFileKind>> Function(String name) onPhoneAs;

  const ModelsScreen({
    super.key,
    this.scan = ModelsInventory.scan,
    this.download = downloadCatalogueFileForReal,
    this.importFiles = ModelImport.pickAndImport,
    this.linkDownload = ModelImport.download,
    this.onPhoneAs = ModelImport.onPhoneAs,
  });

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  static const _intro =
      'Two kinds of models run on this phone, without internet. A detection model finds animals '
      'and draws a box around each one: live in a session, or afterwards with "Find animals in '
      'photos / videos". An identification model then names what is inside each box ("Identify '
      'organisms"). You choose which one to use on the screen that runs it.';

  static const _credits =
      'Most of these models were made by other research teams. FaunaPulse tools only adapted them '
      "to run on a phone, and each model keeps its creators' licence. If you publish results, please "
      'cite the original model: tap ⓘ, then its Source, where the authors say how to cite it.';

  static const _namesHelp =
      'Each identification model needs a name list made for it: a label pack for BioCLIP, the '
      'class list of a classifier such as insectDCT. They are shown together below.';

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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final inv = await widget.scan();
    if (mounted) setState(() => _inv = inv);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // The picker reports when it starts copying a picked file into the app's
  // cache (slow for a 1 GB model); our own checked copy follows.
  void _onPicking(FilePickerStatus status) {
    if (mounted) setState(() => _busy = 'Copying into the app…');
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
    final r = await widget.importFiles(replace: _askReplace, onFileLoading: _onPicking);
    if (!mounted) return;
    setState(() => _busy = null);
    if (r.isEmpty) return;
    if (r.imported.length == 1 && r.kept.isEmpty && r.rejected.isEmpty) {
      final (name, kind) = r.imported.single;
      _snack('Imported $name: ${kind.withArticle}, ${_listedUnder(kind)}.');
    } else {
      await _showImportReport(r);
    }
    if (mounted) await _reload();
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
        title: Text(
          r.rejected.isEmpty
              ? 'Imported'
              : r.imported.isEmpty
              ? 'Not imported'
              : 'Some files were not imported',
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
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
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

  /// Downloads [d] (a detection model), or the name list [list] of [d] plus
  /// its model when the model is not on the phone yet.
  Future<void> _get(ModelDownload d, {NameListDownload? list}) async {
    final onPhone = _inv?.onPhone ?? const <String>{};
    final model = d.file!; // only offers have a Download button
    final withModel = !onPhone.contains(model.name);
    final files = [if (withModel) model, ?list?.file];
    final classList = list?.classList ?? false;
    final what = !d.identification
        ? 'The detection model.'
        : classList
        ? 'The model and its class list.'
        : withModel
        ? 'The model and the name list "${list!.title}".'
        : 'The name list "${list!.title}".';
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
    if (ok != true || !mounted) return;
    // File names, as the list shows them (round 275).
    _snack('Downloaded ${files.map((f) => f.name).join(' and ')}.');
    await _reload();
  }

  Future<bool> _confirmDelete(String name, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $name?'),
        content: Text(body),
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

  Future<void> _deleteDetector(ModelEntry m) async {
    final last = (_inv?.detectors.length ?? 0) <= 1;
    if (!await _confirmDelete(
      m.name,
      'The file is removed from this phone. Sessions that used it keep their results.'
      '${last ? '\n\nIt is the only detection model here. Without one, live detection and "Find '
                'animals in photos / videos" cannot run, and identification has no boxes to name. '
                'Time-lapse and motion capture still work.' : ''}',
    )) {
      return;
    }
    await ModelCatalog.deleteImported(m.id);
    if (!mounted) return;
    _snack('Deleted ${m.name}.');
    await _reload();
  }

  Future<void> _deleteIdentification(File f, {required bool isModel}) async {
    final lists = isModel
        ? IdentificationAssets.classListsOf(f, _inv?.nameLists ?? const [])
        : const <File>[];
    final also = lists.isEmpty
        ? ''
        : ' Its class list ${lists.map(_nameOf).join(', ')} is deleted with it.';
    // A model left without any name list cannot identify (round 271).
    final inv = _inv;
    final orphaned = isModel || inv == null
        ? const <File>[]
        : [
            for (final m in inv.idModels)
              if (inv.listsOf(m).length == 1 && inv.listsOf(m).single.path == f.path) m,
          ];
    final warn = orphaned.isEmpty
        ? ''
        : '\n\nIt is the only name list of ${orphaned.map(_nameOf).join(', ')}, which then '
              'cannot identify until another one is added.';
    if (!await _confirmDelete(
      _nameOf(f),
      'The file is removed from this phone. Identification results already made keep their '
      'answers.$also$warn',
    )) {
      return;
    }
    final deleted = await IdentificationAssets.deleteFiles([f, ...lists]);
    if (!mounted) return;
    _snack('Deleted ${deleted.join(', ')}.');
    await _reload();
  }

  static String _nameOf(File f) => f.path.split('/').last;

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

  Future<void> _showCard(IconData icon, String title, List<(String, String)> rows) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 20)),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 17))),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: helperTextStyle),
                    if (_isLink(value))
                      ExternalLinkText(value, logTag: 'model_card_link')
                    else
                      SelectableText(value, style: const TextStyle(fontSize: 14)),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
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

  static String _listKind(Map<String, dynamic>? h) => h == null
      ? 'A name list that could not be read'
      : isClassListHeader(h)
      ? 'Class list of ${h['model_id']}: ${_count(h['rows'])} classes'
      // The pack's rows include its "none of these" entries (flower,
      // leaf, ...); the names are the rest, as in the catalogue titles.
      : 'Label pack for ${h['model_id']}: ${_count((h['rows'] as num? ?? 0) - (h['sink_rows'] as num? ?? 0))} names';

  void _detectorCard(ModelEntry m, ModelsInventory inv) {
    final d = inv.downloads.modelFor(m.name);
    _showCard(_detectionIcon, m.name, [
      ('Kind', 'Detection model: finds animals and draws a box around each one'),
      ..._catalogueRows(d),
      if (m.labels.isNotEmpty) ('Finds', _finds(m.labels)),
      if (m.inputSize != null) ('Input size', '${m.inputSize} px (each picture is resized to this for the model)'),
      if (m.precision != null) ('Precision', m.precision!),
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
    ]);
  }

  void _idModelCard(File f, ModelsInventory inv) {
    final d = inv.downloads.modelFor(_nameOf(f));
    final lists = inv.listsOf(f);
    _showCard(_identificationIcon, _nameOf(f), [
      ('Kind', 'Identification model: names what is inside each box, choosing from a name list made for it'),
      ..._catalogueRows(d),
      ('Name lists', lists.isEmpty ? 'None on this phone: it cannot identify yet' : lists.map(_nameOf).join('\n')),
      ('File', _onPhone(f.path, inv)),
      ..._originRows(d),
    ]);
  }

  void _nameListCard(File f, ModelsInventory inv) {
    final offer = inv.downloads.listFor(_nameOf(f));
    final list = offer?.$2;
    _showCard(Icons.list_alt, _nameOf(f), [
      ('Kind', _listKind(inv.headers[f.path])),
      if (offer != null) ('Name list', '${offer.$1.title}: ${offer.$2.title}'),
      ('File', _onPhone(f.path, inv)),
      // The names' own licence and source (round 276), else the model's.
      if (list != null && list.licence.isNotEmpty) ('Licence', list.licence),
      if (list != null && list.source.isNotEmpty) ('Source', list.source),
      if (list == null || list.licence.isEmpty) ..._originRows(offer?.$1),
    ]);
  }

  void _offerCard(ModelDownload d) => _showCard(d.identification ? _identificationIcon : _detectionIcon, d.title, [
    ('Kind', d.identification ? 'Identification model' : 'Detection model'),
    ('Use', d.purpose),
    if (d.note != null) ('Note', d.note!),
    ('File', '${d.file!.name}, ${formatBytes(d.file!.bytes)}'),
    for (final l in d.nameLists)
      (l.classList ? 'Class list' : 'Label pack', '${l.title}\n${l.file.name}, ${formatBytes(l.file.bytes)}'),
    ..._originRows(d),
  ]);

  /// A file on the phone: its name (round 275, owner: the file name for
  /// every file, no catalogue title), ⓘ and delete.
  Widget _tile(IconData icon, String name, VoidCallback onInfo, VoidCallback? onDelete, {String? warning}) => ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    leading: Icon(icon, color: Colors.white70),
    minLeadingWidth: 24,
    title: Text(name),
    subtitle: warning == null ? null : Text(warning, style: const TextStyle(color: Colors.amber, fontSize: 12.5)),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _infoButton(onInfo),
        if (onDelete != null)
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Delete',
            visualDensity: VisualDensity.compact,
            onPressed: _busy == null ? onDelete : null,
          ),
      ],
    ),
  );

  Widget _offerTile(IconData? icon, String title, String details, VoidCallback? onInfo, VoidCallback onGet) => ListTile(
    contentPadding: EdgeInsets.only(left: icon == null ? 40 : 0),
    dense: true,
    leading: icon == null ? null : Icon(icon, color: Colors.lightBlueAccent),
    minLeadingWidth: 24,
    title: Text(title),
    subtitle: Text(details, style: helperTextStyle),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onInfo != null) _infoButton(onInfo, tooltip: 'About this model'),
        TextButton(onPressed: _busy == null ? onGet : null, child: const Text('Download')),
      ],
    ),
  );

  Widget _detectorTile(ModelEntry m, ModelsInventory inv) {
    final wrong = inv.wrongKind[m.id];
    return _tile(
      _detectionIcon,
      m.name,
      () => _detectorCard(m, inv),
      m.source == ModelSource.imported ? () => _deleteDetector(m) : null,
      warning: wrong == null ? null : _wrongKindText(wrong, ModelFileKind.detection),
    );
  }

  /// A model and its name lists, or a warning that it has none (round 271).
  List<Widget> _idModelGroup(File f, ModelsInventory inv) {
    final lists = inv.listsOf(f);
    final wrong = inv.wrongKind[f.path];
    return [
      _tile(
        _identificationIcon,
        _nameOf(f),
        () => _idModelCard(f, inv),
        () => _deleteIdentification(f, isModel: true),
        warning: wrong == null ? null : _wrongKindText(wrong, ModelFileKind.identification),
      ),
      for (final l in lists) Padding(padding: const EdgeInsets.only(left: 32), child: _nameListRow(l, inv)),
      if (lists.isEmpty && wrong == null)
        const Padding(
          padding: EdgeInsets.only(left: 32, bottom: 8),
          child: Text(
            '⚠ No name list: this model cannot identify. Download or import one.',
            style: TextStyle(color: Colors.amber, fontSize: 13),
          ),
        ),
    ];
  }

  Widget _nameListRow(File f, ModelsInventory inv) =>
      _tile(Icons.list_alt, _nameOf(f), () => _nameListCard(f, inv), () => _deleteIdentification(f, isModel: false));

  static List<ModelDownload> _byTitle(Iterable<ModelDownload> offers) =>
      offers.toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  /// Detection models not on the phone yet.
  List<Widget> _detectorOffers(ModelsInventory inv) {
    final onPhone = inv.onPhone;
    final offers = _byTitle(inv.downloads.detectorOffers.where((d) => !onPhone.contains(d.file!.name)));
    if (offers.isEmpty) return const [];
    return [
      _subheading('Available to download'),
      for (final d in offers)
        _offerTile(_detectionIcon, d.title, formatBytes(d.file!.bytes), () => _offerCard(d), () => _get(d)),
    ];
  }

  /// Identification models and name lists not on the phone yet: one row per
  /// missing name list, which brings the model along when it is missing too.
  List<Widget> _identificationOffers(ModelsInventory inv) {
    final onPhone = inv.onPhone;
    final rows = <Widget>[];
    for (final d in _byTitle(inv.downloads.identificationOffers)) {
      final model = d.file!;
      final hasModel = onPhone.contains(model.name);
      final missing = [for (final l in d.nameLists) if (!onPhone.contains(l.file.name)) l];
      if (missing.isEmpty) continue;
      if (d.nameLists.length == 1) {
        // A classifier and its class list: one row, one download.
        final l = missing.single;
        rows.add(
          _offerTile(
            _identificationIcon,
            d.title,
            formatBytes((hasModel ? 0 : model.bytes) + l.file.bytes),
            () => _offerCard(d),
            () => _get(d, list: l),
          ),
        );
        continue;
      }
      rows.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(_identificationIcon, color: Colors.lightBlueAccent),
          minLeadingWidth: 24,
          title: Text(d.title),
          subtitle: Text(
            hasModel
                ? 'Model on this phone; name lists below'
                : 'Model ${formatBytes(model.bytes)}, downloaded with the first name list',
            style: helperTextStyle,
          ),
          trailing: _infoButton(() => _offerCard(d), tooltip: 'About this model'),
        ),
      );
      for (final l in missing) {
        rows.add(
          _offerTile(
            null,
            l.title,
            hasModel ? formatBytes(l.file.bytes) : '${formatBytes(l.file.bytes)} plus the model',
            null,
            () => _get(d, list: l),
          ),
        );
      }
    }
    return rows.isEmpty ? const [] : [_subheading('Available to download'), ...rows];
  }

  @override
  Widget build(BuildContext context) {
    final inv = _inv;
    return Scaffold(
      appBar: AppBar(title: const Text('Download & import models')),
      body: SafeArea(
        child: inv == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  const Text(
                    _intro,
                    style: TextStyle(fontSize: 13.5, color: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  const _CreditsNote(_credits),
                  if (inv.storage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(inv.storage, style: helperTextStyle),
                    ),
                  if (_busy != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(_busy!)),
                        ],
                      ),
                    ),
                  _section(
                    'Detection models',
                    'Find animals and draw a box around each one',
                  ),
                  _subheading('On this phone'),
                  if (inv.detectors.isEmpty)
                    const Text(
                      'None yet: live detection and "Find animals in photos / videos" need one.',
                      style: helperTextStyle,
                    ),
                  for (final m in inv.detectors) _detectorTile(m, inv),
                  ..._detectorOffers(inv),
                  _section(
                    'Identification models',
                    'Name what is inside each box',
                  ),
                  _subheading('On this phone'),
                  if (inv.idModels.isEmpty)
                    const Text(
                      'None yet: "Identify organisms" needs one.',
                      style: helperTextStyle,
                    ),
                  if (inv.idModels.isNotEmpty) const Text(_namesHelp, style: helperTextStyle),
                  for (final f in inv.idModels) ..._idModelGroup(f, inv),
                  if (inv.orphanLists.isNotEmpty) ...[
                    _subheading('Name lists without their model'),
                    const Text(
                      'Their model is not on this phone, so they cannot be used yet.',
                      style: TextStyle(color: Colors.amber, fontSize: 13),
                    ),
                    for (final f in inv.orphanLists) _nameListRow(f, inv),
                  ],
                  ..._identificationOffers(inv),
                  _section('Your own models', _ownHelp),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _busy == null ? _import : null,
                    icon: const Icon(Icons.file_upload, size: 18),
                    label: const Text('Import model files…'),
                  ),
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
    );
  }
}

/// The credits note at the top of the screen (round 277).
class _CreditsNote extends StatelessWidget {
  final String text;
  const _CreditsNote(this.text);

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
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white70))),
      ],
    ),
  );
}
