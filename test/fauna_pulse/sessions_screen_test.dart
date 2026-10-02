// Round 277 (owner): the past sessions on their own screen, with a search,
// a filter panel, a sort menu, and press-and-hold to select several sessions
// to delete; and the home screen that leads to it.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_actions.dart';
import 'package:fauna_pulse/fauna_pulse/screens/sessions_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/session_tile.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/support_faunapulse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'past_sessions_test.dart' show session;
import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

final _now = DateTime(2026, 10, 2, 12);
final _sessions = [
  session('meadow_timelapse', DateTime(2026, 10, 2, 8), duration: const Duration(minutes: 5), kind: RecordingKind.timeLapse),
  session('meadow_live', DateTime(2026, 9, 27, 8), duration: const Duration(minutes: 30), found: true),
  session('river_videos', DateTime(2026, 9, 10, 8), duration: const Duration(hours: 2), kind: RecordingKind.importedVideos),
  session('garden_motion_with_a_rather_long_name_for_a_small_phone', DateTime(2026, 8, 1, 8), kind: RecordingKind.motion),
];

Future<void> _pumpSessions(WidgetTester tester, [List<PastSession>? list]) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: SessionsScreen(scan: () async => list ?? _sessions, now: () => _now),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets real file work (scan, delete) finish inside a widget test.
Future<void> _waitFor(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 250 && f.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(f, findsWidgets);
}

