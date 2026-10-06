// FaunaPulse (round 297): the Field notes page, opened from the camera screen's pin button.
//
// Idea from the sister app FaunaLapse (card 2, "Field metadata"): the position and a few
// notes about the setup, set once before recording and saved with every session (the
// start record's `field` block, see models/field_notes.dart). Values are saved as they are
// typed and stay until the user changes them.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/field_notes.dart';
import '../session/location_fix.dart';
import '../widgets/home_button.dart';
import '../widgets/setting_help.dart';

class FieldNotesScreen extends StatefulWidget {
  const FieldNotesScreen({
    super.key,
    required this.location,
    required this.searching,
    required this.onChangePosition,
  });

  /// The session position the camera screen holds (GPS, typed or previous).
  final ValueListenable<SessionLocation?> location;
  final ValueListenable<bool> searching;

  /// Opens the position window (search again, type it, use the last one).
  final Future<void> Function() onChangePosition;

  @override
  State<FieldNotesScreen> createState() => _FieldNotesScreenState();
}

class _FieldNotesScreenState extends State<FieldNotesScreen> {
  FieldNotes _notes = const FieldNotes();
  bool _loaded = false;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String?> _errors = {};

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
      });
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
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
                  for (final s in kFieldNoteSpecs) _field(s),
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
}
