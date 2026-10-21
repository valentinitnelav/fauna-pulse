// Round 319 part 2 (S4d): the storage note on the "Import videos" screen sent
// the user to a button called "Copy videos to gallery", but the session
// summary's button says "Copy videos" (under the label "Copy videos to
// Gallery", on the Video tab). The note now quotes the button as on screen.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/video_import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoInfo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const thermal = MethodChannel('faunapulse/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319b_s4_note');
    messenger.setMockMethodCallHandler(thermal, (call) async => {'freeBytes': 5 << 30, 'totalBytes': 64 << 30});
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(thermal, null);
    tmp.deleteSync(recursive: true);
  });

  testWidgets('the storage note names the summary button as it is on screen', (tester) async {
    const name = 'VID_20260924_155954.mp4';
    final file = File('${tmp.path}/$name')..writeAsStringSync('video');
    Future<VideoInfo> info(String path) async =>
        const VideoInfo(durationMs: 30000, width: 1920, height: 1080, mime: 'video/avc');
    await tester.pumpWidget(
      MaterialApp(
        home: VideoImportScreen(
          files: [PickedVideo(file.path, name, 40 << 20)],
          infoFn: info,
          sessionsDir: Directory('${tmp.path}/sessions'),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final note = find.textContaining('they take storage twice');
    await tester.scrollUntilVisible(note, 200, scrollable: find.byType(Scrollable).first);
    final text = tester.widget<Text>(note).data!;
    expect(text, contains('(open the session, Video tab, "Copy videos")'));
    expect(text, isNot(contains('Copy videos to gallery')));
  });
}
