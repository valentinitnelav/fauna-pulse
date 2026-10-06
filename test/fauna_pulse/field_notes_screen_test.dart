// Round 297: the Field notes page at phone width (360 px) with a bottom system bar: the last
// field stays above the bar, typed values are saved, and a wrong number shows its message.

import 'package:fauna_pulse/fauna_pulse/models/field_notes.dart';
import 'package:fauna_pulse/fauna_pulse/screens/field_notes_screen.dart';
import 'package:fauna_pulse/fauna_pulse/session/location_fix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

void main() {
  testWidgets('fits a 360-px screen; saves what is typed; refuses a wrong number', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    var positionTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: FieldNotesScreen(
          location: ValueNotifier<SessionLocation?>(
            const SessionLocation(latitude: 51.123456, longitude: 12.654321, accuracyM: 8, fixTimeMs: 1, source: 'gps'),
          ),
          searching: ValueNotifier(false),
          onChangePosition: () async => positionTaps++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('51.12346, 12.65432'), findsOneWidget);
    await tester.tap(find.text('Change position'));
    expect(positionTaps, 1);

    await tester.enterText(find.widgetWithText(TextField, 'Site'), 'Meadow 2');
    await tester.enterText(find.widgetWithText(TextField, 'Camera height (m)'), 'tall');
    await tester.pump();
    expect(find.text(FieldNotes.problem(kFieldNoteSpecs.firstWhere((s) => s.key == 'camera_height_m'))), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Camera height (m)'), '0.4');
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final saved = await tester.runAsync(FieldNotes.load);
    expect(saved!.values['site'], 'Meadow 2');
    expect(saved.values['camera_height_m'], 0.4);

    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectAboveBottomInset(tester, find.widgetWithText(TextField, 'Notes'), label: 'notes field');
  });
}
