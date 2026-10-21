// Round 319, part 3 (owner direction 2026-10-21: FaunaPulse is a measuring tool; the heavy step,
// identification, needs the app kept on the screen, and users are told so). One plain line on the
// Find screens under "Also identify them" while it is on, and on "Identify organisms" near Start
// and under the run's progress. The texts are written out here, so this file also runs against
// the code before the change, where it fails.

import 'dart:async';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_choice.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_run.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_choice_fields.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:fauna_pulse/fauna_pulse/services/analysis_keepalive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';
import 'r319c_b_identify_fixture.dart';

const _find =
    'Identification needs a lot of memory. Keep FaunaPulse on the screen until it ends: if you switch to '
    'another app, it may wait, or Android may stop it.';
const _identify =
    'Identification needs a lot of memory. Keep FaunaPulse on the screen until it ends: if you switch to '
    'another app, Android may stop it.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319c_b_keep');
    IdentificationRun.resetForTest();
    AnalysisKeepAlive.resetForTest();
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    wakelockPlusPlatformInstance = FakeWakelock();
    PackageInfo.setMockInitialValues(appName: 'FaunaPulse', packageName: 'test', version: '0.0.0', buildNumber: '1', buildSignature: '');
    SharedPreferences.setMockInitialValues({'identify_model': 'test-model.tflite', 'identify_pack': 'tiny_pack.fpack'});
  });
  tearDown(() {
    for (final c in [pathChannel, yoloChannel]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A 320 px wide phone (the smallest checked): the line must wrap, not overflow.
  void smallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('Find screens: the line shows under "Also identify them" only while it is on', (tester) async {
    smallPhone(tester);
    Widget section(bool on) => MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: SafeArea(
              child: ListView(
                children: [
                  AlsoIdentifySection(
                    value: on,
                    onChanged: (_) {},
                    choice: IdentificationChoice(),
                    onChoiceChanged: (_) {},
                    onManage: () {},
                  ),
                ],
              ),
            ),
          ),
        );
    await tester.pumpWidget(section(true));
    await tester.pump();
    expect(find.text(_find), findsOneWidget);
    expect(tester.takeException(), isNull);
    final line = tester.getRect(find.text(_find));
    expect(line.right, lessThanOrEqualTo(320));
    expect(line.top, greaterThan(tester.getRect(find.text('Also identify them')).bottom), reason: 'under the switch');

    await tester.pumpWidget(section(false));
    await tester.pump();
    expect(find.text(_find), findsNothing);
  });

  testWidgets('"Identify organisms": the line shows near Start, and under the progress of a run', (tester) async {
    smallPhone(tester);
    final dir = await identifySession(tester, tmp);
    // The model load never answers: the page stays on the run's progress.
    final load = Completer<Object?>();
    messenger.setMockMethodCallHandler(yoloChannel, (call) async => call.method == 'embedderLoad' ? load.future : null);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: IdentificationScreen(sessionDir: dir)));
    final start = find.text('Start', skipOffstage: false);
    await pumpUntilDone(
      tester,
      () => find.textContaining('crops from 1 track ID', skipOffstage: false).evaluate().isNotEmpty,
      'the crops are counted (Start can be tapped)',
    );
    final line = find.text(_identify, skipOffstage: false);
    expect(line, findsOneWidget);
    await tester.ensureVisible(line);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(line).right, lessThanOrEqualTo(320));
    expect(
      tester.getRect(start).top - tester.getRect(line).bottom,
      inInclusiveRange(0, 40),
      reason: 'right above the Start button',
    );
    await tester.ensureVisible(start);
    await tester.pump();

    await tester.tap(start);
    await pumpUntilDone(tester, () => find.textContaining('Loading the model').evaluate().isNotEmpty, 'the run shows');
    expect(find.text(_identify, skipOffstage: false), findsOneWidget, reason: 'also while the run goes on');
    expect(find.text('Cancel (keeps what is done)'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Cancel (keeps what is done)'));
    load.complete({'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': 4, 'loadMs': 1.0});
    await pumpUntilDone(tester, () => find.text('Test speed', skipOffstage: false).evaluate().isNotEmpty, 'the run ends');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
