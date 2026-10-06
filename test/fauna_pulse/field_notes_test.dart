// Round 297: field notes and their `field` block (FaunaLapse keys).

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/error_reporter.dart';
import 'package:fauna_pulse/fauna_pulse/models/field_notes.dart';
import 'package:fauna_pulse/fauna_pulse/session/location_fix.dart';
import 'dart:convert';

void main() {
  test('typing sets, trims and clears; numbers take a comma and must be in range', () {
    var n = const FieldNotes();
    n = n.withText('site', '  Meadow 2 ')!;
    expect(n.values['site'], 'Meadow 2');
    n = n.withText('camera_height_m', '0,35')!;
    expect(n.values['camera_height_m'], 0.35);
    expect(n.withText('camera_height_m', 'tall'), isNull);
    expect(n.withText('camera_height_m', '101'), isNull);
    n = n.withText('site', '')!;
    expect(n.values.containsKey('site'), isFalse);
    expect(n.withText('plant', 'x' * 150)!.values['plant'], hasLength(kFieldNoteTextMax));
  });

  test('saved and loaded through JSON; unknown or wrong keys are dropped', () {
    final n = const FieldNotes().withText('plant', 'Knautia arvensis')!.withText('detection_distance_m', '0.2')!;
    final back = FieldNotes.fromJson(jsonDecode(jsonEncode(n.toJson())) as Map<String, dynamic>);
    expect(back.values, n.values);
    expect(FieldNotes.fromJson({'plant': 3, 'camera_height_m': 'x', 'other': 'y'}).isEmpty, isTrue);
    expect(back.textOf('detection_distance_m'), '0.2');
    expect(back.summary, 'Plant: Knautia arvensis · Distance to the flower (m): 0.2');
  });

  test('the record block has every FaunaLapse key, in order, null when empty', () {
    final b = const FieldNotes().recordBlock(phoneMaker: 'Xiaomi', phoneModel: '2107113SG');
    expect(b.keys.toList(), [
      'phone_maker', 'phone_model', 'phone_id', 'setup_by', 'site', 'transect', 'plant', 'habitat',
      'sample_id', 'session_id', 'camera_height_m', 'detection_distance_m', 'detection_distance_source',
      'site_photos_about', 'custom', 'location', 'site_photos',
    ]);
    expect(b['site'], isNull);
    expect(b['custom'], isEmpty);
    expect(b['location'], isNull);
    final filled = const FieldNotes()
        .withText('detection_distance_m', '0.2')!
        .withText('notes', 'Cloudy, light wind')!
        .recordBlock(
          location: const SessionLocation(latitude: 51.1234567, longitude: 12.3, accuracyM: 7.26, fixTimeMs: 1000, source: 'gps'),
        );
    expect(filled['detection_distance_source'], 'typed');
    expect(filled['custom'], {'Notes': 'Cloudy, light wind'});
    final loc = filled['location'] as Map<String, dynamic>;
    expect(loc['latitude'], 51.123457);
    expect(loc['datum'], 'WGS 84');
    expect(loc['coordinate_uncertainty_m'], 7.3);
    expect(loc['uncertainty_goal_m'], kDefaultGpsGoalM);
    final typed = FieldNotes.locationBlock(
      const SessionLocation(latitude: 1, longitude: 2, fixTimeMs: 5, source: 'manual'),
    );
    expect(typed['source'], 'typed');
    expect(typed['fix_time'], isNull);
  });

  test('problem reports also hide the position inside the field block', () {
    final line = jsonEncode({
      'type': 'start_of_session',
      'location': {'lat': 1, 'lon': 2},
      'field': {'site': 'A', 'location': {'latitude': 1, 'longitude': 2}},
    });
    final out = jsonDecode(redactLocation(line)) as Map<String, dynamic>;
    expect(out['location'], '[redacted]');
    expect((out['field'] as Map)['location'], '[redacted]');
    expect((out['field'] as Map)['site'], 'A');
  });

  group('own fields (round 301)', () {
    test('names and choices follow FaunaLapse\'s rules', () {
      const existing = [CustomField('Observer', CustomFieldType.text)];
      expect(customFieldNameProblem('', existing), isNotNull);
      expect(customFieldNameProblem('observer', existing), contains('already'));
      expect(customFieldNameProblem('Notes', existing), contains('Notes'));
      expect(customFieldNameProblem('x' * 41, existing), contains('40'));
      expect(customFieldNameProblem('Weather', existing), isNull);
      expect(parseCustomChoices('only one').$2, isNotNull);
      expect(parseCustomChoices('Sunny\nCloudy\nsunny').$2, contains('twice'));
      expect(parseCustomChoices(' Sunny \n\nCloudy').$1, ['Sunny', 'Cloudy']);
    });

    test('values: numbers checked, yes/no as true/false, saved and in the record', () {
      var n = const FieldNotes().withText('notes', 'Windy')!.withCustom(const [
        CustomField('Count', CustomFieldType.number),
        CustomField('Rain', CustomFieldType.yesNo),
        CustomField('Stage', CustomFieldType.choice, choices: ['Bud', 'Open']),
        CustomField('Day', CustomFieldType.date),
      ]);
      expect(n.withCustomValue('Count', 'many'), isNull);
      n = n.withCustomValue('Count', '2,5')!.withCustomValue('Rain', 'no')!.withCustomValue('Stage', 'Open')!;
      final back = FieldNotes.fromJson(jsonDecode(jsonEncode(n.toJson())) as Map<String, dynamic>);
      expect(back.custom.map((f) => f.name), ['Count', 'Rain', 'Stage', 'Day']);
      expect(back.custom[2].choices, ['Bud', 'Open']);
      final custom = back.recordBlock()['custom'] as Map;
      expect(custom, {'Count': 2.5, 'Rain': false, 'Stage': 'Open', 'Day': null, 'Notes': 'Windy'});
      expect(back.summary, contains('Count: 2.5'));
      expect(back.withText('site', 'A')!.custom, hasLength(4), reason: 'typing keeps the own fields');
    });
  });
}
