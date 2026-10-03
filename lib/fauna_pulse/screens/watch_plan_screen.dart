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
// Round 281 (owner): the fold also lists the other models already on the
// phone ("Other models on this phone": the user's own, such as a detector
// they trained, and those suggested for other answers), so they can be
// chosen without a download or an entry in the list file.
// Round 284 (owner): the box is "Suggested AI models" ("Chosen for you" read
// as if the choice were made for good). The page of the answer used last
// opens with the models in use now (as home step 1), so pressing the button
// again does not silently replace a model the user chose; a link goes back
// to the suggestions.
// Round 286 (owner): a tap on an answer whose models are on the phone
// switches to it before its page opens (readyChoice; home screen); the button
// returns the choice, which the home screen remembers for that answer.
// Round 287 (owner): in the fold, "To find the animals" and "To name them"
// are two panels, each with its own faint colour and a thick line in that
// colour on top; each radio button sits beside its file name (a ListTile
// put it lower when a row had no details, and in the middle of long ones).
// Round 288 (owner): the panels are ModelKindPanel, shared with Download &
// import models, with the icons of the two kinds of model.

import 'package:flutter/material.dart';

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart' show formatBytes;
import '../models/model_downloads.dart';
import '../models/models_on_phone.dart';
import '../identification/identification_store.dart' show stemOf;
import '../widgets/download_files_dialog.dart';
import '../widgets/setting_help.dart' show helperTextStyle;
import '../widgets/watch_tiles.dart';
import '../widgets/home_button.dart';
import '../widgets/model_kind_panel.dart';
import 'models_screen.dart';

/// What a tap on [use] switches to: the models used last for it ([last]) if
/// their files are still on the phone ([files]); for an answer without them,
/// its first suggested detection model on the phone with its first suggested
/// identification model (and name list) on the phone. Null when something
/// must be downloaded or chosen first (its page offers it).
ModelChoice? readyChoice(WatchUse use, ModelChoice? last, ModelFilesOnPhone files) {
  if (last != null) {
    final detector = last.detector, idModel = last.idModel, list = last.nameList;
    final ready =
        detector != null &&
        files.detectors.contains(detector) &&
        (idModel == null || (list != null && files.idModels.contains(idModel) && files.nameLists.contains(list)));
    return ready ? last : null;
  }
  final detector = use.find.map((d) => d.file!.name).where(files.detectors.contains).firstOrNull;
  final naming = use.name
      .map((n) => (n.$1.file!.name, n.$2.file.name))
      .where((n) => files.idModels.contains(n.$1) && files.nameLists.contains(n.$2))
      .firstOrNull;
  if (detector == null || (use.name.isNotEmpty && naming == null)) return null;
  return (detector: detector, idModel: naming?.$1, nameList: naming?.$2);
}

/// Saves the choice of files (tests give their own).
typedef UseModels = Future<void> Function({String? detector, String? idModel, String? nameList});

class WatchPlanScreen extends StatefulWidget {
  final WatchUse use;

  /// The model files on the phone (tests give their own).
  final Future<ModelFilesOnPhone> Function() onPhone;
  final CatalogueFileDownloader download;
  final UseModels saveChoice;

  /// For the answer used last: reads the models in use now, to open with
  /// them instead of the suggestions (null: open with the suggestions).
  final Future<ModelChoice> Function(Set<String> onPhone)? inUse;

  const WatchPlanScreen({
    super.key,
    required this.use,
    this.onPhone = ModelFilesOnPhone.load,
    this.download = downloadCatalogueFileForReal,
    this.saveChoice = useModels,
    this.inUse,
  });

  @override
  State<WatchPlanScreen> createState() => _WatchPlanScreenState();
}

class _WatchPlanScreenState extends State<WatchPlanScreen> {
  /// Large enough to suggest Wi-Fi (as the download dialog).
  static const _largeBytes = 100 * 1024 * 1024;

  ModelFilesOnPhone? _onPhone;

  /// The chosen detection model file; the first suggestion is chosen for the
  /// user.
  late String _find = _defaultFind;

