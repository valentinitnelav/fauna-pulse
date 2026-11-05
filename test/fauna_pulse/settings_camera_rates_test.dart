// Round 355: the Power tab lists only the frame rates this camera offers, and
// the detector follows the camera unless the user typed a rate of their own.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('faunapulse_rates');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => tmp.path,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    tmp.deleteSync(recursive: true);
  });

  // The visible tab's vertical list (the tab pager is a horizontal Scrollable).
  final tabList = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    skipOffstage: true,
  ).first;

  /// Opens the sheet on the Power tab at phone width and scrolls to the list.
  Future<SettingsDraft> open(WidgetTester tester, SessionConfig config, List<int> rates) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final draft = SettingsDraft();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SizedBox(
            height: 760,
            child: SettingsSheet(config: config, draft: draft, cameraFrameRates: rates),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Power'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Camera frame rate'),
      200,
      scrollable: tabList,
    );
    await tester.pumpAndSettle();
    return draft;
  }

  DropdownButton<int> list(WidgetTester tester) => tester.widget(find.byType(DropdownButton<int>));
  List<int?> choices(WidgetTester tester) => list(tester).items!.map((i) => i.value).toList();

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('only the rates of this camera are listed, plus No limit', (tester) async {
    await open(tester, const SessionConfig(), const [12, 15, 30]);
    expect(choices(tester), [12, 15, 30, 0]);
    expect(list(tester).value, 15);
    expect(find.textContaining('shown once its picture is on screen'), findsNothing);
  });

  testWidgets('another phone shows its own rates', (tester) async {
    await open(tester, const SessionConfig(), const [15, 20, 24, 30]);
    expect(choices(tester), [15, 20, 24, 30, 0]);
  });

  testWidgets('a saved rate this camera lacks shows the rate that runs', (tester) async {
    await open(tester, const SessionConfig(cameraFpsCap: 20), const [12, 15, 30]);
    expect(list(tester).value, 15);
  });

  testWidgets('a lens without 15 shows its next rate up', (tester) async {
    await open(tester, const SessionConfig(), const [16, 30]);
    expect(list(tester).value, 16);
  });

  testWidgets('a detector left at 0 follows the chosen camera rate', (tester) async {
    final draft = await open(tester, const SessionConfig(), const [12, 15, 30]);
    await tester.scrollUntilVisible(find.text('Same as the camera: 15 FPS.'), -200, scrollable: tabList);
    await tester.scrollUntilVisible(find.byType(DropdownButton<int>), 200, scrollable: tabList);
    await choose(tester, '30 FPS');
    expect(draft.value!.cameraFpsCap, 30);
    expect(draft.value!.inferenceFps, 0, reason: 'only the chosen setting changes');
    expect(draft.value!.effectiveInferenceFps, 30);
    await tester.scrollUntilVisible(find.text('Same as the camera: 30 FPS.'), -200, scrollable: tabList);
  });

  testWidgets('a typed detector rate above the camera says which rate is used', (tester) async {
    await open(tester, const SessionConfig(inferenceFps: 20), const [12, 15, 30]);
    await tester.scrollUntilVisible(find.text('Used: 15 FPS, the Camera frame rate below.'), -200, scrollable: tabList);
    expect(find.textContaining('Same as the camera'), findsNothing);
  });

  testWidgets('without a list only the stored rate is offered, and it stays after No limit', (tester) async {
    final draft = await open(tester, const SessionConfig(cameraFpsCap: 20), const []);
    expect(choices(tester), [20, 0]);
    expect(find.textContaining('shown once its picture is on screen'), findsOneWidget);
    await choose(tester, 'No limit (the phone chooses)');
    expect(draft.value!.cameraFpsCap, 0);
    expect(choices(tester), [20, 0]);
  });
}
