// Round 256: Identify organisms says when kept video frames are not saved yet
// (the Video screen was left while saving). Their track IDs have no photo, so
// the crop planner skips them without a word; the pre-flight now counts them
// and links the Video screen. 360-px screen, no overflow.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('identify_unsaved_frames');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => tmp.path,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    tmp.deleteSync(recursive: true);
  });

  testWidgets('counts the track IDs whose kept frames are not saved yet', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final session = Directory('${tmp.path}/sessions/video')..createSync(recursive: true);
    Directory('${session.path}/videos').createSync();
    File('${session.path}/videos/a.mp4').writeAsStringSync('video');
    File('${session.path}/session.jsonl').writeAsStringSync(
      '{"type":"start_of_session","time_ms":1000,"source":"imported_video","file_token":"t3st"}\n',
    );
    // Analysed at 10 frames/s: one insect rests for 3 s at the start, another 20 s later.
    const s0 = 1000000;
    File('${session.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      [
        jsonEncode({
          'type': 'video_run_start',
          'time_ms': 111,
          'settings': {'model': 'm.tflite', 'analysis_fps': 10},
        }),
        '{"type":"video_clip_start","clip":"a.mp4","start_epoch_ms":$s0,"width":1920,"height":1080}',
        for (var t = 0; t <= 25000; t += 100)
          jsonEncode({
            'type': 'raw_detections',
            'frame_ms': s0 + t,
            'clip': 'a.mp4',
            'pts_us': t * 1000,
            'frame': t * 30 ~/ 1000,
            'boxes': [
              if (t <= 3000) [0.2, 0.4, 0.25, 0.48, 0.9, 0],
              if (t >= 20000 && t <= 23000) [0.6, 0.4, 0.65, 0.48, 0.9, 0],
            ],
          }),
        '{"type":"video_clip_done","clip":"a.mp4","frame_width":1920,"frame_height":1080,'
            '"roi_px":[0,0,1920,1080],"class_names":["bee"]}',
      ].join('\n'),
    );
    await tester.runAsync(
      () => VideoTracker.run(
        session,
        const SessionConfig(),
        keep: const KeepFramesSettings(stepSeconds: 1, durationSeconds: 10),
      ),
    );
    // Only the first insect's frames were saved before the Video screen was left.
    final kept = (await tester.runAsync(() => VideoTracker.readKeptFrames(session)))!;
    Directory('${session.path}/roi_frames').createSync();
    final first = [for (final k in kept) if (k.frameMs < s0 + 10000) k];
    for (final k in first) {
      File('${session.path}/roi_frames/${k.file}').writeAsStringSync('jpeg');
    }
    expect(first, isNotEmpty);
    expect(kept.length, greaterThan(first.length));

    await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session)));
    final note = find.textContaining('kept frames of the videos are saved');
    for (var i = 0; i < 250 && find.byType(ListView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final list = find.byType(Scrollable).first;
    for (var i = 0; i < 250 && note.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      if (note.evaluate().isEmpty) await tester.drag(list, const Offset(0, -200));
    }
    expect(
      find.text(
        'Only ${first.length} of ${kept.length} kept frames of the videos are saved, so 1 of 2 track IDs '
        'have no photo to identify yet. Save the remaining frames on the Video screen first.',
      ),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(find.text('Open the Video screen'), 100, scrollable: list);
    expect(find.text('Open the Video screen'), findsOneWidget);
    expect(find.textContaining('No crops to identify'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
