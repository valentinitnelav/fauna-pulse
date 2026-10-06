// FaunaPulse (round 297): the Field notes page, opened from the camera screen's pin button.
//
// Idea from the sister app FaunaLapse (card 2, "Field metadata"): the position and a few
// notes about the setup, set once before recording and saved with every session (the
// start record's `field` block, see models/field_notes.dart). Values are saved as they are
// typed and stay until the user changes them.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/field_notes.dart';
import '../session/location_fix.dart';
import '../session/site_photos.dart';
import '../widgets/dialog_title.dart';
import '../widgets/home_button.dart';
import '../widgets/setting_help.dart';

class FieldNotesScreen extends StatefulWidget {
  const FieldNotesScreen({
    super.key,
    required this.location,
    required this.searching,
    required this.onChangePosition,
    this.loadSitePhotos = waitingSitePhotos,
    this.takePhoto = takeSitePhoto,
  });

  /// The session position the camera screen holds (GPS, typed or previous).
  final ValueListenable<SessionLocation?> location;
  final ValueListenable<bool> searching;

  /// Opens the position window (search again, type it, use the last one).
  final Future<void> Function() onChangePosition;

  /// Round 302: the waiting site photos and the camera-app call (replaced in tests).
  final Future<List<File>> Function({Directory? dir}) loadSitePhotos;
  final Future<File?> Function() takePhoto;

  @override
  State<FieldNotesScreen> createState() => _FieldNotesScreenState();
}

class _FieldNotesScreenState extends State<FieldNotesScreen> {
  FieldNotes _notes = const FieldNotes();
  bool _loaded = false;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String?> _errors = {};
  // Round 301: the user's own fields (text, notes and number inputs), by name.
  final Map<String, TextEditingController> _customControllers = {};
  final Map<String, String?> _customErrors = {};
  // Round 302: GPS goal input and the site photos waiting for the next Start.
  late final TextEditingController _goal = TextEditingController();
  String? _goalError;
  List<File> _sitePhotos = const [];

  @override
  void initState() {
    super.initState();
    FieldNotes.load().then((n) {
      if (!mounted) return;
      setState(() {
        _notes = n;
        _loaded = true;
        for (final s in kFieldNoteSpecs) {
          _controllers[s.key] = TextEditingController(text: n.textOf(s.key));
        }
        for (final f in n.custom) {
          _customControllers[f.name] = TextEditingController(text: f.value ?? '');
        }
        _goal.text = '${n.gpsGoalM}';
      });
    });
    _reloadSitePhotos();
  }

  Future<void> _reloadSitePhotos() async {
    List<File> files;
    try {
      files = await widget.loadSitePhotos();
    } catch (_) {
      files = const [];
    }
    if (mounted) setState(() => _sitePhotos = files);
  }

