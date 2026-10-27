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

/// One field of the page: its record key, its label and hint on screen, and an optional line of
/// help under it.
class FieldNoteSpec {
  final String key;
  final String label;
  final String hint;
  final FieldNoteKind kind;
  final String? help;
  const FieldNoteSpec(this.key, this.label, this.hint, [this.kind = FieldNoteKind.text, this.help]);
}

/// The fields in screen and record order (FaunaLapse keys; `device_id` is new in round 336 and
/// FaunaLapse is to add the same key).
const kFieldNoteSpecs = <FieldNoteSpec>[
  FieldNoteSpec('setup_by', 'Set up by', 'name'),
  FieldNoteSpec('site', 'Site', 'for example Meadow 2'),
  FieldNoteSpec('transect', 'Transect', 'for example 3'),
  FieldNoteSpec('plant', 'Plant', 'common or Latin name'),
  FieldNoteSpec('habitat', 'Habitat', 'for example dry grassland'),
  // Round 336: a field of its own (it was a suggested own field in round 335), read by deviceNameOf.
  FieldNoteSpec(
    'device_id',
    kDeviceIdFieldName,
    'for example cam-03',
    FieldNoteKind.text,
    'When several phones record, give each a short name: it keeps their results apart, in the app '
        'and on the computer. Without it, results show only the phone model, which two phones can share.',
  ),
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

/// The label of the field that names the device (record key `device_id`, round 336), as the
/// Insect Detect camera trap names itself by its hostname. A field of one's own with this name
/// (round 335; FaunaLapse's field help suggests one) names the device too, see [deviceNameOf].
const kDeviceIdFieldName = 'Device ID';

/// The phone model of a session's start record (`device.model`, else the older `device_model`),
/// or null (imported videos have none).
String? phoneModelOf(Map<String, dynamic> start) {
  final d = start['device'];
  return _nameText(d is Map ? d['model'] : null) ?? _nameText(start['device_model']);
}

/// The device's name for a session (round 335), written as `device_id` in
/// `identification/tracks_<pack>.csv`: the Device ID field (`field.device_id`, round 336), else
/// the first filled field of one's own named [kDeviceIdFieldName] (case, spaces, `_` and `-`
/// ignored; FaunaLapse sessions and FaunaPulse round 335), else FaunaLapse's phone ID
/// (`field.phone_id`, 8 characters of Android's ID; always null in FaunaPulse), else the phone
/// model, else '' (imported videos). Characters that file names cannot hold become `-` (and `-`,
/// `.` and spaces at the ends are dropped): insect-detect-post makes a folder
/// `<device_id>_<session_id>_ID<track>` for each track ID.
///
/// Keep in sync with `device_id_of` in fauna-pulse-export (`session_reader.py`), which writes the
/// same name for insect-detect-post; both test it with the same cases
/// (`test/fauna_pulse/fixtures/device_name_cases.json`, a copy of that repository's
/// `tests/fixtures/device_name_cases.json`). Spaces, letter case and number notation are spelled
/// out below instead of using `trim`/`toLowerCase`/`toString`, because Dart and Python treat some
/// characters and numbers differently there.
String deviceNameOf(Map<String, dynamic> start) {
  final field = start['field'];
  final custom = field is Map ? field['custom'] : null;
  final own = custom is Map
      ? custom.entries
            .where((e) => _plainName('${e.key}') == _plainName(kDeviceIdFieldName))
            .map((e) => _safeName(_nameText(e.value)))
            .firstWhere((n) => n.isNotEmpty, orElse: () => '')
      : '';
  for (final name in [
    _safeName(_nameText(field is Map ? field['device_id'] : null)),
    own,
    _safeName(_nameText(field is Map ? field['phone_id'] : null)),
    _safeName(phoneModelOf(start)),
  ]) {
    if (name.isNotEmpty) return name;
  }
  return '';
}

// The spaces trimmed from names and ignored in field names (listed: Dart's trim and Python's
// strip disagree on some Unicode characters, such as the byte order mark).
const _spaces = r' \t\n\r\x0b\x0c ﻿';
final _endSpaces = RegExp('^[$_spaces]+|[$_spaces]+\$');
final _notInFileNames = RegExp(r'[\\/:*?"<>|\x00-\x1f]+');

/// A field name compared without spaces, `_`, `-` and the case of A to Z.
String _plainName(String name) =>
    name.replaceAll(RegExp('[${_spaces}_-]+'), '').replaceAllMapped(RegExp('[A-Z]'), (m) => m[0]!.toLowerCase());

/// [name] with what file names cannot hold as `-`, and `-`, `.` and spaces dropped at the ends.
String _safeName(String? name) => (name ?? '').replaceAll(_notInFileNames, '-').replaceAll(RegExp(r'^[ .-]+|[ .-]+$'), '');

/// Text of a record value that can be a name: a string or a finite number, trimmed; null for
/// anything else or empty text. Numbers are written as Python writes them, so both programs
/// agree: a whole number without decimals (7.0 as 7, as a number field records it, and exact
/// beyond the 64-bit range), and very small numbers as 1e-05.
String? _nameText(Object? v) {
  final text = switch (v) {
    String s => s,
    int i => '$i',
    double d when !d.isFinite => null,
    double d when d == d.truncateToDouble() => BigInt.from(d).toString(),
    double d when d.abs() < 1e-4 =>
      d.toStringAsExponential().replaceFirstMapped(RegExp(r'e([+-])(\d)$'), (m) => 'e${m[1]}0${m[2]}'),
    double d => '$d',
    _ => null,
  };
  final t = text?.replaceAll(_endSpaces, '');
  return t == null || t.isEmpty ? null : t;
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
  // deviceNameOf reads such a field too; a second Device ID would leave the user unsure which counts.
  if (_plainName(n) == _plainName(kDeviceIdFieldName)) return '"$kDeviceIdFieldName" is a field above; use that one.';
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
      for (final k in const ['setup_by', 'site', 'transect', 'plant', 'habitat', 'device_id', 'sample_id', 'session_id'])
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
