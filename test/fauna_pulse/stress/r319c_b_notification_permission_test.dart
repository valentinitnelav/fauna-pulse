// Round 319, part 3 (phone test P1X, step 1): the app asked for the notification permission only
// when a recording or a schedule started. "Identify organisms", "Find animals in videos" and "Find
// animals in photos" never asked, so on Android 13+ their notifications (the progress, "Animals
// found") never showed for a user who never recorded. Now the hold on the analysis service, taken
// at the tap on each of their Start buttons, asks: only while the app is on screen, once per app
// start, not when Android says it is denied for good, and the run never waits for the answer.
//
// permission_handler's channel is faked (Permission.notification is 17; status 0 = denied,
// 1 = granted, 4 = permanently denied).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/identification_run.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  const keepAliveChannel = MethodChannel('faunapulse/keepalive');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
  late Directory tmp;
  late List<String> calls;
  late List<String> asked;
  late int status;

  /// The system dialog: the user has not answered yet (never, in these tests).
  late Completer<Map<int, int>> answer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319c_b_permission');
    IdentificationRun.resetForTest();
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    wakelockPlusPlatformInstance = FakeWakelock();
    PackageInfo.setMockInitialValues(appName: 'FaunaPulse', packageName: 'test', version: '0.0.0', buildNumber: '1', buildSignature: '');
    SharedPreferences.setMockInitialValues({'identify_model': 'test-model.tflite', 'identify_pack': 'tiny_pack.fpack'});
    AnalysisKeepAlive.resetForTest();
    AnalysisKeepAlive.debugIsAndroid = true;
    messenger.setMockMethodCallHandler(keepAliveChannel, (call) async => true);
    status = 0;
    asked = [];
    answer = Completer();
    messenger.setMockMethodCallHandler(permissions, (call) async {
      asked.add('${call.method} ${call.arguments}');
      if (call.method == 'checkPermissionStatus') return status;
      if (call.method == 'requestPermissions') return answer.future;
      return null;
    });
    calls = [];
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'embedderLoad':
          return {'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': pack.dim, 'loadMs': 1.0};
        case 'embedderRun':
          final n = ((call.arguments as Map)['images'] as List).length;
          return {
            'dim': pack.dim,
            'count': n,
            'vectors': Float32List.fromList([for (var i = 0; i < n; i++) ...pack.matrix.sublist(0, pack.dim)]),
            'ms': 1.0,
          };
      }
      return null;
    });
  });
  tearDown(() {
    AnalysisKeepAlive.debugIsAndroid = null;
    for (final c in [pathChannel, yoloChannel, keepAliveChannel, permissions]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final s in states) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void toForeground(WidgetTester tester) =>
      lifecycle(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
  void toBackground(WidgetTester tester) =>
      lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('"Identify organisms": Start asks; the run goes on while the question is open', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = await identifySession(tester, tmp);
    toForeground(tester);
    await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: dir)));
    final start = find.text('Start', skipOffstage: false);
    await pumpUntilDone(
      tester,
      () => find.textContaining('crops from 1 track ID', skipOffstage: false).evaluate().isNotEmpty,
      'the crops are counted (Start can be tapped)',
    );
    await tester.ensureVisible(start);
    await tester.pump();
    expect(asked, isEmpty, reason: 'nothing is asked before Start');
    await tester.tap(start);
    await pumpUntilDone(
      tester,
      () => calls.contains('embedderClose') && find.text('Continue / re-run', skipOffstage: false).evaluate().isNotEmpty,
      'the run ends',
    );
    expect(asked, ['checkPermissionStatus 17', 'requestPermissions [17]']);
    expect(answer.isCompleted, isFalse, reason: 'the run did not wait for the answer');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the Find screens\' Start (their hold on the analysis service) asks too, once per app start',
      (tester) async {
    toForeground(tester);
    final videos = AnalysisKeepAlive.acquire(title: kFindVideosKeepAliveTitle);
    await flush(tester);
    expect(asked, ['checkPermissionStatus 17', 'requestPermissions [17]']);
    videos.release();
    final photos = AnalysisKeepAlive.acquire(title: kFindPhotosKeepAliveTitle);
    await flush(tester);
    photos.release();
    expect(asked, hasLength(2), reason: 'not a second dialog in the same app start');
  });

  testWidgets('not asked while the app is in the background (no dialog can show)', (tester) async {
    toBackground(tester);
    final hold = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
    await flush(tester);
    hold.release();
    expect(asked, isEmpty);
    toForeground(tester);
  });

  testWidgets('not asked when Android says it is denied for good, nor when it is granted', (tester) async {
    toForeground(tester);
    status = 4;
    AnalysisKeepAlive.acquire(title: kFindPhotosKeepAliveTitle).release();
    await flush(tester);
    expect(asked, ['checkPermissionStatus 17']);

    AnalysisKeepAlive.resetForTest();
    asked.clear();
    status = 1;
    AnalysisKeepAlive.acquire(title: kFindPhotosKeepAliveTitle).release();
    await flush(tester);
    expect(asked, ['checkPermissionStatus 17']);
  });
}
