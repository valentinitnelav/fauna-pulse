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
import 'package:fauna_pulse/fauna_pulse/postprocess/video_box_timeline.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoInfo;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar, writeSessionFixture;

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

  testWidgets('imported session: the Video tab plays a clip with its visits, fits 360 px', (tester) async {
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
    expect(find.textContaining('No visits yet'), findsNothing);
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
    await tester.tap(find.byTooltip('Previous visit'));
    await tester.pump();
    expect(player.calls.last, 'seek ${visit.startMs - 1000}');

    // Both views and both box sets draw without errors.
    await tester.scrollUntilVisible(find.text('All AI boxes'), 200, scrollable: scrollable);
    await tester.tap(find.text('What the AI saw'));
    await tester.pump();
    await tester.tap(find.text('All AI boxes'));
    await tester.pump();
    expect(find.textContaining('every box the AI found'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(find.text('Visits in this clip (1)'), 200, scrollable: scrollable);
    await tester.scrollUntilVisible(find.text('#${visit.trackId}'), 200, scrollable: scrollable);
    await tester.tap(find.text('#${visit.trackId}'));
    await tester.pump();
    expect(player.calls.last, 'seek ${visit.startMs - 1000}');
    await tester.scrollUntilVisible(find.text('Identify organisms').last, 200, scrollable: scrollable);
    await tester.drag(scrollable, const Offset(0, -2000));
    await tester.pump();
    expectAboveBottomInset(tester, find.text('Identify organisms').last, label: 'last button');
    expect(tester.takeException(), isNull);

    // Leaving the tab pauses; closing the screen releases the player.
    await tester.scrollUntilVisible(find.byTooltip('Play'), -200, scrollable: scrollable);
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

  testWidgets('without a square, visits or analysis: no view switch, notes say why', (tester) async {
    simulateBottomSystemBar(tester);
    const a = 'VID_20260924_155954.mp4', b = 'VID_20260924_160512.mp4';
    final dir = await _importedSession(tester, [a, b]);
    _writeDetections(dir, a);

    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))));
    await _pumpUntil(tester, find.byTooltip('Play'));
    expect(find.text('Video'), findsOneWidget);
    expect(find.textContaining('No visits yet'), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next)).onPressed, isNull);
    final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.textContaining('every box the AI found'), 200, scrollable: scrollable);
    expect(find.text('What the AI saw'), findsNothing, reason: 'whole frame analysed');
    expect(find.text('All AI boxes'), findsNothing, reason: 'no visits to switch from');
    expect(find.textContaining('Visits in this clip'), findsNothing);

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
