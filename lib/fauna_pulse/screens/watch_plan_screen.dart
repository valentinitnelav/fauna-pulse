// FaunaPulse (round 278, owner): the page behind each answer to the home
// screen's "What do you want to watch?" (pollinators on flowers, insects on a
// flat surface, mammals and birds). It suggests the models for that answer
// (the `uses` of assets/model_downloads.json): one detection model to find
// the animals and, if wanted, one identification model with its name list to
// name them. One button downloads what is not on the phone yet (the same
// download dialog and checks as Download & import models), and "Use them from
// now on" (owner choice, ticked) makes them the choice of the camera, of Find
// animals and of Identify, so the first session starts without a question.

import 'package:flutter/material.dart';

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart' show formatBytes;
import '../models/model_downloads.dart';
import '../models/models_on_phone.dart';
import '../widgets/download_files_dialog.dart';
import '../widgets/setting_help.dart' show helperTextStyle;
import '../widgets/watch_tiles.dart';
import 'models_screen.dart';

/// Saves the choice of files (tests give their own).
typedef UseModels = Future<void> Function({String? detector, String? idModel, String? nameList});

class WatchPlanScreen extends StatefulWidget {
  final WatchUse use;

  /// The model file names on the phone (tests give their own).
  final Future<Set<String>> Function() onPhone;
  final CatalogueFileDownloader download;
  final UseModels saveChoice;

  const WatchPlanScreen({
    super.key,
    required this.use,
    this.onPhone = modelFileNamesOnPhone,
    this.download = downloadCatalogueFileForReal,
    this.saveChoice = useModels,
  });

  @override
  State<WatchPlanScreen> createState() => _WatchPlanScreenState();
}

class _WatchPlanScreenState extends State<WatchPlanScreen> {
  /// Large enough to suggest Wi-Fi (as the download dialog).
  static const _largeBytes = 100 * 1024 * 1024;

  Set<String>? _onPhone;
  int _find = 0;

  /// Index into the use's `name`; -1 = "Not now".
  late int _name = widget.use.name.isEmpty ? -1 : 0;
  bool _useThem = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final names = await widget.onPhone();
    if (mounted) setState(() => _onPhone = names);
  }

  bool _has(DownloadFile f) => _onPhone?.contains(f.name) ?? false;

  ModelDownload get _detector => widget.use.find[_find];
  NamingDownload? get _naming => _name < 0 ? null : widget.use.name[_name];

  /// The chosen files not on the phone yet, with whether each is an
  /// identification file.
  List<(DownloadFile, bool)> get _missing => [
    if (!_has(_detector.file!)) (_detector.file!, false),
    if (_naming case final n?) ...[
      if (!_has(n.$1.file!)) (n.$1.file!, true),
      if (!_has(n.$2.file)) (n.$2.file, true),
    ],
  ];

  /// The size of the files of a choice that are not on the phone.
  int _bytesOf(List<DownloadFile> files) => files.where((f) => !_has(f)).fold(0, (s, f) => s + f.bytes);

  Future<void> _go() async {
    final missing = _missing;
    setState(() => _busy = true);
    try {
      if (missing.isNotEmpty) {
        final n = _naming;
        final what = [
          'The detection model ${_detector.title}',
          if (n != null) 'the identification model ${n.$1.title}${n.$2.classList ? ' with its class list' : ' with the name list "${n.$2.title}"'}',
        ].join(' and ');
        final ok = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => DownloadFilesDialog(
            title: 'the suggested models',
            description: '$what (only the files not on this phone yet).',
            files: [for (final m in missing) m.$1],
            download: (f, onProgress, isCancelled) =>
                widget.download(f, missing.firstWhere((m) => m.$1 == f).$2, onProgress, isCancelled),
          ),
        );
        if (ok != true) {
          // Files that arrived before a failure or Cancel count as present.
          await _reload();
          return;
        }
      }
      if (_useThem) {
        final n = _naming;
        await widget.saveChoice(detector: _detector.file!.name, idModel: n?.$1.file!.name, nameList: n?.$2.file.name);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      logSwallowed('watch_plan_use', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save the choice.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 4),
    child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
  );

  /// "On this phone", or what is still to download.
  Widget _sizeLine(List<DownloadFile> files) {
    final bytes = _bytesOf(files);
    if (bytes == 0) {
      return const Row(
        children: [
          Icon(Icons.check_circle, size: 16, color: Colors.lightGreen),
          SizedBox(width: 6),
          Flexible(child: Text('On this phone', style: TextStyle(color: Colors.lightGreen, fontSize: 13))),
        ],
      );
    }
    final partly = files.any(_has);
    return Text(
      'Download ${formatBytes(bytes)}${partly ? ' (the rest is on this phone)' : ''}'
      '${bytes >= _largeBytes ? ', use Wi-Fi' : ''}',
      style: helperTextStyle,
    );
  }

  Widget _choice({
    required bool chosen,
    required String title,
    required List<String> lines,
    Widget? size,
    required VoidCallback onTap,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      color: chosen ? Theme.of(context).colorScheme.primary : Colors.white54,
    ),
    minLeadingWidth: 24,
    title: Text(title),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final l in lines) Text(l, style: helperTextStyle), ?size],
    ),
    onTap: _busy ? null : onTap,
  );

  @override
  Widget build(BuildContext context) {
    final use = widget.use;
    final missing = _onPhone == null ? const <(DownloadFile, bool)>[] : _missing;
    final bytes = missing.fold(0, (s, m) => s + m.$1.bytes);
    return Scaffold(
      appBar: AppBar(title: Text(use.title)),
      body: SafeArea(
        child: _onPhone == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  Row(
                    children: [
                      WatchIcon(icon: use.icon, size: 56),
                      const SizedBox(width: 14),
                      Expanded(child: Text(use.setup, style: const TextStyle(fontSize: 14))),
                    ],
                  ),
                  _heading('To find the animals'),
                  for (final (i, d) in use.find.indexed)
                    _choice(
                      chosen: i == _find,
                      title: d.title,
                      lines: [d.purpose],
                      size: _sizeLine([d.file!]),
                      onTap: () => setState(() => _find = i),
                    ),
                  if (use.name.isNotEmpty) ...[
                    _heading('To name them'),
                    for (final (i, (d, l)) in use.name.indexed)
                      _choice(
                        chosen: i == _name,
                        title: d.title,
                        lines: [if (!l.classList) 'Name list: ${l.title}', d.purpose],
                        size: _sizeLine([d.file!, l.file]),
                        onTap: () => setState(() => _name = i),
                      ),
                    _choice(
                      chosen: _name < 0,
                      title: 'Not now',
                      lines: const ['You can add one later (Download & import models).'],
                      onTap: () => setState(() => _name = -1),
                    ),
                  ],
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _useThem,
                    onChanged: _busy ? null : (v) => setState(() => _useThem = v ?? true),
                    title: const Text('Use them from now on'),
                    subtitle: const Text('In new sessions, Find animals and Identify.', style: helperTextStyle),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _busy || (missing.isEmpty && !_useThem) ? null : _go,
                    icon: Icon(missing.isEmpty ? Icons.check : Icons.download),
                    label: Text(missing.isEmpty ? 'Use them' : 'Download (${formatBytes(bytes)})'),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () async {
                              await openModelsScreen(context);
                              await _reload();
                            },
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('More models: Download & import models'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
