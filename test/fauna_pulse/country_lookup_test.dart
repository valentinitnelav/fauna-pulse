// Round 374: the country of a position (country_lookup.dart), with the bundled borders
// (assets/country_borders.json) and the shared test points. Both files are written by
// tool/country_borders/make_country_borders.py; the points' answers come from the shapes
// before they were simplified, so this also checks that the simplification changed none.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/country_lookup.dart';
import 'package:fauna_pulse/fauna_pulse/identification/country_names.dart';

void main() {
  final asset = File('assets/country_borders.json');
  final borders = CountryBorders.parse(asset.readAsStringSync());

  test('every shared test point gets its country: inside, the nearest within 25 km, or none', () {
    final cases = (jsonDecode(File('test/fauna_pulse/fixtures/country_point_cases.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
    expect(cases.length, greaterThan(50));
    for (final c in cases) {
      expect(borders.countryAt((c['lat'] as num).toDouble(), (c['lon'] as num).toDouble()), c['code'], reason: '${c['name']}');
    }
    // The kinds of cases the rule has, by name.
    final names = {for (final c in cases) c['name'] as String: c['code']};
    expect(names['Leipzig'], 'DE');
    expect(names['Heligoland'], 'DE', reason: 'a small island');
    expect(names['North Sea off Sylt'], 'DE', reason: 'coastal water');
    expect(names['Mid Atlantic'], isNull);
    expect(names['Lesotho, inside South Africa'], 'LS', reason: 'a country in a hole of another');
    expect(names['Sea west of Taveuni, across 180'], 'FJ', reason: 'the nearest shape lies across the 180 degree meridian');
  });

  test('the distance limit, a longitude given past 180 degrees, and values that are no position', () {
    // The Bay of Biscay, about 163 km off the nearest coast (Spain's): no country within 25 km.
    expect(borders.countryAt(45, -5), isNull);
    expect(borders.countryAt(45, -5, maxKm: 300), 'ES');
    expect(borders.countryAt(51.34, 12.37 + 360), 'DE');
    expect(borders.countryAt(51.34, 12.37 - 360), 'DE');
    expect(borders.countryAt(66.5, 181), 'RU', reason: '181 degrees east is 179 degrees west');
    expect(borders.countryAt(91, 0), isNull);
    expect(borders.countryAt(double.nan, 0), isNull);
    expect(borders.countryAt(0, double.infinity), isNull);
  });

  test('the bundled file: a name for every country, and a size the APK can carry', () {
    final countries = (jsonDecode(asset.readAsStringSync())['countries'] as Map).keys.cast<String>();
    expect(countries.length, greaterThan(240));
    expect([for (final c in countries) if (!kCountryNames.containsKey(c)) c], isEmpty, reason: 'the page shows a code without a name as the code');
    expect(asset.lengthSync(), lessThan(2500000));
  });

  test('a file that is not a borders file is a FormatException', () {
    for (final text in ['[]', '{}', '{"countries": 3}', '{"countries": {"DE": 1}}', '{"countries": {"DE": [[]]}}', '{"countries": {"DE": [[[1, 2, 3, 4]]]}}', '{"countries": {"DE": [[[1, 2, 3, 4, 5, "x"]]]}}', 'not json']) {
      expect(() => CountryBorders.parse(text), throwsFormatException, reason: text);
    }
    final square = CountryBorders.parse('{"countries": {"AA": [[[0, 0, 2, 0, 2, 2, 0, 2], [0.5, 0.5, 1.5, 0.5, 1.5, 1.5, 0.5, 1.5]]], "BB": [[[0.8, 0.8, 1.2, 0.8, 1.2, 1.2, 0.8, 1.2]]]}}');
    expect(square.countryAt(0.25, 0.25), 'AA');
    expect(square.countryAt(1, 1), 'BB', reason: 'inside the hole of AA lies BB');
    expect(square.countryAt(0.6, 0.6), 'AA', reason: 'in the hole but outside BB: AA\'s inner edge (11 km) is nearer than BB (22 km)');
    expect(square.countryAt(1, 2.1), 'AA', reason: 'just outside: the nearest shape');
    expect(square.countryAt(1, 2.5), isNull, reason: '55 km outside');
  });

  testWidgets('the app finds a session\'s country from the bundled borders: Leipzig is in Germany', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('country_bundled');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/session.jsonl').writeAsStringSync('{"type":"start_of_session","time_ms":1,"location":{"lat":51.34,"lon":12.37,"source":"gps"}}\n');
    expect(await tester.runAsync(() => sessionCountryOf(tmp)), 'DE');
    // A session without a position has no country (and the borders are not even read).
    final none = Directory('${tmp.path}/none')..createSync();
    File('${none.path}/session.jsonl').writeAsStringSync('{"type":"start_of_session","time_ms":1}\n');
    expect(await tester.runAsync(() => sessionCountryOf(none)), isNull);
  });

  group('a session\'s position', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('country_lookup'));
    tearDown(() => tmp.deleteSync(recursive: true));
    Directory session(String name, String log) {
      final d = Directory('${tmp.path}/$name')..createSync();
      File('${d.path}/session.jsonl').writeAsStringSync(log);
      return d;
    }

    test('comes from the start record; none without a location, a log or a readable first line', () async {
      final here = session('a', '{"type":"start_of_session","time_ms":1,"location":{"lat":51.34,"lon":12.37,"source":"manual"}}\n{"type":"end_of_session"}\n');
      expect(await sessionPositionOf(here), (51.34, 12.37));
      expect(await sessionPositionOf(session('b', '{"type":"start_of_session","time_ms":1}\n')), isNull);
      expect(await sessionPositionOf(session('c', '{"type":"start_of_session","location":{"lat":"x","lon":12}}\n')), isNull);
      expect(await sessionPositionOf(session('d', 'not json\n')), isNull);
      expect(await sessionPositionOf(Directory('${tmp.path}/missing')), isNull);
    });
  });
}