  @override
  void dispose() {
    for (final c in [..._controllers.values, ..._customControllers.values, _goal]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed(FieldNoteSpec spec, String text) {
    final next = _notes.withText(spec.key, text);
    setState(() => _errors[spec.key] = next == null ? FieldNotes.problem(spec) : null);
    if (next == null) return;
    _notes = next;
    unawaited(next.save());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const FitTitle('Field notes'),
        actions: const [HomeButton()],
      ),
      body: SafeArea(
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                children: [
                  const HelpLabel(
                    label: 'Where and how this session is set up',
                    helperText:
                        'Saved with every session you record, until you change it. '
                        'All fields are optional. They use the same names as the '
                        'FaunaLapse app and the Camtrap DP standard for camera-trap '
                        'data, so sessions from both apps can be analysed together.',
                  ),
                  const SizedBox(height: 12),
                  _positionSection(),
                  const Divider(height: 32, color: Colors.white24),
                  for (final s in kFieldNoteSpecs)
                    if (s.key != 'site_photos_about') _field(s),
                  const Divider(height: 32, color: Colors.white24),
                  ..._sitePhotoSection(),
                  const Divider(height: 32, color: Colors.white24),
                  ..._customSection(),
                ],
              ),
      ),
    );
  }

  Widget _positionSection() {
    return ValueListenableBuilder<SessionLocation?>(
      valueListenable: widget.location,
      builder: (context, loc, _) => ValueListenableBuilder<bool>(
        valueListenable: widget.searching,
        builder: (context, searching, _) {
          final String line;
          if (loc != null) {
            final how = switch (loc.source) {
              'gps' => 'from this phone\'s GPS',
              'manual' => 'typed by hand',
              _ => 'from the last session',
            };
            line = '${loc.label} ($how)';
          } else {
            line = searching ? 'Searching for the GPS position…' : 'No position yet.';
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Position', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(line, style: const TextStyle(fontSize: 13, color: Colors.white70)),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.location_on, size: 18),
                  label: const Text('Change position'),
                  onPressed: widget.onChangePosition,
                ),
              ),
              const SizedBox(height: 12),
              _goalField(),
            ],
          );
        },
      ),
    );
  }

  Widget _field(FieldNoteSpec spec) {
    final notes = spec.kind == FieldNoteKind.notes;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _controllers[spec.key],
        maxLines: notes ? 5 : 1,
        minLines: notes ? 3 : 1,
        maxLength: notes ? kFieldNoteNotesMax : kFieldNoteTextMax,
        keyboardType: switch (spec.kind) {
          FieldNoteKind.number => const TextInputType.numberWithOptions(decimal: true),
          FieldNoteKind.notes => TextInputType.multiline,
          FieldNoteKind.text => TextInputType.text,
        },
        textInputAction: notes ? TextInputAction.newline : TextInputAction.next,
        onChanged: (t) => _changed(spec, t),
        decoration: InputDecoration(
          labelText: spec.label,
          hintText: spec.hint,
          errorText: _errors[spec.key],
          // Only the notes show the count; one-line fields stay quiet.
          counterText: notes ? null : '',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  // --- Round 301: the user's own fields (idea and types from FaunaLapse) -----

  void _setCustom(CustomField f, String? value) {
    final next = _notes.withCustomValue(f.name, value);
    setState(() => _customErrors[f.name] = next == null ? 'Write a number, for example 21.5' : null);
    if (next == null) return;
    setState(() => _notes = next);
    unawaited(next.save());
  }

  List<Widget> _customSection() => [
    const HelpLabel(
      label: 'Your own fields',
      labelStyle: TextStyle(fontWeight: FontWeight.bold),
      helperText:
          'Add fields of your own, for example Observer, Weather or Flower stage. Each '
          'has a type: text, notes, a number, a date, a time, yes or no, or a choice '
          'from a list you write. They are saved with every session, as in the '
          'FaunaLapse app.',
    ),
    const SizedBox(height: 8),
    for (final f in _notes.custom) _customField(f),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add a field'),
        onPressed: _addField,
      ),
    ),
  ];

  Widget _customField(CustomField f) {
    final Widget input;
    switch (f.type) {
      case CustomFieldType.text:
      case CustomFieldType.notes:
      case CustomFieldType.number:
        final notes = f.type == CustomFieldType.notes;
        input = TextField(
          controller: _customControllers.putIfAbsent(f.name, () => TextEditingController(text: f.value ?? '')),
          maxLines: notes ? 5 : 1,
          minLines: notes ? 3 : 1,
          maxLength: notes ? kFieldNoteNotesMax : kFieldNoteTextMax,
          keyboardType: f.type == CustomFieldType.number
              ? const TextInputType.numberWithOptions(decimal: true)
              : (notes ? TextInputType.multiline : TextInputType.text),
          onChanged: (t) => _setCustom(f, t),
          decoration: InputDecoration(
            labelText: f.name,
            errorText: _customErrors[f.name],
            counterText: notes ? null : '',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        );
      case CustomFieldType.date:
      case CustomFieldType.time:
        input = InkWell(
          onTap: () => _pickDateOrTime(f),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: f.name,
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: f.value == null
                  ? Icon(f.type == CustomFieldType.date ? Icons.calendar_today : Icons.schedule, size: 18)
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      tooltip: 'Clear',
                      onPressed: () => _setCustom(f, null),
                    ),
            ),
            child: Text(f.value ?? 'Not set', style: TextStyle(color: f.value == null ? Colors.white38 : null)),
          ),
        );
      case CustomFieldType.yesNo:
      case CustomFieldType.choice:
        final options = f.type == CustomFieldType.yesNo ? const ['yes', 'no'] : f.choices;
        input = DropdownButtonFormField<String?>(
          initialValue: options.contains(f.value) ? f.value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: f.name, border: const OutlineInputBorder(), isDense: true),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Not set', style: TextStyle(color: Colors.white38))),
            for (final o in options)
              DropdownMenuItem<String?>(
                value: o,
                child: Text(
                  f.type == CustomFieldType.yesNo ? (o == 'yes' ? 'Yes' : 'No') : o,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => _setCustom(f, v),
        );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: input),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove the field',
            onPressed: () => _removeField(f),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDateOrTime(CustomField f) async {
    String? v;
    if (f.type == CustomFieldType.date) {
      final now = DateTime.now();
      final d = await showDatePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        initialDate: DateTime.tryParse(f.value ?? '') ?? now,
      );
      if (d != null) {
        v = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      }
    } else {
      final parts = (f.value ?? '').split(':');
      final t = await showTimePicker(
        context: context,
        initialTime: parts.length == 2
            ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 12, minute: int.tryParse(parts[1]) ?? 0)
            : TimeOfDay.now(),
        builder: (ctx, child) =>
            MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
      );
      if (t != null) v = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    if (v != null && mounted) _setCustom(f, v);
  }

  Future<void> _removeField(CustomField f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text('Remove the field ${f.name}?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: const Text(
          'Its value goes too. You can add the field again later.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final next = _notes.withCustom([for (final c in _notes.custom) if (c.name != f.name) c]);
    _customControllers.remove(f.name)?.dispose();
    setState(() => _notes = next);
    unawaited(next.save());
  }

  Future<void> _addField() async {
    final f = await showDialog<CustomField>(
      context: context,
      builder: (_) => _AddFieldDialog(existing: _notes.custom),
    );
    if (f == null || !mounted) return;
    final next = _notes.withCustom([..._notes.custom, f]);
    setState(() => _notes = next);
    unawaited(next.save());
  }

  // --- Round 302: GPS goal and site photos (ideas from FaunaLapse's card 2) ---

  Widget _goalField() {
    final goal = int.tryParse(_goal.text.trim());
    final String? note;
    if (goal == 0) {
      note = '0 m: the search always runs the full 3 min and keeps the best position.';
    } else if (goal != null && goal < 5) {
      note = 'Under 5 m is often not reached: the search may then run the full 3 min and keep the best position.';
    } else {
      note = null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _goal,
          keyboardType: TextInputType.number,
          onChanged: (t) {
            final next = _notes.withGpsGoal(t);
            setState(() => _goalError = next == null ? 'Use a whole number from 0 to $kGpsGoalMaxM m.' : null);
            if (next == null) return;
            _notes = next;
            unawaited(next.save());
          },
          decoration: InputDecoration(
            labelText: 'GPS search stops at (m)',
            helperText: 'Default $kDefaultGpsGoalM m. The search for the position stops when its uncertainty '
                'is this small, or after 3 min with the best one found.',
            helperMaxLines: 3,
            errorText: _goalError,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(note, style: const TextStyle(fontSize: 12, color: Colors.amberAccent)),
          ),
      ],
    );
  }

  List<Widget> _sitePhotoSection() {
    final about = kFieldNoteSpecs.firstWhere((s) => s.key == 'site_photos_about');
    return [
      const HelpLabel(
        label: 'Site photos',
        labelStyle: TextStyle(fontWeight: FontWeight.bold),
        helperText:
            'A few photos of the whole setup, taken with the phone\'s camera app: the plant, '
            'the phone on its stand, the surroundings. They help to understand the session '
            'later. They wait here and move into the session folder when you press Start.',
      ),
      const SizedBox(height: 8),
      Text(
        _sitePhotos.isEmpty
            ? 'No site photos yet.'
            : '${_sitePhotos.length} site photo${_sitePhotos.length == 1 ? '' : 's'}: they move into the session folder at Start.',
        style: const TextStyle(fontSize: 13, color: Colors.white70),
      ),
      if (_sitePhotos.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in _sitePhotos)
              InkWell(
                onTap: () => _viewSitePhoto(f),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(f, width: 72, height: 72, fit: BoxFit.cover, cacheWidth: 216),
                ),
              ),
          ],
        ),
      ],
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.photo_camera_outlined, size: 18),
          label: const Text('Take a site photo'),
          onPressed: () async {
            final f = await widget.takePhoto();
            if (f != null) await _reloadSitePhotos();
          },
        ),
      ),
      const SizedBox(height: 12),
      _field(about),
    ];
  }

  Future<void> _viewSitePhoto(File f) async {
    final name = f.uri.pathSegments.last;
    final delete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text('Site photo $name', overflow: TextOverflow.ellipsis), onClose: () => Navigator.of(ctx).pop(false)),
        content: Image.file(f, fit: BoxFit.contain, cacheWidth: 1080),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Close')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (delete != true) return;
    try {
      await f.delete();
    } catch (_) {}
    await _reloadSitePhotos();
  }
}