  /// The chosen identification model and name list (file names); null =
  /// "Not now". The first suggestion is chosen for the user.
  late (String, String)? _name = _defaultName;
  bool _busy = false;

  String get _defaultFind => widget.use.find.first.file!.name;
  (String, String)? get _defaultName => widget.use.name.isEmpty ? null : _names(widget.use.name.first);
  bool get _isDefault => _find == _defaultFind && _name == _defaultName;

  static (String, String) _names(NamingDownload n) => (n.$1.file!.name, n.$2.file.name);

  @override
  void initState() {
    super.initState();
    _reload(first: true);
  }

  Future<void> _reload({bool first = false}) async {
    final names = await widget.onPhone();
    final inUse = first ? await widget.inUse?.call(names.all) : null;
    if (!mounted) return;
    setState(() {
      _onPhone = names;
      if (inUse != null) {
        _find = inUse.detector ?? _find;
        final (idModel: m, nameList: l, detector: _) = inUse;
        _name = m != null && l != null ? (m, l) : null;
      }
    });
  }

  void _backToSuggestions() => setState(() {
    _find = _defaultFind;
    _name = _defaultName;
  });

  bool _has(DownloadFile f) => _onPhone?.has(f.name) ?? false;

  /// The chosen suggestions; null for a file the phone had already.
  ModelDownload? get _findOffer => widget.use.find.where((d) => d.file!.name == _find).firstOrNull;
  NamingDownload? get _nameOffer => widget.use.name.where((n) => _names(n) == _name).firstOrNull;

  /// The other files on the phone, to choose them too.
  List<String> get _otherDetectors => [
    for (final f in _onPhone!.detectors.toList()..sort())
      if (!widget.use.find.any((d) => d.file!.name == f)) f,
  ];
  List<(String, String)> get _otherNamings => [
    for (final p in _onPhone!.namings)
      if (!widget.use.name.any((n) => _names(n) == p)) p,
  ];

  bool get _namingOffered => widget.use.name.isNotEmpty || _otherNamings.isNotEmpty;

  /// The chosen file names.
  List<String> get _chosen => [_find, if (_name case (final m, final l)?) ...[m, l]];

