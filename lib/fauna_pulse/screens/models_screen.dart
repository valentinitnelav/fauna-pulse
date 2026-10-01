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
// The user imports, downloads (detection models) and deletes files here; the
// screens that run a model only choose one.

import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePickerStatus;
import 'package:flutter/material.dart';

import '../identification/identification_assets.dart';
import '../identification/label_pack.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../models/model_catalog.dart';
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

  const ModelsInventory({
    this.detectors = const [],
    this.idModels = const [],
    this.nameLists = const [],
    this.headers = const {},
    this.sizes = const {},
    this.storage = '',
  });

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
    );
  }
}

class ModelsScreen extends StatefulWidget {
  final Future<ModelsInventory> Function() scan;

  const ModelsScreen({super.key, this.scan = ModelsInventory.scan});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  static const _intro =
      'FaunaPulse uses two kinds of AI models, both running on this phone without internet. '
      'A detection model finds animals in each picture and draws a box around each one: live '
      'during a session, or afterwards with "Run AI on photos" and "Run AI on videos". An '
      'identification model then names what is inside each box ("Identify organisms"). Here you '
      'add and delete model files; you choose which one to use on the screen that runs it. '
      'How to convert your own models: github.com/valentinitnelav/fauna-pulse (docs folder).';

  static const _namesHelp =
      'An identification model chooses its answer from a name list. A BioCLIP model works with '
      'any label pack made for it (names with their taxonomy). A classifier such as insectDCT '
      'knows a fixed set of classes: its class list has the same file name as the model and is '
      'chosen with it.';

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

  Future<void> _download() async {
    final path = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const DownloadModelDialog(),
    );
    if (path == null || !mounted) return;
    _snack('Downloaded ${_nameOf(File(path))}.');
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

  Widget _buttons(List<(IconData, String, VoidCallback)> buttons) => Wrap(
    spacing: 8,
    children: [
      for (final (icon, label, action) in buttons)
        OutlinedButton.icon(
          onPressed: _busy == null ? action : null,
          icon: Icon(icon, size: 18),
          label: Text(label),
        ),
    ],
  );

  Widget _tile(String title, String details, VoidCallback? onDelete) => ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
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

  Widget _detectorTile(ModelEntry m, ModelsInventory inv) {
    final tags = [
      ?m.precision,
      if (m.inputSize != null) '${m.inputSize} px',
      if (isQnnModelPath(m.id)) 'Snapdragon NPU only',
    ].join(', ');
    final details = [
      if (tags.isNotEmpty) tags,
      if (m.labels.isNotEmpty) 'Finds: ${_finds(m.labels)}',
      switch (m.source) {
        ModelSource.bundled => 'Built into the app',
        ModelSource.official => 'Test model (development builds only)',
        ModelSource.imported => _sized('Imported', inv.sizes[m.id]),
      },
    ].join('\n');
    return _tile(
      m.name,
      details,
      m.source == ModelSource.imported ? () => _deleteDetector(m) : null,
    );
  }

  Widget _idModelTile(File f, ModelsInventory inv) {
    final lists = IdentificationAssets.classListsOf(f, inv.nameLists);
    final pairing = lists.isEmpty
        ? 'Uses a label pack made for this model'
        : 'With its class list';
    return _tile(
      _nameOf(f),
      _sized(pairing, inv.sizes[f.path]),
      () => _deleteIdentification(f, isModel: true),
    );
  }

  Widget _nameListTile(File f, ModelsInventory inv) {
    final h = inv.headers[f.path];
    final what = h == null
        ? 'Could not be read'
        : h['kind'] == 'classes'
        ? 'Class list of ${h['model_id']}: ${h['rows']} classes'
        : 'Label pack for ${h['model_id']}: ${h['rows']} names';
    return _tile(
      _nameOf(f),
      _sized(what, inv.sizes[f.path]),
      () => _deleteIdentification(f, isModel: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inv = _inv;
    const none = Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Text('None yet.', style: helperTextStyle),
    );
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
                  _buttons([
                    (Icons.file_upload, 'Import…', _importDetectors),
                    (Icons.cloud_download_outlined, 'Download…', _download),
                  ]),
                  for (final m in inv.detectors) _detectorTile(m, inv),
                  _section(
                    'Identification models',
                    'Name what is inside each box',
                  ),
                  _buttons([
                    (
                      Icons.file_upload,
                      'Import model…',
                      () => _importIdentification(packs: false),
                    ),
                    (
                      Icons.file_upload,
                      'Import name list…',
                      () => _importIdentification(packs: true),
                    ),
                  ]),
                  if (inv.idModels.isEmpty) none,
                  for (final f in inv.idModels) _idModelTile(f, inv),
                  _section('Name lists (.fpack)', _namesHelp),
                  if (inv.nameLists.isEmpty) none,
                  for (final f in inv.nameLists) _nameListTile(f, inv),
                ],
              ),
      ),
    );
  }
}
