// Round 298: the "Before you record" sheet at phone width (360 px) with a bottom system bar.

import 'package:fauna_pulse/fauna_pulse/models/phone_state.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/before_record_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

void main() {
  Future<Future<String?> Function()> openSheet(WidgetTester tester, PhoneState phone) async {
    String? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (_) => BeforeRecordSheet(
                      positionLine: 'Position: 51.12346, 12.65432  ±8 m',
                      fieldSummary: 'Site: Meadow 2 · Plant: Knautia arvensis with a rather long name',
                      plan: 'Photos: one every 1 s for 10 s, then 30 min off. Daily 06:00–10:00 for 3 days; '
                          'each window is its own session.',
                      scheduled: true,
                      readPhone: () async => phone,
                    ),
                  );
                  done = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    return () async => done ? result : 'not closed';
  }

  testWidgets('tips with their buttons; Start; the last button above the system bar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    final result = await openSheet(
      tester,
      const PhoneState(airplaneMode: false, wifiOn: true, bluetoothOn: true, locationOn: true, stayAwake: true, batteryLimited: true),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Before you record'), findsOneWidget);
    expect(find.text('Open settings'), findsNWidgets(4));
    expect(find.textContaining('On: mobile network, Wi-Fi, Bluetooth.'), findsOneWidget);
    expect(find.text('Start the run'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expectAboveBottomInset(tester, find.text('Start the run'), label: 'Start button');
    await tester.tap(find.text('Start the run'));
    await tester.pumpAndSettle();
    expect(await result(), 'start');
  });

  testWidgets('a ready phone; Change and the each-time box', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final result = await openSheet(
      tester,
      const PhoneState(airplaneMode: true, wifiOn: false, bluetoothOn: false, locationOn: false, stayAwake: false, batteryLimited: false),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(PhoneState.readyText), findsOneWidget);
    await tester.tap(find.text('Show this before each start'));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getBool(kBeforeRecordSheetKey), isFalse);
    await tester.tap(find.text('Change').first);
    await tester.pumpAndSettle();
    expect(await result(), 'notes');
  });
}
