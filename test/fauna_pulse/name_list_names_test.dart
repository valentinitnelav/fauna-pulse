// Round 378: the page "Names to choose from" (name_list_names_screen.dart) and what it is
// made of: the names of a name list read without its vectors (name_list_names.dart), the
// window of one name (name_actions.dart) and the web search (external_link.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/identification/name_list_names.dart';
import 'package:fauna_pulse/fauna_pulse/screens/name_list_names_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/external_link.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/home_button.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

// Five species (rows 0 .. 4) and one "none of these" row; the second file is a class list.
final _pack = File('test/fauna_pulse/fixtures/tiny_pack_regions.fpack');
final _classes = File('test/fauna_pulse/fixtures/tiny_classes.fpack');

/// A name list file of [n] species, written for a test (without vectors: `dim` is 0).
File _manyNames(Directory dir, int n) {
  final header = utf8.encode(
    jsonEncode({
      'pack_id': 'many',
      'model_id': 'fake',
      'dim': 0,
      'rows': n,
      'dtype': 'f16',
      'sink_rows': 0,
      'labels': [
        for (var i = 0; i < n; i++) ['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Genus', 's${'$i'.padLeft(3, '0')}', ''],
      ],
    }),
  );
  return File('${dir.path}/many.fpack')..writeAsBytesSync([
    ...'FPK1'.codeUnits,
    ...(ByteData(4)..setUint32(0, header.length, Endian.little)).buffer.asUint8List(),
    ...header,
  ]);
}

