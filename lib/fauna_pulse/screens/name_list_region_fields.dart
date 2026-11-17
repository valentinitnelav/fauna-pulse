// FaunaPulse (round 373): "Names to choose from" on Identify organisms, shown under the
// name list: the countries, when that list carries country lists (label_pack.dart,
// `regions`), and the orders and families (round 377, every name list but a class list).
//
// The settings (IdentifyPrefs): "Names from", the country, the countries chosen by hand
// (round 376) and the orders and families chosen by hand. What they lead to, and when the
// whole list is used instead, is decided in identification/name_list_region.dart
// (`nameListForSettings`), which the scoring reads too, so this page shows what a run will use.

import 'package:flutter/material.dart';

import '../identification/country_names.dart';
import '../identification/identification_assets.dart';
import '../identification/label_pack.dart';
import '../identification/name_list_region.dart';
import '../widgets/country_field.dart';
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

/// "Apidae", "Apidae and Syrphidae", "Apidae, Syrphidae and 3 more orders or families": the
/// chosen orders and families in words, for this page and the results header.
String taxaInWords(List<String> taxa) => switch (taxa.length) {
  0 => 'every order and family',
  1 => taxa.first,
  2 => '${taxa[0]} and ${taxa[1]}',
  3 => '${taxa[0]}, ${taxa[1]} and ${taxa[2]}',
  _ => '${taxa[0]}, ${taxa[1]} and ${taxa.length - 2} more orders or families',
};

class NameListRegionFields extends StatelessWidget {
  final IdentifyPrefs prefs;

  /// The chosen name list's country lists (null: it has none), its orders and families
  /// (null: not known) and its number of names.
  final PackRegions? regions;
  final PackTaxa? taxa;
  final int packNames;

  /// The country of the session's position; null when it is not known.
  final String? sessionCountry;

  /// Applies a change in the host's setState and saves (as IdentifySettingsFields).
  final void Function(VoidCallback change) onEdit;

  /// Round 378: opens the list of the names a run would choose from ("Show these names");
  /// [listed] says which names they are, in one sentence. Null: no such button.
  final void Function(NameListChoice choice, String listed)? onShowNames;

  /// Round 379: another name list on this phone that holds more names of a country, by file
  /// name, with that number (IdentificationChoice.listWithMoreNamesOf); null: none.
  final ({String file, int names})? Function(String country)? listWithMoreNamesOf;

  const NameListRegionFields({
    super.key,
    required this.prefs,
    this.regions,
    this.taxa,
    required this.packNames,
    required this.onEdit,
    this.onShowNames,
    this.sessionCountry,
    this.listWithMoreNamesOf,
  });

  static const _countriesHelp =
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
      'use the neighbours or the whole name list. Whether a country list names insects better than '
      'the whole list is not tested yet.';
  static const _taxaHelp =
      'With "Orders and families" the model chooses only among the names of the groups you tick, '
      'for example bees and hoverflies: whole orders or single families, the ones this name list '
      'holds. This only takes names away, it never adds any. Every animal is then named within '
      'the ticked groups, also an animal of another group, because the model has no other names '
      'to choose from: use it only when other animals do not matter for your question. Whether '
      'it names animals better is not tested yet.';
  static const _bothHelp =
      'With countries and groups together, a name must be listed for the countries and belong to '
      'a ticked group.';
  static const _compareHelp =
      'Results made with different choices cannot be compared directly: a shorter list shares the '
      'same 100 % among fewer names, so its percentages are higher.';

  NameListChoice _choice({bool withTaxa = true}) =>
      nameListForSettings(prefs.toJson(), regions, packNames: packNames, sessionCountry: sessionCountry, taxa: withTaxa ? taxa : null);

