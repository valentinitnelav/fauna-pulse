// Round 297: the Field notes page at phone width (360 px) with a bottom system bar: the last
// field stays above the bar, typed values are saved, and a wrong number shows its message.

import 'dart:io';

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

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.widgetWithText(TextField, 'Site'), 200, scrollable: list);
    await tester.enterText(find.widgetWithText(TextField, 'Site'), 'Meadow 2');
    await tester.scrollUntilVisible(find.widgetWithText(TextField, 'Camera height (m)'), 200, scrollable: list);
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
    expectAboveBottomInset(tester, find.text('Add a field'), label: 'Add a field button');
  });

  testWidgets('own fields: add a choice through the window, set values, all saved (round 301)', (tester) async {
    SharedPreferences.setMockInitialValues({
      FieldNotes.prefsKey: '{"custom_fields":[{"name":"Survey day","type":"date","value":"2026-10-06"},'
          '{"name":"Rain","type":"yes_no","value":null}]}',
    });
    simulateBottomSystemBar(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: FieldNotesScreen(
          location: ValueNotifier<SessionLocation?>(null),
          searching: ValueNotifier(false),
          onChangePosition: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text('2026-10-06'), findsOneWidget);
    await tester.tap(find.text('Add a field'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Flower stage with a fairly long name');
    await tester.tap(find.byType(DropdownButtonFormField<CustomFieldType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(CustomFieldType.choice.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.textContaining('at least 2 choices'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Choices, one per line'), 'Bud\nOpen\nWilting');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((w) => w is DropdownButtonFormField<String?>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open').last);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final saved = await tester.runAsync(FieldNotes.load);
    expect(saved!.custom.map((f) => f.name), ['Survey day', 'Rain', 'Flower stage with a fairly long name']);
    expect(saved.custom.last.value, 'Open');
    expect(saved.recordBlock()['custom'], {'Survey day': '2026-10-06', 'Rain': null, 'Flower stage with a fairly long name': 'Open'});
    expect(tester.takeException(), isNull);
    expectAboveBottomInset(tester, find.text('Add a field'), label: 'Add a field button');
  });

  testWidgets('GPS goal and site photos (round 302) fit a 360-px screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    var takes = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: FieldNotesScreen(
          location: ValueNotifier<SessionLocation?>(null),
          searching: ValueNotifier(false),
          onChangePosition: () async {},
          loadSitePhotos: ({Directory? dir}) async => const [],
          takePhoto: () async {
            takes++;
            return null;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'GPS search stops at (m)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'GPS search stops at (m)'), '0');
    await tester.pump();
    expect(find.textContaining('always runs the full 3 min'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'GPS search stops at (m)'), '1.5');
    await tester.pump();
    expect(find.textContaining('whole number'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('No site photos yet.'), findsOneWidget);
    await tester.tap(find.text('Take a site photo'));
    await tester.pumpAndSettle();
    expect(takes, 1);
    expect(find.widgetWithText(TextField, 'About the site photos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
