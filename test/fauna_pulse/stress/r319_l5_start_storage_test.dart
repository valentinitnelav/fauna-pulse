// Round 319 (L5a, stress finding n53, phone evidence D2c/rec_default200): with
// free storage already below "Keep free storage", Start used to begin a recording
// that the guard stopped a few seconds later. Now Start is blocked with a window,
// and the "Before you record" sheet shows the same facts in red.

import 'package:fauna_pulse/fauna_pulse/logging/device_storage.dart';
import 'package:fauna_pulse/fauna_pulse/models/phone_state.dart';
import 'package:fauna_pulse/fauna_pulse/session/session_guards.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/before_record_sheet.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/not_enough_storage_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mb = 1024 * 1024;
// The free space on the phone in D2c: 146567168 bytes = 139.8 MB.
const _d2cFree = 146567168;
const _facts =
    '139 MB free, but a recording needs at least 200 MB free (Settings, Power tab, Keep free '
    'storage). Free some space first, for example by deleting old sessions or videos.';

void main() {
  test('below the reserve blocks a start; unknown free space never blocks', () {
    expect(storageBelowReserve(_d2cFree, 200), isTrue);
    expect(storageBelowReserve(200 * _mb, 200), isFalse);
    expect(storageBelowReserve(200 * _mb - 1, 200), isTrue);
    expect(storageBelowReserve(null, 200), isFalse);
    // The guard uses the same rule.
    expect(
      guardStopReason(
        batteryPercent: 80,
        isPlugged: true,
        isCharging: true,
        freeBytes: _d2cFree,
        lowBatteryPercent: 15,
        storageReserveMb: 200,
      ),
      'storage_low',
    );
  });

  testWidgets('the window: title with X, the facts, Close at the bottom', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showNotEnoughStorageDialog(context, freeBytes: _d2cFree, reserveMb: 200),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Not enough free storage'), findsOneWidget);
    expect(find.text(_facts), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    expect(find.text('Not enough free storage'), findsNothing);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Not enough free storage'), findsNothing);
  });

  Future<void> openSheet(WidgetTester tester, int? free) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<String>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => BeforeRecordSheet(
                    positionLine: 'No position yet.',
                    fieldSummary: '',
                    plan: 'Photos: one every 1 s.',
                    scheduled: false,
                    readPhone: () async => const PhoneState(),
                    storageReserveMb: 200,
                    readStorage: () async => StorageReading(freeBytes: free),
                  ),
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

  testWidgets('"Before you record": red line when below the reserve', (tester) async {
    await openSheet(tester, _d2cFree);
    final line = find.text('Not enough free storage: $_facts');
    expect(line, findsOneWidget);
    expect(tester.widget<Text>(line).style?.color, Colors.redAccent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Before you record": no line with enough or unknown free space', (tester) async {
    await openSheet(tester, 5 << 30);
    expect(find.textContaining('Not enough free storage'), findsNothing);
    await openSheet(tester, null);
    expect(find.textContaining('Not enough free storage'), findsNothing);
  });
}
