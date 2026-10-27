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
    // Round 336: Device ID sits just above Sample ID, with its reason under it.
    await tester.scrollUntilVisible(find.widgetWithText(TextField, 'Sample ID'), 200, scrollable: list);
    final device = find.widgetWithText(TextField, kDeviceIdFieldName);
    expect(tester.getTopLeft(device).dy, lessThan(tester.getTopLeft(find.widgetWithText(TextField, 'Sample ID')).dy));
    expect(find.textContaining('which two phones can share'), findsOneWidget);
    await tester.enterText(device, 'cam-03');
    await tester.scrollUntilVisible(find.widgetWithText(TextField, 'Camera height (m)'), 200, scrollable: list);
    await tester.enterText(find.widgetWithText(TextField, 'Camera height (m)'), 'tall');
    await tester.pump();
    expect(find.text(FieldNotes.problem(kFieldNoteSpecs.firstWhere((s) => s.key == 'camera_height_m'))), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Camera height (m)'), '0.4');
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final saved = await tester.runAsync(FieldNotes.load);
    expect(saved!.values['site'], 'Meadow 2');
    expect(saved.values['device_id'], 'cam-03');
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
    expect(find.text('for example Observer or Weather'), findsOneWidget);
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
  testWidgets('deleting a site photo asks first; Cancel keeps the file', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('site_photo_delete');
    addTearDown(() => dir.deleteSync(recursive: true));
    // A 1x1 PNG, so the thumbnail can decode.
    final f = File('${dir.path}/site_1.png')
      ..writeAsBytesSync(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
      ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: FieldNotesScreen(
          location: ValueNotifier<SessionLocation?>(null),
          searching: ValueNotifier(false),
          onChangePosition: () async {},
          loadSitePhotos: ({Directory? dir}) async => f.existsSync() ? [f] : const [],
          takePhoto: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('1 site photo: they move into the session folder at Start.'), findsOneWidget);
    final thumb = find.ancestor(of: find.byType(Image), matching: find.byType(InkWell)).first;

    await tester.tap(thumb);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete photo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete this site photo?'), findsOneWidget);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(f.existsSync(), isTrue);
    expect(find.text('Delete this site photo?'), findsNothing);

    await tester.tap(thumb);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete photo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await tester.tap(find.text('Delete'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(f.existsSync(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
