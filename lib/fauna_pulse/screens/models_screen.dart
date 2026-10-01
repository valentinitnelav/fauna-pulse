// FaunaPulse (round 267): the AI models screen, one place for every model
// file (home ⋮ → AI models, and "Manage models…" next to every model list).
//
// Two kinds of model, named for what they do (owner decision, round 267):
//   • Detection models find animals in a picture and draw boxes: live in a
//     session, or afterwards ("Run AI on photos / videos"). ModelCatalog.
//   • Identification models name what is inside a box ("Identify
//     organisms"), choosing from a name list (.fpack): a label pack for
//     BioCLIP, or the class list of a fixed-class classifier such as
//     insectDCT (same file name as its model). IdentificationAssets.
// The user downloads, imports and deletes files here; the screens that run a
// model only choose one.
//
// Round 268: no model ships with the app, so the screen leads with what can
// be downloaded (assets/model_downloads.json, ModelDownloads): an icon for
// what each model is for, one plain line, the size, one tap. A name list
// brings its model along when the model is not on the phone yet. Files on
// the phone whose name is in the catalogue show its title and line too.
// Importing a file and downloading from a link stay for the user's own models.

import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePickerStatus;
import 'package:flutter/material.dart';

import '../identification/identification_assets.dart';
import '../identification/identification_store.dart' show stemOf;
import '../identification/label_pack.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../models/model_catalog.dart';
import '../models/model_downloads.dart';
import '../widgets/download_files_dialog.dart';
import '../widgets/download_model_dialog.dart';
import '../widgets/setting_help.dart' show helperTextStyle;

/// Opens the AI models screen; the caller re-reads its own model list after.
Future<void> openModelsScreen(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const ModelsScreen()));

/// The "Manage models…" link placed next to every model list.
Widget manageModelsButton({required VoidCallback? onPressed}) => TextButton.icon(
  onPressed: onPressed,
  icon: const Icon(Icons.memory, size: 18),
  label: const Text('Manage models…'),
);

/// Shown where a model is needed but none is on the phone (round 268): AI
/// mode, Run AI on photos / videos, Identify organisms.
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
              ? 'No identification model on this phone yet. Download one that names the organisms '
                    'you watch; it then names what the detection model found.'
              : 'No detection model on this phone yet. Download one that finds the animals you '
                    'watch (common animals, insects, insects on flowers).',
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

/// Downloads one catalogue file (injectable for tests).
typedef CatalogueFileDownloader =
    Future<void> Function(
      DownloadFile file,
      bool identification,
      void Function(int receivedBytes, int? totalBytes) onProgress,
      bool Function() isCancelled,
    );

Future<void> _downloadForReal(
  DownloadFile file,
  bool identification,
  void Function(int receivedBytes, int? totalBytes) onProgress,
  bool Function() isCancelled,
) async {
  await downloadCatalogueFile(file, identification: identification, onProgress: onProgress, isCancelled: isCancelled);
}

IconData purposeIcon(ModelPurposeIcon icon) => switch (icon) {
  ModelPurposeIcon.animals => Icons.pets,
  ModelPurposeIcon.insects => Icons.bug_report_outlined,
  ModelPurposeIcon.flowers => Icons.local_florist_outlined,
  ModelPurposeIcon.any => Icons.eco_outlined,
};

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

  const ModelsInventory({
    this.detectors = const [],
    this.idModels = const [],
    this.nameLists = const [],
    this.headers = const {},
    this.sizes = const {},
    this.storage = '',
    this.downloads = const ModelDownloads(),
  });

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
    return ModelsInventory(
      detectors: detectors,
      idModels: idModels,
      nameLists: nameLists,
      headers: headers,
      sizes: sizes,
      storage: (await DeviceStorage.read()).label,
      downloads: await ModelDownloads.load(),
    );
  }
}

class ModelsScreen extends StatefulWidget {
  final Future<ModelsInventory> Function() scan;
  final CatalogueFileDownloader download;

  const ModelsScreen({super.key, this.scan = ModelsInventory.scan, this.download = _downloadForReal});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  static const _intro =
      'FaunaPulse uses two kinds of AI models, both running on this phone without internet. '
      'A detection model finds animals in each picture and draws a box around each one: live '
      'during a session, or afterwards with "Run AI on photos" and "Run AI on videos". An '
      'identification model then names what is inside each box ("Identify organisms"). '
      'Download the ones that fit what you watch; you choose which one to use on the screen '
      'that runs it.';

  static const _namesHelp =
      'An identification model chooses its answer from a name list. A BioCLIP model works with '
      'any label pack made for it (names with their taxonomy). A classifier such as insectDCT '
      'knows a fixed set of classes: its class list has the same file name as the model and is '
      'chosen with it.';

  static const _ownHelp =
      'Import a file already on the phone (for example in Download), or '
      'download a detection model from a link. How to convert models for the phone: '
      'github.com/valentinitnelav/fauna-pulse (docs folder).';

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

