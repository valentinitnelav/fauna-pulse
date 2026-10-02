// FaunaPulse (round 277): on-device check of the new home screen, the
// Sessions screen (with the phone's own sessions) and the credits note of
// Download & import models.
//
// Nothing is deleted, imported or saved: the check only opens screens, opens
// and closes the filter panel and the menus, and selects one session and
// stops selecting again. It opens Android's photo picker for "Import
// videos…" once: run it with shots_back.sh, which presses Back on the phone
// after the "SHOT ..._back" screenshot, so nothing is chosen.
// Run:  flutter test integration_test/home_sessions_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in models_screen_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.

import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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

    // 2. Home: the bottom bar, the side menu, the support box.
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: const HomeScreen()));
    await waitFor(find.text(all.isEmpty ? 'None yet' : '${all.length} saved'));
    await settle();
    await shot('home');
    await tester.tap(find.text('Menu'));
    await settle();
    await shot('home_menu');
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
    await tester.tap(find.text('Import videos…'));
    await tester.pump(const Duration(milliseconds: 300));
    _log('SHOT import_picker_back');
    // The picker covers the app: wait without asking for frames.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 8)));
    await settle();
    expect(find.text('Reading the videos…'), findsNothing);
    expect(find.byType(SnackBar), findsNothing, reason: 'no hint after closing the picker');
    await shot('import_cancelled');

    // 4. Sessions.
    await tester.tap(find.text('Sessions'));
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
