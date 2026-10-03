// The home screen (rounds 277, 278): a bottom bar (Menu, Sessions | a raised
// New session | Dashboard, AI models), the page as numbered steps (1 AI
// models with "What do you want to watch?", 2 Record, 3 Or use your own
// videos, 4 Find and name the animals), the support box, the side menu and a
// quiet scroll bar. Round 279: step 1 keeps its number and says what was set
// up (the answer and the chosen file names); step 2 shows the yellow square.
// Round 280: step 1 says what a choice lacks ("Name: none", "Find: none");
// step 2 shows the phone screen of the answer chosen last.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/models_on_phone.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart' show kHideSessionInfoPrefKey;
import 'package:fauna_pulse/fauna_pulse/perf/slow_phone_hint.dart' show kHideSlowPhoneHintPrefKey;
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/watch_plan_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/scroll_hint.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/session_tile.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/support_faunapulse.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/watch_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'past_sessions_test.dart' show session;
import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

final _sessions = [
  session('meadow_timelapse', DateTime(2026, 10, 2, 8), duration: const Duration(minutes: 5), kind: RecordingKind.timeLapse),
  session('meadow_live', DateTime(2026, 9, 27, 8), duration: const Duration(minutes: 30), found: true),
];

final _downloads = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());

const _tiles = ['Pollinators on flowers', 'Insects on a flat surface', 'Mammals and birds', 'Other models'];

const ModelChoice _noChoice = (detector: null, idModel: null, nameList: null);

