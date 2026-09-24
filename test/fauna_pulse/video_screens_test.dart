// Round 227 screens for imported videos: the import screen, "Run AI on
// videos" and its square editor. Each gets the 360-px layout check (no
// overflow, last control above a 48-px navigation bar); the import screen
// also runs a real import into a temp folder, and the summary must name the
// imported session's mode instead of guessing a camera mode.
//
// Follows summary_bottom_inset_test.dart's async recipe (sync fixture IO,
// runAsync/pump interleave; see that file's header for why).

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoInfo;

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

Future<void> _pumpUntil(WidgetTester tester, Finder ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    // Advance the fake clock too: the session logger yields with a
    // zero-length timer, which a bare pump() never fires.
    await tester.pump(const Duration(milliseconds: 20));
    if (ready.evaluate().isNotEmpty) break;
  }
  expect(ready, findsWidgets, reason: 'content never appeared: $ready');
}

Directory _tempDir(String name) {
  final d = Directory.systemTemp.createTempSync(name);
  addTearDown(() {
    try {
      d.deleteSync(recursive: true);
    } catch (_) {}
  });
  return d;
}

/// A screen with one button that pushes [page] and keeps what it pops.
Widget _host(Widget page, void Function(Object?) onPopped) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () async => onPopped(await Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => page))),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400)); // route transition
}

void main() {
  testWidgets('import screen fits 360 px, leaves out unusable files and imports the rest', (tester) async {
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_import_screen');
    final cache = Directory('${tmp.path}/cache')..createSync();
    final sessions = Directory('${tmp.path}/sessions');
    final names = [
      'VID_20260924_155954.mp4',
      'VID-20260920-WA0003.mp4', // WhatsApp copy: no stored time
      'a_very_long_file_name_from_a_collaborators_camera_meadow_plot_7_clip_0001.mp4',
      'notes.avi',
      'hdr_clip.mp4',
    ];
    final files = [
      for (final n in names)
        PickedVideo((File('${cache.path}/$n')..writeAsStringSync('video $n')).path, n, 1000),
    ];
    Future<VideoInfo> info(String path) async => VideoInfo(
      durationMs: 30000,
      width: 1920,
      height: 1080,
      mime: 'video/avc',
      unsupportedReason: path.contains('hdr') ? '10-bit (HDR) video.' : null,
    );

    Object? popped;
    await tester.pumpWidget(
      _host(VideoImportScreen(files: files, infoFn: info, sessionsDir: sessions), (r) => popped = r),
    );
    await _open(tester);
    await _pumpUntil(tester, find.text('Change…'));
    expect(tester.takeException(), isNull);
    // The list builds lazily: scroll to what lies below the fold.
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Left out (2):'), 200, scrollable: list);
    final button = find.text('Import 3 clips');
    await tester.scrollUntilVisible(button, 200, scrollable: list);
    await tester.pump(); // lay out after the final ensureVisible jump
    expectAboveBottomInset(tester, button);

    await tester.tap(button);
    await _pumpUntil(tester, find.text('Run AI on these videos'));
    expect(tester.takeException(), isNull);
    final dir = sessions.listSync().whereType<Directory>().single;
    expect(VideoDetector.clipsOf(dir), hasLength(3));

    await tester.tap(find.text('Run AI on these videos'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(popped, dir.path); // home opens the analysis screen on it
  });

  testWidgets('video analysis screen fits 360 px and offers to continue a half-done session', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_analysis_screen');
    final session = Directory('${tmp.path}/Meadow plot 7 near the old oak tree second visit');
    Directory('${session.path}/videos').createSync(recursive: true);
    for (final c in ['a.mp4', 'b.mp4']) {
      File('${session.path}/videos/$c').writeAsStringSync('video');
    }
    File('${session.path}/session.jsonl').writeAsStringSync(
      [
        '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}',
        '{"type":"video_clip","time_ms":1000,"file":"videos/a.mp4","duration_ms":30000}',
        '{"type":"video_clip","time_ms":31000,"file":"videos/b.mp4","duration_ms":30000}',
        '{"type":"end_of_session","time_ms":61000,"ended_normally":true}',
      ].join('\n'),
    );
    // A first run with today's default settings finished clip a only.
    final settings = const VideoRunConfig(
      modelPath: 'test_model',
      modelName: 'test_model.tflite',
      confidence: 0.25,
      iou: 0.7,
      useGpu: true,
    ).identity;
    File('${session.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      [
        jsonEncode({'type': 'video_run_start', 'settings': settings}),
        '{"type":"video_clip_done","clip":"a.mp4"}',
      ].join('\n'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: session.path,
          sessionsDir: tmp,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    await _pumpUntil(tester, find.text('About 900 frames for this session.'));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('1 analyzed)'), findsOneWidget);

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Continue (1 of 2 clips left)'), 200, scrollable: list);
    final footer = find.textContaining('Long runs:');
    await tester.scrollUntilVisible(footer, 200, scrollable: list);
    await tester.pump();
    expectAboveBottomInset(tester, footer);
  });

  testWidgets('square editor fits 360 px and returns a side on the 32-pixel grid', (tester) async {
    simulateBottomSystemBar(tester);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    Object? popped;
    await tester.pumpWidget(
      _host(
        VideoSquareEditor(frameJpeg: png, frameWidth: 1920, frameHeight: 1080, initial: Roi.defaultRoi),
        (r) => popped = r,
      ),
    );
    await _open(tester);
    expect(tester.takeException(), isNull);
    final use = find.text('Use this square');
    expectAboveBottomInset(tester, use);

    // Slider to the far right: the biggest square the 1080-px height allows.
    await tester.drag(find.byType(Slider), const Offset(1000, 0));
    await tester.pump();
    expect(find.text('Square: 1056 × 1056 px of the 1920 × 1080 video'), findsOneWidget);

    await tester.tap(use);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final roi = popped as Roi;
    expect(roi.sideFraction * 1920, closeTo(1056, 1e-6));
  });

  test('video analysis settings survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    await VideoAnalysisPrefs(modelId: 'big_model', confidence: 0.4, iou: 0.5, analysisFps: 5, thermalLimitC: 42).save();
    final p = await VideoAnalysisPrefs.load();
    expect([p.modelId, p.confidence, p.iou, p.analysisFps, p.thermalLimitC], ['big_model', 0.4, 0.5, 5, 42]);

    await (p..modelId = null).save();
    expect((await VideoAnalysisPrefs.load()).modelId, isNull);
  });

  testWidgets('summary of an imported session names it instead of a camera mode', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final tmp = _tempDir('video_import_summary');
    final cache = Directory('${tmp.path}/cache')..createSync();
    final sessions = Directory('${tmp.path}/sessions')..createSync();
    const name = 'VID_20260924_155954.mp4';
    final f = File('${cache.path}/$name')..writeAsStringSync('video');
    final dir = await tester.runAsync(
      () => importVideos(
        sessionsDir: sessions,
        sessionName: 'Meadow',
        clips: [
          ImportClip(
            path: f.path,
            name: name,
            sizeBytes: 5,
            info: const VideoInfo(durationMs: 30000, width: 1920, height: 1080, mime: 'video/avc'),
            guess: guessClipStart(fileName: name, durationMs: 30000),
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SessionSummaryScreen(logFile: File('${dir!.path}/session.jsonl'), initialTabIndex: 2),
      ),
    );
    await _pumpUntil(tester, find.text('Imported videos (AI runs afterwards)'));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
