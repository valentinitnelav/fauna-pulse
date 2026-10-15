// Round 308: the tracker controls shared by the camera Settings and the Track
// IDs card of "Find animals in videos" (widgets/tracker_tuning_fields.dart).
// The camera Settings must still edit the camera's SessionConfig with them.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/settings_sheet.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/numeric_setting_field.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/tracker_tuning_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('"New-track confidence" is raised to 0.10 above the confidence, never lowered', () {
    expect(newTrackFloor(0.25), 0.35);
    expect(newTrackFloor(0.1), 0.30, reason: 'never below 0.30');
    expect(newTrackFloor(0.9), 0.95, reason: 'never above 0.95');
    final (p, cp) = raiseNewTrackFloor(const ByteTrackParams(), const CBiouParams(highThresh: 0.8), 0.6);
    expect(p.highThresh, closeTo(0.7, 1e-9));
    expect(cp.highThresh, 0.8, reason: 'already above the floor');
    expect(p.matchThresh, const ByteTrackParams().matchThresh, reason: 'the rest stays');
  });

  group('camera Settings', () {
    late Directory tmp;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('faunapulse_tracker_settings');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        (call) async => tmp.path,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
      tmp.deleteSync(recursive: true);
    });

    testWidgets('the shared tracker controls still edit the camera\'s settings', (tester) async {
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
                      builder: (_) => const SizedBox(height: 760, child: SettingsSheet(config: SessionConfig())),
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
      await tester.tap(find.text('Detection'));
      // The model list may still show its spinner, so no pumpAndSettle.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final list = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        skipOffstage: true,
      ).first;
      Finder box(String label) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(NumericSettingField)),
        matching: find.byType(TextField),
      );
      Future<void> scrollTo(Finder f) async {
        await tester.scrollUntilVisible(f, 200, scrollable: list);
        await tester.pump();
      }

      final fold = find.text('Advanced (ByteTrack tuning)');
      await scrollTo(fold);
      await tester.tap(fold);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await scrollTo(find.text('Velocity smoothing'));
      await tester.enterText(box('Velocity smoothing'), '0.3');
      await tester.pump();
      final algorithm = find.byType(DropdownButton<TrackerAlgorithm>);
      await scrollTo(algorithm);
      await tester.tap(algorithm);
      await tester.pumpAndSettle();
      await tester.tap(find.text('C-BIoU').last);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Advanced (C-BIoU tuning)'), findsOneWidget);
      await scrollTo(find.text('Search margin, pass 1'));
      await tester.enterText(box('Search margin, pass 1'), '0.4');
      await tester.pump();
      expect(find.text('Velocity smoothing'), findsNothing, reason: 'only the chosen algorithm\'s values');
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(result!.trackerAlgorithm, TrackerAlgorithm.cbiou);
      expect(result!.trackerParams.velocitySmoothing, 0.3);
      expect(result!.cbiouParams.bufferScale1, 0.4);
    });
  });
}