const _native = MethodChannel('faunapulse/keepalive');
const _launcher = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// What the app asked of the phone: web searches (native), web addresses (the browser) and
  /// copies. [searchAnswer]: whether an app of the phone takes the web search.
  final searched = <Object?>[], opened = <Object?>[], copied = <Object?>[];
  void phone({bool searchAnswer = true}) {
    searched.clear();
    opened.clear();
    copied.clear();
    messenger.setMockMethodCallHandler(_native, (call) async {
      if (call.method != 'webSearch') return null;
      searched.add((call.arguments as Map)['query']);
      return searchAnswer;
    });
    messenger.setMockMethodCallHandler(_launcher, (call) async {
      opened.add((call.arguments as Map?)?['url']);
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text']);
      return null;
    });
    addTearDown(() {
      for (final c in [_native, _launcher, SystemChannels.platform]) {
        messenger.setMockMethodCallHandler(c, null);
      }
    });
  }

  group('the names of a name list, read without its vectors', () {
    const sink = LabelRow(['none', '', '', '', '', '', 'flower'], 'a photo of a flower.');
    LabelRow row(String order, String family, String genus, String species, [String common = '']) =>
        LabelRow(['Animalia', 'Arthropoda', 'Insecta', order, family, genus, species], common);

    test('in alphabetical order, each with its family, its order and its common name', () {
      final list = nameEntriesOf([
        row('Hymenoptera', 'Apidae', 'Bombus', 'terrestris', 'Buff-tailed bumblebee'),
        sink,
        row('Diptera', 'Syrphidae', 'Eristalis', 'tenax'),
        row('Hymenoptera', 'Apidae', 'Apis', 'mellifera', 'Western honey bee'),
      ]);
      expect([for (final n in list.names) n.name], ['Apis mellifera', 'Bombus terrestris', 'Eristalis tenax']);
      expect([for (final n in list.names) n.detail], [
        'Apidae, Hymenoptera · Western honey bee',
        'Apidae, Hymenoptera · Buff-tailed bumblebee',
        'Syrphidae, Diptera',
      ]);
      expect(list.noneOfThese, ['flower'], reason: 'always on offer, so listed apart');
      expect(list.names.first.search, 'apis mellifera\napidae, hymenoptera · western honey bee');
    });

    test('a row that stops above the species is named by its last rank, which is said', () {
      final list = nameEntriesOf([
        row('Hymenoptera', 'Apidae', 'Bombus', ''),
        row('Hymenoptera', 'Apidae', '', ''),
        row('Coleoptera', '', '', ''),
        // A gap at the family: the name stays, with the order it belongs to.
        row('Diptera', '', 'Eristalis', 'tenax'),
        const LabelRow(['Animalia', '', '', '', '', '', ''], ''),
        const LabelRow(['', '', '', '', '', '', ''], ''),
      ]);
      expect([for (final n in list.names) '${n.name} | ${n.detail}'], [
        'Animalia | Kingdom',
        'Apidae | Family of Hymenoptera',
        'Bombus | Genus of Apidae, Hymenoptera',
        'Coleoptera | Order of Insecta',
        'Eristalis tenax | Diptera',
      ], reason: 'a row without any name is left out');
    });

    test('only the rows on offer; the "none of these" rows whatever the choice', () {
      final rows = [
        row('Diptera', 'Syrphidae', 'Eristalis', 'tenax'),
        row('Hymenoptera', 'Apidae', 'Apis', 'mellifera'),
        row('Hymenoptera', 'Apidae', 'Bombus', 'terrestris'),
        sink,
      ];
      final list = nameEntriesOf(rows, rowBits: Uint8List.fromList([0x0A])); // rows 1 and 3
      expect([for (final n in list.names) n.name], ['Apis mellifera']);
      expect(list.noneOfThese, ['flower']);
      // Bits that end before the last row offer none of the rows after them.
      expect(nameEntriesOf(rows, rowBits: Uint8List(0)).names, isEmpty);
    });

    test('from a file: a label pack and a class list, in a helper isolate', () async {
      expect(LabelPack.readLabelsSync(_pack).length, 6);
      final pack = await readNameListNames(_pack);
      expect([for (final n in pack.names) n.name], ['Apis mellifera', 'Bombus terrestris', 'Episyrphus balteatus', 'Eristalis tenax', 'Misumena vatia']);
      expect(pack.names[1].detail, 'Apidae, Hymenoptera · Buff-tailed bumblebee');
      expect(pack.noneOfThese, ['flower']);
      final narrowed = await readNameListNames(_pack, rowBits: Uint8List.fromList([0x0C])); // rows 2 and 3
      expect([for (final n in narrowed.names) n.name], ['Apis mellifera', 'Bombus terrestris']);
      final classes = await readNameListNames(_classes);
      expect([for (final n in classes.names) '${n.name} | ${n.detail}'], [
        'Apis mellifera | Apidae, Hymenoptera',
        'Eristalis tenax | Syrphidae, Diptera',
        'Syrphidae | Family of Diptera',
      ]);
      expect(classes.noneOfThese, ['Vegetation']);
    });

    test('a file that is not a name list is refused with a plain error', () async {
      final tmp = Directory.systemTemp.createTempSync('names_bad');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final bad = File('${tmp.path}/bad.fpack')..writeAsStringSync('not a pack');
      expect(() => LabelPack.readLabelsSync(bad), throwsFormatException);
      await expectLater(readNameListNames(bad), throwsFormatException);
      await expectLater(readNameListNames(File('${tmp.path}/missing.fpack')), throwsA(isA<FileSystemException>()));
    });
  });

  group('the web search', () {
    test('asks the phone for its own web search and opens no web address', () async {
      phone();
      await searchTheWeb('Bombus terrestris');
      expect(searched, ['Bombus terrestris']);
      expect(opened, isEmpty);
    });

    test('no app of the phone answers: the search opens as a web address', () async {
      phone(searchAnswer: false);
      await searchTheWeb('Bombus terrestris');
      expect(opened, ['https://duckduckgo.com/?q=Bombus+terrestris']);
    });
  });

  group('the page', () {
    /// Lets the helper isolate read the file: its work stands still on the test clock.
    Future<void> load(WidgetTester tester, Finder until) async {
      for (var i = 0; i < 100 && until.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(until, findsWidgets);
    }

    Future<void> pump(WidgetTester tester, {File? file, Uint8List? rowBits, String? intro}) async {
      simulateBottomSystemBar(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: NameListNamesScreen(packFile: file ?? _pack, rowBits: rowBits, intro: intro),
        ),
      );
    }

    List<String> names(WidgetTester tester) => [
      for (final t in tester.widgetList<ListTile>(find.byType(ListTile))) (t.title! as Text).data!,
    ];

    testWidgets('every name of a list on a 360-px phone, the last one above the system bar', (tester) async {
      await pump(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await load(tester, find.text('Apis mellifera'));
      expect(tester.takeException(), isNull);
      expect(find.text('Names to choose from'), findsOneWidget);
      expect(find.byType(HomeButton), findsOneWidget);
      expect(find.text('Every name of this name list.'), findsOneWidget);
      expect(find.text('tiny_pack_regions.fpack'), findsOneWidget);
      expect(find.text('Always among the choices too, for a box that shows no organism: flower.'), findsOneWidget);
      expect(find.text('Tap a name to search the web for it or to copy it.'), findsOneWidget);
      expect(find.text('5 names, in alphabetical order'), findsOneWidget);
      expect(names(tester), ['Apis mellifera', 'Bombus terrestris', 'Episyrphus balteatus', 'Eristalis tenax', 'Misumena vatia']);
      expect(find.text('Apidae, Hymenoptera · Buff-tailed bumblebee'), findsOneWidget);
      expectAboveBottomInset(tester, find.text('Thomisidae, Araneae · Goldenrod crab spider'));
    });

    testWidgets('a long list scrolls to its last name, which stays above the system bar', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('names_many');
      addTearDown(() => tmp.deleteSync(recursive: true));
      await pump(tester, file: _manyNames(tmp, 60));
      await load(tester, find.text('Genus s000'));
      expect(find.text('60 names, in alphabetical order'), findsOneWidget);
      await tester.dragUntilVisible(find.text('Genus s059'), find.byType(ListView), const Offset(0, -400));
      await tester.drag(find.byType(ListView), const Offset(0, -3000)); // to the very end
      await tester.pumpAndSettle();
      expectAboveBottomInset(tester, find.text('Genus s059'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('only the names a run would choose from, with the sentence that says which', (tester) async {
      await pump(tester, rowBits: Uint8List.fromList([0x0C]), intro: 'The 2 names of Apidae (of 5 in the list).');
      await load(tester, find.text('Apis mellifera'));
      expect(find.text('The 2 names of Apidae (of 5 in the list).'), findsOneWidget);
      expect(find.text('Every name of this name list.'), findsNothing);
      expect(find.text('2 names, in alphabetical order'), findsOneWidget);
      expect(names(tester), ['Apis mellifera', 'Bombus terrestris']);
    });

    testWidgets('the search box looks in the names, the families, the orders and the common names', (tester) async {
      await pump(tester);
      await load(tester, find.text('Apis mellifera'));
      await tester.enterText(find.byType(TextField), ' APIDAE ');
      await tester.pump();
      expect(names(tester), ['Apis mellifera', 'Bombus terrestris']);
      expect(find.text('2 of 5 names'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'hoverfly');
      await tester.pump();
      expect(names(tester), ['Episyrphus balteatus']);
      await tester.enterText(find.byType(TextField), 'zebra');
      await tester.pump();
      expect(names(tester), isEmpty);
      expect(find.text('Nothing found among the 5 names.'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear the search'));
      await tester.pump();
      expect(names(tester).length, 5);
      expect(find.text('5 names, in alphabetical order'), findsOneWidget);
    });

    testWidgets('with the keyboard open the search box and the names stay in view', (tester) async {
      await pump(tester);
      await load(tester, find.text('Apis mellifera'));
      // The keyboard: 300 of the screen's 800 logical pixels; Android then reports no bar.
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      tester.view.padding = FakeViewPadding.zero;
      await tester.showKeyboard(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getBottomLeft(find.byType(TextField)).dy, lessThan(500));
      expect(tester.getSize(find.byType(ListView)).height, greaterThan(250));
    });

    testWidgets('a tap on a name: a window to search the web for it or to copy it', (tester) async {
      phone();
      await pump(tester);
      await load(tester, find.text('Bombus terrestris'));
      await tester.tap(find.text('Bombus terrestris'));
      await tester.pumpAndSettle();
      final window = find.byType(AlertDialog);
      expect(find.descendant(of: window, matching: find.text('Bombus terrestris')), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget, reason: 'the X of every window');
      expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget);
      // The copy is confirmed in the window, which stays.
      await tester.tap(find.text('Copy the name'));
      await tester.pumpAndSettle();
      expect(copied, ['Bombus terrestris']);
      expect(find.text('Copied'), findsOneWidget);
      // The search closes the window and asks the phone.
      await tester.tap(find.text('Search the web'));
      await tester.pumpAndSettle();
      expect(window, findsNothing);
      expect(searched, ['Bombus terrestris']);
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a file that cannot be read is said in plain words', (tester) async {
      await pump(tester, file: File('${Directory.systemTemp.path}/no_such_list.fpack'));
      await load(tester, find.textContaining('could not be read'));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    });

    testWidgets('the route of Download & import models lists the file whose path it gets', (tester) async {
      simulateBottomSystemBar(tester);
      await tester.pumpWidget(
        MaterialApp(
          restorationScopeId: 'app',
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).restorablePush(nameListNamesRoute, arguments: _classes.path),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await load(tester, find.text('Syrphidae'));
      expect(find.text('Family of Diptera'), findsOneWidget);
      expect(find.text('tiny_classes.fpack'), findsOneWidget);
      expect(find.text('Always among the choices too, for a box that shows no organism: Vegetation.'), findsOneWidget);
    });
  });
}
