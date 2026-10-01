// The summary's Video tab (round 231): imported sessions get a player with
// the AI's boxes instead of the photo browser. A fake VideoPlayerPlatform
// stands in for ExoPlayer and records what the controls ask of it; a fake
// wakelock shows whether the screen is kept on. Each
// case runs at 360 px with a 48-px navigation bar.
//
// Follows summary_bottom_inset_test.dart's async recipe (sync fixture IO,
// runAsync/pump interleave; see that file's header for why).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/clip_cleanup.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_box_timeline.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/video_review_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoInfo;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar, writeSessionFixture;
import 'summary_tabs_test.dart' show expectSummaryRowValue;

/// Plays nothing; remembers every call as a short string.
class _FakePlayer extends VideoPlayerPlatform {
  final calls = <String>[];
  final _events = <int, StreamController<VideoEvent>>{};
  var _nextId = 1;
  Duration position = Duration.zero;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    calls.add('create ${options.dataSource.uri?.split('/').last}');
    _events[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(1920, 1080),
          duration: const Duration(seconds: 10),
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> setVolume(int playerId, double volume) async => calls.add('volume $volume');

  /// Sends [e] as the newest player's event (round 252: buffering).
  void emit(VideoEvent e) => _events.values.last.add(e);

  @override
  Future<void> seekTo(int playerId, Duration to) async {
    calls.add('seek ${to.inMilliseconds}');
    position = to;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async => calls.add('speed $speed');

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const ColoredBox(color: Colors.black);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(int playerId, bool prevent) async {}
}

/// Keeps the wakelock state the tab asks for.
class _FakeWakelock extends WakelockPlusPlatformInterface {
  bool on = false;

  @override
  Future<void> toggle({required bool enable}) async => on = enable;

  @override
  Future<bool> get enabled async => on;
}

Future<void> _pumpUntil(WidgetTester tester, Finder ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
    if (ready.evaluate().isNotEmpty) break;
  }
  expect(ready, findsWidgets, reason: 'content never appeared: $ready');
}

/// An imported session with the given clips (fake files) in a temp folder.
Future<Directory> _importedSession(WidgetTester tester, List<String> names) async {
  final tmp = Directory.systemTemp.createTempSync('video_review_player');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final cache = Directory('${tmp.path}/cache')..createSync();
  final sessions = Directory('${tmp.path}/sessions')..createSync();
  return (await tester.runAsync(
    () => importVideos(
      sessionsDir: sessions,
      sessionName: 'Meadow',
      clips: [
        for (final name in names)
          ImportClip(
            path: (File('${cache.path}/$name')..writeAsStringSync('video')).path,
            name: name,
            sizeBytes: 5,
            info: const VideoInfo(durationMs: 10000, width: 1920, height: 1080, mime: 'video/avc'),
            guess: guessClipStart(fileName: name, durationMs: 10000),
          ),
      ],
    ),
  ))!;
}

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': 111, ...m});

/// video_detections.jsonl for [clip]: a frame every 100 ms up to 4 s, a bee
/// from 1 to 3 s.
void _writeDetections(Directory dir, String clip, {List<double>? roi, List<int>? roiPx}) {
  File('${dir.path}/${VideoDetector.outputFileName}').writeAsStringSync(
    '${[
      _rec('video_run_start', {
        'settings': {'model': 'm.tflite', 'confidence': 0.25, 'iou': 0.45, 'analysis_fps': 10, 'roi': roi, 'max_side_px': 1280},
        'model_name': 'Bee model',
      }),
      _rec('video_clip_start', {'clip': clip, 'start_epoch_ms': 1000000, 'width': 1920, 'height': 1080}),
      for (var t = 0; t <= 4000; t += 100)
        _rec('raw_detections', {
          'frame_ms': 1000000 + t,
          'clip': clip,
          'pts_us': t * 1000,
          'frame': t * 30 ~/ 1000,
          'boxes': [
            if (t >= 1000 && t <= 3000) [0.4, 0.4, 0.45, 0.48, 0.9, 0],
          ],
        }),
      _rec('video_clip_done', {
        'clip': clip,
        'frame_width': 1920,
        'frame_height': 1080,
        'roi_px': roiPx ?? [0, 0, 1920, 1080],
        'class_names': ['bee'],
      }),
    ].join('\n')}\n',
  );
}

