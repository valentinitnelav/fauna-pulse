// Round 319 (stress test 2026-10-20, report item 13, first half): the "Import
// videos" screen read the free storage once, when it opened. After the user
// freed space in another app and came back, the red "Not enough free
// storage" line stayed and Import stayed off; and space used up after the
// screen opened was not seen before the copy started.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/video_import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoInfo;

class _FakePaths extends PathProviderPlatform {
  final String path;
  _FakePaths(this.path);

  @override
  Future<String?> getExternalStoragePath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const thermal = MethodChannel('faunapulse/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;
  var freeBytes = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319_l3_free');
    PathProviderPlatform.instance = _FakePaths(tmp.path);
    messenger.setMockMethodCallHandler(thermal, (call) async => {'freeBytes': freeBytes, 'totalBytes': 64 << 30});
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(thermal, null);
    tmp.deleteSync(recursive: true);
  });

  Future<void> wait(WidgetTester tester, [int rounds = 15]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> open(WidgetTester tester) async {
    final cache = Directory('${tmp.path}/cache')..createSync();
    const name = 'VID_20260924_155954.mp4';
    final file = File('${cache.path}/$name')..writeAsStringSync('video');
    Future<VideoInfo> info(String path) async =>
        const VideoInfo(durationMs: 30000, width: 1920, height: 1080, mime: 'video/avc');
    // No sessionsDir: the screen finds the sessions folder and reads the
    // free storage as on the phone.
    await tester.pumpWidget(
      MaterialApp(
        home: VideoImportScreen(files: [PickedVideo(file.path, name, 40 << 20)], infoFn: info),
      ),
    );
    await wait(tester);
  }

  Finder importButton() => find.widgetWithText(FilledButton, 'Import 1 clip');
  bool importEnabled(WidgetTester tester) => tester.widget<FilledButton>(importButton()).onPressed != null;
  final notEnough = find.textContaining('Not enough free storage');

  testWidgets('checks again when the app comes back to the front', (tester) async {
    freeBytes = 64 << 20;
    await open(tester);
    await tester.scrollUntilVisible(importButton(), 200, scrollable: find.byType(Scrollable).first);
    expect(notEnough, findsOneWidget);
    expect(importEnabled(tester), isFalse);

    // The user frees space in the Files app, then returns.
    freeBytes = 5 << 30;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await wait(tester);

    expect(notEnough, findsNothing);
    expect(importEnabled(tester), isTrue);
  });

  testWidgets('checks again before the copy starts', (tester) async {
    freeBytes = 5 << 30;
    await open(tester);
    await tester.scrollUntilVisible(importButton(), 200, scrollable: find.byType(Scrollable).first);
    expect(notEnough, findsNothing);

    // Storage filled up while the screen was open.
    freeBytes = 64 << 20;
    await tester.tap(importButton());
    await wait(tester);

    expect(find.text('Find animals in these videos'), findsNothing);
    expect(notEnough, findsOneWidget);
    // The list builds lazily: the longer red line can push the button out.
    await tester.scrollUntilVisible(importButton(), 200, scrollable: find.byType(Scrollable).first);
    expect(importEnabled(tester), isFalse);
    final sessions = Directory('${tmp.path}/sessions');
    expect(sessions.existsSync() ? sessions.listSync() : const [], isEmpty);
  });

  testWidgets('a copy that fails shows a plain message, not the raw error', (tester) async {
    final cache = Directory('${tmp.path}/cache')..createSync();
    final names = ['VID_20260924_155954.mp4', 'VID_20260924_160100.mp4'];
    final files = [for (final n in names) PickedVideo((File('${cache.path}/$n')..writeAsStringSync('video')).path, n, 5)];
    Future<VideoInfo> info(String path) async =>
        const VideoInfo(durationMs: 30000, width: 1920, height: 1080, mime: 'video/avc');
    final sessions = Directory('${tmp.path}/sessions');
    await tester.pumpWidget(MaterialApp(home: VideoImportScreen(files: files, infoFn: info, sessionsDir: sessions)));
    await wait(tester);
    File(files[1].path).deleteSync(); // the second copy fails
    final button = find.widgetWithText(FilledButton, 'Import 2 clips');
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(button);
    await wait(tester);

    expect(find.textContaining('FileSystemException'), findsNothing);
    // The first clip went into the deleted folder: only a new pick can retry.
    expect(find.text('The videos could not be copied. Go back and pick the videos again.'), findsOneWidget);
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(sessions.listSync(), isEmpty);
  });
}
