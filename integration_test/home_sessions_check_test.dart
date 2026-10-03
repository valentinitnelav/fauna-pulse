// FaunaPulse (round 277): on-device check of the new home screen, the
// Sessions screen (with the phone's own sessions) and the credits note of
// Download & import models. Round 278: the home screen as steps, its scroll
// bar, the page of each "What do you want to watch?" answer (the phone's own
// files shown as on the phone; nothing downloaded) and the About text.
// Round 279: the answer pages with their drawing, "Chosen for you" and the
// fold "Choose other models"; step 1 without a tick, step 2 with the yellow
// square.
//
// Nothing is deleted, imported, downloaded or saved: the check only opens
// screens, opens and closes the filter panel and the menus, and selects one
// session and stops selecting again. Opening an answer's page remembers
// which answer was last opened (home_watch_use): the check puts the phone's
// value back. It opens Android's photo picker for "Import
// videos…" once: run it with shots_back.sh, which presses Back on the phone
// after the "SHOT ..._back" screenshot, so nothing is chosen.
// Run:  flutter test integration_test/home_sessions_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in models_screen_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.

import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/watch_plan_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home, Sessions and the credits note on the phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    // 1. The scan of the phone's sessions: how long, and the kinds found.
    final watch = Stopwatch()..start();
    final all = await scanPastSessions();
    _log('SCAN ${all.length} sessions in ${watch.elapsedMilliseconds} ms');
    final kinds = <RecordingKind, int>{};
    for (final s in all) {
      kinds[s.kind] = (kinds[s.kind] ?? 0) + 1;
    }
    _log('KINDS ${kinds.entries.map((e) => '${e.key.label}: ${e.value}').join(', ')}');
    _log('FLAGS videos ${all.where((s) => s.hasVideos).length}, find animals ${all.where((s) => s.hasAnalysis).length}, '
        'identified ${all.where((s) => s.hasIdentification).length}, no end ${all.where((s) => s.duration == null).length}');

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 4));
    }

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> waitFor(Finder f) async {
      for (var i = 0; i < 150 && f.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(f, findsWidgets);
    }

    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await settle();
    }

    // 2. Home: the steps, the bottom bar, the side menu, the support box.
    final prefs = await SharedPreferences.getInstance();
    final watchUse = prefs.getString(kHomeWatchUsePref);
    addTearDown(() async {
      final p = await SharedPreferences.getInstance();
      watchUse == null ? await p.remove(kHomeWatchUsePref) : await p.setString(kHomeWatchUsePref, watchUse);
    });
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: const HomeScreen()));
    final step1 = find.textContaining(RegExp(r'^(On this phone|FaunaPulse needs|Set up for|Chosen AI models)'));
    await waitFor(step1);
    await settle();
    _log('MODELS ${tester.widget<Text>(step1).data}');
    await shot('home');

    // Each answer's page, then back (nothing downloaded).
    for (final (tile, name) in [
      ('Pollinators on flowers', 'watch_pollinators'),
      ('Insects on a flat surface', 'watch_flat_surface'),
      ('Mammals and birds', 'watch_mammals_birds'),
    ]) {
      await tester.tap(find.text(tile));
      await waitFor(find.text('Chosen for you'));
      await settle();
      final onPhone = find.text('On this phone').evaluate().length;
      await shot(name);
      final button = find.textContaining(RegExp(r'^(Download and use \(|Use these$)'));
      _log('WATCH $tile: "On this phone" $onPhone times, button "${tester.widget<Text>(button).data}"');
      await tester.tap(find.text('Choose other models'));
      await settle();
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await settle();
      await shot('${name}_other');
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await settle();
      await shot('${name}_end');
      await back();
      await waitFor(find.byType(HomeScreen));
    }
    expect(find.byType(WatchPlanScreen), findsNothing);

    await tester.tap(find.text('Menu'));
    await settle();
    await shot('home_menu');
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('About FaunaPulse')));
    await waitFor(find.textContaining('name them: an identification model'));
    await settle();
    await shot('home_about');
    await tester.tap(find.text('Close'));
    await settle();
    await tester.tap(find.text('Menu'));
    await settle();
    // The menu's item (the box of the same name can be visible behind it).
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Support FaunaPulse')));
    await settle();
    await shot('home_support');
    await tester.tap(find.text('Close'));
    await settle();
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await settle();
    await shot('home_bottom');
    await tester.drag(find.byType(ListView), const Offset(0, 1500));
    await settle();

    // 3. Import videos: the photo picker opens (shots_back.sh then presses
    // Back); closing it leaves no message behind.
    // In the middle of the screen: near the bottom, the raised New session
    // button covers it (round 279: the shorter steps moved it there).
    await Scrollable.ensureVisible(tester.element(find.text('Import videos…')), alignment: 0.4);
    await settle();
    await tester.tap(find.text('Import videos…'));
    await tester.pump(const Duration(milliseconds: 300));
    _log('SHOT import_picker_back');
    // The picker covers the app: wait without asking for frames.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 8)));
    await settle();
    expect(find.text('Reading the videos…'), findsNothing);
    expect(find.byType(SnackBar), findsNothing, reason: 'no hint after closing the picker');
    await shot('import_cancelled');

    // 4. Sessions (in the bottom bar).
    await tester.tap(find.descendant(of: find.byType(BottomAppBar), matching: find.text('Sessions')));
    await waitFor(find.byType(all.isEmpty ? Text : SessionTile));
    await settle();
    await shot('sessions');
    if (all.isEmpty) return;

    await tester.tap(find.textContaining('Filters'));
    await settle();
    await shot('filters_panel');
    final kind = all.first.kind;
    await tester.tap(find.widgetWithText(FilterChip, kind.label));
    await settle();
    final show = find.textContaining(RegExp(r'^Show \d+ session'));
    _log('PANEL ${(tester.widget<Text>(show)).data} for ${kind.label}');
    await shot('filters_chosen');
    await tester.tap(show);
    await settle();
    await shot('sessions_filtered');
    await tester.tap(find.byTooltip('Remove this filter'));
    await settle();

    await tester.longPress(find.byType(SessionTile).first);
    await settle();
    await shot('sessions_selecting');
    await tester.tap(find.byTooltip('Stop selecting'));
    await settle();

    await tester.tap(find.byTooltip('More'));
    await settle();
    await shot('sessions_menu');
    await back();
    await back(); // to the home screen
    await waitFor(find.text('New session'));

    // 5. The credits note and a card's source link.
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: const ModelsScreen()));
    await waitFor(find.text('Detection models'));
    await settle();
    await shot('models_credits');
    final info = find.byTooltip('About this file');
    if (info.evaluate().isNotEmpty) {
      await tester.tap(info.first);
      await settle();
      await shot('models_card_source');
      await tester.tap(find.text('Close'));
      await settle();
    }
  });
}