  @override
  Widget build(BuildContext context) {
    final choice = _choice();
    final all = thousands(packNames);
    final sentence = _used(choice, all);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HelpLabel(
          label: 'Names to choose from',
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperText: [
            if (regions != null) _countriesHelp,
            if (taxa != null) _taxaHelp,
            if (regions != null && taxa != null) _bothHelp,
            _compareHelp,
          ].join(' '),
        ),
        if (regions case final lists?) ..._countryBoxes(context, lists),
        if (taxa case final groups?) ...[const SizedBox(height: 8), _taxaBox(context, groups)],
        // No name in both choices: nothing narrows, which the user has to see.
        if (choice.wholeListReason == kWholeNoCommonNames)
          _warning(sentence)
        else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(sentence, style: helperTextStyle),
          ),
        if (onShowNames case final show?)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('show names'),
              onPressed: () {
                final names = _namesInWords(choice, all);
                show(choice, '${names[0].toUpperCase()}${names.substring(1)}.');
              },
              icon: const Icon(Icons.list, size: 18),
              label: const Text('Show these names'),
            ),
          ),
        if (choice.shortList)
          _warning(
            'Only ${thousands(choice.countryNames)} names${choice.taxa.isEmpty ? '' : ' in all orders and families'}. '
            'GBIF holds few records from '
            '${choice.countries.length == 1 ? countryName(choice.countries.first) : 'these countries'}, so species that '
            'live there are probably missing from this list, and the model then has to pick a wrong name. '
            '${switch (prefs.nameListScope) {
              kScopeCountry => '"The country and its neighbours" or "The whole name list" is',
              kScopeCountries => 'More countries, or "The whole name list", is',
              _ => '"The whole name list" is',
            }} '
            'safer.',
          ),
        if (choice.lowCoverage) _warning(_lowCoverage(choice.lowCoverageCountries)),
        if (choice.taxa.isNotEmpty)
          _warning(
            'Every animal will be named as one of ${taxaInWords(choice.taxa)}. '
            'This forces the model to pick a name from these groups, even for an animal of another group.',
          ),
      ],
    );
  }

  /// "Orders and families": a window with a search box, the families under their order.
  Widget _taxaBox(BuildContext context, PackTaxa groups) {
    final chosen = [for (final t in prefs.nameListChosenTaxa) if (groups.contains(t)) t];
    return InkWell(
      key: const ValueKey('name list taxa'),
      onTap: () async {
        // The numbers of names are those of the chosen countries: what ticking an entry gives.
        final n = groups.counts(_choice(withTaxa: false).rowBits);
        final familiesOf = [for (final _ in groups.orders) <int>[]];
        for (var f = 0; f < groups.families.length; f++) {
          familiesOf[groups.familyOrder[f]].add(f);
        }
        final picked = await showMultiPickDialog(
          context,
          title: 'Orders and families',
          searchHint: 'Search an order or a family',
          items: [
            for (var o = 0; o < groups.orders.length; o++) ...[
              PickItem(groups.orders[o], groups.orders[o], detail: 'Order, ${thousands(n.orders[o])} names'),
              for (final f in familiesOf[o])
                PickItem(
                  groups.families[f],
                  groups.families[f],
                  detail: 'Family of ${groups.orders[o]}, ${thousands(n.families[f])} names',
                  group: groups.orders[o],
                ),
            ],
          ],
          chosen: prefs.nameListChosenTaxa,
        );
        // Saved in alphabetical order: the same set is always the same saved value.
        if (picked != null && context.mounted) onEdit(() => prefs.nameListChosenTaxa = picked..sort());
      },
      child: InputDecorator(
        decoration: const InputDecoration(labelText: 'Orders and families', suffixIcon: Icon(Icons.arrow_drop_down)),
        child: Text(chosen.isEmpty ? 'All' : chosen.join(', '), maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  /// "Names from" and the country, or the countries chosen by hand.
  List<Widget> _countryBoxes(BuildContext context, PackRegions regions) {
    final codes = regions.countries.keys.toList()..sort((a, b) => countryName(a).compareTo(countryName(b)));
    String withNames(String c) => '${countryName(c)} (${thousands(PackRegions.countRows(regions.countries[c]!.bits))} names)';
    final wholeList = prefs.nameListScope == kScopeAll;
    final byHand = prefs.nameListScope == kScopeCountries;
    // The chosen countries this list knows, by name (the others add nothing to a run).
    final chosen = [for (final c in codes) if (prefs.nameListChosenCountries.contains(c)) c];
    return [
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
              items: [for (final c in codes) PickItem(c, withNames(c), searchText: countrySearchText(c))],
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
        // Round 382: typing narrows the countries (CountryField).
        CountryField(
          // The key shows a country that is no longer in the list as "the session's" one.
          key: ValueKey('name list country ${prefs.nameListCountry} $wholeList'),
          value: regions.countries.containsKey(prefs.nameListCountry) ? prefs.nameListCountry : '',
          codes: codes,
          labelOf: withNames,
          label: 'Country',
          helperText: wholeList ? 'Not used with the whole name list.' : null,
          extra: [
            (
              '',
              sessionCountry == null
                  ? 'Where the session was recorded'
                  : 'Where the session was recorded (${countryName(sessionCountry!)})',
            ),
          ],
          // Greyed with the whole list; the stored country stays for the next change.
          onChanged: wholeList ? null : (v) => onEdit(() => prefs.nameListCountry = v),
        ),
    ];
  }

  /// The warning for the countries this name list was not made for (it holds a small share
  /// of their own GBIF lists).
  String _lowCoverage(List<String> low) {
    String share(String c) => '${((regions?.countries[c]?.coverage ?? 0) * 100).round()} of 100';
    if (low.length == 1) {
      // Round 379: the lists for the other continents; the one on the phone that holds the most
      // names of that country, or where to get one.
      final better = listWithMoreNamesOf?.call(low.first);
      return 'This name list holds only ${share(low.first)} species that GBIF lists for ${countryName(low.first)}: it was '
          'made for another region, so many species of that country cannot be named with it. '
          '${better == null ? 'Download & import models offers name lists for other parts of the world.' : 'The name list ${better.file} on this phone holds ${thousands(better.names)} of them: choose it under "Name list" above.'}';
    }
    final named = [for (final c in low.take(4)) '${countryName(c)} (${share(c)})'].join(', ');
    return 'This name list holds only a part of the species that GBIF lists for $named'
        '${low.length > 4 ? ' and ${low.length - 4} more of the chosen countries' : ''}: it was made for another '
        'region, so many species of these countries cannot be named with it.';
  }

  /// The names on offer in words: "the 8,405 names of Apidae listed for Germany and its 10
  /// neighbours (of 34,978 in the list)", "all 34,978 names". For the sentence below and for
  /// the page that lists them.
  static String _namesInWords(NameListChoice c, String all) {
    final groups = c.taxa.isEmpty ? null : taxaInWords(c.taxa);
    if (c.countries.isEmpty) {
      return groups == null ? 'all $all names' : 'the ${thousands(c.names)} names of $groups (of $all in the list)';
    }
    final where = countriesInWords(c.countries, scope: c.scope);
    return 'the ${thousands(c.names)} names of ${groups == null ? where : '$groups listed for $where'} (of $all in the list)';
  }

  /// One sentence on the names a run will choose from. Every form holds "run chooses among"
  /// (the device check finds the sentence by it).
  static String _used(NameListChoice c, String all) {
    final names = _namesInWords(c, all);
    if (c.countries.isNotEmpty) return 'A run chooses among $names.';
    // No country narrows: every name, or those of the chosen orders and families.
    final country = c.country == null ? null : countryName(c.country!);
    if (c.wholeListReason == kWholeNoCommonNames) {
      return 'No name of the chosen orders and families is listed for the chosen countries, so a run chooses among '
          'all $all names. Change one of the two choices.';
    }
    if (c.scope == kScopeCountries && c.wholeListReason != null) {
      return c.wholeListReason == kWholeNoCountry
          ? 'No country is chosen yet, so a run chooses among $names. Tap "Countries" above to choose.'
          : 'This name list has no names for the chosen countries, so a run chooses among $names.';
    }
    return switch (c.wholeListReason) {
      kWholeNoCountry =>
        'The country of this session is not known (it has no position, or one far from land), so a run '
            'chooses among $names. Choose a country above to narrow them.',
      kWholeNotInList => 'This name list has no names for $country, so a run chooses among $names.',
      kWholeShortList =>
        'GBIF holds few records from $country and its neighbours (a short list misses many species), so a run '
            'chooses among $names. To use the short list anyway, choose $country above.',
      _ => 'A run chooses among $names.',
    };
  }

  static Widget _warning(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text('⚠ $text', style: const TextStyle(color: Colors.amber, fontSize: 13)),
  );
}
