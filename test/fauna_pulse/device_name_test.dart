// Rounds 335 and 336: the device's name of a session (deviceNameOf, the device_id of tracks_<pack>.csv).
// The cases are shared with fauna-pulse-export, which writes the same name for
// insect-detect-post: the fixture is a copy of its tests/fixtures/device_name_cases.json.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/field_notes.dart';

void main() {
  final cases = (jsonDecode(File('test/fauna_pulse/fixtures/device_name_cases.json').readAsStringSync())['cases'] as List)
      .cast<Map<String, dynamic>>();

  test('the cases shared with fauna-pulse-export', () {
    expect(cases, hasLength(greaterThan(10)));
    for (final c in cases) {
      final start = (c['start'] as Map).cast<String, dynamic>();
      expect(deviceNameOf(start), c['device_id'], reason: c['why'] as String);
      expect(phoneModelOf(start) ?? '', c['phone_model'], reason: c['why'] as String);
    }
  });

  test('the record of the Field notes page names the device', () {
    final notes = const FieldNotes().withText('device_id', ' cam-03 ')!;
    final start = {
      'device': {'model': '2107113SG'},
      'field': notes.recordBlock(phoneModel: '2107113SG'),
    };
    expect(deviceNameOf(start), 'cam-03');
    // An own field of that name (round 335, and FaunaLapse's help suggests one) still counts; a
    // number field records a number (7, not "7").
    const numbered = FieldNotes({}, [CustomField('device id', CustomFieldType.number, value: '7')]);
    expect(deviceNameOf({'field': numbered.recordBlock()}), '7');
  });
}