/// A session recorded with time-lapse video bursts (round 238): two clips
/// (fake files) and a third burst without one (storage low).
Directory _recordedSession() {
  final tmp = Directory.systemTemp.createTempSync('video_bursts');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final dir = Directory('${tmp.path}/sessions/Balcony')..createSync(recursive: true);
  final videos = Directory('${dir.path}/videos')..createSync();
  const a = 'roi_tok1_2026-09-27_120000_000.mp4', b = 'roi_tok1_2026-09-27_120025_000.mp4';
  for (final n in [a, b]) {
    File('${videos.path}/$n').writeAsStringSync('video');
  }
  final t0 = DateTime(2026, 9, 27, 12).millisecondsSinceEpoch;
  String rec(String type, int ms, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': ms, ...m});
  Map<String, dynamic> clip(String n, int burst, int start) => {
    'file': 'videos/$n',
    'start_epoch_ms': start,
    'start_time_source': 'camera',
    'duration_ms': 10000,
    'size_bytes': 1200000,
    'width': 480,
    'height': 480,
    'rotation': 0,
    'codec': 'video/avc',
    'frame_count': 150,
    'fps_mean': 15.0,
    'fps_nominal': 15,
    'frames_skipped': 0,
    'burst': burst,
    'end_reason': 'burst_end',
  };
  File('${dir.path}/session.jsonl').writeAsStringSync(
    '${[
      rec('start_of_session', t0, {
        'file_token': 'tok1',
        'config': {
          'captureTrigger': 'timelapse',
          'timeLapseSaveAs': 'video',
          'timeLapseVideoFps': 15,
          'durationSeconds': 10.0,
          'timeLapseGapSeconds': 15.0,
          'stepSeconds': 1.0,
        },
      }),
      rec('timelapse_video_start', t0, {'file': 'videos/$a', 'burst': 0, 'fps': 15, 'side_px': 480}),
      rec('thermal', t0 + 5000, {'battery_temp_c': 30.0}),
      rec('video_clip', t0 + 10000, clip(a, 0, t0)),
      rec('timelapse_video_start', t0 + 25000, {'file': 'videos/$b', 'burst': 1, 'fps': 15, 'side_px': 480}),
      rec('video_clip', t0 + 35000, clip(b, 1, t0 + 25000)),
      rec('video_skipped', t0 + 50000, {'burst': 2, 'reason': 'storage_low'}),
      rec('end_of_session', t0 + 55000, {'ended_normally': true, 'unique_track_count': 0}),
    ].join('\n')}\n',
  );
  return dir;
}

/// Scrolls to "Track IDs in this clip (n)" and opens the list when folded (round 247).
Future<void> _openTrackList(WidgetTester tester, int n, Finder scrollable) async {
  await tester.scrollUntilVisible(find.text('Track IDs in this clip ($n)'), 200, scrollable: scrollable);
  if (find.textContaining('Tap to list them', skipOffstage: false).evaluate().isNotEmpty) {
    // The note is part of the header's tap target and sits below the header text, so once it
    // is on screen the tap lands. (ensureVisible would also move the tab pager.)
    await tester.scrollUntilVisible(find.textContaining('Tap to list them'), 50, scrollable: scrollable);
    await tester.pump();
    await tester.tap(find.textContaining('Tap to list them'));
    await tester.pump();
  }
}

