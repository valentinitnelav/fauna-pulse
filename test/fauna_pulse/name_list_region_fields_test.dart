// Round 373: "Names to choose from" on Identify organisms (name_list_region_fields.dart) on a
// 360-px phone: each control changes one stored setting, the page says which names a run will
// use and why, and warns about a short list or a list made for another region. Round 376:
// countries chosen by hand in a window with a search box. Round 377: orders and families
// chosen by hand, in the same kind of window with the families under their order. Round 378:
// "Show these names" hands over the names a run would choose from, to be listed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/country_field.dart';
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

/// The search box of the window (the country box on the page is a text field too, r382).
final _windowSearch = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

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

  // The 7,994 names in two orders: Diptera = rows 0 .. 4,999 (Syrphidae rows 0 .. 49, then
  // Muscidae), Hymenoptera = the others (Apidae rows 5,000 .. 5,099, then Formicidae); the six
  // last rows are "none of these".
  final groups = PackTaxa.of([
    for (var r = 0; r < _rows; r++)
      r >= _rows - 6
          ? const LabelRow(['none', '', '', '', '', '', 'flower'], '')
          : LabelRow(['Animalia', 'Arthropoda', 'Insecta', r < 5000 ? 'Diptera' : 'Hymenoptera', r < 50 ? 'Syrphidae' : r < 5000 ? 'Muscidae' : r < 5100 ? 'Apidae' : 'Formicidae', 'G', 's$r'], ''),
  ]);

  // What "Show these names" hands over: the choice and the sentence that says which names.
  final shown = <(NameListChoice, String)>[];
  Future<void> pump(
    WidgetTester tester,
    IdentifyPrefs prefs, {
    String? sessionCountry,
    PackTaxa? taxa,
    bool countryLists = true,
    bool namesButton = true,
    ({String file, int names})? Function(String country)? moreNamesOf,
  }) async {
    shown.clear();
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
                  regions: countryLists ? regions : null,
                  taxa: taxa,
                  packNames: _rows - 6,
                  sessionCountry: sessionCountry,
                  onEdit: (change) => setState(change),
                  onShowNames: namesButton ? (choice, listed) => shown.add((choice, listed)) : null,
                  listWithMoreNamesOf: moreNamesOf,
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
    expect(find.text('Names to choose from'), findsOneWidget);
    expect(find.text('The country and its neighbours'), findsOneWidget);
    expect(find.text('Where the session was recorded'), findsOneWidget);
    expect(
      find.textContaining('The country of this session is not known (it has no position, or one far from land), so a run chooses among all 7,994 names.'),
      findsOneWidget,
    );
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
    expect(tester.widget<CountryField>(find.byKey(const ValueKey('name list country IS true'))).onChanged, isNull);
  });

  testWidgets('typing in the country box narrows the countries (r382)', (tester) async {
    final prefs = IdentifyPrefs(nameListScope: kScopeCountry);
    await pump(tester, prefs, sessionCountry: 'DE');
    final box = find.descendant(of: find.byKey(const ValueKey('name list country  false')), matching: find.byType(TextField));
    await tester.tap(box);
    await tester.pumpAndSettle();
    await tester.enterText(box, 'ICE');
    await tester.pumpAndSettle();
    expect(find.text('Iceland (100 names)'), findsWidgets);
    expect(find.text('Austria (5,200 names)'), findsNothing);
    await tester.tap(find.text('Iceland (100 names)').last);
    await tester.pumpAndSettle();
    expect(prefs.nameListCountry, 'IS');
  });

  testWidgets('a tap empties the country box, so typed letters do not mix into the choice', (tester) async {
    final prefs = IdentifyPrefs(nameListScope: kScopeCountry);
    await pump(tester, prefs, sessionCountry: 'DE');
    final box = find.descendant(of: find.byKey(const ValueKey('name list country  false')), matching: find.byType(TextField));
    String text() => tester.widget<TextField>(box).controller!.text;
    expect(text(), 'Where the session was recorded (Germany)');
    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(text(), isEmpty, reason: 'typing starts in an empty box (it mixed into the text on a phone)');
    // Typed, then a tap outside the box and its menu without a choice: the box loses the focus
    // (phones keep it by default), the choice shows again and nothing is saved.
    await tester.enterText(box, 'ICE');
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(350, 770));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<CountryField>(), isNull);
    expect(text(), 'Where the session was recorded (Germany)');
    expect(prefs.nameListCountry, isNot('IS'));
  });

  testWidgets('the country list opens above the keyboard', (tester) async {
    // The menu did not move when the keyboard came up after it opened, so on a Redmi Note 9S
    // (box low on the page) the matching countries stayed under the keyboard.
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          const SizedBox(height: 350),
          CountryField(value: 'DE', codes: const ['AT', 'BE', 'DE', 'FR', 'IT'], label: 'Country', onChanged: (_) {}),
        ]),
      ),
    ));
    // As on the phone: the menu is open before the keyboard comes up.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final entries = find.byType(MenuItemButton).hitTestable();
    expect(entries, findsWidgets);
    for (final e in entries.evaluate()) {
      expect(tester.getRect(find.byWidget(e.widget)).bottom, lessThanOrEqualTo(780 - 300));
    }
  });

  group('round 387: the box on a page that keeps it after a pick', () {
    // As on "What do you want to watch?": the page passes the new value to the same widget
    // (Identify organisms builds a new one). Opened from a first page, so Back can leave it.
    String value = '';
    // What the page's own Back guard heard (Identify organisms asks there before it stops a run).
    final refused = <bool>[];
    Future<Finder> open(WidgetTester tester) async {
      value = '';
      refused.clear();
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => PopScope(
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop) refused.add(true);
                },
                child: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => Column(children: [
                    const SizedBox(height: 300),
                    CountryField(
                      value: value,
                      codes: const ['DZ', 'DE', 'IT', 'NE', 'TR'],
                      label: 'Your country',
                      extra: [if (value.isEmpty) ('', 'Not known')],
                      onChanged: (v) => setState(() => value = v),
                    ),
                  ]),
                ),
                ),
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return find.descendant(of: find.byType(CountryField), matching: find.byType(TextField));
    }

    bool focused() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<CountryField>() != null;

    testWidgets('a pick takes the focus away, so the next tap empties the box again', (tester) async {
      final box = await open(tester);
      String text() => tester.widget<TextField>(box).controller!.text;
      await tester.tap(box);
      await tester.pumpAndSettle();
      await tester.enterText(box, 'Ita');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Italy').last);
      await tester.pumpAndSettle();
      expect(value, 'IT');
      expect(focused(), isFalse, reason: 'on a Samsung M12 the box kept the focus after a pick');
      expect(text(), 'Italy');
      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(text(), isEmpty, reason: 'typed letters went after "Germany" ("GermanyFra")');
    });

    testWidgets('Done picks the best match, also one found by another name', (tester) async {
      final box = await open(tester);
      await tester.tap(box);
      await tester.pumpAndSettle();
      await tester.enterText(box, 'Ger');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(value, 'DE', reason: 'Algeria came first, alphabetically');
      await tester.tap(box);
      await tester.pumpAndSettle();
      await tester.enterText(box, 'Turkey');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(value, 'TR');
    });

    testWidgets('Back closes the list first, as a tap outside does', (tester) async {
      final box = await open(tester);
      await tester.tap(box);
      await tester.pumpAndSettle();
      await tester.enterText(box, 'Ita');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CountryField), findsOneWidget, reason: 'the page stays');
      expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
      expect(focused(), isFalse);
      expect(tester.widget<TextField>(box).controller!.text, 'Not known');
      expect(value, isEmpty);
      expect(refused, isEmpty, reason: 'Identify organisms asked to stop a run that was not running');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CountryField), findsNothing);
    });

    testWidgets('drawn like the other dropdowns: an underline, no frame', (tester) async {
      final box = await open(tester);
      final decorator = find.descendant(of: find.byType(CountryField), matching: find.byType(InputDecorator));
      expect(tester.widget<InputDecorator>(decorator.first).decoration.border, isNot(isA<OutlineInputBorder>()));
      expect(box, findsOneWidget);
    });
  });

  testWidgets('a name list made for another region: the coverage warning', (tester) async {
    await pump(tester, IdentifyPrefs(nameListCountry: 'US'));
    expect(find.textContaining('⚠ This name list holds only 14 of 100 species that GBIF lists for United States'), findsOneWidget);
    expect(find.textContaining('Only 5,500 names'), findsNothing);
    expect(find.textContaining('Download & import models offers name lists for other parts of the world.'), findsOneWidget);
  });

  testWidgets('round 379: the warning names a list on the phone that holds more of the country\'s names', (tester) async {
    await pump(
      tester,
      IdentifyPrefs(nameListCountry: 'US'),
      moreNamesOf: (c) => c == 'US' ? (file: 'bioclip-2_pollinator-orders-north-america_v1.fpack', names: 41000) : null,
    );
    expect(
      find.textContaining(
        'The name list bioclip-2_pollinator-orders-north-america_v1.fpack on this phone holds 41,000 of them: choose it under "Name list" above.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Download & import models offers'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the default never uses a short list: the whole list and the reason', (tester) async {
    await pump(tester, IdentifyPrefs(), sessionCountry: 'IS');
    expect(
      find.textContaining('GBIF holds few records from Iceland and its neighbours (a short list misses many species), so a run chooses among all 7,994 names.'),
      findsOneWidget,
    );
    expect(find.textContaining('⚠'), findsNothing);
  });

  group('round 376: countries chosen by hand', () {
    Future<void> openWindow(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('name list countries')));
      await tester.pumpAndSettle();
    }

    testWidgets('ticked in a window with a search box; one setting is written, on "Use these" only', (tester) async {
      final prefs = IdentifyPrefs(nameListCountry: 'IS');
      await pump(tester, prefs, sessionCountry: 'DE');
      await choose(tester, 'name list scope', 'Countries I choose');
      expect(prefs.nameListScope, kScopeCountries);
      expect(prefs.nameListChosenCountries, isEmpty);
      expect(prefs.nameListCountry, 'IS', reason: 'the single country keeps its value');
      expect(find.text('None yet: tap to choose'), findsOneWidget);
      expect(find.text('No country is chosen yet, so a run chooses among all 7,994 names. Tap "Countries" above to choose.'), findsOneWidget);
      expect(find.byType(CountryField), findsNothing, reason: 'the single-country box is replaced');

      // Every country of the list is offered, by name with its number of names.
      await openWindow(tester);
      expect(find.widgetWithText(AlertDialog, 'Countries'), findsOneWidget);
      expect(find.text('0 ticked'), findsOneWidget);
      expect(find.text('Austria (5,200 names)'), findsOneWidget);
      expect(find.textContaining('South Georgia and the South Sandwich Islands'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The search narrows the entries, whatever the case of the letters.
      await tester.enterText(_windowSearch, 'LAND');
      await tester.pump();
      expect(find.text('Iceland (100 names)'), findsOneWidget);
      expect(find.text('Austria (5,200 names)'), findsNothing);
      await tester.tap(find.text('Iceland (100 names)'));
      await tester.pump();
      expect(find.text('1 ticked'), findsOneWidget);
      await tester.enterText(_windowSearch, 'xyz');
      await tester.pump();
      expect(find.text('Nothing found.'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear the search'));
      await tester.pump();
      await tester.tap(find.text('Austria (5,200 names)'));
      await tester.pump();
      expect(find.text('2 ticked'), findsOneWidget);
      expect(prefs.nameListChosenCountries, isEmpty, reason: 'nothing is saved before "Use these"');
      await tester.tap(find.text('Use these'));
      await tester.pumpAndSettle();
      expect(prefs.nameListChosenCountries, ['AT', 'IS']);
      expect(prefs.nameListScope, kScopeCountries);
      expect(find.text('Austria, Iceland'), findsOneWidget);
      expect(find.text('A run chooses among the 5,300 names of Austria and Iceland (of 7,994 in the list).'), findsOneWidget);
      expect(find.textContaining('⚠'), findsNothing);

      // Cancel and the X change nothing; the window opens with the saved countries ticked.
      await openWindow(tester);
      expect(find.text('2 ticked'), findsOneWidget);
      await tester.tap(find.text('Untick all'));
      await tester.pump();
      expect(find.text('0 ticked'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(prefs.nameListChosenCountries, ['AT', 'IS']);
      await openWindow(tester);
      await tester.tap(find.text('Germany (6,000 names)'));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(prefs.nameListChosenCountries, ['AT', 'IS']);
    });

    testWidgets('a short list and a list made for another region are warned about, as for one country', (tester) async {
      await pump(tester, IdentifyPrefs(nameListScope: kScopeCountries, nameListChosenCountries: ['GS', 'IS']));
      expect(find.text('A run chooses among the 150 names of South Georgia and the South Sandwich Islands and Iceland (of 7,994 in the list).'), findsOneWidget);
      expect(find.textContaining('⚠ Only 150 names. GBIF holds few records from these countries'), findsOneWidget);
      expect(find.textContaining('More countries, or "The whole name list", is safer.'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await pump(tester, IdentifyPrefs(nameListScope: kScopeCountries, nameListChosenCountries: ['DE', 'US']));
      expect(find.textContaining('Only '), findsNothing);
      expect(find.textContaining('⚠ This name list holds only 14 of 100 species that GBIF lists for United States'), findsOneWidget);
    });

    testWidgets('chosen countries this name list does not know are not used and not shown', (tester) async {
      await pump(tester, IdentifyPrefs(nameListScope: kScopeCountries, nameListChosenCountries: ['XX', 'YY']));
      expect(find.text('None yet: tap to choose'), findsOneWidget);
      expect(find.text('This name list has no names for the chosen countries, so a run chooses among all 7,994 names.'), findsOneWidget);
      await pump(tester, IdentifyPrefs(nameListScope: kScopeCountries, nameListChosenCountries: ['DE', 'XX']));
      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('A run chooses among the 6,000 names of Germany only (of 7,994 in the list).'), findsOneWidget);
    });

    testWidgets('the window fits a 360-px phone with the keyboard open', (tester) async {
      await pump(tester, IdentifyPrefs(nameListScope: kScopeCountries));
      await openWindow(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.showKeyboard(_windowSearch);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Use these'), findsOneWidget);
      expect(tester.getBottomLeft(find.text('Use these')).dy, lessThanOrEqualTo(780 - 320));
      expect(tester.getSize(find.byType(ListView)).height, greaterThan(60), reason: 'entries stay in view above the keyboard');
    });
  });

  group('round 377: orders and families chosen by hand', () {
    Future<void> openWindow(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('name list taxa')));
      await tester.pumpAndSettle();
    }

    CheckboxListTile tile(WidgetTester tester, String label) => tester.widget(find.widgetWithText(CheckboxListTile, label));

    testWidgets('ticked in a window, the families under their order; one setting is written', (tester) async {
      final prefs = IdentifyPrefs();
      await pump(tester, prefs, sessionCountry: 'DE', taxa: groups);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('A run chooses among the 6,000 names of Germany and its neighbour (of 7,994 in the list).'), findsOneWidget);
      expect(find.textContaining('⚠'), findsNothing);

      // Each entry with its number of names among the countries' names (rows 0 .. 5,999).
      await openWindow(tester);
      expect(find.widgetWithText(AlertDialog, 'Orders and families'), findsOneWidget);
      expect(find.text('Order, 5,000 names'), findsOneWidget);
      expect(find.text('Family of Diptera, 50 names'), findsOneWidget);
      expect(find.text('Order, 1,000 names'), findsOneWidget);
      expect(find.text('Family of Hymenoptera, 900 names'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // A family, then a whole order: its families show ticked and cannot be changed.
      await tester.tap(find.text('Apidae'));
      await tester.tap(find.text('Diptera'));
      await tester.pump();
      expect(find.text('2 ticked'), findsOneWidget);
      expect(tile(tester, 'Syrphidae').value, isTrue);
      expect(tile(tester, 'Syrphidae').onChanged, isNull);
      expect(tile(tester, 'Formicidae').value, isFalse);
      expect(prefs.nameListChosenTaxa, isEmpty, reason: 'nothing is saved before "Use these"');
      await tester.tap(find.text('Use these'));
      await tester.pumpAndSettle();
      expect(prefs.nameListChosenTaxa, ['Apidae', 'Diptera']);
      expect(prefs.nameListScope, kScopeNeighbours, reason: 'the countries keep their settings');
      expect(find.text('Apidae, Diptera'), findsOneWidget);
      expect(find.text('A run chooses among the 5,100 names of Apidae and Diptera listed for Germany and its neighbour (of 7,994 in the list).'), findsOneWidget);
      expect(
        find.text('⚠ Every animal will be named as one of Apidae and Diptera. This forces the model to pick a name from these groups, even for an animal of another group.'),
        findsOneWidget,
      );

      // Ticking the order of a ticked family: the order then stands for it.
      await openWindow(tester);
      expect(find.text('2 ticked'), findsOneWidget);
      await tester.tap(find.text('Hymenoptera'));
      await tester.pump();
      expect(find.text('2 ticked'), findsOneWidget);
      expect(tile(tester, 'Apidae').onChanged, isNull);
      // The search shows orders and families that match, whatever the case of the letters.
      await tester.enterText(_windowSearch, 'MICI');
      await tester.pump();
      expect(find.text('Formicidae'), findsOneWidget);
      expect(find.text('Diptera'), findsNothing);
      await tester.tap(find.text('Use these'));
      await tester.pumpAndSettle();
      expect(prefs.nameListChosenTaxa, ['Diptera', 'Hymenoptera']);

      // Nothing ticked is every order and family again.
      await openWindow(tester);
      await tester.tap(find.text('Untick all'));
      await tester.tap(find.text('Use these'));
      await tester.pumpAndSettle();
      expect(prefs.nameListChosenTaxa, isEmpty);
      expect(find.text('All'), findsOneWidget);
      expect(find.textContaining('⚠'), findsNothing);
    });

    testWidgets('a name list without country lists has only this choice', (tester) async {
      final prefs = IdentifyPrefs(nameListChosenTaxa: ['Syrphidae', 'Felidae']);
      await pump(tester, prefs, taxa: groups, countryLists: false);
      expect(find.text('Names to choose from'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('Syrphidae'), findsOneWidget, reason: 'a name this list does not have is not shown');
      expect(find.text('A run chooses among the 50 names of Syrphidae (of 7,994 in the list).'), findsOneWidget);
      // The numbers in the window are the whole list's.
      await openWindow(tester);
      expect(find.text('Order, 2,994 names'), findsOneWidget);
      expect(tile(tester, 'Syrphidae').value, isTrue);
      expect(find.text('1 ticked'), findsOneWidget);
    });

    testWidgets('no name in both choices: said in amber, nothing narrows', (tester) async {
      // Iceland lists the rows 7,000 .. 7,099, all Formicidae.
      await pump(tester, IdentifyPrefs(nameListCountry: 'IS', nameListChosenTaxa: ['Syrphidae']), taxa: groups);
      expect(
        find.text('⚠ No name of the chosen orders and families is listed for the chosen countries, so a run chooses among all 7,994 names. Change one of the two choices.'),
        findsOneWidget,
      );
      expect(find.textContaining('Every animal'), findsNothing);
    });

    testWidgets('a short country list is judged before the orders and families', (tester) async {
      await pump(tester, IdentifyPrefs(nameListCountry: 'IS', nameListChosenTaxa: ['Formicidae']), taxa: groups);
      expect(find.text('A run chooses among the 100 names of Formicidae listed for Iceland only (of 7,994 in the list).'), findsOneWidget);
      expect(find.textContaining('⚠ Only 100 names in all orders and families. GBIF holds few records from Iceland'), findsOneWidget);
      // Few names of a family in a well recorded country are no reason to warn.
      await pump(tester, IdentifyPrefs(nameListCountry: 'DE', nameListScope: kScopeCountry, nameListChosenTaxa: ['Syrphidae']), taxa: groups);
      expect(find.text('A run chooses among the 50 names of Syrphidae listed for Germany only (of 7,994 in the list).'), findsOneWidget);
      expect(find.textContaining('Only '), findsNothing);
      // Where the whole list is used for a reason, the orders and families still narrow.
      await pump(tester, IdentifyPrefs(nameListChosenTaxa: ['Apidae']), taxa: groups);
      expect(
        find.text(
          'The country of this session is not known (it has no position, or one far from land), so a run chooses among '
          'the 100 names of Apidae (of 7,994 in the list). Choose a country above to narrow them.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the window fits a 360-px phone with the keyboard open', (tester) async {
      await pump(tester, IdentifyPrefs(), taxa: groups);
      await openWindow(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.showKeyboard(_windowSearch);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getBottomLeft(find.text('Use these')).dy, lessThanOrEqualTo(780 - 320));
      expect(tester.getSize(find.byType(ListView)).height, greaterThan(60), reason: 'entries stay in view above the keyboard');
    });

    test('taxaInWords', () {
      expect(taxaInWords(const ['Apidae']), 'Apidae');
      expect(taxaInWords(const ['Apidae', 'Diptera']), 'Apidae and Diptera');
      expect(taxaInWords(const ['Apidae', 'Diptera', 'Vespidae']), 'Apidae, Diptera and Vespidae');
      expect(taxaInWords(const ['A', 'B', 'C', 'D', 'E']), 'A, B and 3 more orders or families');
    });
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
    expect(choice.packTaxa!.families, ['Apidae', 'Syrphidae', 'Thomisidae']);
    choice.selectPack(plain);
    expect(choice.packRegions, isNull);
    expect(choice.packTaxa!.orders, ['Araneae', 'Diptera', 'Hymenoptera'], reason: 'round 377: every name list has orders and families');
    choice.selectPack(classes);
    expect(choice.packRegions, isNull);
    expect(choice.packTaxa, isNull, reason: 'a class list is never narrowed');
  });

  group('round 378: "Show these names"', () {
    Future<void> tapShow(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Show these names'));
      await tester.tap(find.text('Show these names'));
      await tester.pump();
    }

    testWidgets('hands over the rows a run would choose from and says which names they are', (tester) async {
      // Countries and groups together: Apidae (rows 5,000 .. 5,099) and Diptera (0 .. 4,999)
      // among the names of Germany and Austria (rows 0 .. 5,999).
      await pump(tester, IdentifyPrefs(nameListChosenTaxa: ['Apidae', 'Diptera']), sessionCountry: 'DE', taxa: groups);
      await tapShow(tester);
      expect(shown.single.$2, 'The 5,100 names of Apidae and Diptera listed for Germany and its neighbour (of 7,994 in the list).');
      final bits = shown.single.$1.rowBits!;
      expect(PackRegions.countRows(bits), 5100);
      expect(PackRegions.hasRow(bits, 5099), isTrue);
      expect(PackRegions.hasRow(bits, 5100), isFalse, reason: 'Formicidae is not ticked');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a family on the whole list, whatever the country', (tester) async {
      await pump(tester, IdentifyPrefs(nameListScope: kScopeAll, nameListChosenTaxa: ['Apidae']), sessionCountry: 'IS', taxa: groups);
      expect(find.text('A run chooses among the 100 names of Apidae (of 7,994 in the list).'), findsOneWidget);
      await tapShow(tester);
      expect(shown.single.$2, 'The 100 names of Apidae (of 7,994 in the list).');
      expect(PackRegions.countRows(shown.single.$1.rowBits!), 100);
    });

    testWidgets('nothing chosen, or no name in both choices: every name', (tester) async {
      await pump(tester, IdentifyPrefs(nameListScope: kScopeAll), taxa: groups);
      await tapShow(tester);
      expect(shown.single.$2, 'All 7,994 names.');
      expect(shown.single.$1.rowBits, isNull);
      // Iceland lists the rows 7,000 .. 7,099, all Formicidae: no Syrphidae among them.
      await pump(tester, IdentifyPrefs(nameListScope: kScopeCountry, nameListCountry: 'IS', nameListChosenTaxa: ['Syrphidae']), taxa: groups);
      expect(find.textContaining('⚠ No name of the chosen orders and families is listed for the chosen countries'), findsOneWidget);
      await tapShow(tester);
      expect(shown.single.$2, 'All 7,994 names.');
      expect(shown.single.$1.rowBits, isNull);
    });

    testWidgets('no button where the names cannot be listed', (tester) async {
      await pump(tester, IdentifyPrefs(), taxa: groups, namesButton: false);
      expect(find.text('Show these names'), findsNothing);
    });
  });

  test('countriesInWords', () {
    expect(countriesInWords(const [], scope: kScopeAll), 'the whole name list');
    expect(countriesInWords(const ['DE'], scope: kScopeNeighbours), 'Germany only');
    expect(countriesInWords(const ['MT', 'IT'], scope: kScopeNeighbours), 'Malta and its neighbour');
    expect(countriesInWords(const ['DE', 'AT', 'BE'], scope: kScopeNeighbours), 'Germany and its 2 neighbours');
    expect(countriesInWords(const ['XX'], scope: kScopeCountry), 'XX only', reason: 'an unknown code is shown as it is');
    // Chosen by hand: named, up to three.
    expect(countriesInWords(const ['DE'], scope: kScopeCountries), 'Germany only');
    expect(countriesInWords(const ['AT', 'DE'], scope: kScopeCountries), 'Austria and Germany');
    expect(countriesInWords(const ['AT', 'DE', 'MT'], scope: kScopeCountries), 'Austria, Germany and Malta');
    expect(countriesInWords(const ['AT', 'DE', 'IS', 'MT', 'US'], scope: kScopeCountries), 'Austria, Germany and 3 more countries');
  });
}
