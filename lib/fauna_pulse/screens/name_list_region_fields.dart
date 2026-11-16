// FaunaPulse (round 373): "Names to choose from" on Identify organisms, shown under the
// name list when that list carries country lists (label_pack.dart, `regions`).
//
// The settings (IdentifyPrefs): "Names from", the country, and the countries chosen by hand
// (round 376). What they lead to, and when the whole list is used instead, is decided in
// identification/name_list_region.dart (`nameListForSettings`), which the scoring reads too,
// so this page shows what a run will use.

import 'package:flutter/material.dart';

import '../identification/country_names.dart';
import '../identification/identification_assets.dart';
import '../identification/label_pack.dart';
import '../identification/name_list_region.dart';
import '../widgets/multi_pick_dialog.dart';
import '../widgets/setting_help.dart';
import 'identification_choice_fields.dart' show thousands;

/// "Germany and its 10 neighbours", "Malta and its neighbour", "Iceland only": the countries
/// of a narrowed list in words ([countries]: the country itself first), for this page and the
/// results header. Countries chosen by hand are named, up to three ("France, Spain and 4 more
/// countries").
String countriesInWords(List<String> countries, {required String scope}) {
  if (countries.isEmpty) return 'the whole name list';
  final name = countryName(countries.first);
  final others = countries.length - 1;
  if (scope == kScopeCountry || others == 0) return '$name only';
  if (scope == kScopeCountries) {
    final second = countryName(countries[1]);
    return switch (others) {
      1 => '$name and $second',
      2 => '$name, $second and ${countryName(countries[2])}',
      _ => '$name, $second and ${others - 1} more countries',
    };
  }
  return others == 1 ? '$name and its neighbour' : '$name and its $others neighbours';
}

class NameListRegionFields extends StatelessWidget {
  final IdentifyPrefs prefs;

  /// The chosen name list's country lists and its number of names.
  final PackRegions regions;
  final int packNames;

  /// The country of the session's position; null when it is not known.
  final String? sessionCountry;

  /// Applies a change in the host's setState and saves (as IdentifySettingsFields).
  final void Function(VoidCallback change) onEdit;

  const NameListRegionFields({
    super.key,
    required this.prefs,
    required this.regions,
    required this.packNames,
    required this.onEdit,
    this.sessionCountry,
  });

