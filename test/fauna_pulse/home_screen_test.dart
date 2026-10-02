// The home screen (rounds 277, 278): a bottom bar (Menu, Sessions | a raised
// New session | Dashboard, AI models), the page as numbered steps (1 AI
// models with "What do you want to watch?", 2 Record, 3 Or use your own
// videos, 4 Find and name the animals), the support box, the side menu and a
// quiet scroll bar.

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

Future<void> _pumpHome(WidgetTester tester, {ModelsOnPhone models = const ModelsOnPhone()}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: HomeScreen(
        scan: () async => _sessions,
        countModels: () async => models,
        loadDownloads: () async => _downloads,
        modelNames: () async => const {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

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
    expect(find.byIcon(Icons.check), findsNothing, reason: 'step 1 not done');
    double y(Finder f) => tester.getCenter(f).dy;
    expect(y(find.text('AI models').first), lessThan(y(find.text('Record'))));
    expect(y(find.text('Record')), lessThan(y(find.text('Import videos…'))));
    expect(y(find.text('Import videos…')), lessThan(y(find.text('Find animals in photos'))));
    expect(find.textContaining('at least 5 pictures per second'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Support FaunaPulse'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Find animals in videos'), findsOneWidget);
    expect(find.text('Sponsor on GitHub'), findsNothing, reason: 'no money link unless built with DONATION_LINK');
    expect(find.text('How to cite'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'nothing overflows at 360 px');
  });

  testWidgets('with models: step 1 counts them and is ticked', (tester) async {
    await _pumpHome(tester, models: const ModelsOnPhone(detectors: 3, namers: 2));
    expect(find.text('On this phone: 3 to find animals, 2 to name them.'), findsOneWidget);
    expect(find.textContaining('FaunaPulse needs AI models'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'step 1 done');
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

  testWidgets('a tile opens its suggested models and is marked afterwards', (tester) async {
    await _pumpHome(tester);
    await tester.tap(find.text('Mammals and birds'));
    await tester.pumpAndSettle();
    expect(find.byType(WatchPlanScreen), findsOneWidget);
    expect(find.text('MegaDetector V6'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString(kHomeWatchUsePref), 'mammals_birds');
    await tester.pageBack();
    await tester.pumpAndSettle();
    final icons = tester.widgetList<WatchIcon>(find.byType(WatchIcon)).toList();
    expect([for (final i in icons) i.selected], [false, false, true, false]);
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
