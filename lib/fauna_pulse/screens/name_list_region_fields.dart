// FaunaPulse (round 373): "Names of one country" on Identify organisms, shown under the
// name list when that list carries country lists (label_pack.dart, `regions`).
//
// Two settings (IdentifyPrefs): "Names from" and the country. What they lead to, and when
// the whole list is used instead, is decided in identification/name_list_region.dart
// (`resolveNameList`), which the scoring reads too, so this page shows what a run will use.

import 'package:flutter/material.dart';

import '../identification/country_names.dart';
import '../identification/identification_assets.dart';
import '../identification/label_pack.dart';
import '../identification/name_list_region.dart';
import '../widgets/setting_help.dart';
import 'identification_choice_fields.dart' show thousands;

/// "Germany and its 10 neighbours", "Malta and its neighbour", "Iceland only": the countries
/// of a narrowed list in words ([countries]: the country itself first), for this page and the
/// results header.
String countriesInWords(List<String> countries, {required String scope}) {
  if (countries.isEmpty) return 'the whole name list';
  final name = countryName(countries.first);
  final others = countries.length - 1;
  if (scope == kScopeCountry || others == 0) return '$name only';
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
    final choice = resolveNameList(
      regions,
      packNames: packNames,
      scope: prefs.nameListScope,
      country: prefs.nameListCountry,
      sessionCountry: sessionCountry,
    );
    final codes = regions.countries.keys.toList()..sort((a, b) => countryName(a).compareTo(countryName(b)));
    final all = thousands(packNames);
    final wholeList = prefs.nameListScope == kScopeAll;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HelpLabel(
          label: 'Names of one country',
          labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperText:
              'This name list covers a large region, so it holds many species that do not live where the '
              'camera stood. It also knows in which countries each species was recorded, from the records '
              'of GBIF (the Global Biodiversity Information Facility, gbif.org). With that, the model '
              'chooses only among the species recorded in one country and, by default, its neighbours. '
              'The neighbours are included because species do not stop at borders and some countries '
              'have few records. The lists follow where people observe and upload: they are dense in '
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
            DropdownMenuItem(value: kScopeAll, child: Text('The whole name list', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) {
            if (v != null) onEdit(() => prefs.nameListScope = v);
          },
        ),
        const SizedBox(height: 8),
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
              DropdownMenuItem(
                value: c,
                child: Text(
                  '${countryName(c)} (${thousands(PackRegions.countRows(regions.countries[c]!.bits))} names)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
            '${prefs.nameListScope == kScopeCountry ? '"The country and its neighbours" or "The whole name list" is' : '"The whole name list" is'} '
            'safer.',
          ),
        if (choice.narrowed && choice.lowCoverage)
          _warning(
            'This name list holds only ${(choice.coverage! * 100).round()} of 100 species that GBIF lists for '
            '${countryName(choice.country!)}: it was made for another region, so many species of that country '
            'cannot be named with it.',
          ),
      ],
    );
  }

  /// One sentence on the names a run will choose from.
  static String _used(NameListChoice c, String all) {
    if (c.narrowed) {
      final where = countriesInWords(c.countries, scope: c.scope);
      return 'A run chooses among the ${thousands(c.names)} names of $where (of $all in the list).';
    }
    final country = c.country == null ? null : countryName(c.country!);
    return switch (c.wholeListReason) {
      kWholeNoCountry =>
        'The country of this session is not known, so a run chooses among all $all names. Choose a country '
            'above to narrow them.',
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
