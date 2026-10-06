// FaunaPulse (round 297): field notes saved with every session.
//
// Idea and record keys from the sister app FaunaLapse (card 2, "Field metadata"): who set
// the phone up, where, on which plant, and how far the camera is from it. The start record
// gets a `field` block with the SAME keys as FaunaLapse's, every key always present (null
// when empty), so one R or Python script reads sessions from both apps. Words follow the
// Camtrap DP camera-trap data standard where one fits (`setup_by`,
// `coordinate_uncertainty_m`). The notes stay on the phone until the user changes them.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_error_hooks.dart';
import '../session/location_fix.dart';

/// What kind of input a field takes.
enum FieldNoteKind { text, number, notes }

/// One field of the page: its record key, its label and hint on screen.
class FieldNoteSpec {
  final String key;
  final String label;
  final String hint;
  final FieldNoteKind kind;
  const FieldNoteSpec(this.key, this.label, this.hint, [this.kind = FieldNoteKind.text]);
}

/// The fields in screen and record order (FaunaLapse keys).
const kFieldNoteSpecs = <FieldNoteSpec>[
  FieldNoteSpec('setup_by', 'Set up by', 'name'),
  FieldNoteSpec('site', 'Site', 'for example Meadow 2'),
  FieldNoteSpec('transect', 'Transect', 'for example 3'),
  FieldNoteSpec('plant', 'Plant', 'common or Latin name'),
  FieldNoteSpec('habitat', 'Habitat', 'for example dry grassland'),
  FieldNoteSpec('sample_id', 'Sample ID', 'optional'),
  FieldNoteSpec('session_id', 'Session ID', 'optional'),
  FieldNoteSpec('camera_height_m', 'Camera height (m)', 'above the ground', FieldNoteKind.number),
  FieldNoteSpec('detection_distance_m', 'Distance to the flower (m)', 'camera to flower', FieldNoteKind.number),
  FieldNoteSpec('notes', 'Notes', 'anything else worth knowing later', FieldNoteKind.notes),
];

/// Longest text (characters) for a one-line field and for the notes.
const kFieldNoteTextMax = 100;
const kFieldNoteNotesMax = 5000;

/// The largest distance or height accepted (m).
const kFieldNoteMaxMeters = 100.0;

/// FaunaPulse's GPS stops at this uncertainty ([LocationFixTracker]); recorded as the goal.
const kFieldNoteGpsGoalM = 15.0;

class FieldNotes {
  const FieldNotes([this.values = const {}]);

  /// Filled values by record key: trimmed text, or a number for number fields.
  final Map<String, Object> values;

  static const prefsKey = 'field_notes';

  bool get isEmpty => values.isEmpty;

  /// The value for [key] on screen (numbers without a trailing ".0").
  String textOf(String key) {
    final v = values[key];
    if (v == null) return '';
    if (v is double) return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    return v.toString();
  }

  /// A copy with [key] set from what the user typed. Empty text clears it. A
  /// number field takes a decimal point or comma; text that is not a number in
  /// range returns null (the caller shows [problem]).
  FieldNotes? withText(String key, String text) {
    final spec = kFieldNoteSpecs.firstWhere((s) => s.key == key);
    final t = text.trim();
    final next = Map<String, Object>.of(values);
    if (t.isEmpty) {
      next.remove(key);
      return FieldNotes(next);
    }
    if (spec.kind == FieldNoteKind.number) {
      final n = double.tryParse(t.replaceAll(',', '.'));
      if (n == null || n < 0 || n > kFieldNoteMaxMeters) return null;
      next[key] = n;
    } else {
      final max = spec.kind == FieldNoteKind.notes ? kFieldNoteNotesMax : kFieldNoteTextMax;
      next[key] = t.length > max ? t.substring(0, max) : t;
    }
    return FieldNotes(next);
  }

  /// The message for a number field that [withText] refused.
  static String problem(FieldNoteSpec spec) =>
      'Use 0 to ${kFieldNoteMaxMeters.toInt()} m, or leave it empty.';

  /// A short line for summaries: the filled one-line fields, "Label: value".
  String get summary => [
    for (final s in kFieldNoteSpecs)
      if (s.kind != FieldNoteKind.notes && values[s.key] != null) '${s.label}: ${textOf(s.key)}',
  ].join(' · ');

  Map<String, dynamic> toJson() => Map<String, dynamic>.of(values);

  static FieldNotes fromJson(Map<String, dynamic> j) {
    final out = <String, Object>{};
    for (final s in kFieldNoteSpecs) {
      final v = j[s.key];
      if (v == null) continue;
      if (s.kind == FieldNoteKind.number) {
        if (v is num) out[s.key] = v.toDouble();
      } else if (v is String && v.trim().isNotEmpty) {
        out[s.key] = v;
      }
    }
    return FieldNotes(out);
  }

  static Future<FieldNotes> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
      if (raw == null) return const FieldNotes();
      return fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (e) {
      logSwallowed('field_notes_load', e);
      return const FieldNotes();
    }
  }

  Future<void> save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(prefsKey, jsonEncode(toJson()));
    } catch (e) {
      logSwallowed('field_notes_save', e);
    }
  }

  /// The start record's `field` block, with FaunaLapse's keys in its order. FaunaPulse has
  /// no phone ID, site photos or custom fields yet (null or empty); the notes go under
  /// `custom` as "Notes", where a FaunaLapse user would add them as a custom field.
  Map<String, dynamic> recordBlock({
    String? phoneMaker,
    String? phoneModel,
    SessionLocation? location,
  }) {
    final distance = values['detection_distance_m'];
    return {
      'phone_maker': phoneMaker,
      'phone_model': phoneModel,
      'phone_id': null,
      for (final k in const ['setup_by', 'site', 'transect', 'plant', 'habitat', 'sample_id', 'session_id'])
        k: values[k],
      'camera_height_m': values['camera_height_m'],
      'detection_distance_m': distance,
      'detection_distance_source': distance == null ? null : 'typed',
      'site_photos_about': null,
      'custom': {if (values['notes'] != null) 'Notes': values['notes']},
      'location': location == null ? null : locationBlock(location),
      'site_photos': const <String>[],
    };
  }

  /// A session location in FaunaLapse's `field.location` form.
  static Map<String, dynamic> locationBlock(SessionLocation l) => {
    'latitude': double.parse(l.latitude.toStringAsFixed(6)),
    'longitude': double.parse(l.longitude.toStringAsFixed(6)),
    'datum': 'WGS 84',
    // FaunaLapse says "typed" for a position entered by hand.
    'source': l.source == 'manual' ? 'typed' : l.source,
    'coordinate_uncertainty_m': l.accuracyM == null ? null : double.parse(l.accuracyM!.toStringAsFixed(1)),
    'satellites_used': null,
    'uncertainty_goal_m': l.source == 'gps' ? kFieldNoteGpsGoalM : null,
    'fix_time': l.source == 'manual' || l.fixTimeMs <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(l.fixTimeMs).toIso8601String(),
  };
}
