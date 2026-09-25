// Widget test for the tip shown when the video picker closes without a
// choice (round 233): the picker's Downloads view hides files Android did not
// mark as downloads, such as the owner's WhatsApp clip moved into Download.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';

void main() {
  testWidgets('tip names the other views, retries and times out', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  videoPickTipSnackBar(onRetry: () => retries++),
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
    expect(find.textContaining('choose Videos'), findsOneWidget);
    expect(find.textContaining('WhatsApp'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(retries, 1);

    // Unlike a plain snack bar with an action, this one does not stay.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.textContaining('choose Videos'), findsNothing);
  });
}
