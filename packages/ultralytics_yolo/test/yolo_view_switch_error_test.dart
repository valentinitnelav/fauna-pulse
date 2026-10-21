// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

// FaunaPulse (round 319): a model that fails to load during an in-place
// switch (a damaged file: "LiteRtException: Failed to compile model") is an
// expected failure the host handles through onModelError. It was also sent to
// FlutterError.reportError, which the app's error hooks save as a crash file,
// one per try. Now it is logged only when the host handles it; without an
// onModelError, or for a programming error, it is still reported.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';
import 'package:ultralytics_yolo/widgets/yolo_controller.dart';
import 'package:ultralytics_yolo/yolo_view.dart';

import 'utils/test_helpers.dart';

/// A controller whose in-place switch fails with a programming error.
class _BuggyController extends YOLOViewController {
  @override
  Future<void> switchModel(
    String modelPath, [
    YOLOTask? task,
    bool useGpu = true,
    int cpuThreads = 0,
  ]) async => throw StateError('bug in switchModel');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a running view on 'a.tflite', switches it to 'b.tflite' (native
  /// setModel fails like a damaged file) and returns what was reported as a
  /// Flutter error and what reached onModelError.
  Future<({List<FlutterErrorDetails> reported, List<Object> handled})>
  switchToDamaged(
    WidgetTester tester, {
    required bool withHandler,
    YOLOViewController? controller,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final singleImageChannel = YOLOTestHelpers.setupMockChannel();
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(singleImageChannel, null);
    });
    final ctrl = controller ?? YOLOViewController();
    final handled = <Object>[];
    Widget view(String path) => MaterialApp(
      home: YOLOView(
        modelPath: path,
        task: YOLOTask.detect,
        controller: ctrl,
        onModelError: withHandler ? (e, _, _) => handled.add(e) : null,
      ),
    );

    await tester.pumpWidget(view('a.tflite'));
    await tester.pump();
    final androidView = tester.widget<AndroidView>(find.byType(AndroidView));
    final viewId =
        (androidView.creationParams! as Map<dynamic, dynamic>)['viewId']
            as String;
    final controlChannel = MethodChannel(
      'com.ultralytics.yolo/controlChannel_$viewId',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (call) async {
          if (call.method == 'setModel') {
            throw PlatformException(
              code: 'MODEL_NOT_FOUND',
              message: 'LiteRtException: Failed to compile model',
            );
          }
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(controlChannel, null);
    });
    androidView.onPlatformViewCreated?.call(7);
    await tester.pump();

    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    try {
      await tester.pumpWidget(view('b.tflite'));
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previous;
    }
    debugDefaultTargetPlatformOverride = null;
    return (reported: reported, handled: handled);
  }

  testWidgets('a damaged model handled by the host is not reported as a crash', (
    tester,
  ) async {
    final r = await switchToDamaged(tester, withHandler: true);
    expect(r.handled, hasLength(1), reason: 'the host still hears about it');
    expect((r.handled.single as PlatformException).code, 'MODEL_NOT_FOUND');
    expect(r.reported, isEmpty, reason: 'no FlutterError, so no crash file');
  });

  testWidgets('without onModelError the failure is still reported', (
    tester,
  ) async {
    final r = await switchToDamaged(tester, withHandler: false);
    expect(r.reported, hasLength(1), reason: 'not lost when nobody listens');
  });

  testWidgets('a programming error in the switch is still reported', (
    tester,
  ) async {
    final r = await switchToDamaged(
      tester,
      withHandler: true,
      controller: _BuggyController(),
    );
    expect(r.reported, hasLength(1));
    expect(r.reported.single.exception, isA<StateError>());
    expect(r.handled, hasLength(1), reason: 'the host can still recover');
  });
}