  Future<void> _afterImport(List<String> messages) async {
    if (!mounted) return;
    setState(() => _busy = null);
    if (messages.isNotEmpty) _snack(messages.join(' '));
    await _reload();
  }

  Future<void> _importDetectors() async {
    final r = await ModelCatalog.importModels(onFileLoading: _onPicking);
    final n = r.imported;
    await _afterImport([
      if (n > 0) 'Imported $n detection model${n == 1 ? '' : 's'}.',
      if (r.rejected.isNotEmpty) 'Rejected: ${r.rejected.join(' ')}',
    ]);
  }

  Future<void> _importIdentification({required bool packs}) async {
    final o = await IdentificationAssets.importFiles(
      packs: packs,
      onFileLoading: _onPicking,
    );
    await _afterImport([
      if (o.imported.isNotEmpty) 'Imported ${o.imported.join(', ')}.',
      if (o.rejected.isNotEmpty) 'Rejected: ${o.rejected.join(' ')}',
    ]);
  }

  Future<void> _downloadLink() async {
    final path = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const DownloadModelDialog(),
    );
    if (path == null || !mounted) return;
    _snack('Downloaded ${_nameOf(File(path))}.');
    await _reload();
  }

  /// Downloads [d] (a detection model), or the name list [list] of [d] plus
  /// its model when the model is not on the phone yet.
  Future<void> _get(ModelDownload d, {NameListDownload? list}) async {
    final onPhone = _inv?.onPhone ?? const <String>{};
    final withModel = !onPhone.contains(d.file.name);
    final files = [if (withModel) d.file, ?list?.file];
    final classList = list != null && stemOf(list.file.name) == stemOf(d.file.name);
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
    _snack('Downloaded ${d.title}.');
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
    if (!await _confirmDelete(
      m.name,
      'The file is removed from this phone. Sessions that used it keep their results; screens '
      'that had it chosen switch to another model.',
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
    if (!await _confirmDelete(
      _nameOf(f),
      'The file is removed from this phone. Identification results already made keep their '
      'answers.$also',
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

  static String _finds(List<String> labels) => labels.length <= 6
      ? labels.join(', ')
      : '${labels.take(5).join(', ')}… (${labels.length} classes)';

  String _sized(String text, int? bytes) =>
      bytes == null ? text : '$text, ${formatBytes(bytes)}';

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

  Widget _buttons(List<(IconData, String, VoidCallback)> buttons) => Wrap(
    spacing: 8,
    children: [
      for (final (icon, label, action) in buttons)
        TextButton.icon(
          onPressed: _busy == null ? action : null,
          icon: Icon(icon, size: 18),
          label: Text(label),
        ),
    ],
  );

  Widget _tile(IconData icon, String title, String details, VoidCallback? onDelete) => ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    leading: Icon(icon, color: Colors.white70),
    minLeadingWidth: 24,
    title: Text(title),
    subtitle: Text(details, style: helperTextStyle),
    trailing: onDelete == null
        ? null
        : IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _busy == null ? onDelete : null,
          ),
  );

  Widget _offerTile(IconData? icon, String title, String details, VoidCallback onGet) => ListTile(
    contentPadding: EdgeInsets.only(left: icon == null ? 40 : 0),
    dense: true,
    leading: icon == null ? null : Icon(icon, color: Colors.lightBlueAccent),
    minLeadingWidth: 24,
    title: Text(title),
    subtitle: Text(details, style: helperTextStyle),
    trailing: TextButton(
      onPressed: _busy == null ? onGet : null,
      child: const Text('Download'),
    ),
  );

  Widget _detectorTile(ModelEntry m, ModelsInventory inv) {
    final offer = inv.downloads.modelFor(m.name);
    final tags = [
      ?m.precision,
      if (m.inputSize != null) '${m.inputSize} px',
      if (isQnnModelPath(m.id)) 'Snapdragon NPU only',
    ].join(', ');
    final details = [
      ?offer?.purpose,
      if (offer != null) m.name,
      if (tags.isNotEmpty) tags,
      if (m.labels.isNotEmpty) 'Finds: ${_finds(m.labels)}',
      switch (m.source) {
        ModelSource.bundled => 'Built into the app',
        ModelSource.official => 'Test model (development builds only)',
        ModelSource.imported => _sized('On this phone', inv.sizes[m.id]),
      },
    ].join('\n');
    return _tile(
      offer == null ? Icons.center_focus_strong_outlined : purposeIcon(offer.icon),
      offer?.title ?? m.name,
      details,
      m.source == ModelSource.imported ? () => _deleteDetector(m) : null,
    );
  }

  Widget _idModelTile(File f, ModelsInventory inv) {
    final offer = inv.downloads.modelFor(_nameOf(f));
    final lists = IdentificationAssets.classListsOf(f, inv.nameLists);
    final pairing = lists.isEmpty
        ? 'Uses a label pack made for this model'
        : 'With its class list';
    final details = [
      ?offer?.purpose,
      if (offer != null) _nameOf(f),
      _sized(pairing, inv.sizes[f.path]),
    ].join('\n');
    return _tile(
      offer == null ? Icons.biotech_outlined : purposeIcon(offer.icon),
      offer?.title ?? _nameOf(f),
      details,
      () => _deleteIdentification(f, isModel: true),
    );
  }

  Widget _nameListTile(File f, ModelsInventory inv) {
    final h = inv.headers[f.path];
    final offer = inv.downloads.listFor(_nameOf(f));
    final what = h == null
        ? 'Could not be read'
        : h['kind'] == 'classes'
        ? 'Class list of ${h['model_id']}: ${_count(h['rows'])} classes'
        // The pack's rows include its "none of these" entries (flower,
        // leaf, ...); the names are the rest, as in the catalogue titles.
        : 'Label pack for ${h['model_id']}: ${_count((h['rows'] as num? ?? 0) - (h['sink_rows'] as num? ?? 0))} names';
    return _tile(
      Icons.list_alt,
      offer == null ? _nameOf(f) : '${offer.$1.title}: ${offer.$2.title}',
      [if (offer != null) _nameOf(f), _sized(what, inv.sizes[f.path])].join('\n'),
      () => _deleteIdentification(f, isModel: false),
    );
  }

  String _offerDetails(ModelDownload d, {int? bytes}) => [
    d.purpose,
    ?d.note,
    '${formatBytes(bytes ?? d.file.bytes)}${d.licence.isEmpty ? '' : ', licence ${d.licence}'}',
  ].join('\n');

  /// Detection models not on the phone yet.
  List<Widget> _detectorOffers(ModelsInventory inv) {
    final onPhone = inv.onPhone;
    final offers = [for (final d in inv.downloads.detectors) if (!onPhone.contains(d.file.name)) d];
    if (offers.isEmpty) return const [];
    return [
      _subheading('Available to download'),
      for (final d in offers) _offerTile(purposeIcon(d.icon), d.title, _offerDetails(d), () => _get(d)),
    ];
  }

  /// Identification models and name lists not on the phone yet: one row per
  /// missing name list, which brings the model along when it is missing too.
  List<Widget> _identificationOffers(ModelsInventory inv) {
    final onPhone = inv.onPhone;
    final rows = <Widget>[];
    for (final d in inv.downloads.identification) {
      final hasModel = onPhone.contains(d.file.name);
      final missing = [for (final l in d.lists) if (!onPhone.contains(l.file.name)) l];
      if (missing.isEmpty) continue;
      final single = d.lists.length == 1;
      if (single) {
        // A classifier and its class list: one row, one download.
        final l = missing.single;
        rows.add(
          _offerTile(
            purposeIcon(d.icon),
            d.title,
            _offerDetails(d, bytes: (hasModel ? 0 : d.file.bytes) + l.file.bytes),
            () => _get(d, list: l),
          ),
        );
        continue;
      }
      rows.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(purposeIcon(d.icon), color: Colors.lightBlueAccent),
          minLeadingWidth: 24,
          title: Text(d.title),
          subtitle: Text(
            [
              d.purpose,
              ?d.note,
              hasModel
                  ? 'Model on this phone; name lists below'
                  : 'Model ${formatBytes(d.file.bytes)}, downloaded with the first name list'
                        '${d.licence.isEmpty ? '' : ', licence ${d.licence}'}',
            ].join('\n'),
            style: helperTextStyle,
          ),
        ),
      );
      for (final l in missing) {
        rows.add(
          _offerTile(
            null,
            l.title,
            hasModel ? formatBytes(l.file.bytes) : '${formatBytes(l.file.bytes)} plus the model',
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
      appBar: AppBar(title: const Text('AI models')),
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
                      'None yet: the camera\'s AI mode and "Run AI on photos / videos" need one.',
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
                  for (final f in inv.idModels) _idModelTile(f, inv),
                  if (inv.nameLists.isNotEmpty) ...[
                    _subheading('Name lists (.fpack)'),
                    const Text(_namesHelp, style: helperTextStyle),
                    for (final f in inv.nameLists) _nameListTile(f, inv),
                  ],
                  ..._identificationOffers(inv),
                  _section('Your own models', _ownHelp),
                  _buttons([
                    (Icons.file_upload, 'Import detection model…', _importDetectors),
                    (Icons.link, 'Detection model from a link…', _downloadLink),
                    (
                      Icons.file_upload,
                      'Import identification model…',
                      () => _importIdentification(packs: false),
                    ),
                    (
                      Icons.file_upload,
                      'Import name list…',
                      () => _importIdentification(packs: true),
                    ),
                  ]),
                ],
              ),
      ),
    );
  }
}
