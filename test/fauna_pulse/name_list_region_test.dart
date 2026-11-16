// Tests for the names a run chooses from (round 373, name_list_region.dart): the "Names
// from" setting and the country give the rows on offer, or the whole list with the reason.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/identification/name_list_region.dart';

const _rows = 8000;

/// Bits of a country that lists the rows [from] .. [to] - 1.
String _bits(int from, int to) {
  final b = Uint8List((_rows + 7) ~/ 8);
  for (var r = from; r < to; r++) {
    b[r >> 3] |= 1 << (r & 7);
  }
  return base64.encode(b);
}

void main() {
  // BIG: 6,000 names. SMALL: 100 names, next to NEAR (5,200 others). ALONE: 100 names, no
  // neighbour. FAR: the pack holds half of the country's own list.
  final regions = PackRegions.tryParse({
    'countries': {
      'BG': {'rows': _bits(0, 6000), 'names': 6000, 'names_in_country': 6000},
      'SM': {'rows': _bits(0, 100), 'names': 100, 'names_in_country': 100},
      'NR': {'rows': _bits(100, 5300), 'names': 5200, 'names_in_country': 5300},
      'AL': {'rows': _bits(7000, 7100), 'names': 100, 'names_in_country': 104},
      'FR': {'rows': _bits(0, 5500), 'names': 5500, 'names_in_country': 11000},
    },
    'neighbours': {
      'SM': ['NR', 'ZZ'],
      'NR': ['SM'],
    },
  }, _rows)!;
  NameListChoice choose({String scope = kScopeNeighbours, String country = '', String? session}) =>
      resolveNameList(regions, packNames: _rows - 6, scope: scope, country: country, sessionCountry: session);
  NameListChoice byHand(List<String> countries, {String country = 'BG', String? session = 'BG'}) => resolveNameList(
    regions,
    packNames: _rows - 6,
    scope: kScopeCountries,
    country: country,
    chosenCountries: countries,
    sessionCountry: session,
  );

  test('the whole list: asked for, or a pack without country lists', () {
    for (final c in [
      choose(scope: kScopeAll, country: 'BG', session: 'BG'),
      resolveNameList(null, packNames: _rows - 6, scope: kScopeNeighbours, country: 'BG', sessionCountry: 'BG'),
    ]) {
      expect(c.narrowed, isFalse);
      expect(c.rowBits, isNull);
      expect(c.names, _rows - 6);
      expect(c.wholeListReason, isNull);
      expect(c.label, 'all');
      expect(c.shortList, isFalse);
    }
  });

  test('no country: no position and none chosen by hand', () {
    final c = choose();
    expect(c.narrowed, isFalse);
    expect(c.wholeListReason, kWholeNoCountry);
    expect(c.toJson(), {'countries': [], 'taxa': [], 'names': _rows - 6, 'scope': kScopeNeighbours, 'whole_list_reason': kWholeNoCountry});
  });

  test('the session\'s country with its neighbours is the default', () {
    final big = choose(session: 'BG');
    expect(big.countries, ['BG']);
    expect(big.names, 6000);
    expect(big.fromSession, isTrue);
    expect(big.shortList, isFalse);
    expect(big.coverage, 1);
    expect(PackRegions.countRows(big.rowBits!), 6000);
    // A small country next to a well recorded one: together they are long enough. A neighbour
    // the pack has no list for (ZZ) adds nothing.
    final small = choose(session: 'SM');
    expect(small.countries, ['SM', 'NR']);
    expect(small.names, 5300);
    expect(small.label, 'SM+NR');
    expect(small.toJson(), {
      'countries': ['SM', 'NR'],
      'taxa': [],
      'names': 5300,
      'scope': kScopeNeighbours,
      'country': 'SM',
      'country_from_session': true,
      'country_coverage': 1.0,
    });
  });

  test('the default never picks a short list: the whole list is used and the reason kept', () {
    final c = choose(session: 'AL');
    expect(c.narrowed, isFalse);
    expect(c.wholeListReason, kWholeShortList);
    expect(c.country, 'AL');
    expect(c.fromSession, isTrue);
    expect(c.names, _rows - 6);
    expect(c.label, 'all');
  });

  test('a choice made by hand is kept also when the list is short; the page warns', () {
    // The country chosen by hand.
    final byHand = choose(country: 'AL', session: 'BG');
    expect(byHand.countries, ['AL']);
    expect(byHand.names, 100);
    expect(byHand.fromSession, isFalse);
    expect(byHand.shortList, isTrue);
    expect(byHand.wholeListReason, isNull);
    // "The country only" chosen by hand, for the session's country.
    final only = choose(scope: kScopeCountry, session: 'SM');
    expect(only.countries, ['SM']);
    expect(only.names, 100);
    expect(only.shortList, isTrue);
    expect(only.fromSession, isTrue);
    expect(kShortNameList, 5000);
  });

  test('a country the name list has no names for', () {
    for (final c in [choose(country: 'ZZ'), choose(session: 'ZZ')]) {
      expect(c.narrowed, isFalse);
      expect(c.wholeListReason, kWholeNotInList);
      expect(c.country, 'ZZ');
    }
  });

  test('coverage: the share of the country\'s own list that the pack holds', () {
    final far = choose(country: 'FR');
    expect(far.coverage, 0.5);
    expect(far.lowCoverage, isTrue);
    expect(far.shortList, isFalse);
    expect(choose(country: 'NR').lowCoverage, isFalse); // 5,200 of 5,300
    expect(kLowCountryCoverage, 0.8);
  });

  group('round 376: countries chosen by hand', () {
    test('the names of the chosen countries are put together; the country and the session are not read', () {
      final c = byHand(['SM', 'AL']);
      expect(c.countries, ['AL', 'SM'], reason: 'in the order of the codes, whatever the order of the choice');
      expect(c.names, 200);
      expect(PackRegions.countRows(c.rowBits!), 200);
      expect(c.label, 'AL+SM');
      expect(c.country, isNull);
      expect(c.fromSession, isFalse);
      expect(c.toJson(), {'countries': ['AL', 'SM'], 'taxa': [], 'names': 200, 'scope': kScopeCountries});
      // Names two countries share count once.
      expect(byHand(['BG', 'NR', 'SM']).names, 6000);
      // One country by hand here equals "The country only" for that country.
      expect(byHand(['NR']).rowBits, choose(scope: kScopeCountry, country: 'NR').rowBits);
    });

    test('kept also when short, with the warning; no neighbours are added', () {
      final c = byHand(['SM']);
      expect(c.countries, ['SM'], reason: 'SM\'s neighbour NR is not added');
      expect(c.shortList, isTrue);
      expect(c.wholeListReason, isNull);
      expect(byHand(['SM', 'NR']).shortList, isFalse); // 5,300 names together
    });

    test('nothing chosen, or only countries the name list does not know: the whole list and why', () {
      final none = byHand([]);
      expect(none.narrowed, isFalse);
      expect(none.wholeListReason, kWholeNoCountry);
      expect(none.toJson(), {'countries': [], 'taxa': [], 'names': _rows - 6, 'scope': kScopeCountries, 'whole_list_reason': kWholeNoCountry});
      final unknown = byHand(['ZZ', 'YY']);
      expect(unknown.narrowed, isFalse);
      expect(unknown.wholeListReason, kWholeNotInList);
      // A code the list does not know adds nothing and is not recorded.
      expect(byHand(['ZZ', 'BG', 'BG']).countries, ['BG']);
    });

    test('every chosen country the name list was not made for is named', () {
      final c = byHand(['FR', 'BG', 'AL']);
      expect(c.lowCoverageCountries, ['FR'], reason: 'AL: 100 of 104, BG: all');
      expect(c.lowCoverage, isTrue);
      expect(c.coverage, isNull, reason: 'the share is one country\'s');
      expect(byHand(['BG', 'NR']).lowCoverage, isFalse);
    });

    test('the settings as saved give the same answer; values of a wrong kind count as the defaults', () {
      NameListChoice of(Map<String, dynamic> s, {String? session}) => nameListForSettings(s, regions, packNames: _rows - 6, sessionCountry: session);
      final c = of({'name_list_scope': 'countries', 'name_list_country': 'BG', 'name_list_chosen_countries': ['SM', 'AL']});
      expect(c.label, 'AL+SM');
      expect(of({'name_list_scope': 'countries', 'name_list_chosen_countries': 'SM'}).wholeListReason, kWholeNoCountry);
      expect(of({'name_list_scope': 'countries', 'name_list_chosen_countries': ['SM', 3, null]}).countries, ['SM']);
      expect(of({'name_list_scope': 7, 'name_list_country': 9}, session: 'BG').label, 'BG');
      // The session's country is looked up only when a run would read it.
      expect(nameListNeedsSessionCountry({'name_list_scope': 'neighbours', 'name_list_country': ''}), isTrue);
      expect(nameListNeedsSessionCountry({}), isTrue, reason: 'the defaults');
      expect(nameListNeedsSessionCountry({'name_list_scope': 'country', 'name_list_country': 'BG'}), isFalse);
      expect(nameListNeedsSessionCountry({'name_list_scope': 'countries', 'name_list_country': ''}), isFalse);
      expect(nameListNeedsSessionCountry({'name_list_scope': 'all', 'name_list_country': ''}), isFalse);
    });
  });

  group('round 377: orders and families chosen by hand', () {
    // The 7,994 names in two orders: Diptera = rows 0 .. 4,999 (Syrphidae rows 0 .. 49, then
    // Muscidae), Hymenoptera = rows 5,000 .. 7,993 (Apidae 5,000 .. 5,099, then Formicidae).
    // The six last rows are "none of these".
    final taxa = PackTaxa.of([
      for (var r = 0; r < _rows; r++)
        r >= _rows - 6
            ? const LabelRow(['none', '', '', '', '', '', 'flower'], '')
            : LabelRow(['Animalia', 'Arthropoda', 'Insecta', r < 5000 ? 'Diptera' : 'Hymenoptera', r < 50 ? 'Syrphidae' : r < 5000 ? 'Muscidae' : r < 5100 ? 'Apidae' : 'Formicidae', 'G', 's$r'], ''),
    ]);
    NameListChoice pick(List<String> chosen, {String scope = kScopeAll, String country = '', List<String> countries = const [], String? session}) => resolveNameList(
      regions,
      packNames: _rows - 6,
      scope: scope,
      country: country,
      chosenCountries: countries,
      sessionCountry: session,
      taxa: taxa,
      chosenTaxa: chosen,
    );

    test('nothing chosen: every order and family, the record says so', () {
      final c = pick([]);
      expect(c.narrowed, isFalse);
      expect(c.taxa, isEmpty);
      expect(c.taxaLabel, 'all');
      expect(c.toJson(), {'countries': [], 'taxa': [], 'names': _rows - 6, 'scope': kScopeAll});
    });

    test('on the whole list: the names of the chosen orders and families, each once', () {
      final c = pick(['Syrphidae', 'Hymenoptera']);
      expect(c.taxa, ['Hymenoptera', 'Syrphidae'], reason: 'alphabetical, whatever the order of the choice');
      expect(c.names, 50 + 2994);
      expect(c.countryNames, _rows - 6);
      expect(c.narrowed, isTrue);
      expect(c.countries, isEmpty);
      expect(c.label, 'all');
      expect(c.taxaLabel, 'Hymenoptera+Syrphidae');
      expect(c.shortList, isFalse, reason: 'few names of a family say nothing about a country\'s records');
      expect(c.toJson(), {'countries': [], 'taxa': ['Hymenoptera', 'Syrphidae'], 'names': 3044, 'scope': kScopeAll});
      // A family of a chosen order adds nothing.
      expect(pick(['Hymenoptera', 'Apidae']).names, 2994);
      expect(PackRegions.hasRow(c.rowBits!, _rows - 1), isFalse, reason: 'the "none of these" rows are the scorer\'s, never in the bits');
    });

    test('with countries: a name must be listed for the countries and be in a chosen order or family', () {
      // BG lists the rows 0 .. 5,999: all Diptera and the first 1,000 Hymenoptera.
      final c = pick(['Hymenoptera'], scope: kScopeCountry, country: 'BG');
      expect(c.countries, ['BG']);
      expect(c.taxa, ['Hymenoptera']);
      expect(c.names, 1000);
      expect(c.countryNames, 6000);
      expect(c.shortList, isFalse, reason: 'the country\'s own list is long enough');
      expect(c.toJson(), {'countries': ['BG'], 'taxa': ['Hymenoptera'], 'names': 1000, 'scope': kScopeCountry, 'country': 'BG', 'country_from_session': false, 'country_coverage': 1.0});
      // A short country list stays short, and is judged before the orders and families.
      final small = pick(['Syrphidae'], scope: kScopeCountries, countries: ['SM']);
      expect(small.names, 50);
      expect(small.countryNames, 100);
      expect(small.shortList, isTrue);
      // The warning about a list made for another region stays the countries'.
      expect(pick(['Diptera'], scope: kScopeCountry, country: 'FR').lowCoverageCountries, ['FR']);
    });

    test('the default never picks a short country list; the orders and families still narrow', () {
      final c = pick(['Apidae'], scope: kScopeNeighbours, session: 'AL');
      expect(c.wholeListReason, kWholeShortList);
      expect(c.countries, isEmpty);
      expect(c.taxa, ['Apidae']);
      expect(c.names, 100);
      expect(c.narrowed, isTrue);
    });

    test('no name in both choices: neither is used, with the reason', () {
      // AL lists the rows 7,000 .. 7,099, all Formicidae.
      final c = pick(['Syrphidae'], scope: kScopeCountry, country: 'AL');
      expect(c.narrowed, isFalse);
      expect(c.rowBits, isNull);
      expect(c.wholeListReason, kWholeNoCommonNames);
      expect(c.names, _rows - 6);
      expect(c.countries, isEmpty);
      expect(c.taxa, isEmpty);
      expect(c.label, 'all');
      expect(c.taxaLabel, 'all');
      expect(c.shortList, isFalse);
    });

    test('names this name list does not have are left out; a class list has no such choice', () {
      expect(pick(['Syrphidae', 'Felidae']).taxa, ['Syrphidae']);
      final other = pick(['Felidae', 'Carnivora'], scope: kScopeCountry, country: 'BG');
      expect(other.taxa, isEmpty);
      expect(other.names, 6000, reason: 'the countries narrow as without the choice');
      final classes = resolveNameList(null, packNames: 40, scope: kScopeAll, country: '', chosenTaxa: ['Syrphidae']);
      expect(classes.narrowed, isFalse);
    });

    test('the settings as saved give the same answer', () {
      final c = nameListForSettings(
        {'name_list_scope': 'country', 'name_list_country': 'BG', 'name_list_chosen_taxa': ['Hymenoptera', 7, null]},
        regions,
        packNames: _rows - 6,
        taxa: taxa,
      );
      expect(c.label, 'BG');
      expect(c.taxaLabel, 'Hymenoptera');
      expect(chosenTaxaOf({'name_list_chosen_taxa': 'Hymenoptera'}), isEmpty, reason: 'a value of a wrong kind');
      expect(chosenTaxaOf({}), isEmpty);
    });
  });
}
