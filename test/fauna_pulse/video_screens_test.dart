// Round 227 screens for imported videos: the import screen, "Run AI on
// videos" (with its Visits section, r228), its settings screen (round 308)
// and its square editor. Each gets the 360-px layout check (no
// overflow, last control above a 48-px navigation bar); the import screen
// also runs a real import into a temp folder, and the summary must name the
// imported session's mode instead of guessing a camera mode. Round 309: the
// player under the results plays through the fakes of video_test_fakes.dart.
//
// Follows summary_bottom_inset_test.dart's async recipe (sync fixture IO,
// runAsync/pump interleave; see that file's header for why).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart' show IdentifyPrefs;
import 'package:fauna_pulse/fauna_pulse/identification/identification_choice.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_frame_keeper.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart' show KeepFramesSettings, VideoTracker;
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_import_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_tuning_screen.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/model_kind_panel.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/numeric_setting_field.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/video_review_player.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/video_timeline_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show SavedFramesChunk, SavedVideoFrame, VideoInfo;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;
import 'summary_tabs_test.dart' show expectSummaryRowValue;
import 'video_cut_off_test.dart' show box;
import 'video_test_fakes.dart';

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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Round 308: opens "Detection, track ID and identification settings" from
/// the video screen, and closes it with Back.
Future<void> _openTuning(WidgetTester tester) async {
  final entry = find.text('Detection, track ID and identification settings');
  // Round 309: from the top, as the player under the results makes the list long and the entry
  // may be far above.
  final list = find.byType(Scrollable).first;
  tester.state<ScrollableState>(list).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(entry, 200, scrollable: list);
  await tester.pump();
  await tester.tap(entry);
  await _pumpUntil(tester, find.text('Detection')); // the first card's title
  await _settle(tester);
}

/// Round 309: waits until the player under the results has loaded its clip (its time bar shows).
/// Until then it shows a spinner, which pumpAndSettle would wait for forever.
Future<void> _playerReady(WidgetTester tester) =>
    _pumpUntil(tester, find.byKey(const ValueKey('track_id_timeline'), skipOffstage: false));

Future<void> _closeTuning(WidgetTester tester) async {
  await tester.pageBack();
  await _settle(tester);
}

