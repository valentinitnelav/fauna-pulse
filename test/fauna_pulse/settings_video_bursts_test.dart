// Round 238: the "Save bursts as" block of the settings sheet at phone width
// (360 px): the video frame rate, the storage estimate, the camera-cap
// warning, and the photo settings greyed out for video bursts.

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
    tmp = Directory.systemTemp.createTempSync('faunapulse_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => tmp.path,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    tmp.deleteSync(recursive: true);
  });

  Future<SessionConfig?> open(WidgetTester tester, SessionConfig config) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SessionConfig? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<SessionConfig>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SizedBox(height: 760, child: SettingsSheet(config: config)),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  // The visible tab's vertical list (the tab pager is a horizontal
  // Scrollable too, and dragging it would switch tabs).
  final list = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    skipOffstage: true,
  ).first;

  testWidgets('video bursts: frame rate, estimate, cap warning, photo step greyed', (tester) async {
    final config = const SessionConfig(sessionMinutes: 60, cameraFpsCap: 10).copyWith(
      captureTrigger: CaptureTrigger.timelapse,
      timeLapseSaveAs: TimeLapseSaveAs.video,
      durationSeconds: 10,
      timeLapseGapSeconds: 30,
    );
    await open(tester, config);
    await tester.scrollUntilVisible(find.text('Save bursts as'), 200, scrollable: list);
    expect(find.text('Video (MP4), AI later on "Run AI on videos"'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('per hour of video'), 200, scrollable: list);
    expect(find.text('Video frame rate'), findsOneWidget);
    expect(find.textContaining('The camera is capped at 10 frames per second'), findsOneWidget);
    expect(find.textContaining('A 60 min session records about 15 min of video'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Not used for video bursts: a clip keeps every frame.'), 200, scrollable: list);
    expect(find.text('Burst duration (clip length)'), findsOneWidget);
    expect(find.textContaining('whole multiple of the step'), findsNothing);
    final e = tester.takeException();
    if (e != null) debugPrint('OVERFLOW ${(e as FlutterError).toStringDeep()}');
    expect(e, isNull);

    // Photos tab: the photo source and its companion are greyed with a note.
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Not used for time-lapse video bursts'),
      200,
      scrollable: list,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('photo bursts: no video fields; choosing video shows them', (tester) async {
    final config = const SessionConfig().copyWith(captureTrigger: CaptureTrigger.timelapse);
    final done = open(tester, config);
    await done;
    await tester.scrollUntilVisible(find.text('Save bursts as'), 200, scrollable: list);
    expect(find.text('Video frame rate'), findsNothing);
    expect(find.text('Photo duration'), findsOneWidget);
    expect(find.text('Not used for video bursts: a clip keeps every frame.'), findsNothing);
    await tester.tap(find.byType(DropdownButton<TimeLapseSaveAs>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Video (MP4), AI later on "Run AI on videos"').last);
    await tester.pumpAndSettle();
    expect(find.text('Video frame rate'), findsOneWidget);
    expect(find.textContaining('The camera is capped'), findsNothing, reason: 'default cap 15 = default video rate');
    expect(tester.takeException(), isNull);
  });

  testWidgets('other capture triggers show no "Save bursts as"', (tester) async {
    await open(tester, const SessionConfig());
    await tester.pumpAndSettle();
    expect(find.text('Save bursts as'), findsNothing);
  });
}