  @override
  Widget build(BuildContext context) {
    final choice = nameListForSettings(prefs.toJson(), regions, packNames: packNames, sessionCountry: sessionCountry);
    final codes = regions.countries.keys.toList()..sort((a, b) => countryName(a).compareTo(countryName(b)));
    String withNames(String c) => '${countryName(c)} (${thousands(PackRegions.countRows(regions.countries[c]!.bits))} names)';
    final all = thousands(packNames);
    final wholeList = prefs.nameListScope == kScopeAll;
    final byHand = prefs.nameListScope == kScopeCountries;
    // The chosen countries this list knows, by name (the others add nothing to a run).
    final chosen = [for (final c in codes) if (prefs.nameListChosenCountries.contains(c)) c];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HelpLabel(
          label: 'Names to choose from',
          labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperText:
              'This name list covers a large region, so it holds many species that do not live where the '
              'camera stood. It also knows in which countries each species was recorded, from the records '
              'of GBIF (the Global Biodiversity Information Facility, gbif.org). With that, the model '
              'chooses only among the species recorded in one country and, by default, its neighbours. '
              'The country is found from the session\'s position, on this phone and without internet (near '
              'a coast, the nearest country within 25 km counts); you can choose another one. '
              'The neighbours are included because species do not stop at borders and some countries '
              'have few records. With "Countries I choose" you tick any countries yourself, for '
              'example for a region that lies in several countries; their names are put together. '
              'The lists follow where people observe and upload: they are dense in '
              'Europe and North America and thin in much of the tropics, Africa and Asia. When unsure, '
              'use the neighbours or the whole name list. Results made with different choices cannot be '
              'compared directly: a shorter list shares the same 100 % among fewer names, so its '
              'percentages are higher. Whether a country list names insects better than the whole list '
              'is not tested yet.',
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('name list scope'),
          initialValue: prefs.nameListScope,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Names from'),
          items: const [
            DropdownMenuItem(value: kScopeNeighbours, child: Text('The country and its neighbours', overflow: TextOverflow.ellipsis)),
            DropdownMenuItem(value: kScopeCountry, child: Text('The country only', overflow: TextOverflow.ellipsis)),
            DropdownMenuItem(value: kScopeCountries, child: Text('Countries I choose', overflow: TextOverflow.ellipsis)),
            DropdownMenuItem(value: kScopeAll, child: Text('The whole name list', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) {
            if (v != null) onEdit(() => prefs.nameListScope = v);
          },
        ),
        const SizedBox(height: 8),
        if (byHand)
          // A window with a search box: a dropdown cannot tick several entries.
          InkWell(
            key: const ValueKey('name list countries'),
            onTap: () async {
              final picked = await showMultiPickDialog(
                context,
                title: 'Countries',
                searchHint: 'Search a country',
                items: [for (final c in codes) PickItem(c, withNames(c))],
                chosen: prefs.nameListChosenCountries,
              );
              // Saved in the order of the codes: the same set is always the same saved value.
              if (picked != null && context.mounted) onEdit(() => prefs.nameListChosenCountries = picked..sort());
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Countries', suffixIcon: Icon(Icons.arrow_drop_down)),
              child: Text(
                chosen.isEmpty ? 'None yet: tap to choose' : chosen.map(countryName).join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
        else
          DropdownButtonFormField<String>(
            // The key shows a country that is no longer in the list as "the session's" one.
            key: ValueKey('name list country ${prefs.nameListCountry} $wholeList'),
            initialValue: regions.countries.containsKey(prefs.nameListCountry) ? prefs.nameListCountry : '',
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Country',
              helperText: wholeList ? 'Not used with the whole name list.' : null,
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  sessionCountry == null
                      ? 'Where the session was recorded'
                      : 'Where the session was recorded (${countryName(sessionCountry!)})',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final c in codes)
                DropdownMenuItem(value: c, child: Text(withNames(c), overflow: TextOverflow.ellipsis)),
            ],
            // Greyed with the whole list; the stored country stays for the next change.
            onChanged: wholeList
                ? null
                : (v) {
                    if (v != null) onEdit(() => prefs.nameListCountry = v);
                  },
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_used(choice, all), style: helperTextStyle),
        ),
        if (choice.shortList)
          _warning(
            'Only ${thousands(choice.names)} names. GBIF holds few records from '
            '${choice.countries.length == 1 ? countryName(choice.countries.first) : 'these countries'}, so species that '
            'live there are probably missing from this list, and the model then has to pick a wrong name. '
            '${switch (prefs.nameListScope) {
              kScopeCountry => '"The country and its neighbours" or "The whole name list" is',
              kScopeCountries => 'More countries, or "The whole name list", is',
              _ => '"The whole name list" is',
            }} '
            'safer.',
          ),
        if (choice.narrowed && choice.lowCoverage) _warning(_lowCoverage(choice.lowCoverageCountries)),
      ],
    );
  }

  /// The warning for the countries this name list was not made for (it holds a small share
  /// of their own GBIF lists).
  String _lowCoverage(List<String> low) {
    String share(String c) => '${((regions.countries[c]?.coverage ?? 0) * 100).round()} of 100';
    if (low.length == 1) {
      return 'This name list holds only ${share(low.first)} species that GBIF lists for ${countryName(low.first)}: it was '
          'made for another region, so many species of that country cannot be named with it.';
    }
    final named = [for (final c in low.take(4)) '${countryName(c)} (${share(c)})'].join(', ');
    return 'This name list holds only a part of the species that GBIF lists for $named'
        '${low.length > 4 ? ' and ${low.length - 4} more of the chosen countries' : ''}: it was made for another '
        'region, so many species of these countries cannot be named with it.';
  }

  /// One sentence on the names a run will choose from.
  static String _used(NameListChoice c, String all) {
    if (c.narrowed) {
      final where = countriesInWords(c.countries, scope: c.scope);
      return 'A run chooses among the ${thousands(c.names)} names of $where (of $all in the list).';
    }
    final country = c.country == null ? null : countryName(c.country!);
    if (c.scope == kScopeCountries && c.wholeListReason != null) {
      return c.wholeListReason == kWholeNoCountry
          ? 'No country is chosen yet, so a run chooses among all $all names. Tap "Countries" above to choose.'
          : 'This name list has no names for the chosen countries, so a run chooses among all $all names.';
    }
    return switch (c.wholeListReason) {
      kWholeNoCountry =>
        'The country of this session is not known (it has no position, or one far from land), so a run '
            'chooses among all $all names. Choose a country above to narrow them.',
      kWholeNotInList => 'This name list has no names for $country, so a run chooses among all $all names.',
      kWholeShortList =>
        'GBIF holds few records from $country and its neighbours (a short list misses many species), so a run '
            'chooses among all $all names. To use the short list anyway, choose $country above.',
      _ => 'A run chooses among all $all names.',
    };
  }

  static Widget _warning(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text('⚠ $text', style: const TextStyle(color: Colors.amber, fontSize: 13)),
  );
}
