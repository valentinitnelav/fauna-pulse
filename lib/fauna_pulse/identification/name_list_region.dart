// FaunaPulse (round 373): which names of a name list a run chooses from.
//
// A name list with country lists (the `regions` block, label_pack.dart) can be narrowed to the
// names GBIF lists in one country, with or without its neighbours, or in any set of countries
// chosen by hand (round 376). The settings (IdentifyPrefs): "Names from" (the country and its
// neighbours, the country only, countries chosen by hand, the whole list), the country (from
// the session's position, or one chosen by hand) and the set of countries. This file turns
// them into the rows on offer, with the reason when the whole list is used instead; the
// scoring (identification_job.dart) and the Identify page read the same answer
// ([nameListForSettings]). How the rows on offer change the scores: track_fusion.dart, file
// header.
//
// Pure Dart, no I/O, unit-tested.

import 'dart:typed_data';

import 'label_pack.dart';

/// The "Names from" values (saved as `identify_name_list_scope`, written to the results).
const kScopeNeighbours = 'neighbours';
const kScopeCountry = 'country';
const kScopeCountries = 'countries'; // round 376: any set of countries, chosen by hand
const kScopeAll = 'all';
const kNameListScopes = [kScopeNeighbours, kScopeCountry, kScopeCountries, kScopeAll];

/// A list with fewer names than this is called short. A country's list is short when few
/// records of it reached GBIF (Romania 3,775 names of the four orders of the Europe list,
/// Germany 16,770), and then the species in front of the camera is often missing from it, so
/// the model has to pick a wrong name. Maintainer's choice (2026-11-15), a judgement: no data
/// yet on how the answers get worse as a list gets shorter.
const kShortNameList = 5000;

/// Below this share of a country's own GBIF list, the name list was made for another region
/// (the Europe list holds 13 % of the species listed for the United States); every country
/// of Europe is above it (lowest: Turkey, 86 %). Same status as [kShortNameList].
const kLowCountryCoverage = 0.8;

/// Why a run uses the whole list although a country list was asked for.
const kWholeNoCountry = 'no_country'; // no position, or not on land, and no country chosen
const kWholeNotInList = 'not_in_list'; // the name list has no names for that country (or those)
const kWholeShortList = 'short_list'; // the default choice would be a short list

/// The names a run chooses from.
class NameListChoice {
  /// The countries whose names are on offer; empty = the whole list. The country itself comes
  /// first, then its neighbours; countries chosen by hand are in the order of their codes.
  final List<String> countries;

  /// The rows on offer ([PackRegions.rowBits]); null = the whole list.
  final Uint8List? rowBits;

  /// Names on offer (without the "none of these" entries, which are always on offer).
  final int names;

  /// The settings as asked, and the country they led to (null when none was found).
  final String scope;
  final String? country;

  /// The country came from the session's position, not from a choice by hand.
  final bool fromSession;

  /// One of the `kWhole...` values when the whole list is used although a country list was
  /// asked for; null otherwise.
  final String? wholeListReason;

  /// Share of [country]'s own GBIF list that the name list holds; null without a country.
  final double? coverage;

  /// The countries the name list was not made for (see [kLowCountryCoverage]): [country], or
  /// those of the countries chosen by hand. The neighbours are not judged: they only add names.
  final List<String> lowCoverageCountries;

  const NameListChoice({
    required this.countries,
    required this.rowBits,
    required this.names,
    required this.scope,
    this.country,
    this.fromSession = false,
    this.wholeListReason,
    this.coverage,
    this.lowCoverageCountries = const [],
  });

  bool get narrowed => rowBits != null;

  /// A narrowed list with few names (see [kShortNameList]): the page warns.
  bool get shortList => narrowed && names < kShortNameList;

  bool get lowCoverage => lowCoverageCountries.isNotEmpty;

  /// `DE+AT+BE` or `all`: the `name_list_countries` column of the results.
  String get label => countries.isEmpty ? 'all' : countries.join('+');

  /// The `name_list` block of `summary_<pack>.json`.
  Map<String, dynamic> toJson() => {
    'countries': countries,
    'names': names,
    'scope': scope,
    'country': ?country,
    if (country != null) 'country_from_session': fromSession,
    'whole_list_reason': ?wholeListReason,
    if (coverage != null) 'country_coverage': double.parse(coverage!.toStringAsFixed(3)),
  };
}