  /// The chosen files not on the phone yet, with whether each is an
  /// identification file.
  List<(DownloadFile, bool)> get _missing => [
    if (_findOffer case final d? when !_has(d.file!)) (d.file!, false),
    if (_nameOffer case final n?) ...[
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
                '${missing.length < _chosen.length ? ' (the other chosen files are on this phone)' : ''}.',
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
      await widget.saveChoice(detector: _find, idModel: _name?.$1, nameList: _name?.$2);
      if (mounted) Navigator.of(context).pop<ModelChoice>((detector: _find, idModel: _name?.$1, nameList: _name?.$2));
    } catch (e) {
      logSwallowed('watch_plan_use', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save the choice.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "On this phone", or what is still to download.
  Widget _sizeLine(List<DownloadFile> files) {
    final bytes = _bytesOf(files);
    if (bytes == 0) return _onPhoneLine;
    final partly = files.any(_has);
    return Text(
      'Download ${formatBytes(bytes)}${partly ? ' (the rest is on this phone)' : ''}'
      '${bytes >= _largeBytes ? ', use Wi-Fi' : ''}',
      style: helperTextStyle,
    );
  }

  static const _onPhoneLine = Row(
    children: [
      Icon(Icons.check_circle, size: 16, color: Colors.lightGreen),
      SizedBox(width: 6),
      Flexible(child: Text('On this phone', style: TextStyle(color: Colors.lightGreen, fontSize: 13))),
    ],
  );

  /// The name list's file, unless it is the class list of its [model] (same
  /// name, nothing to choose).
  static String? _listFile(String model, String list) => stemOf(list) == stemOf(model) ? null : list;

  /// Under the chosen files: "On this phone", or only what the button does
  /// not say (it shows the size).
  Widget _boxNote() {
    final missing = _missing;
    if (missing.isEmpty) return _onPhoneLine;
    final bytes = missing.fold(0, (s, m) => s + m.$1.bytes);
    final notes = [
      if (missing.length < _chosen.length) 'The rest is on this phone.',
      if (bytes >= _largeBytes) 'A large download: use Wi-Fi.',
    ];
    return notes.isEmpty ? const SizedBox.shrink() : Text(notes.join(' '), style: helperTextStyle);
  }

  /// A label and the file names under it, in the "Suggested AI models" box.
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
    final n = _name;
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
            _isDefault ? 'Suggested AI models' : 'Your choice',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          _chosenRow('To find the animals', [_find]),
          if (_namingOffered)
            n == null
                ? _chosenRow('To name them', const ['None ($kNoNamingNote)'])
                : _chosenRow('To name them', [n.$1, if (_listFile(n.$1, n.$2) case final f?) 'with $f']),
          const SizedBox(height: 10),
          _boxNote(),
          if (!_isDefault)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy ? null : _backToSuggestions,
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                child: const Text('Back to the suggested models'),
              ),
            ),
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

  /// One model to choose: the radio button beside the file name (also when
  /// the name takes two lines or the font is large), the details under it.
  Widget _choice({
    required bool chosen,
    required String title,
    required List<String> lines,
    Widget? size,
    required VoidCallback onTap,
  }) => Semantics(
    inMutuallyExclusiveGroup: true,
    checked: chosen,
    child: InkWell(
      onTap: _busy ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: chosen ? Theme.of(context).colorScheme.primary : Colors.white54,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.bodyLarge)),
              ],
            ),
            if (lines.isNotEmpty || size != null)
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final l in lines) Text(l, style: helperTextStyle), ?size],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  /// Above the models of a kind that the phone has besides the suggestions.
  Widget _otherOnPhone() => const Padding(
    padding: EdgeInsets.only(top: 8),
    child: Text('Other models on this phone', style: helperTextStyle),
  );

  /// Every suggestion of this answer and every other model on the phone, to
  /// choose another one.
  Widget _otherModels() {
    final use = widget.use;
    final otherDetectors = _otherDetectors;
    final otherNamings = _otherNamings;
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
          const SizedBox(height: 12),
          ModelKindPanel(identification: false, title: 'To find the animals', children: [
            for (final d in use.find)
              _choice(
                chosen: d.file!.name == _find,
                title: d.file!.name,
                lines: [d.purpose],
                size: _sizeLine([d.file!]),
                onTap: () => setState(() => _find = d.file!.name),
              ),
            if (otherDetectors.isNotEmpty) _otherOnPhone(),
            for (final f in otherDetectors)
              _choice(chosen: f == _find, title: f, lines: const [], onTap: () => setState(() => _find = f)),
          ]),
          if (_namingOffered) ...[
            const SizedBox(height: 12),
            ModelKindPanel(identification: true, title: 'To name them', children: [
              for (final n in use.name)
                _choice(
                  chosen: _names(n) == _name,
                  title: n.$1.file!.name,
                  lines: [
                    if (_listFile(n.$1.file!.name, n.$2.file.name) case final f?)
                      ...['with $f', n.$2.title]
                    else
                      n.$1.purpose,
                  ],
                  size: _sizeLine([n.$1.file!, n.$2.file]),
                  onTap: () => setState(() => _name = _names(n)),
                ),
              _choice(
                chosen: _name == null,
                title: 'Not now',
                lines: const ['Then $kNoNamingNote.'],
                onTap: () => setState(() => _name = null),
              ),
              if (otherNamings.isNotEmpty) _otherOnPhone(),
              for (final (m, l) in otherNamings)
                _choice(
                  chosen: (m, l) == _name,
                  title: m,
                  lines: [if (_listFile(m, l) case final f?) 'with $f'],
                  onTap: () => setState(() => _name = (m, l)),
                ),
            ]),
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
      appBar: AppBar(title: FitTitle(use.title), actions: const [HomeButton()]),
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
