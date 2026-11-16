// IdentifyPrefs persistence (round 262: the "Square crops" switch; rounds 373 and 376: the name
// list's country settings).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';

void main() {
  test('square crops default on, survive save and load, and reach the run record', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await IdentifyPrefs.load();
    expect(p.squareCrops, isTrue);
    expect(p.toJson()['square_crops'], isTrue);
    p
      ..squareCrops = false
      ..margin = 0.1;
    await p.save();
    final back = await IdentifyPrefs.load();
    expect(back.squareCrops, isFalse);
    expect(back.margin, closeTo(0.1, 1e-9));
    expect(back.toJson()['square_crops'], isFalse);
  });

  test('round 373: the country settings default to the session\'s country with its neighbours, survive save and load', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await IdentifyPrefs.load();
    expect(p.nameListScope, 'neighbours');
    expect(p.nameListCountry, '', reason: 'empty = the country of the session');
    expect(p.toJson(), containsPair('name_list_scope', 'neighbours'));
    expect(p.toJson(), containsPair('name_list_country', ''));
    expect(p.nameListChosenCountries, isEmpty);
    expect(p.toJson(), containsPair('name_list_chosen_countries', []));
    p
      ..nameListScope = 'country'
      ..nameListCountry = 'MT';
    await p.save();
    final back = await IdentifyPrefs.load();
    expect(back.nameListScope, 'country');
    expect(back.nameListCountry, 'MT');
    expect(back.toJson(), p.toJson());
  });

  test('round 376: the countries chosen by hand survive save and load, next to the single country', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await IdentifyPrefs.load()
      ..nameListScope = 'countries'
      ..nameListCountry = 'MT'
      ..nameListChosenCountries = ['DE', 'FR'];
    await p.save();
    final back = await IdentifyPrefs.load();
    expect(back.nameListScope, 'countries');
    expect(back.nameListChosenCountries, ['DE', 'FR']);
    expect(back.nameListCountry, 'MT', reason: 'kept for when "Names from" changes back');
    expect(back.toJson(), p.toJson());
    // Saved values that are not country codes are left out; a value of another kind gives none.
    SharedPreferences.setMockInitialValues({'identify_name_list_chosen_countries': <String>['FR', 'de', 'Germany', 'DE', 'FR']});
    expect((await IdentifyPrefs.load()).nameListChosenCountries, ['DE', 'FR']);
    SharedPreferences.setMockInitialValues({'identify_name_list_chosen_countries': 'DE'});
    expect((await IdentifyPrefs.load()).nameListChosenCountries, isEmpty);
  });

  test('round 373: a saved value this version does not know, or of another type, gives the default', () async {
    for (final saved in <Map<String, Object>>[
      {'identify_name_list_scope': 'continent', 'identify_name_list_country': 'Germany'},
      {'identify_name_list_scope': 3, 'identify_name_list_country': true},
      {'identify_name_list_scope': '', 'identify_name_list_country': 'de'},
    ]) {
      SharedPreferences.setMockInitialValues(saved);
      final p = await IdentifyPrefs.load();
      expect(p.nameListScope, 'neighbours', reason: '$saved');
      expect(p.nameListCountry, '', reason: '$saved');
    }
  });
}