void main() {
  testWidgets('every session with its recording kind; the search narrows the list', (tester) async {
    await _pumpSessions(tester);
    expect(find.byType(SessionTile), findsNWidgets(4));
    expect(find.textContaining('4 sessions'), findsOneWidget);
    expect(find.textContaining('Hold one to select several.'), findsOneWidget);
    expect(find.byTooltip('Time-lapse'), findsOneWidget);
    expect(find.byTooltip('Imported videos'), findsOneWidget);
    expect(find.byTooltip('Motion'), findsOneWidget);
    expect(find.byTooltip('Live detection'), findsOneWidget);
    expect(find.byTooltip('Session actions'), findsNWidgets(4), reason: 'the ⋮ at the end of each row');

    await tester.enterText(find.byType(TextField), 'MEADOW');
    await tester.pumpAndSettle();
    expect(find.byType(SessionTile), findsNWidgets(2));
    expect(find.textContaining('2 of 4 sessions'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'nothing');
    await tester.pumpAndSettle();
    expect(find.text('No session matches.'), findsOneWidget);
    await tester.tap(find.text('Clear search and filters'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionTile), findsNWidgets(4));
  });

  testWidgets('the filter panel: chosen filters become chips, removed with ✕', (tester) async {
    await _pumpSessions(tester);
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(find.text('Show 4 sessions'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Time-lapse'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Imported videos'));
    await tester.pumpAndSettle();
    expect(find.text('Show 2 sessions'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Last 7 days'));
    await tester.pumpAndSettle();
    expect(find.text('Show 1 session'), findsOneWidget);
    await tester.tap(find.text('Show 1 session'));
    await tester.pumpAndSettle();
    expect(find.text('Filters (2)'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Last 7 days'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Time-lapse, Imported videos'), findsOneWidget);
    expect(find.byType(SessionTile), findsOneWidget);
    expect(find.textContaining('1 of 4 sessions'), findsOneWidget);

    await tester.tap(find.descendant(of: find.widgetWithText(InputChip, 'Last 7 days'), matching: find.byTooltip('Remove this filter')));
    await tester.pumpAndSettle();
    expect(find.text('Filters (1)'), findsOneWidget);
    expect(find.byType(SessionTile), findsNWidgets(2));

    // Sort: the longest first.
    await tester.tap(find.text('Newest first'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Longest first').last);
    await tester.pumpAndSettle();
    final names = [for (final t in tester.widgetList<SessionTile>(find.byType(SessionTile))) t.session.name];
    expect(names, ['river_videos', 'meadow_timelapse']);
  });

  testWidgets('press and hold selects; the top bar counts, selects all shown, and stops', (tester) async {
    await _pumpSessions(tester);
    await tester.longPress(find.text('river_videos'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(4));
    expect(find.byTooltip('Session actions'), findsNothing, reason: 'no ⋮ while selecting');
    await tester.tap(find.text('meadow_live'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('meadow_live'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget, reason: 'a second tap unselects');
    await tester.tap(find.byTooltip('Select all shown'));
    await tester.pumpAndSettle();
    expect(find.text('4 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete the selected sessions'));
    await tester.pumpAndSettle();
    expect(find.byType(DeleteAllSessionsDialog), findsOneWidget, reason: 'all sessions: type "delete"');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Back ends the selection, not the screen.
    final popped = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('deleting the selected sessions removes exactly their folders', (tester) async {
    final root = Directory.systemTemp.createTempSync('sessions_screen');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final (i, name) in ['a_first', 'b_second', 'c_third'].indexed) {
      final d = Directory('${root.path}/$name')..createSync();
      File('${d.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":${1000000 * (i + 1)},"config":{}}\n'
        '{"type":"end_of_session","time_ms":${1000000 * (i + 1) + 60000},"ended_normally":true}\n',
      );
    }
    File('${root.path}/notes_copied_over_usb.txt').writeAsStringSync('keep me');
    await tester.pumpWidget(MaterialApp(home: SessionsScreen(scan: () => scanPastSessions(root: root))));
    await _waitFor(tester, find.byType(SessionTile));
    expect(find.byType(SessionTile), findsNWidgets(3));

    await tester.longPress(find.text('a_first'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b_second'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete the selected sessions'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 sessions?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    final gone = find.text('a_first');
    for (var i = 0; i < 250 && (gone.evaluate().isNotEmpty || find.byType(Checkbox).evaluate().isNotEmpty); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(SessionTile), findsOneWidget);
    expect(find.text('c_third'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget, reason: 'selection ended');
    expect(Directory('${root.path}/a_first').existsSync(), isFalse);
    expect(Directory('${root.path}/b_second').existsSync(), isFalse);
    expect(Directory('${root.path}/c_third').existsSync(), isTrue);
    expect(File('${root.path}/notes_copied_over_usb.txt').existsSync(), isTrue);
  });

  testWidgets('the ⋮ menu: select, import videos, delete all', (tester) async {
    await _pumpSessions(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Select sessions'), findsOneWidget);
    expect(find.text('Import videos…'), findsOneWidget);
    expect(find.text('Delete all sessions…'), findsOneWidget);
    await tester.tap(find.text('Delete all sessions…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete ALL sessions?'), findsOneWidget);
    expect(find.textContaining('all 4 sessions'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select sessions'));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
  });

  testWidgets('no sessions yet', (tester) async {
    await _pumpSessions(tester, const []);
    expect(find.textContaining('No sessions yet.'), findsOneWidget);
  });

  testWidgets('fits a 360-px screen; the last row stays above the system bar', (tester) async {
    simulateBottomSystemBar(tester);
    await _pumpSessions(tester, [
      for (var i = 0; i < 12; i++) session('session_$i', DateTime(2026, 9, 1 + i, 8), duration: Duration(minutes: 3 * i)),
      ..._sessions,
    ]);
    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectAboveBottomInset(tester, find.byType(SessionTile).last, label: 'last session row');
    await tester.longPress(find.byType(SessionTile).last);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'the filter panel fits');
  });

  group('home screen', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> pumpHome(WidgetTester tester, List<PastSession> list) async {
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: HomeScreen(scan: () async => list)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('bottom bar: Menu, a raised New session, Dashboard; Sessions under the name', (tester) async {
      simulateBottomSystemBar(tester);
      await pumpHome(tester, _sessions);
      // The three bottom buttons, each with its word under it.
      final fab = find.byType(FloatingActionButton);
      expect(fab, findsOneWidget);
      expect(tester.getSize(fab), const Size(72, 72));
      expect(find.text('New session'), findsOneWidget);
      expect(find.text('Menu'), findsOneWidget);
      expect(find.text('Dashboard'), findsOneWidget);
      final bar = tester.getRect(find.byType(BottomAppBar));
      expect(tester.getRect(fab).top, lessThan(bar.top), reason: 'raised above the bar');
      expect(tester.getCenter(find.text('New session')).dy, greaterThan(tester.getRect(fab).bottom - 1));
      expect(tester.getCenter(find.text('Menu')).dx, lessThan(tester.getCenter(fab).dx));
      expect(tester.getCenter(find.text('Dashboard')).dx, greaterThan(tester.getCenter(fab).dx));
      // The bar's colour may reach under the system bar; its words may not.
      for (final word in ['Menu', 'New session', 'Dashboard']) {
        expectAboveBottomInset(tester, find.text(word), label: word);
      }
      // The content, top to bottom.
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('4 saved'), findsOneWidget);
      expect(find.text('Import videos…'), findsOneWidget);
      expect(find.text('Find animals in photos'), findsOneWidget);
      expect(find.text('Find animals in videos'), findsOneWidget);
      double y(String text) => tester.getCenter(find.text(text)).dy;
      expect(y('Sessions'), lessThan(y('Import videos…')));
      expect(y('Import videos…'), lessThan(y('Find animals in photos')));
      expect(find.byType(SessionTile), findsNothing, reason: 'no latest session row');
      await tester.scrollUntilVisible(find.text('Support FaunaPulse'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Sponsor on GitHub'), findsNothing, reason: 'no money link unless built with DONATION_LINK');
      expect(find.text('How to cite'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the side menu: models first, About last; Support opens the box', (tester) async {
      await pumpHome(tester, _sessions);
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
      expect(find.text('Import videos…'), findsOneWidget, reason: 'only on the screen, not in the menu');
      await tester.tap(find.text('Support FaunaPulse'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing, reason: 'the menu closes');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('stays free for science')), findsOneWidget);
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

    testWidgets('no sessions yet', (tester) async {
      await pumpHome(tester, const []);
      expect(find.text('None yet'), findsOneWidget);
    });

    testWidgets('a small screen scrolls instead of overflowing', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHome(tester, _sessions);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('Support FaunaPulse'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