/// Whether these settings need the country of the session's position: a country list is
/// asked for and no country was chosen by hand.
bool nameListNeedsSessionCountry(Map<String, dynamic> settings) {
  final scope = settings['name_list_scope'];
  return scope != kScopeAll && scope != kScopeCountries && (settings['name_list_country'] ?? '') == '';
}

/// [resolveNameList] for a run's settings as they are saved and written to the results
/// (`IdentifyPrefs.toJson`, `IdentifyRunSettings.toJson`): the one reading of those keys, for
/// the scoring and the Identify page. A value of a wrong kind counts as the default.
NameListChoice nameListForSettings(
  Map<String, dynamic> settings,
  PackRegions? regions, {
  required int packNames,
  String? sessionCountry,
}) {
  final scope = settings['name_list_scope'], country = settings['name_list_country'], chosen = settings['name_list_chosen_countries'];
  return resolveNameList(
    regions,
    packNames: packNames,
    scope: scope is String && kNameListScopes.contains(scope) ? scope : kScopeNeighbours,
    country: country is String ? country : '',
    chosenCountries: [if (chosen is List) ...chosen.whereType<String>()],
    sessionCountry: sessionCountry,
  );
}

/// The names on offer for a pack with [regions] (null: it has no country lists) and
/// [packNames] names, for the settings [scope], [country] ('' = the country of the session,
/// [sessionCountry], which is null when the session has no usable position) and
/// [chosenCountries] (read only with "countries chosen by hand").
///
/// The whole list is used when it is asked for, when no country is known or chosen, when the
/// pack has no names for the country, and when nothing was chosen by hand (the default
/// "country and its neighbours" of the session's country) and that list is short. A choice
/// made by hand is kept also when short; the page then warns.
NameListChoice resolveNameList(
  PackRegions? regions, {
  required int packNames,
  required String scope,
  required String country,
  List<String> chosenCountries = const [],
  String? sessionCountry,
}) {
  NameListChoice whole({String? reason, String? used, bool fromSession = false, double? coverage}) => NameListChoice(
    countries: const [],
    rowBits: null,
    names: packNames,
    scope: scope,
    country: used,
    fromSession: fromSession,
    wholeListReason: reason,
    coverage: coverage,
  );
  if (regions == null || scope == kScopeAll) return whole();
  bool low(String c) => (regions.countries[c]?.coverage ?? 1) < kLowCountryCoverage;
  if (scope == kScopeCountries) {
    // The union of the chosen countries' names. A code the pack has no list for adds nothing
    // and is left out of the record; the codes are sorted, so the same set always gives the
    // same record.
    if (chosenCountries.isEmpty) return whole(reason: kWholeNoCountry);
    final codes = {for (final c in chosenCountries) if (regions.countries.containsKey(c)) c}.toList()..sort();
    final bits = regions.rowBits(codes);
    final names = PackRegions.countRows(bits);
    if (names == 0) return whole(reason: kWholeNotInList);
    return NameListChoice(
      countries: codes,
      rowBits: bits,
      names: names,
      scope: scope,
      lowCoverageCountries: [for (final c in codes) if (low(c)) c],
    );
  }
  final byHand = country.isNotEmpty;
  final code = byHand ? country : sessionCountry;
  if (code == null) return whole(reason: kWholeNoCountry);
  final own = regions.countries[code];
  if (own == null) return whole(reason: kWholeNotInList, used: code, fromSession: !byHand);
  final codes = scope == kScopeCountry ? [code] : regions.withNeighbours(code);
  final bits = regions.rowBits(codes);
  final names = PackRegions.countRows(bits);
  final coverage = own.coverage;
  if (names == 0) return whole(reason: kWholeNotInList, used: code, fromSession: !byHand, coverage: coverage);
  if (!byHand && scope == kScopeNeighbours && names < kShortNameList) {
    return whole(reason: kWholeShortList, used: code, fromSession: true, coverage: coverage);
  }
  return NameListChoice(
    countries: codes,
    rowBits: bits,
    names: names,
    scope: scope,
    country: code,
    fromSession: !byHand,
    coverage: coverage,
    lowCoverageCountries: [if (low(code)) code],
  );
}
