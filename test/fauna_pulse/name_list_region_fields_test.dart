// Round 373: "Names of one country" on Identify organisms (name_list_region_fields.dart) on a
// 360-px phone: each control changes one stored setting, the page says which names a run will
// use and why, and warns about a short list or a list made for another region.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_choice.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/identification/name_list_region.dart';
import 'package:fauna_pulse/fauna_pulse/screens/name_list_region_fields.dart';

const _rows = 8000;

String _bits(int from, int to) {
  final b = Uint8List((_rows + 7) ~/ 8);
  for (var r = from; r < to; r++) {
    b[r >> 3] |= 1 << (r & 7);
  }
  return base64.encode(b);
}

void main() {
  // Germany 6,000 names with Austria next to it; Iceland 100 names and no neighbour; the pack
  // holds 14 of 100 species of the United States; one country with a very long name.
  final regions = PackRegions.tryParse({
    'countries': {
      'DE': {'rows': _bits(0, 6000), 'names': 6000, 'names_in_country': 6000},
      'AT': {'rows': _bits(100, 5300), 'names': 5200, 'names_in_country': 5200},
      'IS': {'rows': _bits(7000, 7100), 'names': 100, 'names_in_country': 100},
      'US': {'rows': _bits(0, 5500), 'names': 5500, 'names_in_country': 40000},
      'GS': {'rows': _bits(0, 50), 'names': 50, 'names_in_country': 50},
    },
    'neighbours': {
      'DE': ['AT'],
      'AT': ['DE'],
    },
  }, _rows)!;

  Future<void> pump(WidgetTester tester, IdentifyPrefs prefs, {String? sessionCountry}) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: StatefulBuilder(
                builder: (context, setState) => NameListRegionFields(
                  prefs: prefs,
                  regions: regions,
                  packNames: _rows - 6,
                  sessionCountry: sessionCountry,
                  onEdit: (change) => setState(change),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> choose(WidgetTester tester, String key, String item) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  testWidgets('no country known: the whole list, said in words; no overflow at 360 px', (tester) async {
    final prefs = IdentifyPrefs();
    await pump(tester, prefs);
    expect(find.text('Names of one country'), findsOneWidget);
    expect(find.text('The country and its neighbours'), findsOneWidget);
    expect(find.text('Where the session was recorded'), findsOneWidget);
    expect(find.textContaining('The country of this session is not known, so a run chooses among all 7,994 names.'), findsOneWidget);
    expect(find.textContaining('⚠'), findsNothing);
    // The open country list, with a very long country name, fits too.
    await tester.tap(find.byKey(const ValueKey('name list country  false')));
    await tester.pumpAndSettle();
    expect(find.text('Germany (6,000 names)'), findsOneWidget);
    expect(find.textContaining('South Georgia and the South Sandwich Islands'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the session\'s country with its neighbours is used by default', (tester) async {
    final prefs = IdentifyPrefs();
    await pump(tester, prefs, sessionCountry: 'DE');
    expect(find.text('Where the session was recorded (Germany)'), findsOneWidget);
    expect(find.text('A run chooses among the 6,000 names of Germany and its neighbour (of 7,994 in the list).'), findsOneWidget);
    expect(find.textContaining('⚠'), findsNothing);
  });

  testWidgets('each control changes one stored setting', (tester) async {
    final prefs = IdentifyPrefs();
    await pump(tester, prefs, sessionCountry: 'DE');
    await choose(tester, 'name list scope', 'The country only');
    expect(prefs.nameListScope, kScopeCountry);
    expect(prefs.nameListCountry, '');
    expect(find.text('A run chooses among the 6,000 names of Germany only (of 7,994 in the list).'), findsOneWidget);

    await choose(tester, 'name list country  false', 'Iceland (100 names)');
    expect(prefs.nameListCountry, 'IS');
    expect(prefs.nameListScope, kScopeCountry);
    expect(find.text('A run chooses among the 100 names of Iceland only (of 7,994 in the list).'), findsOneWidget);
    // A short list chosen by hand is kept, with a warning that names the safer choices.
    expect(find.textContaining('⚠ Only 100 names. GBIF holds few records from Iceland'), findsOneWidget);
    expect(find.textContaining('"The country and its neighbours" or "The whole name list" is safer.'), findsOneWidget);

    // The whole list: the country box is greyed and keeps its value (no second setting is written).
    await choose(tester, 'name list scope', 'The whole name list');
    expect(prefs.nameListScope, kScopeAll);
    expect(prefs.nameListCountry, 'IS');
    expect(find.text('A run chooses among all 7,994 names.'), findsOneWidget);
    expect(find.text('Not used with the whole name list.'), findsOneWidget);
    expect(find.textContaining('⚠'), findsNothing);
    expect(tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('name list country IS true'))).onChanged, isNull);
  });

  testWidgets('a name list made for another region: the coverage warning', (tester) async {
    await pump(tester, IdentifyPrefs(nameListCountry: 'US'));
    expect(find.textContaining('⚠ This name list holds only 14 of 100 species that GBIF lists for United States'), findsOneWidget);
    expect(find.textContaining('Only 5,500 names'), findsNothing);
  });

  testWidgets('the default never uses a short list: the whole list and the reason', (tester) async {
    await pump(tester, IdentifyPrefs(), sessionCountry: 'IS');
    expect(
      find.textContaining('GBIF holds few records from Iceland and its neighbours (a short list misses many species), so a run chooses among all 7,994 names.'),
      findsOneWidget,
    );
    expect(find.textContaining('⚠'), findsNothing);
  });

  test('the Identify page gets the country lists of the chosen name list, decoded once; other lists have none', () async {
    final withLists = File('test/fauna_pulse/fixtures/tiny_pack_regions.fpack');
    final plain = File('test/fauna_pulse/fixtures/tiny_pack.fpack'), classes = File('test/fauna_pulse/fixtures/tiny_classes.fpack');
    final choice = IdentificationChoice(
      packs: [withLists, plain, classes],
      headers: await IdentificationChoice.readHeaders([withLists, plain, classes]),
      pack: withLists,
    );
    final lists = choice.packRegions;
    expect(lists!.countries.keys, unorderedEquals(['AT', 'DE', 'MT']));
    expect(identical(choice.packRegions, lists), isTrue);
    choice.selectPack(plain);
    expect(choice.packRegions, isNull);
    choice.selectPack(classes);
    expect(choice.packRegions, isNull);
  });

  test('countriesInWords', () {
    expect(countriesInWords(const [], scope: kScopeAll), 'the whole name list');
    expect(countriesInWords(const ['DE'], scope: kScopeNeighbours), 'Germany only');
    expect(countriesInWords(const ['MT', 'IT'], scope: kScopeNeighbours), 'Malta and its neighbour');
    expect(countriesInWords(const ['DE', 'AT', 'BE'], scope: kScopeNeighbours), 'Germany and its 2 neighbours');
    expect(countriesInWords(const ['XX'], scope: kScopeCountry), 'XX only', reason: 'an unknown code is shown as it is');
  });
}
