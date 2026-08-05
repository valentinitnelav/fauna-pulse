// Widget tests for the ⋮ menu's About dialog (AboutFaunaPulseDialog).
//
// Round 193: the muted "Third-party licenses" action is back (store releases
// must ship the bundled packages' license texts; Flutter's auto-generated
// LicensePage is the zero-maintenance way). It PUSHES the page on top of the
// dialog instead of popping first, so backing out of the long list returns
// to the About.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';

Future<void> _pumpHost(WidgetTester tester, {String? version}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AboutFaunaPulseDialog(version: version),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('About shows version, repo link, AGPL line and licenses action', (
    tester,
  ) async {
    await _pumpHost(tester, version: 'v0.6.4 (build 10)');
    expect(find.text('FaunaPulse'), findsOneWidget);
    expect(find.text('v0.6.4 (build 10)'), findsOneWidget);
    expect(find.text('github.com/valentinitnelav/fauna-pulse'), findsOneWidget);
    expect(find.textContaining('AGPL-3.0'), findsOneWidget);
    expect(find.text('Third-party licenses'), findsOneWidget);
  });

  testWidgets('a null version renders no version line', (tester) async {
    await _pumpHost(tester);
    expect(find.text('FaunaPulse'), findsOneWidget);
    expect(find.textContaining('build'), findsNothing);
  });

  testWidgets('Third-party licenses pushes the LicensePage over the dialog', (
    tester,
  ) async {
    await _pumpHost(tester, version: 'v0.6.4 (build 10)');
    await tester.tap(find.text('Third-party licenses'));
    // No pumpAndSettle here: LicensePage shows a progress indicator while the
    // LicenseRegistry stream loads, which may never settle in a test.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LicensePage), findsOneWidget);

    // Backing out of the license list must land on the still-open About.
    // (.first: LicensePage's master-detail layout nests its own Navigator,
    // so byType matches two; the root one is the pushed route's owner.)
    final NavigatorState navigator = tester.state(
      find.byType(Navigator).first,
    );
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // One more frame: the popped route leaves the overlay only after its
    // exit animation reports dismissed.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LicensePage), findsNothing);
    expect(find.byType(AboutFaunaPulseDialog), findsOneWidget);
  });
}
