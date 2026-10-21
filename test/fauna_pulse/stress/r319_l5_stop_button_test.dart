// Round 319 (L5d, stress finding n43): while a stop runs (video clips closing,
// files written), the record button shows "Stopping…" with a progress ring and
// takes no taps. The camera screen feeds it from the same flag that already
// blocks a second stop (_stopInProgress), in every mode, time-lapse video too.

import 'package:fauna_pulse/fauna_pulse/widgets/record_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<int>> pump(WidgetTester tester, {required bool stopping, bool square = true}) async {
    final taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: RecordButton(
              ready: true,
              square: square,
              scheduleBadge: false,
              stopping: stopping,
              onTap: () => taps.add(1),
            ),
          ),
        ),
      ),
    );
    return taps;
  }

  testWidgets('recording: one tap is taken, no "Stopping…" yet', (tester) async {
    final taps = await pump(tester, stopping: false);
    expect(find.text('Stopping…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byType(RecordButton));
    expect(taps, [1]);
  });

  testWidgets('stopping: label, ring, dimmed, and taps do nothing', (tester) async {
    final taps = await pump(tester, stopping: true);
    expect(find.text('Stopping…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final opacity = tester.widget<Opacity>(find.descendant(of: find.byType(RecordButton), matching: find.byType(Opacity)));
    expect(opacity.opacity, lessThan(1));
    await tester.tap(find.byType(RecordButton), warnIfMissed: false);
    await tester.tap(find.text('Stopping…'), warnIfMissed: false);
    expect(taps, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle with a schedule: clock badge, no ring', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordButton(ready: true, square: false, scheduleBadge: true, stopping: false, onTap: () {}),
        ),
      ),
    );
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