Future<void> _pumpHome(
  WidgetTester tester, {
  ModelsOnPhone models = const ModelsOnPhone(),
  ModelChoice choice = _noChoice,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: HomeScreen(
        scan: () async => _sessions,
        countModels: () async => models,
        loadDownloads: () async => _downloads,
        modelNames: () async => const {},
        modelChoice: (_) async => choice,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _image(String asset) =>
    find.byWidgetPredicate((w) => w is Image && w.image is AssetImage && (w.image as AssetImage).assetName == asset);

void _phoneSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('bottom bar: Menu, Sessions | a raised New session | Dashboard, AI models', (tester) async {
    simulateBottomSystemBar(tester);
    await _pumpHome(tester);
    final fab = find.byType(FloatingActionButton);
    expect(fab, findsOneWidget);
    expect(tester.getSize(fab), const Size(72, 72));
    final bar = tester.getRect(find.byType(BottomAppBar));
    expect(tester.getRect(fab).top, lessThan(bar.top), reason: 'raised above the bar');
    expect(tester.getCenter(find.text('New session')).dy, greaterThan(tester.getRect(fab).bottom - 1));
    final words = ['Menu', 'Sessions', 'New session', 'Dashboard', 'AI models'];
    final xs = [for (final w in words) tester.getCenter(find.descendant(of: find.byType(BottomAppBar), matching: find.text(w))).dx];
    expect(xs, orderedEquals([...xs]..sort()), reason: 'left to right: $words');
    expect(xs[1], lessThan(tester.getCenter(fab).dx));
    expect(xs[3], greaterThan(tester.getCenter(fab).dx));
    // The bar's colour may reach under the system bar; its words may not.
    for (final w in words) {
      expectAboveBottomInset(tester, find.descendant(of: find.byType(BottomAppBar), matching: find.text(w)), label: w);
    }
    expect(find.byType(SessionTile), findsNothing, reason: 'no latest session row');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no model yet: step 1 says models are needed, then the steps in order', (tester) async {
    // Tall enough to see every step at once; 360 px wide, as small phones.
    _phoneSize(tester, const Size(360, 1600));
    await _pumpHome(tester);
    expect(find.textContaining('FaunaPulse needs AI models'), findsOneWidget);
    expect(find.text('What do you want to watch?'), findsOneWidget);
    for (final t in _tiles) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.byType(WatchIcon), findsNWidgets(4));
    expect(find.text('Tap one: FaunaPulse suggests which AI models to download.'), findsOneWidget);
    for (final n in ['1', '2', '3', '4']) {
      expect(find.text(n), findsOneWidget, reason: 'step $n keeps its number');
    }
    double y(Finder f) => tester.getCenter(f).dy;
    expect(y(find.text('AI models').first), lessThan(y(find.text('Record'))));
    expect(y(find.text('Record')), lessThan(y(find.text('Import videos…'))));
    expect(y(find.text('Import videos…')), lessThan(y(find.text('Find animals in photos'))));
    expect(find.textContaining('move the yellow square over the place to watch'), findsOneWidget);
    expect(_image(roiPicture('pollinators')), findsOneWidget, reason: 'no answer chosen yet: the main use');
    await tester.scrollUntilVisible(find.text('Support FaunaPulse'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Find animals in videos'), findsOneWidget);
    expect(find.text('Sponsor on GitHub'), findsNothing, reason: 'no money link unless built with DONATION_LINK');
    expect(find.text('How to cite'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'nothing overflows at 360 px');
  });

  testWidgets('with models but none chosen: step 1 counts them and keeps its number', (tester) async {
    await _pumpHome(tester, models: const ModelsOnPhone(detectors: 3, namers: 2));
    expect(find.text('On this phone: 3 to find animals, 2 to name them.'), findsOneWidget);
    expect(find.textContaining('FaunaPulse needs AI models'), findsNothing);
    expect(find.text('Tap one: FaunaPulse suggests the AI models for it.'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing, reason: 'no tick for any step');
    expect(const ModelsOnPhone(detectors: 1).summary, 'On this phone: 1 to find animals, none to name them.');
  });

  test('models that can name: a class list by name, a label pack by the first part', () {
    List<File> files(List<String> names) => [for (final n in names) File('/x/$n')];
    final models = files([
      'insectdct-cls-v7_eff2s_fp16.tflite',
      'bioclip-2_image_fp16_4d.tflite',
      'bioclip-25_image_fp16.tflite',
      'bioclip-2.5_224_fp16.tflite',
      'lonely_224_fp16.tflite',
    ]);
    final packs = files([
      'insectdct-cls-v7_eff2s_fp16.fpack',
      'bioclip2_pollinator_orders_europe_v1.fpack',
      'bioclip25_flower_visitors_32fam_v1.fpack',
    ]);
    expect(ModelsOnPhone.namersOf(models, packs), 4, reason: 'all but the lonely one');
    expect(ModelsOnPhone.namersOf(models, const []), 0);
  });

  testWidgets('a tile opens its suggested models; back without choosing marks nothing', (tester) async {
    await _pumpHome(tester);
    await tester.tap(find.text('Mammals and birds'));
    await tester.pumpAndSettle();
    expect(find.byType(WatchPlanScreen), findsOneWidget);
    expect(find.text('MDV6-yolov10-c_int8_256.tflite'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString(kHomeWatchUsePref), isNull);
    final icons = tester.widgetList<WatchIcon>(find.byType(WatchIcon)).toList();
    expect([for (final i in icons) i.selected], [false, false, false, false]);
  });

  testWidgets('set up: step 1 names the answer and the chosen files, its tile marked', (tester) async {
    SharedPreferences.setMockInitialValues({kHomeWatchUsePref: 'pollinators'});
    await _pumpHome(
      tester,
      models: const ModelsOnPhone(detectors: 1, namers: 1),
      choice: (
        detector: 'insectdct-v8-s_640_fp16.tflite',
        idModel: 'insectdct-cls-v7_eff2s_fp16.tflite',
        nameList: 'insectdct-cls-v7_eff2s_fp16.fpack',
      ),
    );
    expect(find.text('Set up for: Pollinators on flowers'), findsOneWidget);
    expect(find.text('Find: insectdct-v8-s_640_fp16.tflite'), findsOneWidget);
    expect(find.text('Name: insectdct-cls-v7_eff2s_fp16.tflite'), findsOneWidget, reason: 'its class list goes unsaid');
    expect(find.textContaining('Tap one'), findsNothing);
    expect(find.textContaining('On this phone:'), findsNothing);
    expect(find.text('1'), findsOneWidget);
    final icons = tester.widgetList<WatchIcon>(find.byType(WatchIcon)).toList();
    expect([for (final i in icons) i.selected], [true, false, false, false]);
  });

  testWidgets('set up with a label pack; a camera model from elsewhere is just "Chosen AI models"', (tester) async {
    SharedPreferences.setMockInitialValues({kHomeWatchUsePref: 'mammals_birds'});
    const bioclip = (
      detector: 'MDV6-yolov10-c_int8_256.tflite',
      idModel: 'bioclip-2_image_fp16_4d.tflite',
      nameList: 'bioclip-2_mammals-birds-world_v1.fpack',
    );
    _phoneSize(tester, const Size(360, 1200));
    await _pumpHome(tester, models: const ModelsOnPhone(detectors: 1, namers: 1), choice: bioclip);
    expect(find.text('Set up for: Mammals and birds'), findsOneWidget);
    expect(find.text('Name: bioclip-2_image_fp16_4d.tflite with bioclip-2_mammals-birds-world_v1.fpack'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Record'), 200, scrollable: find.byType(Scrollable).first);
    expect(_image(roiPicture('mammals_birds')), findsOneWidget, reason: 'step 2 shows the answer chosen last');
    expect(tester.takeException(), isNull, reason: 'long file names wrap at 360 px');
    SharedPreferences.setMockInitialValues({kHomeWatchUsePref: 'pollinators'});
    await tester.pumpWidget(const SizedBox());
    await _pumpHome(tester, models: const ModelsOnPhone(detectors: 1, namers: 1), choice: bioclip);
    expect(find.text('Chosen AI models'), findsOneWidget, reason: 'MegaDetector is not a pollinator suggestion');
    final icons = tester.widgetList<WatchIcon>(find.byType(WatchIcon)).toList();
    expect([for (final i in icons) i.selected], [false, false, false, false]);
  });

  testWidgets('a choice without naming, or without finding, says so in plain words', (tester) async {
    SharedPreferences.setMockInitialValues({kHomeWatchUsePref: 'flat_surface'});
    await _pumpHome(
      tester,
      models: const ModelsOnPhone(detectors: 1),
      choice: (detector: 'flatbug-n_640_fp16.tflite', idModel: null, nameList: null),
    );
    expect(find.text('Set up for: Insects on a flat surface'), findsOneWidget);
    expect(find.text('Name: none (animals are found and followed, not named)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _pumpHome(
      tester,
      models: const ModelsOnPhone(namers: 1),
      choice: (detector: null, idModel: 'insectdct-cls-v7_eff2s_fp16.tflite', nameList: 'insectdct-cls-v7_eff2s_fp16.fpack'),
    );
    expect(find.text('Chosen AI models'), findsOneWidget);
    expect(find.text('Find: none (naming works only where animals were already found)'), findsOneWidget);
    expect(find.text('Name: insectdct-cls-v7_eff2s_fp16.tflite'), findsOneWidget);
    expect(find.textContaining('Tap one'), findsNothing);
  });

  testWidgets('the side menu: models first, About last; Support opens the box', (tester) async {
    await _pumpHome(tester);
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    final items = [
      for (final tile in tester.widgetList<ListTile>(find.descendant(of: find.byType(Drawer), matching: find.byType(ListTile))))
        ((tile.title as Text).data)!,
    ];
    expect(items, [
      'Download & import models',
      'Show setup tips at session start',
      'Report a problem',
      'Share FaunaPulse',
      'Support FaunaPulse',
      'About FaunaPulse',
    ]);
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Support FaunaPulse')));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing, reason: 'the menu closes');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('stays free for science')), findsOneWidget);
  });

  testWidgets('turning the setup tips on brings back the slow-phone hint', (tester) async {
    SharedPreferences.setMockInitialValues({kHideSessionInfoPrefKey: true, kHideSlowPhoneHintPrefKey: true});
    await _pumpHome(tester);
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show setup tips at session start'));
    await tester.pumpAndSettle();
    final p = await SharedPreferences.getInstance();
    expect(p.getBool(kHideSessionInfoPrefKey), isFalse);
    expect(p.getBool(kHideSlowPhoneHintPrefKey), isNull);
  });

  testWidgets('the support box with the donation link (GitHub release builds)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SupportFaunaPulseCard(donationLink: true, onReportProblem: () {})),
      ),
    );
    expect(find.text('Sponsor on GitHub'), findsOneWidget);
    expect(find.textContaining('own budget'), findsOneWidget);
    expect(supportText(donationLink: false), isNot(contains('budget')));
    expect(kDonationLink, isFalse, reason: 'tests and normal builds have no money link');
  });

  testWidgets('the scroll bar: drawn while the page is longer than the screen', (tester) async {
    _phoneSize(tester, const Size(360, 740));
    await _pumpHome(tester);
    expect(find.byType(ScrollHint), findsOneWidget);
    final paint = find.descendant(of: find.byType(ScrollHint), matching: find.byType(CustomPaint)).last;
    expect(tester.renderObject(paint), paints..rrect()..rrect(), reason: 'the path and the bar');
  });

  testWidgets('a small screen scrolls instead of overflowing', (tester) async {
    _phoneSize(tester, const Size(320, 480));
    await _pumpHome(tester, models: const ModelsOnPhone(detectors: 12, namers: 3));
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text('Support FaunaPulse'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
