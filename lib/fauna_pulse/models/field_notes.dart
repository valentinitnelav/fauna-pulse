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
  // Round 302: shown with the site photos on the page; cleared after each Start (FaunaLapse).
  FieldNoteSpec('site_photos_about', 'About the site photos', 'what they show'),
];

/// Longest text (characters) for a one-line field and for the notes.
const kFieldNoteTextMax = 100;
const kFieldNoteNotesMax = 5000;

/// The largest distance or height accepted (m).
const kFieldNoteMaxMeters = 100.0;

/// The GPS goal's range (m): 0 = search the whole time ([kGpsMaxWaitMs]).
const kGpsGoalMaxM = 1000;

/// Round 301: the user's own fields, with FaunaLapse's seven types and their record tags.
enum CustomFieldType {
  text('text', 'Text (up to 100 characters)'),
  notes('notes', 'Notes (several lines, up to 5000 characters)'),
  number('number', 'Number'),
  date('date', 'Date'),
  time('time', 'Time'),
  yesNo('yes_no', 'Yes or no'),
  choice('choice', 'Choice from a list that you write');

  const CustomFieldType(this.tag, this.label);
  final String tag;
  final String label;
}

/// One field of the user's own (FaunaLapse's custom fields): its name, type, value and, for a
/// choice, the choices. The value is kept as text (`yyyy-MM-dd`, `HH:mm`, `yes`/`no`, a number).
class CustomField {
  const CustomField(this.name, this.type, {this.value, this.choices = const []});
  final String name;
  final CustomFieldType type;
  final String? value;
  final List<String> choices;

  CustomField withValue(String? v) => CustomField(name, type, value: v, choices: choices);

  /// The value in the record: a number, true/false, text, or null when empty.
  Object? get recordValue {
    final v = value;
    if (v == null || v.isEmpty) return null;
    return switch (type) {
      CustomFieldType.number => num.tryParse(v),
      CustomFieldType.yesNo => v == 'yes',
      _ => v,
    };
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type.tag,
    'value': value,
    if (type == CustomFieldType.choice) 'choices': choices,
  };

  static CustomField? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    final type = CustomFieldType.values.where((t) => t.tag == j['type']).firstOrNull;
    if (name is! String || type == null) return null;
    return CustomField(
      name,
      type,
      value: j['value'] as String?,
      choices: [for (final c in (j['choices'] as List?) ?? const []) '$c'],
    );
  }
}

/// Longest name of a field of one's own, and the number of choices allowed.
const kCustomFieldNameMax = 40;
const kCustomChoicesMin = 2;
const kCustomChoicesMax = 30;

/// Why [name] cannot name a new field (plain language), or null.
String? customFieldNameProblem(String name, List<CustomField> existing) {
  final n = name.trim();
  if (n.isEmpty) return 'Write a name.';
  if (n.length > kCustomFieldNameMax) return 'At most $kCustomFieldNameMax characters.';
  if (n.toLowerCase() == 'notes') return '"Notes" is the notes field above; choose another name.';
  if (existing.any((f) => f.name.toLowerCase() == n.toLowerCase())) return 'There is already a field with this name.';
  return null;
}

/// The choices written one per line, or a plain-language problem.
(List<String>?, String?) parseCustomChoices(String text) {
  final list = [for (final l in text.split('\n')) if (l.trim().isNotEmpty) l.trim()];
  if (list.length < kCustomChoicesMin) return (null, 'Write at least $kCustomChoicesMin choices, one per line.');
  if (list.length > kCustomChoicesMax) return (null, 'At most $kCustomChoicesMax choices.');
  if (list.any((c) => c.length > kCustomFieldNameMax)) return (null, 'Each choice at most $kCustomFieldNameMax characters.');
  if (list.map((c) => c.toLowerCase()).toSet().length != list.length) return (null, 'A choice is written twice.');
  return (list, null);
}

class FieldNotes {
  const FieldNotes([this.values = const {}, this.custom = const []]);

  /// Filled values by record key: trimmed text, or a number for number fields.
  final Map<String, Object> values;

  /// Round 301: the user's own fields, in the order they were added.
  final List<CustomField> custom;

  FieldNotes withCustom(List<CustomField> c) => FieldNotes(values, List.unmodifiable(c));

  /// Round 302 (FaunaLapse): the GPS search stops at this uncertainty (m); 0 = whole time.
  int get gpsGoalM => (values['gps_goal_m'] as num?)?.toInt() ?? kDefaultGpsGoalM;

