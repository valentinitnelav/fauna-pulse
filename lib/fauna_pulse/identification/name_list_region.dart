// FaunaPulse (round 373): which names of a name list a run chooses from.
//
// A name list with country lists (the `regions` block, label_pack.dart) can be narrowed to the
// names GBIF lists in one country, with or without its neighbours. Two settings decide it
// (IdentifyPrefs): "Names from" (the country and its neighbours, the country only, the whole
// list) and the country (from the session's position, or one chosen by hand). This file turns
// them into the rows on offer, with the reason when the whole list is used instead; the
// scoring (identification_job.dart) and the Identify page read the same answer. How the rows
// on offer change the scores: track_fusion.dart, file header.
//
// Pure Dart, no I/O, unit-tested.

import 'dart:typed_data';

import 'label_pack.dart';

/// The "Names from" values (saved as `identify_name_list_scope`, written to the results).
const kScopeNeighbours = 'neighbours';
const kScopeCountry = 'country';
const kScopeAll = 'all';
const kNameListScopes = [kScopeNeighbours, kScopeCountry, kScopeAll];

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
const kWholeNotInList = 'not_in_list'; // the name list has no names for that country
const kWholeShortList = 'short_list'; // the default choice would be a short list

/// The names a run chooses from.
class NameListChoice {
  /// The countries whose names are on offer, the country itself first; empty = the whole list.
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

  const NameListChoice({
    required this.countries,
    required this.rowBits,
    required this.names,
    required this.scope,
    this.country,
    this.fromSession = false,
    this.wholeListReason,
    this.coverage,
  });

  bool get narrowed => rowBits != null;

  /// A narrowed list with few names (see [kShortNameList]): the page warns.
  bool get shortList => narrowed && names < kShortNameList;

  bool get lowCoverage => coverage != null && coverage! < kLowCountryCoverage;

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

/// The names on offer for a pack with [regions] (null: it has no country lists) and
/// [packNames] names, for the settings [scope] and [country] ('' = the country of the
/// session, [sessionCountry], which is null when the session has no usable position).
///
/// The whole list is used when it is asked for, when no country is known, when the pack has
/// no names for the country, and when nothing was chosen by hand (the default "country and
/// its neighbours" of the session's country) and that list is short. A choice made by hand
/// is kept also when short; the page then warns.
NameListChoice resolveNameList(
  PackRegions? regions, {
  required int packNames,
  required String scope,
  required String country,
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
  final byHand = country.isNotEmpty;
  final code = byHand ? country : sessionCountry;
  if (code == null) return whole(reason: kWholeNoCountry);
  final own = regions.countries[code];
  if (own == null) return whole(reason: kWholeNotInList, used: code, fromSession: !byHand);
  final codes = scope == kScopeCountry ? [code] : regions.withNeighbours(code);
  final bits = regions.rowBits(codes);
  final names = PackRegions.countRows(bits);
  final coverage = own.namesInCountry > 0 ? own.names / own.namesInCountry : null;
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
  );
}
