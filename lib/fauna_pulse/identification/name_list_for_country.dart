// FaunaPulse (round 381, owner): the name list to suggest for where the user is, before any
// list is downloaded. "What do you want to watch?" used to suggest the Europe list to everyone.
//
// The numbers come from `assets/name_list_countries.json`: for each offered name list with
// country lists, how many of its names GBIF lists in each country. tool/model_downloads/
// update_catalogue.py --countries writes it from the lists' headers (`regions.countries.<code>
// .names`), so it never drifts from the files users download.
//
// Rule: the list of the same model and the same organisms that holds the most names of the
// country. The organisms are the catalogue title's words before " of " ("Mammals and birds of
// the world", "Flies, ... and moths of Asia"): without that, the mammals and birds answer would
// suggest an insect list, which holds more names of most countries. Continents are GBIF's, a
// practical cut: a country near a border can have almost as many names in the
// neighbouring continent's list (Turkey: Asia 3,941, Europe 3,628 with BioCLIP 2.5). Such a
// list (at least [kCloseShare] of the best) is offered too, right after it.
//
// The country, in this order: the one the user chose on the page; the country of the newest
// session with a position (country_lookup.dart, offline); the country of the mobile network
// the phone is on; the country of its SIM card. No permission is asked for (owner's decision):
// the network and SIM countries need none, and the session positions are already saved. A
// planned world list that loads only the names on offer would make this choice unnecessary,
// so it stays simple.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_error_hooks.dart';
import '../logging/past_sessions.dart';
import '../models/model_downloads.dart';
import '../models/saved_prefs.dart';
import 'country_lookup.dart';

const kNameListCountriesAsset = 'assets/name_list_countries.json';

/// The country the user chose on "What do you want to watch?" (a two-letter code).
const kWatchCountryPref = 'watch_country';

/// A second list holding at least this share of the best list's names of a country is offered
/// too: the user may record on the other side of the border.
const kCloseShare = 0.9;

/// How many of the newest sessions are read for a position (each read is the log's first line).
const _kSessionsToRead = 20;

/// Names per country of each offered name list with country lists.
class NameListCountries {
  /// list file name -> country code -> names.
  final Map<String, Map<String, int>> lists;

  const NameListCountries(this.lists);

  /// How many names of [list] GBIF lists in [country]; null when the table does not know
  /// [list] (a list without country lists, such as a class list).
  int? namesIn(String list, String country) => lists[list] == null ? null : lists[list]![country] ?? 0;

  /// The country codes of the table, for a country choice.
  Set<String> get countries => {for (final l in lists.values) ...l.keys};

  static NameListCountries parse(String text) {
    final raw = (jsonDecode(text) as Map<String, dynamic>)['lists'] as Map<String, dynamic>;
    return NameListCountries({
      for (final MapEntry(:key, :value) in raw.entries)
        if (value is Map) key: {for (final e in value.entries) if (e.value is int) e.key as String: e.value as int},
    });
  }

  /// The bundled table; empty when it cannot be read (the page then suggests as the catalogue
  /// says).
  static Future<NameListCountries> load() async {
    try {
      return parse(await rootBundle.loadString(kNameListCountriesAsset));
    } catch (e) {
      logSwallowed('name_list_countries', e);
      return const NameListCountries({});
    }
  }
}

/// The best list of [n]'s model and organisms for [country], and a close second, with their
/// names in it.
/// Empty when [n]'s list has no country lists.
List<(NamingDownload, int)> listsForCountry(NamingDownload n, String country, NameListCountries table) {
  if (table.namesIn(n.$2.file.name, country) == null) return const [];
  final organisms = listOrganisms(n.$2);
  final ranked = [
    for (final l in n.$1.nameLists)
      if (listOrganisms(l) == organisms)
        if (table.namesIn(l.file.name, country) case final names?) ((n.$1, l), names),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  if (ranked.isEmpty) return const [];
  return [ranked.first, if (ranked.length > 1 && ranked[1].$2 >= kCloseShare * ranked.first.$2) ranked[1]];
}

/// The organisms a name list holds: its title before " of " (see the file header).
String listOrganisms(NameListDownload l) => l.title.split(' of ').first;

/// Whether a country can change [n]'s suggestion: [n]'s model has another list of the same
/// organisms with country lists. The mammals and birds list has country lists but is one list
/// for the whole world, so the page asks for no country there.
bool countryPicksList(NamingDownload n, NameListCountries table) {
  final organisms = listOrganisms(n.$2);
  return n.$1.nameLists.where((l) => listOrganisms(l) == organisms && table.lists.containsKey(l.file.name)).length > 1;
}

/// [use] with each suggested name list replaced by the list of the same model and organisms
/// that holds the most names of [country], and a close second inserted after it. Unchanged
/// without a country or for lists without country lists.
WatchUse useForCountry(WatchUse use, String? country, NameListCountries table) {
  if (country == null) return use;
  final name = <NamingDownload>[];
  void add(NamingDownload n) {
    if (!name.any((m) => m.$1 == n.$1 && m.$2.file.name == n.$2.file.name)) name.add(n);
  }

  for (final n in use.name) {
    final fit = listsForCountry(n, country, table);
    if (fit.isEmpty) {
      add(n);
    } else {
      for (final (f, _) in fit) {
        add(f);
      }
    }
  }
  return WatchUse(id: use.id, icon: use.icon, title: use.title, setup: use.setup, find: use.find, name: name);
}

/// Where the country of [UserCountry] comes from (shown under the country box).
enum CountrySource { chosen, lastSession, network, sim }

typedef UserCountry = ({String code, CountrySource source});

/// The country of the newest session with a position, or null.
Future<String?> lastSessionCountry() async {
  try {
    for (final s in (await scanPastSessionsList()).take(_kSessionsToRead)) {
      final position = await sessionPositionOf(s.logFile.parent);
      if (position != null) return (await bundledCountryBorders())?.countryAt(position.$1, position.$2);
    }
  } catch (e) {
    logSwallowed('last_session_country', e);
  }
  return null;
}

const _channel = MethodChannel('faunapulse/keepalive');

/// The countries of the mobile network and of the SIM card (MainActivity.phoneCountry), upper
/// case; null when unknown (no SIM, airplane mode, a tablet).
Future<({String? network, String? sim})> phoneCountries() async {
  if (!Platform.isAndroid) return (network: null, sim: null);
  try {
    final m = await _channel.invokeMethod<Map<dynamic, dynamic>>('phoneCountry') ?? const {};
    String? code(Object? v) => v is String && v.length == 2 ? v.toUpperCase() : null;
    return (network: code(m['network']), sim: code(m['sim']));
  } catch (e) {
    logSwallowed('phone_country', e);
    return (network: null, sim: null);
  }
}

/// The user's country by the order in the file header; null when none is known. The phone is
/// asked only when no country was chosen and no session has a position.
Future<UserCountry?> guessUserCountry({
  Future<String?> Function() lastSession = lastSessionCountry,
  Future<({String? network, String? sim})> Function() phone = phoneCountries,
}) async {
  final chosen = (await SharedPreferences.getInstance()).stringOrNull(kWatchCountryPref);
  if (chosen != null && chosen.isNotEmpty) return (code: chosen, source: CountrySource.chosen);
  if (await lastSession() case final c?) return (code: c, source: CountrySource.lastSession);
  final p = await phone();
  if (p.network case final c?) return (code: c, source: CountrySource.network);
  if (p.sim case final c?) return (code: c, source: CountrySource.sim);
  return null;
}
