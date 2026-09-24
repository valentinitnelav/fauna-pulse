// Round 227 screens for imported videos: the import screen, "Run AI on
// videos" (with its Visits section, r228) and its square editor. Each gets the 360-px layout check (no
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
import 'summary_tabs_test.dart' show expectSummaryRowValue;

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
    // Clip a is done, so the Visits section follows; its button is the last row.
    final findVisits = find.text('Find visits');
    await tester.scrollUntilVisible(findVisits, 200, scrollable: list);
    await tester.pump();
    expectAboveBottomInset(tester, findVisits);
  });

  testWidgets('Find visits tracks the finished clips and offers the results (r228)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_visits_screen');
    final session = Directory('${tmp.path}/Meadow plot 7 near the old oak tree second visit');
    Directory('${session.path}/videos').createSync(recursive: true);
    for (final c in ['a.mp4', 'b.mp4']) {
      File('${session.path}/videos/$c').writeAsStringSync('video');
    }
    File('${session.path}/session.jsonl').writeAsStringSync(
      '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}\n'
      '{"type":"end_of_session","time_ms":61000,"ended_normally":true}\n',
    );
    final settings = const VideoRunConfig(
      modelPath: 'test_model',
      modelName: 'test_model.tflite',
      confidence: 0.25,
      iou: 0.7,
      useGpu: true,
    ).identity;
    // Clip a analysed at 10 fps with one insect resting for 3 s; b not yet.
    File('${session.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      [
        jsonEncode({'type': 'video_run_start', 'time_ms': 111, 'settings': settings}),
        '{"type":"video_clip_start","clip":"a.mp4","start_epoch_ms":1000000,"width":1920,"height":1080}',
        for (var t = 0; t <= 3000; t += 100)
          jsonEncode({
            'type': 'raw_detections',
            'frame_ms': 1000000 + t,
            'clip': 'a.mp4',
            'pts_us': t * 1000,
            'frame': t * 30 ~/ 1000,
            'boxes': [
              [0.4, 0.4, 0.45, 0.48, 0.9, 0],
            ],
          }),
        '{"type":"video_clip_done","clip":"a.mp4","frame_width":1920,"frame_height":1080,'
            '"roi_px":[0,0,1920,1080],"class_names":["bee"]}',
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
    await _pumpUntil(tester, find.textContaining('1 analyzed)'));
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Find visits'), 200, scrollable: list);
    await tester.pump();
    await tester.tap(find.text('Find visits'));
    await _pumpUntil(tester, find.text('Share results'));
    expect(tester.takeException(), isNull);
    expect(find.text('Found 1 visit in 1 clip.'), findsOneWidget);
    expect(find.text('1 visit in 1 of 2 clips (occlusion tolerance 3.0 s, minimum visit 0.2 s).'), findsOneWidget);
    expect(find.text('Find visits again'), findsOneWidget);
    expect(File('${session.path}/visits.csv').existsSync(), isTrue);
    expect(File('${session.path}/mot/a.txt').existsSync(), isTrue);

    final share = find.text('Share results');
    await tester.scrollUntilVisible(share, 200, scrollable: list);
    await tester.pump();
    expectAboveBottomInset(tester, share);
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
    await VideoAnalysisPrefs(
      modelId: 'big_model',
      confidence: 0.4,
      iou: 0.5,
      analysisFps: 5,
      thermalLimitC: 42,
      occlusionSeconds: 5.0,
      minVisitSeconds: 0.5,
    ).save();
    final p = await VideoAnalysisPrefs.load();
    expect(
      [p.modelId, p.confidence, p.iou, p.analysisFps, p.thermalLimitC, p.occlusionSeconds, p.minVisitSeconds],
      ['big_model', 0.4, 0.5, 5, 42, 5.0, 0.5],
    );

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

  // Round 229: once "Find visits" has run, the summary reads the visits from
  // post_tracks.jsonl and the Setup tab shows what the video screen used.
  testWidgets('summary of an imported session shows visits found afterwards', (tester) async {
    simulateBottomSystemBar(tester); // 360 px wide
    SharedPreferences.setMockInitialValues({});
    final tmp = _tempDir('video_visits_summary');
    final cache = Directory('${tmp.path}/cache')..createSync();
    final sessions = Directory('${tmp.path}/sessions')..createSync();
    const name = 'VID_20260924_155954.mp4';
    final f = File('${cache.path}/$name')..writeAsStringSync('video');
    final dir = (await tester.runAsync(
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
    ))!;
    final log = File('${dir.path}/session.jsonl');
    final t0 = (jsonDecode(log.readAsLinesSync().first) as Map)['time_ms'] as int;
    String rec(String type, Map<String, dynamic> fields) => jsonEncode({'type': type, ...fields});
    File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      '${rec('video_run_start', {
        'settings': {'model': 'bees.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 15, 'roi': [0.5, 0.5, 0.5], 'max_side_px': 1280},
        'model_name': 'Bee model',
        'use_gpu': false,
        'thermal_limit_c': 40,
      })}\n',
    );
    String dets(int ms, List<int> ids) => rec('detections', {
      'time_ms': t0 + ms,
      'frame_ms': t0 + ms,
      'tracks': [
        for (final id in ids) {'track_id': id, 'class_name': 'bee', 'confidence': 0.9},
      ],
    });
    File('${dir.path}/post_tracks.jsonl').writeAsStringSync(
      '${[
        rec('post_track_start', {
          'time_ms': t0,
          'occlusion_seconds': 3.0,
          'min_hits_seconds': 0.2,
          'observed_ms': 30000,
          'tracker': {'algorithm': 'bytetrack', 'trackBuffer': 45},
        }),
        dets(2000, [1]),
        dets(4000, [1, 2]),
        dets(9000, [2]),
        rec('post_track_end', {'time_ms': t0 + 30000, 'visits': 2}),
      ].join('\n')}\n',
    );

    await tester.pumpWidget(
      MaterialApp(home: SessionSummaryScreen(logFile: log, initialTabIndex: 1)),
    );
    await _pumpUntil(tester, find.text('2 (found afterwards in the videos)'));
    expect(find.textContaining('occlusion tolerance 3 s, minimum visit length 0.2 s'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.textContaining('All session settings'), 200, scrollable: scrollable);
    await tester.tap(find.textContaining('All session settings'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Chosen on the "Run AI on videos" screen.'), 200, scrollable: scrollable);
    await expectSummaryRowValue(tester, scrollable, label: 'Confidence threshold', value: '0.25');
    await expectSummaryRowValue(tester, scrollable, label: 'Area to analyze', value: 'a square, 50 % of the picture width');
    await expectSummaryRowValue(tester, scrollable, label: 'Pause above battery temperature', value: '40 °C');
    await expectSummaryRowValue(tester, scrollable, label: 'Clips', value: '1');
    await tester.scrollUntilVisible(find.textContaining('Visits found afterwards with "Find visits"'), 200, scrollable: scrollable);
    await expectSummaryRowValue(tester, scrollable, label: 'Occlusion tolerance', value: '3 s');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