/// The "Add a field" window: name, type and, for a choice, the choices one per line.
class _AddFieldDialog extends StatefulWidget {
  const _AddFieldDialog({required this.existing});
  final List<CustomField> existing;

  @override
  State<_AddFieldDialog> createState() => _AddFieldDialogState();
}

class _AddFieldDialogState extends State<_AddFieldDialog> {
  final _name = TextEditingController();
  final _choices = TextEditingController();
  CustomFieldType _type = CustomFieldType.text;
  String? _nameError;
  String? _choicesError;

  @override
  void dispose() {
    _name.dispose();
    _choices.dispose();
    super.dispose();
  }

  void _add() {
    final nameError = customFieldNameProblem(_name.text, widget.existing);
    final (choices, choicesError) =
        _type == CustomFieldType.choice ? parseCustomChoices(_choices.text) : (const <String>[], null);
    setState(() {
      _nameError = nameError;
      _choicesError = choicesError;
    });
    if (nameError != null || choicesError != null) return;
    Navigator.of(context).pop(CustomField(_name.text.trim(), _type, choices: choices ?? const []));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      actionsOverflowDirection: VerticalDirection.up,
      title: DialogTitle(const Text('Add a field'), onClose: () => Navigator.of(context).pop()),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              maxLength: kCustomFieldNameMax,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'for example Observer or Weather',
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<CustomFieldType>(
              initialValue: _type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [
                for (final t in CustomFieldType.values)
                  DropdownMenuItem(value: t, child: Text(t.label, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (t) => setState(() => _type = t ?? CustomFieldType.text),
            ),
            if (_type == CustomFieldType.choice) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _choices,
                minLines: 3,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: 'Choices, one per line',
                  helperText: '$kCustomChoicesMin to $kCustomChoicesMax choices',
                  errorText: _choicesError,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: _add, child: const Text('Add', style: TextStyle(fontWeight: FontWeight.bold))),
      ],
    );
  }
}
