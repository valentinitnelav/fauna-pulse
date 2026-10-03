// FaunaPulse (round 278, owner): the page behind each answer to the home
// screen's "What do you want to watch?" (pollinators on flowers, insects on a
// flat surface, mammals and birds). It suggests the models for that answer
// (the `uses` of assets/model_downloads.json): one detection model to find
// the animals and, if wanted, one identification model with its name list to
// name them. One button downloads what is not on the phone yet (the same
// download dialog and checks as Download & import models) and makes them the
// choice of the camera, of Find animals and of Identify, so the first session
// starts without a question.
//
// Round 279 (owner, after a test user found the page wordy):
//   • a drawing of the setup on top (assets/images/setup_<icon>.png, the side
//     view and what the phone screen shows, with the yellow square);
//   • the choice is made for the user: "Chosen for you", and one button kept
//     at the bottom edge (visible also after choosing in the fold); the other
//     models in a closed fold "Choose other models" (researchers);
//   • models are shown by their file names (the titles, such as "flat-bug n
//     (small)", confused more than they helped);
//   • no "Use them from now on" tick box: choosing is using.
// Round 280 (owner): "Not now" for naming says what it means (the animals are
// found and followed, not named) and clears Identify's choice.

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

  /// The suggestion chosen for the user is the first of each list.
  int _find = 0;

  /// Index into the use's `name`; -1 = "Not now".
  late int _name = _defaultName;
  bool _busy = false;

  int get _defaultName => widget.use.name.isEmpty ? -1 : 0;
  bool get _isDefault => _find == 0 && _name == _defaultName;

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
        final ok = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => DownloadFilesDialog(
            title: 'the chosen models',
            description:
                '${missing.map((m) => m.$1.name).join(', ')}'
                '${missing.length < _chosenFiles.length ? ' (the other chosen files are on this phone)' : ''}.',
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
      final n = _naming;
      await widget.saveChoice(detector: _detector.file!.name, idModel: n?.$1.file!.name, nameList: n?.$2.file.name);
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

  List<DownloadFile> get _chosenFiles => [
    _detector.file!,
    if (_naming case final n?) ...[n.$1.file!, n.$2.file],
  ];

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
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

  /// The name list's file, unless it is the class list of its model (same
  /// name, nothing to choose).
  static String? _listFile(NamingDownload n) => n.$2.classList ? null : n.$2.file.name;

  /// Under the chosen files: "On this phone", or only what the button does
  /// not say (it shows the size).
  Widget _boxNote(List<DownloadFile> files) {
    final bytes = _bytesOf(files);
    if (bytes == 0) return _sizeLine(files);
    final notes = [
      if (files.any(_has)) 'The rest is on this phone.',
      if (bytes >= _largeBytes) 'A large download: use Wi-Fi.',
    ];
    return notes.isEmpty ? const SizedBox.shrink() : Text(notes.join(' '), style: helperTextStyle);
  }

  /// A label and the file names under it, in the "Chosen for you" box.
  Widget _chosenRow(String label, List<String> files) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: helperTextStyle),
        for (final f in files) Text(f, style: const TextStyle(fontSize: 14)),
      ],
    ),
  );

  Widget _chosenBox() {
    final n = _naming;
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _isDefault ? 'Chosen for you' : 'Your choice',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          _chosenRow('To find the animals', [_detector.file!.name]),
          if (widget.use.name.isNotEmpty)
            n == null
                ? _chosenRow('To name them', const ['None ($kNoNamingNote)'])
                : _chosenRow('To name them', [n.$1.file!.name, if (_listFile(n) case final f?) 'with $f']),
          const SizedBox(height: 10),
          _boxNote(_chosenFiles),
        ],
      ),
    );
  }

  /// Downloads what is missing and saves the choice.
  Widget _button() {
    final missing = _missing;
    final bytes = missing.fold(0, (s, m) => s + m.$1.bytes);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: _busy ? null : _go,
          icon: Icon(missing.isEmpty ? Icons.check : Icons.download),
          label: Text(missing.isEmpty ? 'Use these' : 'Download and use (${formatBytes(bytes)})'),
        ),
      ),
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

  /// Every suggestion of this answer, to choose another one.
  Widget _otherModels() {
    final use = widget.use;
    return Theme(
      // No lines above and below the fold.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        title: const Text('Choose other models'),
        subtitle: const Text('For example a larger, more accurate one', style: helperTextStyle),
        children: [
          _heading('To find the animals'),
          for (final (i, d) in use.find.indexed)
            _choice(
              chosen: i == _find,
              title: d.file!.name,
              lines: [d.purpose],
              size: _sizeLine([d.file!]),
              onTap: () => setState(() => _find = i),
            ),
          if (use.name.isNotEmpty) ...[
            _heading('To name them'),
            for (final (i, n) in use.name.indexed)
              _choice(
                chosen: i == _name,
                title: n.$1.file!.name,
                lines: [
                  if (_listFile(n) case final f?) ...['with $f', n.$2.title] else n.$1.purpose,
                ],
                size: _sizeLine([n.$1.file!, n.$2.file]),
                onTap: () => setState(() => _name = i),
              ),
            _choice(
              chosen: _name < 0,
              title: 'Not now',
              lines: const ['Then $kNoNamingNote.'],
              onTap: () => setState(() => _name = -1),
            ),
          ],
          const SizedBox(height: 4),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final use = widget.use;
    return Scaffold(
      appBar: AppBar(title: Text(use.title)),
      bottomNavigationBar: _onPhone == null ? null : _button(),
      body: SafeArea(
        child: _onPhone == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  SetupPicture(icon: use.icon),
                  const SizedBox(height: 12),
                  Text(use.setup, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 16),
                  _chosenBox(),
                  const SizedBox(height: 8),
                  _otherModels(),
                ],
              ),
      ),
    );
  }
}