void main() {
  late _FakePlayer player;
  late _FakeWakelock wake;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    player = _FakePlayer();
    VideoPlayerPlatform.instance = player;
    wake = _FakeWakelock();
    wakelockPlusPlatformInstance = wake;
  });

  testWidgets('imported session: the Video tab plays a clip with its track IDs, fits 360 px', (tester) async {
    simulateBottomSystemBar(tester);
    const clip = 'VID_20260924_155954.mp4';
    final dir = await _importedSession(tester, [clip]);
    _writeDetections(dir, clip, roi: [0.5, 0.5, 0.5625], roiPx: [420, 0, 1080, 1080]);
    await tester.runAsync(() => VideoTracker.run(dir, const SessionConfig()));
    final visit = VideoBoxTimeline.readSync(dir.path).clips[clip]!.visits.single;

    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.byTooltip('Play'));
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Photos'), findsNothing);
    expect(player.calls, containsAllInOrder(['create $clip', 'volume 0.0']));
    expect(find.textContaining('No track IDs yet'), findsNothing);
    expect(find.byKey(const ValueKey('kept_frame_ticks')), findsNothing); // none kept
    expect(tester.takeException(), isNull);
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));

    // Play, then 2×: the speed reaches the player while it plays. The
    // screen stays on only while a clip plays.
    expect(wake.on, isFalse);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(wake.on, isTrue);
    await tester.tap(find.text('2×'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(player.calls, containsAllInOrder(['play', 'speed 2.0']));
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(player.calls.last, 'pause');
    expect(wake.on, isFalse);

    await tester.tap(find.byTooltip('Forward 5 s'));
    await tester.pump();
    expect(player.calls.last, 'seek 5000');
    await tester.tap(find.byTooltip('Previous track ID'));
    await tester.pump();
    expect(player.calls.last, 'seek ${visit.startMs - 1000}');

    // Both views and both box sets draw without errors.
    await tester.scrollUntilVisible(find.text('All boxes'), 200, scrollable: scrollable);
    await tester.tap(find.text('What the detector saw'));
    await tester.pump();
    await tester.tap(find.text('All boxes'));
    await tester.pump();
    expect(find.textContaining('every box the detector found'), findsOneWidget);
    // Round 247: the frames with a box are marked under the time bar, and the note explains
    // what starts a track ID.
    expect(find.byKey(const ValueKey('raw_box_strip'), skipOffstage: false), findsOneWidget);
    expect(find.textContaining('A new track ID starts only from a box the detector is at least 0.50 sure of', skipOffstage: false),
        findsOneWidget);
    expect(tester.takeException(), isNull);

    // Folded: the count and the note, no rows until tapped.
    await tester.scrollUntilVisible(find.text('Track IDs in this clip (1)'), 200, scrollable: scrollable);
    expect(find.textContaining('can be false detections', skipOffstage: false), findsOneWidget);
    expect(find.text('#${visit.trackId}', skipOffstage: false), findsNothing);
    await _openTrackList(tester, 1, scrollable);
    expect(find.textContaining('a white tick under the time bar'), findsNothing); // none kept
    await tester.scrollUntilVisible(find.text('#${visit.trackId}'), 200, scrollable: scrollable);
    await tester.tap(find.text('#${visit.trackId}'));
    await tester.pump();
    expect(player.calls.last, 'seek ${visit.startMs - 1000}');
    // Round 234: the kept frames (none: this run kept none) come next.
    await tester.scrollUntilVisible(find.textContaining('No kept frames yet.'), 200, scrollable: scrollable);
    // (A `.last` finder can't scroll to a row not built yet: drag first.)
    await tester.drag(scrollable, const Offset(0, -2000));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Identify organisms').last, 200, scrollable: scrollable);
    await tester.drag(scrollable, const Offset(0, -2000));
    await tester.pump();
    expectAboveBottomInset(tester, find.text('Identify organisms').last, label: 'last button');
    expect(tester.takeException(), isNull);

    // Leaving the tab pauses; closing the screen releases the player.
    await tester.scrollUntilVisible(find.byTooltip('Play'), -200, scrollable: scrollable);
    // (It can stop with the button under the app bar: bring it fully on screen.)
    await tester.ensureVisible(find.byTooltip('Play'));
    await tester.pump();
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(player.calls.last, 'speed 2.0');
    expect(wake.on, isTrue);
    await tester.tap(find.text('Graphs'));
    await tester.pump();
    expect(player.calls.last, 'pause');
    expect(wake.on, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(player.calls.last, 'dispose');
  });

  /// An imported session whose visit kept 2 frames (saved as small JPEGs),
  /// with an identification of that visit made for the Find visits run
  /// [identifiedRunOffset] away from the current one (null: none).
  Future<(Directory, List<KeptFrame>)> keptSession(WidgetTester tester, {int? identifiedRunOffset}) async {
    const clip = 'VID_20260924_155954.mp4';
    final dir = await _importedSession(tester, [clip]);
    _writeDetections(dir, clip, roi: [0.5, 0.5, 0.5625], roiPx: [420, 0, 1080, 1080]);
    await tester.runAsync(
      () => VideoTracker.run(dir, const SessionConfig(), keep: const KeepFramesSettings(stepSeconds: 1, durationSeconds: 10)),
    );
    final kept = (await tester.runAsync(() => VideoTracker.readKeptFrames(dir)))!;
    expect(kept, hasLength(2)); // the 2-s visit: its first frame and one a second later
    final jpeg = img.encodeJpg(img.Image(width: 64, height: 64));
    for (final k in kept) {
      File('${dir.path}/roi_frames/${k.file}')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(jpeg);
    }
    if (identifiedRunOffset != null) {
      final runId = (await tester.runAsync(() => VideoTracker.readSummary(dir)))!.runId!;
      File('${dir.path}/identification/summary_p.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'pack_id': 'p',
            'generated_iso': '2026-09-26T10:00:00.000',
            'capture': {'visits_run_id': runId + identifiedRunOffset},
            'tracks': [
              {'track_id': kept.first.trackIds.first, 'headline': 'Bombus', 'identified_rank': 'genus', 'p': 0.9},
            ],
          }),
        );
    }
    return (dir, kept);
  }

  /// Opens the summary on [dir] and scrolls to the kept frames' viewer.
  Future<Finder> openKeptFrames(WidgetTester tester, Directory dir) async {
    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.byTooltip('Play'));
    // The tab's own list (the photo viewer inside it scrolls too).
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Kept frames'), 200, scrollable: scrollable);
    await _pumpUntil(tester, find.text('Show in video'));
    return scrollable;
  }

  testWidgets('kept frames show under the player; "Show in video" moves it there (r234)', (tester) async {
    simulateBottomSystemBar(tester);
    final (dir, kept) = await keptSession(tester, identifiedRunOffset: 0);
    // Round 235: white ticks under the time bar mark the kept frames.
    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.byTooltip('Play'));
    expect(find.byKey(const ValueKey('kept_frame_ticks')), findsOneWidget);
    // The tab's own list (the photo viewer inside it scrolls too).
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.textContaining('a white tick under the time bar'), 200, scrollable: scrollable);
    await tester.scrollUntilVisible(find.text('Kept frames'), 200, scrollable: scrollable);
    await _pumpUntil(tester, find.text('Show in video'));
    expect(find.text('Showing 2 of 2 kept frames this session.'), findsOneWidget);
    // The identification made for these visits labels the frame.
    await tester.scrollUntilVisible(find.textContaining('Bombus (genus, 90 %)').first, 200, scrollable: scrollable);
    expect(find.textContaining('The track IDs were found again since identification ran'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(find.text('Show in video').first, 200, scrollable: scrollable);
    await tester.tap(find.text('Show in video').first);
    // Back up to the player: a jump to the top, then the block aligned.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(player.calls.last, 'seek ${kept.first.ptsUs ~/ 1000}');
    expect(find.byTooltip('Play').hitTestable(), findsOneWidget);
    // Round 235: the header text scrolled off; the player block sits at the
    // top of the tab, so the controls are on screen with a tall clip too.
    expect(find.text("Videos with the detector's boxes").hitTestable(), findsNothing);
    expect(tester.state<ScrollableState>(scrollable).position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  });

  // Round 252: after a jump the player shows the old picture until it has
  // decoded the new one (its buffering flag, up to 2.7 s on the Samsung);
  // boxes of the new moment would sit on the old picture meanwhile.
  testWidgets('after a jump the boxes wait for the new picture (r252)', (tester) async {
    simulateBottomSystemBar(tester);
    final (dir, _) = await keptSession(tester, identifiedRunOffset: 0);
    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.byTooltip('Play'));
    final state = tester.state<VideoReviewPlayerState>(find.byType(VideoReviewPlayer));
    expect(state.waitingForPicture, isFalse);
    await tester.ensureVisible(find.byTooltip('Forward 5 s'));
    await tester.pump();
    await tester.tap(find.byTooltip('Forward 5 s'));
    await tester.pump();
    expect(player.calls.last, 'seek 5000');
    expect(state.waitingForPicture, isTrue); // asked; the player has not answered yet
    player.emit(VideoEvent(eventType: VideoEventType.bufferingStart));
    await tester.pump(const Duration(milliseconds: 600)); // past the guard: the flag holds it
    expect(state.waitingForPicture, isTrue);
    player.emit(VideoEvent(eventType: VideoEventType.bufferingEnd));
    await tester.pump();
    expect(state.waitingForPicture, isFalse);
    // A jump the player answers without fetching: the guard lets the boxes back.
    await tester.tap(find.byTooltip('Back 5 s'));
    await tester.pump();
    expect(state.waitingForPicture, isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.waitingForPicture, isFalse);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  });

  testWidgets('an identification of track IDs found before is not shown on the frames (r235)', (tester) async {
    simulateBottomSystemBar(tester);
    final (dir, _) = await keptSession(tester, identifiedRunOffset: -1);
    final scrollable = await openKeptFrames(tester, dir);
    await tester.scrollUntilVisible(
      find.textContaining('The track IDs were found again since identification ran'),
      -200,
      scrollable: scrollable,
    );
    expect(find.textContaining('are shown under each photo'), findsNothing);
    // The frame's info rows are there, without the outdated answer.
    await tester.scrollUntilVisible(find.text('In video'), 200, scrollable: scrollable);
    expect(find.text('Track IDs'), findsOneWidget);
    expect(find.text('Identified'), findsNothing);
    expect(find.textContaining('Bombus'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  });

  testWidgets('a clip deleted to free storage says so, keeps its track IDs; Setup counts it (r236)', (tester) async {
    simulateBottomSystemBar(tester);
    const clip = 'VID_20260924_155954.mp4';
    final dir = await _importedSession(tester, [clip]);
    _writeDetections(dir, clip);
    await tester.runAsync(() async {
      await VideoTracker.run(dir, const SessionConfig());
      await ClipCleanup.run(dir, await ClipCleanup.planAll(dir));
    });

    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.textContaining('to free storage'));
    expect(find.textContaining('This clip was deleted on '), findsOneWidget);
    expect(player.calls.where((c) => c.startsWith('create')), isEmpty);
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Track IDs in this clip (1)'), 200, scrollable: scrollable);
    // No time bar, so no ticks explained; nothing left to analyse again.
    expect(find.textContaining('a white tick under the time bar'), findsNothing);
    expect(find.text('Square in the wrong place?'), findsNothing);
    expect(find.text('Other track ID settings?'), findsOneWidget);
    expect(find.text('Find animals in videos'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    final setup = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.textContaining('All session settings'), 200, scrollable: setup);
    await tester.tap(find.textContaining('All session settings'));
    await tester.pump();
    await expectSummaryRowValue(tester, setup, label: 'Videos deleted', value: '1 (5 B freed)');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('without a square, track IDs or analysis: no view switch, notes say why', (tester) async {
    simulateBottomSystemBar(tester);
    const a = 'VID_20260924_155954.mp4', b = 'VID_20260924_160512.mp4';
    final dir = await _importedSession(tester, [a, b]);
    _writeDetections(dir, a);

    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.byTooltip('Play'));
    expect(find.text('Video'), findsOneWidget);
    expect(find.textContaining('No track IDs yet'), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next)).onPressed, isNull);
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.textContaining('every box the detector found'), 200, scrollable: scrollable);
    expect(find.text('What the detector saw'), findsNothing, reason: 'whole frame analysed');
    expect(find.text('All boxes'), findsNothing, reason: 'no track IDs to switch from');
    expect(find.textContaining('Track IDs in this clip'), findsNothing);

    // The second clip was not analysed.
    await tester.scrollUntilVisible(find.text(a), -200, scrollable: scrollable);
    await tester.tap(find.text(a));
    await tester.pumpAndSettle();
    await tester.tap(find.text('$b · not analysed').last);
    await _pumpUntil(tester, find.textContaining('This clip was not analysed yet'));
    expect(player.calls.where((c) => c.startsWith('create')), ['create $a', 'create $b']);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('recorded video bursts: Video tab, clip line, copy videos, Setup rows, graphs switch (r239)', (tester) async {
    simulateBottomSystemBar(tester);
    final dir = _recordedSession();
    const channel = MethodChannel('faunapulse/crop');
    final copied = <List<Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'saveVideosToGallery');
      expect((call.arguments as Map)['album'], 'Balcony');
      copied.add((call.arguments as Map)['paths'] as List<Object?>);
      return {'supported': true, 'exported': 1, 'skipped': 0, 'failed': 0};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.byTooltip('Play'));
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Photos'), findsNothing);
    await _pumpUntil(tester, find.text('2 clips · 20.0 s filmed · 2.3 MB'));
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('Not analysed yet'), 200, scrollable: scrollable);
    expect(find.text('Square in the wrong place?'), findsNothing);
    expect(find.text('Find animals in videos'), findsOneWidget);

    // Copy videos: one clip per call, then the counts.
    await tester.scrollUntilVisible(find.text('Copy videos'), 200, scrollable: scrollable);
    expectAboveBottomInset(tester, find.text('Copy videos'), label: 'Copy videos');
    await tester.tap(find.text('Copy videos'));
    await tester.pumpAndSettle();
    expect(find.text('Copy 2 videos to Gallery?'), findsOneWidget);
    expect(find.textContaining('"Movies/FaunaPulse/Balcony"'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await _pumpUntil(tester, find.textContaining('Copied 2 videos to Gallery ▸ Movies/FaunaPulse/Balcony.'));
    expect(copied.map((c) => c.length), [1, 1]);
    expect(copied.first.single, endsWith('videos/roi_tok1_2026-09-27_120000_000.mp4'));
    expect(tester.takeException(), isNull);
    // The snack bar's 4 s start after its entrance animation.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Setup: the mode and the clips.
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    final setup = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('Time-lapse video bursts (detection afterwards)'), 200, scrollable: setup);
    await tester.scrollUntilVisible(find.textContaining('All session settings'), 200, scrollable: setup);
    await tester.tap(find.textContaining('All session settings'));
    await tester.pumpAndSettle();
    await expectSummaryRowValue(tester, setup, label: 'Clips', value: '2');
    await expectSummaryRowValue(tester, setup, label: 'Bursts without a clip', value: '1');
    await expectSummaryRowValue(tester, setup, label: 'Save bursts as', value: 'video');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // After an analysis and Find visits: the visits, and the graphs can show
    // the recording or the analysis run.
    _writeDetections(dir, 'roi_tok1_2026-09-27_120000_000.mp4');
    await tester.runAsync(() => VideoTracker.run(dir, const SessionConfig()));
    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'), initialTabIndex: 1)));
    await _pumpUntil(tester, find.text('1 (found afterwards in the videos)'));
    final graphs = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.textContaining('Extra graphs'), 300, scrollable: graphs);
    // Off the bottom edge after the scroll: drag it well into view before tapping.
    await tester.drag(graphs, const Offset(0, -300));
    await tester.pump();
    if (find.text('While recording').evaluate().isEmpty) {
      await tester.tap(find.textContaining('Extra graphs'));
      await tester.pumpAndSettle();
    }
    await tester.scrollUntilVisible(find.text('While the detector ran'), 200, scrollable: graphs);
    expect(find.text('Phone temperature over the session (°C)'), findsOneWidget);
    await tester.tap(find.text('While the detector ran'));
    await _pumpUntil(tester, find.textContaining('No measurements yet.'));
    expect(find.text('Phone temperature over the session (°C)'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('live detection + ROI video: the Video tab plays the clips with the live boxes (r240)', (tester) async {
    simulateBottomSystemBar(tester);
    final tmp = Directory.systemTemp.createTempSync('live_video');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final dir = Directory('${tmp.path}/sessions/Lavender')..createSync(recursive: true);
    Directory('${dir.path}/videos').createSync();
    Directory('${dir.path}/roi_frames').createSync();
    const clip = 'roi_tok1_2026-09-27_150000_000.mp4';
    File('${dir.path}/videos/$clip').writeAsStringSync('video');
    final t0 = DateTime(2026, 9, 27, 15).millisecondsSinceEpoch;
    String rec(String type, int ms, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': ms, ...m});
    File('${dir.path}/session.jsonl').writeAsStringSync(
      '${[
        rec('start_of_session', t0, {
          'file_token': 'tok1',
          'config': {'captureTrigger': 'detector', 'liveAiVideo': true, 'liveAiVideoFps': 15},
        }),
        rec('live_video_start', t0, {'file': 'videos/$clip', 'segment': 0, 'fps': 15, 'side_px': 480}),
        for (var ms = 2000; ms <= 4000; ms += 100)
          rec('detections', t0 + ms + 30, {
            'frame_sensor_ms': t0 + ms,
            'tracks': [
              {
                'track_id': 7,
                'class_name': 'bee',
                'confidence': 0.9,
                'box_in_roi': {'left': 0.4, 'top': 0.4, 'right': 0.5, 'bottom': 0.5},
              },
            ],
          }),
        rec('video_clip', t0 + 10000, {
          'file': 'videos/$clip',
          'start_epoch_ms': t0,
          'start_time_source': 'camera',
          'duration_ms': 10000,
          'size_bytes': 900000,
          'width': 480,
          'height': 480,
          'frame_count': 150,
          'segment': 0,
          'end_reason': 'session_end',
        }),
        rec('end_of_session', t0 + 11000, {'ended_normally': true, 'unique_track_count': 1}),
      ].join('\n')}\n',
    );

    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.byTooltip('Play'));
    expect(find.text('Video'), findsOneWidget);
    expect(find.text("Videos with live detection's boxes"), findsOneWidget);
    await _pumpUntil(tester, find.text('1 clip · 10.0 s filmed · 879 KB'));
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await _openTrackList(tester, 1, scrollable);
    await tester.scrollUntilVisible(find.text('#7'), 100, scrollable: scrollable);
    expect(find.text('0:02.0 – 0:04.0'), findsOneWidget);
    expect(find.text('All boxes'), findsNothing);
    expect(find.text('Not analysed yet'), findsNothing);
    expect(find.text('Square in the wrong place?'), findsNothing);
    expect(find.text('Live detection'), findsNothing, reason: 'nothing analysed afterwards yet');
    // Above the (opened) track list.
    await tester.scrollUntilVisible(find.text('Compare with detection afterwards'), -200, scrollable: scrollable);
    expect(find.widgetWithText(FilledButton, 'Find animals in videos'), findsOneWidget);
    // The session's own photos follow, and the clips can be copied.
    await tester.scrollUntilVisible(find.textContaining('Saved photos'), 200, scrollable: scrollable);
    await tester.scrollUntilVisible(find.text('Copy videos'), 200, scrollable: scrollable);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // Round 241: the same clip analysed afterwards (a bee from 1 to 3 s).
    _writeDetections(dir, clip);
    await tester.runAsync(() => VideoTracker.run(dir, const SessionConfig()));
    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.text('Detection afterwards', skipOffstage: false));
    final list2 = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await _openTrackList(tester, 1, list2);
    await tester.scrollUntilVisible(find.text('#7'), 100, scrollable: list2);
    await tester.scrollUntilVisible(find.text('Detection afterwards'), -200, scrollable: list2);
    await tester.drag(list2, const Offset(0, 150)); // clear of the tab bar
    await tester.pump();
    await tester.tap(find.text('Detection afterwards'));
    await tester.pumpAndSettle();
    expect(find.text('All boxes'), findsOneWidget);
    final after = VideoBoxTimeline.readSync(dir.path).clips[clip]!.visits.single;
    expect(after.trackId, isNot(7));
    await _openTrackList(tester, 1, list2);
    await tester.scrollUntilVisible(find.text('#${after.trackId}'), 100, scrollable: list2);
    expect(find.text('#7'), findsNothing, reason: 'the afterwards track ID has its own number');
    expect(find.text('Compare with detection afterwards'), findsNothing);
    await tester.scrollUntilVisible(find.text('Live detection'), -200, scrollable: list2);
    await tester.drag(list2, const Offset(0, 150)); // clear of the tab bar
    await tester.pump();
    await tester.tap(find.text('Live detection'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Find animals in videos again'), 200, scrollable: list2);
    expect(tester.takeException(), isNull);

    // Graphs: the live count, and the afterwards one for comparison.
    await tester.tap(find.text('Graphs'));
    await _pumpUntil(tester, find.text('1 (for comparison; Video tab)'));
    expect(find.text('Track IDs found afterwards in the videos'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('live sessions keep the Photos tab', (tester) async {
    final log = writeSessionFixture(const []);
    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: log, initialTabIndex: 2)));
    await _pumpUntil(tester, find.text('Setup'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Video'), findsNothing);
    expect(player.calls, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
