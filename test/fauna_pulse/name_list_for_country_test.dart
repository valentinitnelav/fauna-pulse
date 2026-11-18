// Round 381: the name list suggested for the user's country on "What do you want to watch?",
// before any list is downloaded (identification/name_list_for_country.dart).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/country_names.dart';
import 'package:fauna_pulse/fauna_pulse/identification/name_list_for_country.dart';
import 'package:fauna_pulse/fauna_pulse/models/list_search.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _downloads = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
final _table = NameListCountries.parse(File(kNameListCountriesAsset).readAsStringSync());
WatchUse _use(String id) => _downloads.uses.firstWhere((u) => u.id == id);
List<String> _lists(WatchUse u) => [for (final n in u.name) n.$2.file.name];

void main() {
  test('the table holds exactly the offered name lists with country lists', () {
    final offered = {
      for (final m in _downloads.identification)
        for (final l in m.nameLists)
          if (!l.classList) l.file.name: l.title,
    };
    // update_catalogue.py --countries drops lists no longer offered; a new list with country
    // lists must be given to it.
    for (final list in _table.lists.keys) {
      expect(offered.containsKey(list), isTrue, reason: '$list is not offered: run update_catalogue.py --countries');
    }
    for (final MapEntry(key: list, value: title) in offered.entries) {
      expect(_table.lists.containsKey(list), title.contains('country lists'), reason: list);
    }
    expect(_table.countries.length, greaterThan(240));
  });

  test('the list of the same model with the most names of the country', () {
    expect(_lists(useForCountry(_use('pollinators'), 'US', _table)), [
      'bioclip-2_pollinator-orders-north-america_v1.fpack',
      'insectdct-cls-v7-eff2s_224_fp16.fpack',
    ]);
    expect(useForCountry(_use('pollinators'), 'DE', _table).name.first.$2.file.name,
        'bioclip-2_pollinator-orders-europe_v4.fpack');
    expect(useForCountry(_use('flat_surface'), 'ID', _table).name.first.$2.file.name,
        'bioclip-2_pollinator-orders-asia_v1.fpack');
    // No country, or a list without country lists: as the catalogue says.
    expect(_lists(useForCountry(_use('pollinators'), null, _table)), _lists(_use('pollinators')));
    expect(_lists(useForCountry(_use('mammals_birds'), 'US', _table)), ['bioclip-2_mammals-birds-world_v2.fpack']);
  });

  test('near a continent border a list with almost as many names comes right after the best', () {
    // Turkey: 4,000 names in the Asia list, 3,666 in the Europe list (92 %).
    final fit = listsForCountry(_use('pollinators').name.first, 'TR', _table);
    expect([for (final (n, names) in fit) (n.$2.file.name, names)], [
      ('bioclip-2_pollinator-orders-asia_v1.fpack', 4000),
      ('bioclip-2_pollinator-orders-europe_v4.fpack', 3666),
    ]);
    expect(_lists(useForCountry(_use('pollinators'), 'TR', _table)).take(2), [for (final f in fit) f.$1.$2.file.name]);
    // Indonesia: Oceania holds less than half of Asia's names, so only Asia.
    expect(listsForCountry(_use('pollinators').name.first, 'ID', _table), hasLength(1));
  });

  group('the country, in order', () {
    Future<UserCountry?> guess({String? chosen, String? session, String? network, String? sim}) async {
      SharedPreferences.setMockInitialValues({kWatchCountryPref: ?chosen});
      return guessUserCountry(lastSession: () async => session, phone: () async => (network: network, sim: sim));
    }

    test('chosen, last session, mobile network, SIM card, none', () async {
      expect(await guess(chosen: 'FR', session: 'DE', network: 'AT', sim: 'IT'), (code: 'FR', source: CountrySource.chosen));
      expect(await guess(session: 'DE', network: 'AT', sim: 'IT'), (code: 'DE', source: CountrySource.lastSession));
      expect(await guess(network: 'AT', sim: 'IT'), (code: 'AT', source: CountrySource.network));
      expect(await guess(sim: 'IT'), (code: 'IT', source: CountrySource.sim));
      expect(await guess(), isNull);
    });
  });

  test('a country search ignores case and accents and knows other names (r382)', () {
    bool finds(String code, String query) => searchRank(foldForSearch(countrySearchText(code)), foldForSearch(query)) != null;
    expect(finds('TR', 'turk'), isTrue);
    expect(finds('TR', 'Turkey'), isTrue);
    expect(finds('CI', 'cote'), isTrue);
    expect(finds('CI', 'Ivory'), isTrue);
    expect(finds('GB', 'uk'), isTrue);
    expect(finds('US', 'USA'), isTrue);
    expect(finds('AX', 'aland'), isTrue);
    expect(finds('DE', 'france'), isFalse);
  });

  test('round 387: a search lists the best matches first, and still every match', () {
    List<String> found(String query) =>
        searchList(const ['DZ', 'DE', 'NE', 'NG', 'IT', 'MR', 'GB', 'TR'], query, (c) => foldForSearch(countrySearchText(c)));
    // Algeria, Niger and Nigeria hold "ger" inside a word: after Germany (Done picks the first).
    expect(found('Ger'), ['DE', 'DZ', 'NE', 'NG']);
    expect(found('ita').first, 'IT');
    // A later word, or another name, before a match inside a word.
    expect(searchRank('apis mellifera\napidae · western honey bee', 'bee'), 1);
    expect(searchRank('apis\napidae · bumblebee', 'bee'), 2);
    expect(searchRank('germany', 'ger'), 0);
    expect(searchRank('germany', 'fra'), isNull);
    expect(found('turkey'), ['TR']);
    expect(found('  '), hasLength(8), reason: 'nothing typed: the whole list, in its order');
  });
}