  /// A copy with the GPS goal from what the user typed; null when not a whole number in range.
  FieldNotes? withGpsGoal(String text) {
    final t = text.trim();
    final next = Map<String, Object>.of(values);
    if (t.isEmpty) {
      next.remove('gps_goal_m');
      return FieldNotes(next, custom);
    }
    final n = int.tryParse(t);
    if (n == null || n < 0 || n > kGpsGoalMaxM) return null;
    next['gps_goal_m'] = n;
    return FieldNotes(next, custom);
  }

  /// A copy with the value of the own field [name]; null when a number is not a number.
  FieldNotes? withCustomValue(String name, String? value) {
    final v = value?.trim();
    final i = custom.indexWhere((f) => f.name == name);
    if (i < 0) return this;
    final f = custom[i];
    if (f.type == CustomFieldType.number && v != null && v.isNotEmpty && num.tryParse(v.replaceAll(',', '.')) == null) {
      return null;
    }
    final stored = f.type == CustomFieldType.number ? v?.replaceAll(',', '.') : v;
    final max = f.type == CustomFieldType.notes ? kFieldNoteNotesMax : kFieldNoteTextMax;
    final cut = stored != null && stored.length > max ? stored.substring(0, max) : stored;
    return withCustom([...custom]..[i] = f.withValue(cut == null || cut.isEmpty ? null : cut));
  }

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
      return FieldNotes(next, custom);
    }
    if (spec.kind == FieldNoteKind.number) {
      final n = double.tryParse(t.replaceAll(',', '.'));
      if (n == null || n < 0 || n > kFieldNoteMaxMeters) return null;
      next[key] = n;
    } else {
      final max = spec.kind == FieldNoteKind.notes ? kFieldNoteNotesMax : kFieldNoteTextMax;
      next[key] = t.length > max ? t.substring(0, max) : t;
    }
    return FieldNotes(next, custom);
  }

  /// The message for a number field that [withText] refused.
  static String problem(FieldNoteSpec spec) =>
      'Use 0 to ${kFieldNoteMaxMeters.toInt()} m, or leave it empty.';

  /// A short line for summaries: the filled one-line fields, "Label: value".
  String get summary => [
    for (final s in kFieldNoteSpecs)
      if (s.kind != FieldNoteKind.notes && s.key != 'site_photos_about' && values[s.key] != null)
        '${s.label}: ${textOf(s.key)}',
    for (final f in custom)
      if (f.type != CustomFieldType.notes && f.recordValue != null) '${f.name}: ${f.value}',
  ].join(' · ');

  Map<String, dynamic> toJson() => {
    ...values,
    if (custom.isNotEmpty) 'custom_fields': [for (final f in custom) f.toJson()],
  };

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
    if (j['gps_goal_m'] is num) out['gps_goal_m'] = (j['gps_goal_m'] as num).toInt();
    final custom = [
      for (final c in (j['custom_fields'] as List?) ?? const [])
        if (CustomField.fromJson(c) case final CustomField f) f,
    ];
    return FieldNotes(out, custom);
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
  /// no phone ID (null); [sitePhotos] are the names in the session's `site_photos/` (r302). `custom` holds the user's own fields (round
  /// 301), then the notes as "Notes", where a FaunaLapse user would add them as a custom field.
  Map<String, dynamic> recordBlock({
    String? phoneMaker,
    String? phoneModel,
    SessionLocation? location,
    List<String> sitePhotos = const [],
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
      'site_photos_about': values['site_photos_about'],
      'custom': {
        for (final f in custom) f.name: f.recordValue,
        if (values['notes'] != null) 'Notes': values['notes'],
      },
      'location': location == null ? null : locationBlock(location, goalM: gpsGoalM),
      'site_photos': sitePhotos,
    };
  }

  /// A session location in FaunaLapse's `field.location` form.
  static Map<String, dynamic> locationBlock(SessionLocation l, {int goalM = kDefaultGpsGoalM}) => {
    'latitude': double.parse(l.latitude.toStringAsFixed(6)),
    'longitude': double.parse(l.longitude.toStringAsFixed(6)),
    'datum': 'WGS 84',
    // FaunaLapse says "typed" for a position entered by hand.
    'source': l.source == 'manual' ? 'typed' : l.source,
    'coordinate_uncertainty_m': l.accuracyM == null ? null : double.parse(l.accuracyM!.toStringAsFixed(1)),
    'satellites_used': null,
    'uncertainty_goal_m': l.source == 'gps' ? goalM : null,
    'fix_time': l.source == 'manual' || l.fixTimeMs <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(l.fixTimeMs).toIso8601String(),
  };
}