/// Scrolls the settings screen to [finder].
Future<void> _scrollTo(WidgetTester tester, Finder finder, [double delta = 200]) async {
  await tester.scrollUntilVisible(finder, delta, scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

/// The number box of the NumericSettingField labelled [label].
Finder _numberBox(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(NumericSettingField)),
  matching: find.byType(TextField),
);

/// A post_tracks.jsonl of "Find track IDs" on [clips] with the app's default
/// video settings (round 308), so a test session has up-to-date track IDs.
String postTracks(List<String> clips, {bool keepFrames = true, int trackIds = 0}) => [
  jsonEncode({
    'type': 'post_track_start',
    'time_ms': 1,
    'run_id': 1,
    'occlusion_seconds': 3.0,
    'min_hits_seconds': 1.0,
    'tracker': {'algorithm': 'bytetrack', ...const ByteTrackParams().toJson()},
    'clips': clips,
    'keep_frames': keepFrames ? const KeepFramesSettings(stepSeconds: 1, durationSeconds: 10).toJson() : null,
  }),
  jsonEncode({'type': 'post_track_end', 'time_ms': 2, 'track_ids': trackIds}),
].join('\n');

/// Round 274: an insectDCT classifier with its class list, as files (the
/// fields show their sizes), for the "Also identify them" switch.
IdentificationChoice idChoice(Directory dir) {
  final model = File('${dir.path}/insectdct-eff2s_cls.tflite')..writeAsBytesSync([0]);
  final list = File('${dir.path}/insectdct-eff2s_cls.fpack')..writeAsBytesSync([0]);
  return IdentificationChoice.fromFiles([model], [list], {
    list.path: {'model_id': 'insectdct-eff2s_cls', 'kind': 'classes', 'rows': 104, 'sink_rows': 1, 'heads': [0, 1]},
  });
}

/// A session whose only clip, a, was analysed at 10 frames per second: one
/// insect rests in it for 3 s.
Directory _oneTrackSession(Directory tmp) {
  final session = Directory('${tmp.path}/Meadow');
  Directory('${session.path}/videos').createSync(recursive: true);
  File('${session.path}/videos/a.mp4').writeAsStringSync('video');
  File('${session.path}/session.jsonl').writeAsStringSync(
    '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}\n',
  );
  final settings = const VideoRunConfig(
    modelPath: 'test_model',
    modelName: 'test_model.tflite',
    confidence: 0.25,
    iou: 0.7,
    analysisFps: 10,
    useGpu: true,
  ).identity;
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
  return session;
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

/// Writes a small file for each frame asked for, as the phone's decoder
/// would.
class _FakeFrameSaver implements FrameSaveBackend {
  final saved = <String>[];

  @override
  Future<void> open(String path, List<int> roiPx) async {}

  @override
  Future<SavedFramesChunk> save(List<int> ptsUs, List<String> paths) async {
    for (final p in paths) {
      File(p).writeAsStringSync('jpeg');
      saved.add(p.split('/').last);
    }
    return SavedFramesChunk(
      saved: [for (var i = 0; i < ptsUs.length; i++) SavedVideoFrame(i, ptsUs[i], 1920, 1080, 4)],
      missing: const [],
      processed: ptsUs.length,
    );
  }

  @override
  Future<void> close() async {}
}

/// Holds every save until [gate] completes, so a test can act mid-save.
class _GatedFrameSaver extends _FakeFrameSaver {
  final gate = Completer<void>();

  @override
  Future<SavedFramesChunk> save(List<int> ptsUs, List<String> paths) async {
    await gate.future;
    return super.save(ptsUs, paths);
  }
}

void main() {
  // Round 309: "Find animals in videos" plays the analysed videos too.
  late FakeVideoPlayer player;
  late FakeWakelock wake;
  setUp(() {
    VideoPlayerPlatform.instance = player = FakeVideoPlayer();
    wakelockPlusPlatformInstance = wake = FakeWakelock();
  });

  testWidgets('leaving while the kept frames are saved asks first (r256)', (tester) async {
    // The rate the clip was analysed at, so only the track IDs are due.
    SharedPreferences.setMockInitialValues({'video_analysis_fps': 10.0});
    // Tall, so the whole list is built without scrolling.
    tester.view.physicalSize = const Size(360, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tmp = _tempDir('video_leave_guard');
    final session = Directory('${tmp.path}/leave');
    Directory('${session.path}/videos').createSync(recursive: true);
    File('${session.path}/videos/a.mp4').writeAsStringSync('video');
    File('${session.path}/session.jsonl').writeAsStringSync('{"type":"start_of_session","time_ms":1000,"source":"imported_video"}\n');
    final settings = const VideoRunConfig(
      modelPath: 'test_model',
      modelName: 'test_model.tflite',
      confidence: 0.25,
      iou: 0.7,
      analysisFps: 10, // the frames below are 100 ms apart
      useGpu: true,
    ).identity;
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
    final saver = _GatedFrameSaver();
    addTearDown(() {
      if (!saver.gate.isCompleted) saver.gate.complete();
    });
    var popped = false;
    await tester.pumpWidget(
      _host(
        VideoAnalysisScreen(
          initialSessionPath: session.path,
          sessionsDir: tmp,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
          frameSaveBackend: saver,
        ),
        (_) => popped = true,
      ),
    );
    await _open(tester);
    await _pumpUntil(tester, find.textContaining('1 analyzed)'));
    await tester.tap(find.text('Find track IDs'));
    await _pumpUntil(tester, find.textContaining('Saving the kept frames'));

    Future<void> back() async {
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await back();
    expect(find.text('Frames are still being saved'), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Frames are still being saved'), findsNothing);
    expect(find.textContaining('Saving the kept frames'), findsOneWidget); // still running
    expect(popped, isFalse);

    await back();
    await tester.tap(find.text('Stop and leave'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // the dialog closes
    await tester.pump(const Duration(milliseconds: 400)); // the screen's route transition
    expect(popped, isTrue);
    expect(find.byType(VideoAnalysisScreen), findsNothing);
    saver.gate.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a detection model the video screen offers one (round 268)', (tester) async {
    final tmp = _tempDir('video_no_model');
    await tester.pumpWidget(_host(VideoAnalysisScreen(sessionsDir: tmp, models: const []), (_) {}));
    await _open(tester);
    await _pumpUntil(tester, find.text('Get a detection model…'));
    expect(find.textContaining('No detection model on this phone yet.'), findsOneWidget);
    expect(find.text('Detection model'), findsNothing);
  });

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
    // Round 277 (owner): said before the import, that the videos are copies.
    expect(find.textContaining('take storage twice'), findsOneWidget);

    await tester.tap(button);
    await _pumpUntil(tester, find.text('Find animals in these videos'));
    expect(tester.takeException(), isNull);
    final dir = sessions.listSync().whereType<Directory>().single;
    expect(VideoDetector.clipsOf(dir), hasLength(3));

    await tester.tap(find.text('Find animals in these videos'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(popped, dir.path); // home opens the analysis screen on it
  });

  /// Round 306: the import screen for one picked file.
  Widget importScreen(Directory tmp, String name, {int? storedMs}) {
    final file = File('${tmp.path}/$name')..writeAsStringSync('video');
    Future<VideoInfo> info(String path) async =>
        VideoInfo(durationMs: 30000, width: 1920, height: 1080, mime: 'video/avc', creationEpochMs: storedMs);
    return MaterialApp(
      key: ValueKey(name),
      home: VideoImportScreen(
        files: [PickedVideo(file.path, name, 1000)],
        infoFn: info,
        sessionsDir: Directory('${tmp.path}/sessions'),
      ),
    );
  }

  testWidgets('import screen says where the start came from before any change (round 306)', (tester) async {
    final tmp = _tempDir('video_import_source');
    final stop = DateTime(2026, 9, 24, 16, 0, 24).millisecondsSinceEpoch;
    for (final (name, storedMs, note, unsure) in [
      ('VID_20260924_155954.mp4', null, 'From the file name: 2026-09-24 15:59:54.', false),
      (
        'IMG_1234.mp4',
        stop,
        'The file name holds no date. From the time stored in the video (2026-09-24 16:00:24, when filming '
            'stopped) minus the clip length.',
        false,
      ),
      (
        'clip.mp4',
        null,
        'The file name holds no date; the video stores no time either, so this is when the file was copied. '
            'Please set the time it was filmed.',
        true,
      ),
    ]) {
      await tester.pumpWidget(importScreen(tmp, name, storedMs: storedMs));
      await _pumpUntil(tester, find.text('Change…'));
      final shown = tester.widget<Text>(find.text(note));
      expect(shown.style?.color, unsure ? Colors.amber : Colors.white54, reason: name);
      expect(find.text('Back to the time read from the file'), findsNothing, reason: name);
    }
  });

  testWidgets('import screen: a start set by hand ends at second 0, the read time comes back (round 306)', (
    tester,
  ) async {
    final tmp = _tempDir('video_import_change');
    await tester.pumpWidget(importScreen(tmp, 'VID_20260924_155954.mp4'));
    await _pumpUntil(tester, find.text('Change…'));
    String sessionName() => tester.widget<TextField>(find.byType(TextField)).controller!.text;
    expect(find.text('Filming started: 2026-09-24 15:59:54'), findsOneWidget);
    expect(find.text('From the file name: 2026-09-24 15:59:54.'), findsOneWidget);
    expect(sessionName(), 'video_20260924');

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    // Change… to the next day, keeping the time the pickers offer.
    Future<void> changeToThe25th() async {
      await tester.tap(find.text('Change…'));
      await settle();
      await tester.tap(find.text('25')); // the date picker's calendar
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle();
      expect(find.text('Time the first clip started'), findsOneWidget);
      expect(find.text('PM'), findsNothing, reason: 'the time picker counts 24 hours');
      await tester.tap(find.text('OK'));
      await settle();
    }

    await changeToThe25th();
    expect(find.text('Filming started: 2026-09-25 15:59:00'), findsOneWidget);
    expect(find.text('Set by you; every clip moves by the same amount.'), findsOneWidget);
    expect(sessionName(), 'video_20260925', reason: 'the suggested name follows the day');

    await tester.tap(find.text('Back to the time read from the file'));
    await tester.pump();
    expect(find.text('Filming started: 2026-09-24 15:59:54'), findsOneWidget);
    expect(find.text('From the file name: 2026-09-24 15:59:54.'), findsOneWidget);
    expect(find.text('Back to the time read from the file'), findsNothing);
    expect(sessionName(), 'video_20260924');

    // A name the user typed stays.
    await tester.enterText(find.byType(TextField), 'Meadow 7');
    await changeToThe25th();
    expect(find.text('Filming started: 2026-09-25 15:59:00'), findsOneWidget);
    expect(sessionName(), 'Meadow 7');
    expect(tester.takeException(), isNull);
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
    await _pumpUntil(tester, find.textContaining('1 analyzed)'));
    expect(tester.takeException(), isNull);
    // Round 273: the last run was on the whole picture, so that stays. Round
    // 308: the numbers are on their own screen; its entry says them.
    final whole = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>).first);
    expect(whole.selected, {false}, reason: 'whole picture, as the last run');
    expect(find.byType(Slider), findsNothing);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Detection: confidence 0.25, 5 frames per second, IoU 0.70'), 200, scrollable: list);
    expect(
      find.text('Track IDs: ByteTrack, new-track confidence 0.50, occlusion 3.0 s, minimum 1.0 s, keep frames on'),
      findsOneWidget,
    );
    expect(find.text('Identification: off'), findsOneWidget);
    await _openTuning(tester);
    // 60 s of video at the default 5 frames per second (round 254; was 15).
    expect(find.text('About 300 frames for this session.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _closeTuning(tester);

    // Clip b is left, so analyzing comes first; no track IDs yet, so the
    // note on long runs comes before the player (round 309), which shows the
    // boxes of clip a and says how to get its track IDs.
    await tester.scrollUntilVisible(find.text('Continue (1 of 2 clips left)'), 200, scrollable: list);
    final note = find.textContaining('Long runs: keep the phone charging');
    await tester.scrollUntilVisible(note, 200, scrollable: list);
    await tester.pump();
    expectAboveBottomInset(tester, note);
    expect(find.text('Track IDs'), findsNothing);
    await tester.scrollUntilVisible(find.text('Watch the results'), 200, scrollable: list);
    await _playerReady(tester);
    expect(find.textContaining('No track IDs yet: "Find track IDs" (button above)', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Find track IDs tracks the finished clips and offers the results (r228)', (tester) async {
    SharedPreferences.setMockInitialValues({'video_analysis_fps': 10.0});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_visits_screen');
    final session = Directory('${tmp.path}/Meadow plot 7 near the old oak tree second visit');
    Directory('${session.path}/videos').createSync(recursive: true);
    File('${session.path}/videos/a.mp4').writeAsStringSync('video');
    File('${session.path}/session.jsonl').writeAsStringSync(
      '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}\n'
      '{"type":"end_of_session","time_ms":61000,"ended_normally":true}\n',
    );
    final settings = const VideoRunConfig(
      modelPath: 'test_model',
      modelName: 'test_model.tflite',
      confidence: 0.25,
      iou: 0.7,
      analysisFps: 10, // the frames below are 100 ms apart
      useGpu: true,
    ).identity;
    // Clip a analysed at 10 fps with one insect resting for 3 s.
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

    final decoder = _FakeFrameSaver();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: session.path,
          sessionsDir: tmp,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
          frameSaveBackend: decoder,
        ),
      ),
    );
    await _pumpUntil(tester, find.textContaining('1 analyzed)'));
    final list = find.byType(Scrollable).first;
    // Round 308: the track ID settings are on the settings screen, also
    // before any track ID is found.
    expect(find.text('Keep frames of each track ID'), findsNothing);
    await _openTuning(tester);
    await _scrollTo(tester, find.text('For up to'));
    // Round 234: frames kept of each visit (on by default) are saved right
    // after, here by a fake decoder.
    expect(find.text('Keep frames of each track ID'), findsOneWidget);
    expect(find.text('Keep a frame every'), findsOneWidget);
    // Round 256: the minimum track length as detections in a row, at the analysed rate.
    expect(find.text('= 10 detections in a row at 10 frames per second.'), findsOneWidget);
    await _closeTuning(tester);
    // Every clip is analyzed with these settings, so the main button finds them.
    final findIds = find.text('Find track IDs');
    await tester.scrollUntilVisible(findIds, 200, scrollable: list);
    await tester.pump();
    await tester.tap(findIds);
    await _pumpUntil(tester, find.text('Share results'));
    // Round 256: the track IDs show while the frames are saved, then the count.
    await _pumpUntil(tester, find.text('Kept frames saved: 3 of 3 (12 B).'));
    expect(tester.takeException(), isNull);
    // A 3-s visit, one frame a second from its first sighting.
    expect(find.textContaining(RegExp(r'^Found 1 track ID in 1 clip\. Saved 3 frames in ')), findsOneWidget);
    expect(find.text('Kept frames saved: 3 of 3 (12 B).'), findsOneWidget); // 4-byte fake files
    expect(decoder.saved, hasLength(3));
    expect(Directory('${session.path}/roi_frames').listSync(), hasLength(3));
    expect(find.text('1 track ID in 1 of 1 clips (occlusion tolerance 3.0 s, minimum track 1.0 s).'), findsOneWidget);
    expect(File('${session.path}/track_ids.csv').existsSync(), isTrue);
    expect(File('${session.path}/mot/a.txt').existsSync(), isTrue);
    expect(find.text('Every analyzed clip has at least one track ID.', skipOffstage: false), findsOneWidget);
    // Nothing is due any more.
    await tester.scrollUntilVisible(find.text('All clips analyzed with these settings'), -200, scrollable: list);

    // Keep frames off: the step rows go, a note says what finding again
    // would do, and the main button offers it.
    await _openTuning(tester);
    final keep = find.text('Keep frames of each track ID');
    await _scrollTo(tester, keep);
    await tester.tap(keep);
    await tester.pump();
    expect(find.text('Keep a frame every'), findsNothing);
    expect(find.textContaining('Finding track IDs again with this off removes the 3 frames saved before'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _closeTuning(tester);
    expect(find.text('Find track IDs again with these settings'), findsOneWidget);
    // The warning is under that button too.
    expect(find.textContaining('finding the track IDs again removes the 3 frames saved before'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Settings changed: the button above finds the track IDs again with them.'), 200, scrollable: list);

    final share = find.text('Share results');
    await tester.scrollUntilVisible(share, 200, scrollable: list);
    await tester.pump();
    expectAboveBottomInset(tester, share);
  });

  testWidgets('Free storage deletes the clips without track IDs, then all clips (r236)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_free_storage');
    final session = Directory('${tmp.path}/Meadow');
    Directory('${session.path}/videos').createSync(recursive: true);
    File('${session.path}/videos/a.mp4').writeAsStringSync('a' * 3000);
    File('${session.path}/videos/b.mp4').writeAsStringSync('b' * 2000);
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
    // Both clips analysed at 10 fps: an insect rests in a for 3 s, b is empty.
    List<String> clip(String name, int startMs, bool insect) => [
      '{"type":"video_clip_start","clip":"$name","start_epoch_ms":$startMs,"width":1920,"height":1080}',
      for (var t = 0; t <= 3000; t += 100)
        jsonEncode({
          'type': 'raw_detections',
          'frame_ms': startMs + t,
          'clip': name,
          'pts_us': t * 1000,
          'frame': t * 30 ~/ 1000,
          'boxes': [
            if (insect) [0.4, 0.4, 0.45, 0.48, 0.9, 0],
          ],
        }),
      '{"type":"video_clip_done","clip":"$name","frame_width":1920,"frame_height":1080,'
          '"roi_px":[0,0,1920,1080],"class_names":["bee"]}',
    ];
    File('${session.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      [
        jsonEncode({'type': 'video_run_start', 'time_ms': 111, 'settings': settings}),
        ...clip('a.mp4', 1000000, true),
        ...clip('b.mp4', 2000000, false),
      ].join('\n'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: session.path,
          sessionsDir: tmp,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
          frameSaveBackend: _FakeFrameSaver(),
        ),
      ),
    );
    await _pumpUntil(tester, find.textContaining('2 analyzed)'));
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Find track IDs'), 200, scrollable: list);
    await tester.pump();
    await tester.tap(find.text('Find track IDs'));
    await _pumpUntil(tester, find.textContaining('Kept frames saved: 3 of 3'));

    // One clip without a visit. Round 309: the player under it loads first.
    final withoutVisits = find.textContaining('Delete 1 clip without any track ID (2 KB)');
    await tester.scrollUntilVisible(withoutVisits, 200, scrollable: list);
    await _playerReady(tester);
    expect(find.text('Videos: 2 clips, 5 KB.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(withoutVisits);
    await tester.pumpAndSettle();
    expect(find.textContaining('This permanently deletes 1 video (2 KB): b.mp4.'), findsOneWidget);
    await tester.tap(find.text('Delete 1'));
    await _pumpUntil(tester, find.textContaining('(1 deleted before)'));
    expect(File('${session.path}/videos/b.mp4').existsSync(), isFalse);
    expect(File('${session.path}/videos/a.mp4').existsSync(), isTrue);
    await _pumpUntil(tester, find.text('Every analyzed clip has at least one track ID.'));
    expect(find.text('Videos: 1 clip, 3 KB (1 deleted before).'), findsOneWidget);
    // Round 309: the player under it plays clip a and lists the deleted one.
    await _playerReady(tester);
    expect(find.text('a.mp4 · 1 track ID', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('b.mp4 · ', skipOffstage: false), findsOneWidget);

    // Then all: the session stays, the visits too.
    final all = find.textContaining('Delete the only clip, keep the saved frames');
    // The "Deleted 1 video" snack bar covers the end of the list for 4 s.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(all, 200, scrollable: list);
    await tester.pump();
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(find.text('Delete all videos?'), findsOneWidget);
    await tester.tap(find.text('Delete 1'));
    await _pumpUntil(tester, find.text('All 2 videos were deleted.'));
    expect(VideoDetector.clipsOf(session), isEmpty);
    // Round 309: nothing left to play, so no player; its last clip was closed.
    expect(find.byType(VideoReviewPlayer, skipOffstage: false), findsNothing);
    expect(find.text('Watch the results', skipOffstage: false), findsNothing);
    expect(player.calls.last, 'dispose');
    await tester.scrollUntilVisible(find.textContaining('1 track ID in 2 of 2 clips'), -200, scrollable: list);
    await tester.scrollUntilVisible(find.text('The videos were deleted'), -200, scrollable: list); // the start button
    expect(find.textContaining('they cannot be analyzed again; the track IDs can still be found again'), findsOneWidget);
    final records = [
      for (final l in File('${session.path}/session.jsonl').readAsLinesSync())
        if (l.contains('"video_cleanup"')) (jsonDecode(l) as Map)['mode'],
    ];
    expect(records, ['without_track_ids', 'all']);
    await tester.drag(list, const Offset(0, -3000));
    await tester.pump();
    await tester.drag(list, const Offset(0, -3000));
    await tester.pump();
    expectAboveBottomInset(tester, find.text('All 2 videos were deleted.'));
    expect(tester.takeException(), isNull);
  });

  // Round 309 (owner): after a run the videos play on this screen, under the track ID results, to
  // judge them before changing the settings and running again.
  testWidgets('the videos play under the track IDs: not while busy, paused under other screens, 360 px (r309)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'video_analysis_fps': 10.0});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_watch_results');
    final session = _oneTrackSession(tmp);
    final saver = _GatedFrameSaver();
    addTearDown(() {
      if (!saver.gate.isCompleted) saver.gate.complete();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: session.path,
          sessionsDir: tmp,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
          frameSaveBackend: saver,
        ),
      ),
    );
    await _pumpUntil(tester, find.textContaining('1 analyzed)'));
    final list = find.byType(Scrollable).first;
    final watch = find.text('Watch the results');
    await tester.scrollUntilVisible(watch, 200, scrollable: list);
    await _playerReady(tester);
    // A moment to come back to after the run.
    final moved = tester.state<VideoReviewPlayerState>(find.byType(VideoReviewPlayer)).showMoment('a.mp4', 2000);
    await _settle(tester);
    await moved;

    // Finding the track IDs saves frames from the video: the player is gone meanwhile, and the
    // screen stays on for the saving.
    final findIds = find.text('Find track IDs');
    await tester.scrollUntilVisible(findIds, -200, scrollable: list);
    await tester.pump();
    await tester.tap(findIds);
    await _pumpUntil(tester, find.textContaining('Saving the kept frames'));
    await tester.scrollUntilVisible(find.text('Free storage'), 200, scrollable: list);
    expect(find.byType(VideoReviewPlayer, skipOffstage: false), findsNothing);
    expect(watch, findsNothing);
    expect(wake.on, isTrue);
    saver.gate.complete();
    await _pumpUntil(tester, find.text('Kept frames saved: 3 of 3 (12 B).'));
    expect(wake.on, isFalse);

    // Back under the results, on the same clip and moment as before: the time bar over the track
    // ID, the share under it, the list.
    await tester.scrollUntilVisible(watch, 200, scrollable: list);
    await _playerReady(tester);
    await _settle(tester);
    expect(player.calls.sublist(player.calls.lastIndexOf('create a.mp4')), contains('seek 2000'));
    expect(tester.state<VideoReviewPlayerState>(find.byType(VideoReviewPlayer, skipOffstage: false)).view?.ms, 2000);
    final bar = tester.widget<VideoTimelineBar>(find.byKey(const ValueKey('track_id_timeline'), skipOffstage: false));
    expect(bar.spans, hasLength(1));
    expect(bar.keptMs, hasLength(3));
    expect(find.textContaining(RegExp(r'^Track IDs in \d+ % of this clip'), skipOffstage: false), findsOneWidget);
    // Nothing that would open this screen again; the notes point to the controls above.
    expect(find.widgetWithText(FilledButton, 'Find animals in videos', skipOffstage: false), findsNothing);
    expect(find.text('Change square and analyse again', skipOffstage: false), findsNothing);
    expect(find.text('Square in the wrong place?', skipOffstage: false), findsNothing);
    expect(find.textContaining('(see Kept frames below)', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);

    // Playing keeps the screen on; another screen opening over it pauses the clip.
    final play = find.byTooltip('Play');
    await tester.scrollUntilVisible(play, 200, scrollable: list);
    await tester.pump();
    await tester.tap(play);
    await tester.pump();
    expect(player.calls, contains('play'));
    expect(wake.on, isTrue);
    await _openTuning(tester);
    expect(player.calls.last, 'pause');
    expect(wake.on, isFalse);
    await _closeTuning(tester);

    // A track ID of the list, the screen's last row, moves the video there and stays above the bar.
    final toggle = find.byKey(const ValueKey('track_list_toggle'));
    await tester.scrollUntilVisible(toggle, 200, scrollable: list);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    final row = find.byType(ListTile);
    await tester.scrollUntilVisible(row, 200, scrollable: list);
    await tester.drag(list, const Offset(0, -3000));
    await tester.pump();
    expectAboveBottomInset(tester, row, label: 'last row');
    // The "Found 1 track ID" snack bar covers the end of the list for 4 s.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pump();
    expect(player.calls.last, startsWith('seek '));
    expect(tester.takeException(), isNull);
  });

  testWidgets('recorded video bursts: whole picture by default, with the reason (r239)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_analysis_recorded');
    final session = Directory('${tmp.path}/Balcony');
    Directory('${session.path}/videos').createSync(recursive: true);
    File('${session.path}/videos/roi_tok1_a.mp4').writeAsStringSync('video');
    File('${session.path}/session.jsonl').writeAsStringSync(
      [
        '{"type":"start_of_session","time_ms":1000,"config":{"captureTrigger":"timelapse","timeLapseSaveAs":"video"}}',
        '{"type":"video_clip","time_ms":11000,"file":"videos/roi_tok1_a.mp4","duration_ms":10000,"burst":0,'
            '"width":480,"height":480}',
        '{"type":"end_of_session","time_ms":20000,"ended_normally":true}',
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
    // Round 273: a square clip is the camera's square already, so its default
    // area is the whole picture.
    await _pumpUntil(tester, find.textContaining('recorded by the app as the camera'));
    final whole = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>).first);
    expect(whole.selected, {false}, reason: 'whole picture');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a video never analysed starts on the largest square in the middle (r273)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_analysis_default_square');
    final session = Directory('${tmp.path}/Echium');
    Directory('${session.path}/videos').createSync(recursive: true);
    File('${session.path}/videos/a.mp4').writeAsStringSync('video');
    File('${session.path}/session.jsonl').writeAsStringSync(
      [
        '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}',
        '{"type":"video_clip","time_ms":1000,"file":"videos/a.mp4","duration_ms":30000,"width":640,"height":480}',
        '{"type":"end_of_session","time_ms":31000,"ended_normally":true}',
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
    await _pumpUntil(tester, find.text('Square 480 × 480 px.'));
    // The proposed square is in view, to accept or change; the numbers are on
    // their own screen (round 308).
    final area = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>).first);
    expect(area.selected, {true}, reason: 'a square');
    expect(find.text('Change…'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    // The whole picture is one tap away.
    await tester.tap(find.text('Whole picture'));
    await tester.pump();
    expect(find.text('Square 480 × 480 px.'), findsNothing);
    expect(tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>).first).selected, {false});
    await tester.scrollUntilVisible(find.text('Analyze 1 clip'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Detection: confidence 0.25, 5 frames per second, IoU 0.70'), findsOneWidget);
    // Round 309: nothing analysed, so nothing to watch yet.
    expect(find.byType(VideoReviewPlayer, skipOffstage: false), findsNothing);
    // Round 308: the track ID settings before the first run.
    await _openTuning(tester);
    for (final label in ['Tracking algorithm', 'New-track confidence', 'Occlusion tolerance', 'Minimum track length']) {
      await _scrollTo(tester, find.text(label));
    }
    expect(find.text('= 5 detections in a row at 5 frames per second.'), findsOneWidget);
    await _scrollTo(tester, find.text('Keep frames of each track ID'));
    expect(tester.takeException(), isNull);
  });

  group('Also identify them (r274)', () {
    const models = [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)];

    /// A 640x480 session with one clip; [lines] are extra session.jsonl
    /// records, [detections] the video_detections.jsonl lines.
    Directory session(Directory tmp, {List<String> start = const [], List<String>? detections}) {
      final dir = Directory('${tmp.path}/Echium');
      Directory('${dir.path}/videos').createSync(recursive: true);
      File('${dir.path}/videos/a.mp4').writeAsStringSync('video');
      File('${dir.path}/session.jsonl').writeAsStringSync(
        [
          ...start.isEmpty ? ['{"type":"start_of_session","time_ms":1000,"source":"imported_video"}'] : start,
          '{"type":"video_clip","time_ms":1000,"file":"videos/a.mp4","duration_ms":30000,"width":640,"height":480'
              '${start.isEmpty ? '' : ',"segment":0'}}',
          '{"type":"end_of_session","time_ms":31000,"ended_normally":true}',
        ].join('\n'),
      );
      if (detections != null) {
        File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync(detections.join('\n'));
      }
      return dir;
    }

    Future<void> open(WidgetTester tester, Directory tmp, Directory dir, Finder ready) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoAnalysisScreen(
            initialSessionPath: dir.path,
            sessionsDir: tmp,
            models: models,
            identificationChoice: idChoice(Directory.systemTemp.createTempSync('id_choice')),
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Area to analyze'));
      await tester.scrollUntilVisible(ready, 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();
    }

    testWidgets('on by default with a usable model: Start says it, the model and list show, fits 360 px', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      final tmp = _tempDir('also_identify_video');
      await open(tester, tmp, session(tmp), find.text('Analyze 1 clip and identify'));
      expect(find.text('Also identify them'), findsOneWidget);
      expect(find.textContaining('Then the track IDs are found, their frames saved'), findsOneWidget);
      expect(find.text('Model (.tflite)'), findsOneWidget);
      expect(find.text('Name list (.fpack)'), findsOneWidget);
      expect(find.textContaining('Class list of insectdct-eff2s_cls: 104 classes on 2 levels'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Off: only the detector, and the choice is remembered.
      final list = find.byType(Scrollable).first;
      await tester.ensureVisible(find.text('Also identify them'));
      await tester.pump();
      await tester.tap(find.text('Also identify them'));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Analyze 1 clip'), 200, scrollable: list);
      expect(find.text('Analyze 1 clip'), findsOneWidget);
      expect(find.text('Model (.tflite)'), findsNothing);
      expect((await SharedPreferences.getInstance()).getBool('find_also_identify'), isFalse);
    });

    testWidgets('needs kept frames: greyed with the reason', (tester) async {
      SharedPreferences.setMockInitialValues({'video_analysis_keep_frames': false});
      simulateBottomSystemBar(tester);
      final tmp = _tempDir('also_identify_keep_off');
      await open(tester, tmp, session(tmp), find.text('Analyze 1 clip'));
      expect(find.textContaining('Needs "Keep frames of each track ID"'), findsOneWidget);
      expect(find.text('Model (.tflite)'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a live detection session points to Identify organisms instead', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      final tmp = _tempDir('also_identify_live');
      final dir = session(
        tmp,
        start: ['{"type":"start_of_session","time_ms":1000,"config":{"captureTrigger":"detector","liveAiVideo":true}}'],
      );
      await open(tester, tmp, dir, find.textContaining('To name the live track IDs'));
      expect(find.text('Also identify them'), findsNothing);
      expect(find.text('Analyze 1 clip'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('everything analyzed already: Start only identifies', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      final tmp = _tempDir('also_identify_done');
      final settings = const VideoRunConfig(
        modelPath: 'test_model',
        modelName: 'test_model.tflite',
        confidence: 0.25,
        iou: 0.7,
        useGpu: true,
        roi: [0.5, 0.5, 0.75],
      ).identity;
      final dir = session(
        tmp,
        detections: [jsonEncode({'type': 'video_run_start', 'settings': settings}), '{"type":"video_clip_done","clip":"a.mp4"}'],
      );
      // Round 308: the track IDs are up to date too, else finding them comes first.
      File('${dir.path}/post_tracks.jsonl').writeAsStringSync(postTracks(['a.mp4'], trackIds: 1));
      await open(tester, tmp, dir, find.text('Identify the animals found'));
      final start = tester.widget<FilledButton>(find.ancestor(of: find.text('Identify the animals found'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
      expect(start.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no track IDs found: nothing to identify, so no Identify button (r312)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      final tmp = _tempDir('also_identify_none');
      final settings = const VideoRunConfig(
        modelPath: 'test_model',
        modelName: 'test_model.tflite',
        confidence: 0.25,
        iou: 0.7,
        useGpu: true,
        roi: [0.5, 0.5, 0.75],
      ).identity;
      final dir = session(
        tmp,
        detections: [jsonEncode({'type': 'video_run_start', 'settings': settings}), '{"type":"video_clip_done","clip":"a.mp4"}'],
      );
      File('${dir.path}/post_tracks.jsonl').writeAsStringSync(postTracks(['a.mp4']));
      await open(tester, tmp, dir, find.text('All clips analyzed with these settings'));
      expect(find.text('Identify the animals found'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a clip cut off by a killed app: said, left out, deletable at 360 px (r243)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_analysis_cut_off');
    final session = Directory('${tmp.path}/Balcony');
    Directory('${session.path}/videos').createSync(recursive: true);
    File('${session.path}/videos/roi_tok1_a.mp4').writeAsBytesSync([...box('ftyp', 16), ...box('mdat', 100), ...box('moov', 20)]);
    final cut = File('${session.path}/videos/roi_tok1_b.mp4')
      ..writeAsBytesSync([...box('ftyp', 16), ...box('mdat', 2000, sizeField: 0)]);
    File('${session.path}/session.jsonl').writeAsStringSync(
      [
        '{"type":"start_of_session","time_ms":1000,"config":{"captureTrigger":"timelapse","timeLapseSaveAs":"video"}}',
        '{"type":"video_clip","time_ms":11000,"file":"videos/roi_tok1_a.mp4","duration_ms":10000,"burst":0}',
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
    await _pumpUntil(tester, find.text('Area to analyze'));
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.textContaining('1 clip was cut off: the app stopped while recording it'), 200, scrollable: list);
    final delete = find.textContaining('Delete the cut-off clip (2 KB)');
    await tester.scrollUntilVisible(delete, 200, scrollable: list);
    await tester.pump();
    expect(find.text('Analyze 1 clip'), findsOneWidget, reason: 'only the readable clip is pending');
    expect(tester.takeException(), isNull);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete the cut-off clip?'), findsOneWidget);
    expect(find.textContaining('roi_tok1_b.mp4. It was never finished'), findsOneWidget);
    await tester.tap(find.text('Delete 1'));
    await _pumpUntil(tester, find.textContaining('freed.'));
    expect(cut.existsSync(), isFalse);
    // The screen reads the session again after the snack bar.
    for (var i = 0; i < 100 && find.textContaining('cut off').evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.textContaining('cut off'), findsNothing);
    expect(find.text('Analyze 1 clip'), findsOneWidget);
    expect(File('${session.path}/session.jsonl').readAsStringSync(), contains('"mode":"cut_off"'));

    // Every clip cut off (killed in the first burst): no "videos were deleted".
    File('${session.path}/videos/roi_tok1_a.mp4').writeAsBytesSync([...box('ftyp', 16), ...box('mdat', 100, sizeField: 0)]);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: session.path,
          sessionsDir: tmp,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    await _pumpUntil(tester, find.textContaining('Balcony'));
    await tester.scrollUntilVisible(find.text('No clip can be read'), 200, scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(find.textContaining('1 clip was cut off'), 200, scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });

  testWidgets('live detection session: track IDs for comparison, no kept frames (r241)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    simulateBottomSystemBar(tester);
    final tmp = _tempDir('video_analysis_live');
    final session = Directory('${tmp.path}/Lavender');
    Directory('${session.path}/videos').createSync(recursive: true);
    File('${session.path}/videos/a.mp4').writeAsStringSync('video');
    File('${session.path}/session.jsonl').writeAsStringSync(
      [
        '{"type":"start_of_session","time_ms":1000,"config":{"captureTrigger":"detector","liveAiVideo":true}}',
        '{"type":"video_clip","time_ms":11000,"file":"videos/a.mp4","duration_ms":10000,"segment":0}',
        '{"type":"end_of_session","time_ms":20000,"ended_normally":true}',
      ].join('\n'),
    );
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
    // Track IDs found before, without kept frames (none for live sessions).
    File('${session.path}/post_tracks.jsonl').writeAsStringSync(postTracks(['a.mp4'], keepFrames: false));
    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: session.path,
          sessionsDir: tmp,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Area to analyze'));
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.textContaining('The track IDs found here are for comparison'), 200, scrollable: list);
    expect(find.text('All clips analyzed with these settings'), findsOneWidget);
    // No keep-frames switch, so the summary does not mention it.
    await tester.scrollUntilVisible(
      find.text('Track IDs: ByteTrack, new-track confidence 0.50, occlusion 3.0 s, minimum 1.0 s'),
      -200,
      scrollable: list,
    );
    expect(find.text('Identification: from the session\'s ⋮ menu (a live detection session)'), findsOneWidget);
    await _openTuning(tester);
    await _scrollTo(tester, find.textContaining('No frames are kept for these track IDs'));
    expect(find.text('Keep frames of each track ID'), findsNothing);
    await _scrollTo(tester, find.textContaining('Not used for this session: it was recorded with live detection'));
    expect(tester.takeException(), isNull);
  });

  group('Detection, track ID and identification settings (r308)', () {
    const models = [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)];

    Future<void> showTuning(WidgetTester tester, VideoTuningScreen screen) async {
      await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: ThemeData.dark(useMaterial3: true), home: screen));
      await _pumpUntil(tester, find.text('Detection'));
    }

    testWidgets('fits 360 px: the three cards, the last row above the bar', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      await showTuning(tester, VideoTuningScreen(prefs: VideoAnalysisPrefs(), totalMs: 60000));
      expect(find.text('Detection, track IDs, identification'), findsOneWidget);
      expect(find.text('About 300 frames for this session.'), findsOneWidget);
      await _scrollTo(tester, find.text('Track IDs'));
      // The track IDs card in its own colour.
      final track = tester.widget<ModelKindPanel>(find.ancestor(of: find.text('Track IDs'), matching: find.byType(ModelKindPanel)));
      expect(track.color, kTrackingColor);
      expect({kDetectionColor, kIdentificationColor, kTrackingColor}, hasLength(3));
      await _scrollTo(tester, find.text('Identification'));
      final last = find.textContaining('Changes nothing in the app');
      await _scrollTo(tester, last);
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pump();
      expectAboveBottomInset(tester, last, label: 'last row');
      expect(tester.takeException(), isNull);
    });

    testWidgets('identification: greyed with the reason, editable when it will run', (tester) async {
      SharedPreferences.setMockInitialValues({'identify_model': 'chosen.tflite', 'identify_pack': 'chosen.fpack'});
      simulateBottomSystemBar(tester);
      final greyed = find.ancestor(
        of: find.text('Crop margin'),
        matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.4),
      );
      for (final (screen, why) in [
        (VideoTuningScreen(prefs: VideoAnalysisPrefs()), 'Used only when "Also identify them" is on (on the previous screen).'),
        (
          VideoTuningScreen(prefs: VideoAnalysisPrefs(keepFrames: false), alsoIdentify: true),
          'Needs "Keep frames of each track ID" (Track IDs card above): identification names the saved frames.',
        ),
        (
          VideoTuningScreen(prefs: VideoAnalysisPrefs(), alsoIdentify: true, liveAi: true),
          'Not used for this session: it was recorded with live detection, so its track IDs are named from the '
              'session\'s ⋮ menu (Identify organisms), which has these settings too.',
        ),
      ]) {
        await showTuning(tester, screen);
        await _scrollTo(tester, find.text('Crop margin'));
        expect(greyed, findsOneWidget, reason: why);
        await _scrollTo(tester, find.text(why), -200);
      }

      final prefs = VideoAnalysisPrefs();
      await showTuning(
        tester,
        VideoTuningScreen(prefs: prefs, alsoIdentify: true, identifyModel: 'm.tflite', identifyList: 'm.fpack'),
      );
      await _scrollTo(tester, find.text('Crop margin'));
      expect(greyed, findsNothing);
      expect(
        find.text('Model m.tflite with the name list m.fpack (chosen under "Also identify them" on the previous screen).'),
        findsOneWidget,
      );
      await _scrollTo(tester, find.text('CPU threads (0 = automatic)'), -200);
      await tester.enterText(_numberBox('CPU threads (0 = automatic)'), '4');
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      final saved = await IdentifyPrefs.load();
      expect(saved.cpuThreads, 4);
      expect([saved.modelName, saved.packName], ['chosen.tflite', 'chosen.fpack'], reason: 'kept as stored');
      // Kept frames switched off here grey it at once.
      final keep = find.text('Keep frames of each track ID');
      await _scrollTo(tester, keep, -200);
      await tester.tap(keep);
      await tester.pump();
      expect(prefs.keepFrames, isFalse);
      await _scrollTo(tester, find.textContaining('(Track IDs card above)'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('"New-track confidence" stays 0.10 above the video confidence', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = VideoAnalysisPrefs();
      await showTuning(tester, VideoTuningScreen(prefs: prefs));
      final slider = tester.widget<Slider>(find.byType(Slider).first);
      slider.onChanged!(0.6);
      slider.onChangeEnd!(0.6);
      await tester.pump();
      expect(find.text('Confidence threshold: 0.60'), findsOneWidget);
      expect([prefs.trackerParams.highThresh, prefs.cbiouParams.highThresh], [closeTo(0.7, 1e-9), closeTo(0.7, 1e-9)]);
      await _scrollTo(tester, find.text('New-track confidence'));
      expect(tester.widget<TextField>(_numberBox('New-track confidence')).controller!.text, '0.70');
      // Typed lower, it stays at the floor.
      await tester.enterText(_numberBox('New-track confidence'), '0.5');
      await tester.pump();
      expect(prefs.trackerParams.highThresh, closeTo(0.7, 1e-9));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect((await VideoAnalysisPrefs.load()).trackerParams.highThresh, closeTo(0.7, 1e-9), reason: 'saved');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the videos\' own tracker: used by Find track IDs, the camera\'s unchanged', (tester) async {
      SharedPreferences.setMockInitialValues({'video_analysis_fps': 10.0});
      simulateBottomSystemBar(tester);
      await const SessionConfig(confidenceThreshold: 0.3).save();
      final camera = jsonEncode((await SessionConfig.load()).toJson());
      final tmp = _tempDir('video_own_tracker');
      final session = _oneTrackSession(tmp);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoAnalysisScreen(
            initialSessionPath: session.path,
            sessionsDir: tmp,
            models: models,
            frameSaveBackend: _FakeFrameSaver(),
          ),
        ),
      );
      await _pumpUntil(tester, find.textContaining('1 analyzed)'));
      await _openTuning(tester);
      final algorithm = find.byType(DropdownButton<TrackerAlgorithm>);
      await _scrollTo(tester, algorithm);
      await tester.tap(algorithm);
      await _settle(tester);
      await tester.tap(find.text('C-BIoU').last);
      await _settle(tester);
      await tester.enterText(_numberBox('New-track confidence'), '0.6');
      await tester.pump();
      await _scrollTo(tester, find.text('Fine-tuning (C-BIoU)'));
      expect(find.text('Search margins 0.30 and 0.50'), findsOneWidget);
      await _closeTuning(tester);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Track IDs: C-BIoU, new-track confidence 0.60, occlusion 3.0 s, minimum 1.0 s, keep frames on'),
        200,
        scrollable: list,
      );
      final findIds = find.text('Find track IDs');
      await tester.scrollUntilVisible(findIds, 200, scrollable: list);
      await tester.tap(findIds);
      await _pumpUntil(tester, find.text('Share results'));
      final start = jsonDecode(File('${session.path}/post_tracks.jsonl').readAsLinesSync().first) as Map;
      expect([start['tracker']['algorithm'], start['tracker']['highThresh']], ['cbiou', 0.6]);
      expect(jsonEncode((await SessionConfig.load()).toJson()), camera, reason: 'the camera keeps its own');
      await _pumpUntil(tester, find.textContaining('Kept frames saved: 3 of 3'));
      await tester.scrollUntilVisible(find.text('All clips analyzed with these settings'), -200, scrollable: list);

      // Only a tracker value changed: the main button finds the track IDs again.
      await _openTuning(tester);
      await _scrollTo(tester, find.text('New-track confidence'));
      await tester.enterText(_numberBox('New-track confidence'), '0.7');
      await tester.pump();
      await _closeTuning(tester);
      expect(find.text('Find track IDs again with these settings'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Settings changed: the button above finds the track IDs again with them.'),
        200,
        scrollable: list,
      );
      expect(jsonEncode((await SessionConfig.load()).toJson()), camera);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the main button: clips left come before track IDs found already', (tester) async {
      SharedPreferences.setMockInitialValues({'video_analysis_fps': 10.0});
      simulateBottomSystemBar(tester);
      final tmp = _tempDir('video_main_button');
      final session = _oneTrackSession(tmp);
      File('${session.path}/videos/b.mp4').writeAsStringSync('video');
      final prefs = VideoAnalysisPrefs(analysisFps: 10);
      await tester.runAsync(() => VideoTracker.run(session, prefs.trackerConfig(const SessionConfig()), keep: prefs.keep));
      await tester.pumpWidget(
        MaterialApp(
          home: VideoAnalysisScreen(initialSessionPath: session.path, sessionsDir: tmp, models: models),
        ),
      );
      await _pumpUntil(tester, find.textContaining('1 analyzed)'));
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Continue (1 of 2 clips left)'), 200, scrollable: list);
      await tester.scrollUntilVisible(
        find.text('1 track ID in 1 of 2 clips (occlusion tolerance 3.0 s, minimum track 1.0 s).'),
        200,
        scrollable: list,
      );
      expect(find.textContaining('Settings changed'), findsNothing);
      expect(find.text('Find track IDs for the clips analyzed so far'), findsNothing, reason: 'up to date');
      await tester.scrollUntilVisible(find.text('Analyze every clip first (1 left).'), 200, scrollable: list);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clips left: the analyzed ones still get their track IDs (a clip that cannot be read)', (tester) async {
      SharedPreferences.setMockInitialValues({'video_analysis_fps': 10.0});
      simulateBottomSystemBar(tester);
      final tmp = _tempDir('video_track_so_far');
      final session = _oneTrackSession(tmp);
      // Clip b fails at every run (no video_clip_done), so it stays to analyze.
      File('${session.path}/videos/b.mp4').writeAsStringSync('video');
      File('${session.path}/${VideoDetector.outputFileName}').writeAsStringSync(
        '\n{"type":"video_clip_error","clip":"b.mp4","error":"cannot decode"}',
        mode: FileMode.append,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoAnalysisScreen(
            initialSessionPath: session.path,
            sessionsDir: tmp,
            models: models,
            frameSaveBackend: _FakeFrameSaver(),
          ),
        ),
      );
      await _pumpUntil(tester, find.textContaining('1 analyzed)'));
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Continue (1 of 2 clips left)'), 200, scrollable: list);
      final soFar = find.text('Find track IDs for the clips analyzed so far');
      await tester.scrollUntilVisible(soFar, 200, scrollable: list);
      await tester.pump();
      await tester.tap(soFar);
      await _pumpUntil(tester, find.textContaining('Kept frames saved: 3 of 3'));
      expect(find.text('1 track ID in 1 of 2 clips (occlusion tolerance 3.0 s, minimum track 1.0 s).'), findsOneWidget);
      expect(soFar, findsNothing);
      expect(find.text('Continue (1 of 2 clips left)'), findsOneWidget);
      // Round 236: only a can be judged, and deleting all clips waits for b.
      await tester.scrollUntilVisible(find.text('Analyze every clip first (1 left).'), 200, scrollable: list);
      expect(find.text('Every analyzed clip has at least one track ID.'), findsOneWidget);

      // A track ID setting changed: the button is back, the notes name it.
      await _openTuning(tester);
      final keep = find.text('Keep frames of each track ID');
      await _scrollTo(tester, keep);
      await tester.tap(keep);
      await tester.pump();
      await _closeTuning(tester);
      await tester.scrollUntilVisible(soFar, -200, scrollable: list);
      expect(find.textContaining('finding the track IDs again removes the 3 frames saved before'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Settings changed: "Find track IDs for the clips analyzed so far" above finds the track IDs again with them.'),
        200,
        scrollable: list,
      );
      expect(tester.takeException(), isNull);
    });
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
      sampleSeconds: 30,
      keepFrames: false,
      keepStepSeconds: 0.5,
      keepDurationSeconds: 30,
      trackerAlgorithm: TrackerAlgorithm.cbiou,
      trackerParams: const ByteTrackParams(matchThresh: 0.2, velocitySmoothing: 0.3),
      cbiouParams: const CBiouParams(bufferScale1: 0.4, bufferScale2: 0.8, highThresh: 0.6),
    ).save();
    final p = await VideoAnalysisPrefs.load();
    expect(
      [p.modelId, p.confidence, p.iou, p.analysisFps, p.thermalLimitC, p.occlusionSeconds, p.minVisitSeconds, p.sampleSeconds],
      ['big_model', 0.4, 0.5, 5, 42, 5.0, 0.5, 30],
    );
    // Round 234: the kept-frames rule; off gives no rule to "Find visits".
    expect([p.keepFrames, p.keepStepSeconds, p.keepDurationSeconds, p.keep], [false, 0.5, 30.0, null]);
    expect((p..keepFrames = true).keep, const KeepFramesSettings(stepSeconds: 0.5, durationSeconds: 30));
    // Round 308: the videos' own tracker.
    expect(p.trackerAlgorithm, TrackerAlgorithm.cbiou);
    expect([p.trackerParams.matchThresh, p.trackerParams.velocitySmoothing], [0.2, 0.3]);
    expect([p.cbiouParams.bufferScale1, p.cbiouParams.bufferScale2, p.cbiouParams.highThresh], [0.4, 0.8, 0.6]);
    expect(p.newTrackConfidence, 0.6);
    final config = p.trackerConfig(const SessionConfig(confidenceThreshold: 0.33));
    expect(config.trackerAlgorithm, TrackerAlgorithm.cbiou);
    expect([config.occlusionSeconds, config.minHitsSeconds, config.cbiouParams.bufferScale2], [5.0, 0.5, 0.8]);
    expect(config.confidenceThreshold, 0.33, reason: 'the app\'s other settings stay');
    SharedPreferences.setMockInitialValues({});
    final defaults = await VideoAnalysisPrefs.load();
    expect(defaults.sampleSeconds, 10);
    expect(defaults.minVisitSeconds, 1.0); // round 256 (was 0.2)
    expect(defaults.keep, const KeepFramesSettings(stepSeconds: 1, durationSeconds: 10));
    // The app's defaults, not the camera's values.
    expect(defaults.trackerAlgorithm, TrackerAlgorithm.bytetrack);
    expect(defaults.trackerParams.toJson(), const ByteTrackParams().toJson());
    expect(defaults.cbiouParams.toJson(), const CBiouParams().toJson());
    // "New-track confidence" stays 0.10 above a raised confidence.
    expect((defaults..confidence = 0.6).newTrackConfidence, closeTo(0.7, 1e-9));

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
    await _pumpUntil(tester, find.text('Imported videos (detection afterwards)'));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  // Round 229: once "Find visits" has run, the summary reads the visits from
  // post_tracks.jsonl and the Setup tab shows what the video screen used.
  testWidgets('summary of an imported session shows track IDs found afterwards', (tester) async {
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
        'sample_s': 10,
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
    expect(find.textContaining('occlusion tolerance 3 s, minimum track length 0.2 s'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.textContaining('All session settings'), 200, scrollable: scrollable);
    await tester.tap(find.textContaining('All session settings'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Chosen on the "Find animals in videos" screen.'), 200, scrollable: scrollable);
    await expectSummaryRowValue(tester, scrollable, label: 'Confidence threshold', value: '0.25');
    await expectSummaryRowValue(tester, scrollable, label: 'Area to analyze', value: 'a square, 50 % of the picture width');
    await expectSummaryRowValue(tester, scrollable, label: 'Pause above battery temperature', value: '40 °C');
    await expectSummaryRowValue(tester, scrollable, label: 'Measure the phone every', value: '10 s');
    await expectSummaryRowValue(tester, scrollable, label: 'Clips', value: '1');
    await tester.scrollUntilVisible(find.textContaining('Track IDs found afterwards with "Find track IDs"'), 200, scrollable: scrollable);
    await expectSummaryRowValue(tester, scrollable, label: 'Occlusion tolerance', value: '3 s');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  // Round 232: the Graphs tab of an imported session shows the phone while
  // the AI ran on the videos, from the samples in video_detections.jsonl.
  testWidgets('summary of an imported session graphs the phone during the analysis', (tester) async {
    simulateBottomSystemBar(tester); // 360 px wide
    SharedPreferences.setMockInitialValues({'extra_graphs_expanded': true});
    final tmp = _tempDir('video_graphs_summary');
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
    const t0 = 1790337600000, t1 = t0 + 3600000;
    String rec(String type, int t, [Map<String, dynamic> fields = const {}]) =>
        jsonEncode({'type': type, 'time_ms': t, ...fields});
    List<String> sampleAt(int t, double temp, {double? fps, double? detectMs, int? pausedMs, bool paused = false}) => [
      rec('thermal', t, {'battery_temp_c': temp, 'thermal_status': 'none', 'clip': name, if (paused) 'paused': true}),
      rec('power', t, {'power_w': 2.0, 'battery_current_ua': -500000, 'battery_voltage_mv': 4000, 'is_charging': false, 'is_plugged': false}),
      if (fps != null) rec('analysis_speed', t, {'clip': name, 'frames_per_s': fps, 'detect_ms': ?detectMs, 'paused_ms': ?pausedMs}),
    ];
    File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync(
      '${[
        rec('video_run_start', t0, {
          'settings': {'model': 'bees.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 15, 'roi': null, 'max_side_px': 1280},
          'sample_s': 10,
        }),
        ...sampleAt(t0, 31),
        for (var i = 0; i < 300; i++) rec('raw_detections', t0 + 100 + i, {'boxes': []}),
        ...sampleAt(t0 + 10000, 35, fps: 25, detectMs: 30),
        rec('video_thermal_pause', t0 + 12000, {'temp_c': 40}),
        ...sampleAt(t0 + 20000, 39, fps: 5, pausedMs: 8000, paused: true),
        rec('video_thermal_resume', t0 + 25000, {'paused_ms': 13000}),
        rec('video_run_end', t0 + 30000),
        rec('video_run_start', t1, {'sample_s': 10}),
        ...sampleAt(t1, 30),
        ...sampleAt(t1 + 30000, 33, fps: 20, detectMs: 32),
        rec('video_run_end', t1 + 30000),
      ].join('\n')}\n',
    );

    await tester.pumpWidget(
      MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'), initialTabIndex: 1)),
    );
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await _pumpUntil(tester, find.text('While the detector ran on the videos', skipOffstage: false));
    await tester.scrollUntilVisible(find.text('While the detector ran on the videos'), 200, scrollable: scrollable);
    // The note sits just below the fold since the timeline text grew (round 247).
    expect(find.textContaining('Measured every 10 s', skipOffstage: false), findsOneWidget);
    await expectSummaryRowValue(tester, scrollable, label: 'Analysis time', value: '1m 0s in 2 runs');
    await expectSummaryRowValue(tester, scrollable, label: 'Frames analyzed', value: '300');
    // 300 frames in 60 s, less 13 s cooling down.
    await expectSummaryRowValue(tester, scrollable, label: 'Speed while running', value: '6.4 frames per second');
    await expectSummaryRowValue(tester, scrollable, label: 'Cooling pauses', value: '1 (0m 13s in total)');
    // 2 W over the 50 s of the two runs; the hour between them is not counted.
    await expectSummaryRowValue(tester, scrollable, label: 'Energy used', value: '≈ 0.03 Wh (on battery)');
    for (final title in ['Battery temperature (°C)', 'Frames analyzed per second', 'Detector time per frame (ms)', 'Power draw (W)']) {
      await tester.scrollUntilVisible(find.text(title), 200, scrollable: scrollable);
    }
    expect(find.text('Not enough samples.', skipOffstage: false), findsNothing);
    // 25 and 20 fps; the 5 fps of the period with the pause is left out.
    expect(
      find.text(
        'Without the cooling pauses: median 22.5 fps; min 20.0 fps, max 25.0 fps. '
        'The average is "Speed while running" above.',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Phone temperature over the session'), findsNothing);
    final list = tester.state<ScrollableState>(scrollable);
    list.position.jumpTo(list.position.maxScrollExtent);
    await tester.pump();
    expectAboveBottomInset(tester, find.textContaining('Average power'), label: 'last video graph row');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
