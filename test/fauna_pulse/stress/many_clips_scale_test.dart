// Scale test (2026-11-24): sessions with many video clips. A camera at one spot that films a
// few minutes, pauses and films again makes up to 120 clips a day; camera traps bring hundreds.
// Content does not matter here, only the number of clips: fake video files, the import plan and
// log written by the real code, the analysis output written by the real VideoDetector.run over
// a fake decoder, then every reader a user reaches afterwards ("Find track IDs", the Video tab,
// the Graphs tab, the Dashboard, "Share results", the Sessions list) and the two screens whose
// rows grow with the clip count (Import videos, Find animals in videos).
//
// Each test prints its numbers (lines start with "SCALE"). A limit is an expectation only where
// a user would notice the delay; the limits are several times the laptop's time, as a phone is
// slower. Tests that show a real bug are kept and marked `skip: 'BUG: ...'`.
//
// The normal suite runs the 120-clip cases (a day of one camera, about 15 s); the 500- and
// 2,000-clip cases take about a minute more:
//   flutter test test/fauna_pulse/stress/many_clips_scale_test.dart --dart-define=MANY_CLIPS_ALL=true

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fauna_pulse/fauna_pulse/capture/roi_video.dart' show VideoClipTotals;
import 'package:fauna_pulse/fauna_pulse/logging/dashboard_stats.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_storage.dart' show folderSizesBytes;
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/clip_cleanup.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/track_export.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_box_timeline.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_run_samples.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoChunk, VideoFrameBoxes, VideoInfo;

import '../summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

/// The session sizes: a day of a camera that films 3 minutes every 7.5 minutes, and with
/// MANY_CLIPS_ALL also 500 camera-trap clips of 30 s and 2,000 clips of 20 s. About 108,000,
/// 75,000 and 200,000 analysed frames at the default 5 per second.
const _all = bool.fromEnvironment('MANY_CLIPS_ALL');
const _sizes = [(clips: 120, seconds: 180), if (_all) ...[(clips: 500, seconds: 30), (clips: 2000, seconds: 20)]];

const _fps = 5;
const _pauseS = 270;
final _day = DateTime(2026, 6, 12, 6);

void _say(String line) {
  // ignore: avoid_print
  print('SCALE $line');
}

int _mb(int bytes) => bytes ~/ (1024 * 1024);

/// Runs [run] and returns its result with the process memory peak during it (sampled every
/// millisecond: the readers measured here yield between chunks). See video_timeline_memory_test
/// for why `ProcessInfo.maxRss` cannot be used.
Future<(T, int)> _withPeakRss<T>(Future<T> Function() run) async {
  final before = ProcessInfo.currentRss;
  var peak = before;
  final timer = Timer.periodic(const Duration(milliseconds: 1), (_) => peak = max(peak, ProcessInfo.currentRss));
  try {
    final result = await run();
    peak = max(peak, ProcessInfo.currentRss);
    return (result, peak - before);
  } finally {
    timer.cancel();
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

/// A camera-trap name with a two-digit year, as such cameras write them: CAM01_260612060000.mp4.
String _camName(DateTime t) =>
    'CAM01_${_two(t.year % 100)}${_two(t.month)}${_two(t.day)}${_two(t.hour)}${_two(t.minute)}${_two(t.second)}.mp4';

DateTime _clipStart(int i, int seconds) => _day.add(Duration(seconds: i * (seconds + _pauseS)));

/// [n] picked clips of [seconds] each, as the import screen builds them. Every other clip
/// stores a time that agrees with its name; the others store a trim day, so their start is
/// flagged as uncertain (the case of an edited copy).
List<ImportClip> _importClips(Directory cache, int n, int seconds, {int fakeBytes = 64}) {
  final trimDay = DateTime(2026, 11, 20, 9).millisecondsSinceEpoch;
  return [
    for (var i = 0; i < n; i++)
      () {
        final start = _clipStart(i, seconds);
        final name = _camName(start);
        final f = File('${cache.path}/$i/$name')..createSync(recursive: true);
        f.writeAsBytesSync(List.filled(fakeBytes, 0));
        final stored = i.isEven ? start.millisecondsSinceEpoch + seconds * 1000 : trimDay;
        final info = VideoInfo(
          durationMs: seconds * 1000,
          width: 1920,
          height: 1080,
          mime: 'video/avc',
          frameCount: seconds * 30,
          creationEpochMs: stored,
        );
        return ImportClip(
          path: f.path,
          name: name,
          // What a 3-minute 1080p clip weighs, for the size lines.
          sizeBytes: seconds * 800000,
          info: info,
          guess: guessClipStart(fileName: name, storedMs: stored, durationMs: seconds * 1000),
        );
      }(),
  ];
}

/// Fake decoder at [_fps] frames per second. One clip in three has an animal for a stretch
/// (seeded by the clip name), so most clips end without a track ID, as at a quiet spot.
class _Backend implements VideoBackend {
  final int seconds;
  _Backend(this.seconds);

  List<int> _pts = const [];
  var _i = 0;
  (int, int)? _animal;
  var _first = true;

  @override
  Future<VideoInfo> info(String path) async =>
      VideoInfo(durationMs: seconds * 1000, firstPtsUs: 0, frameCount: seconds * 30, width: 1920, height: 1080);

  @override
  Future<void> open(String path, VideoRunConfig config, {required int startPtsUs}) async {
    _pts = [for (var i = 0; i < seconds * _fps; i++) i * 1000000 ~/ _fps].where((p) => p >= startPtsUs).toList();
    _i = 0;
    _first = true;
    final r = Random(path.split('/').last.hashCode);
    if (r.nextInt(3) == 0) {
      final from = r.nextInt(seconds * 1000 ~/ 2);
      _animal = (from, from + 3000 + r.nextInt(seconds * 1000 ~/ 2));
    } else {
      _animal = null;
    }
  }

  @override
  Future<VideoChunk> next() async {
    final end = min(_i + 8, _pts.length);
    final a = _animal;
    final frames = [
      for (var k = _i; k < end; k++)
        VideoFrameBoxes(_pts[k], _pts[k] * 30 ~/ 1000000, [
          if (a != null && _pts[k] ~/ 1000 >= a.$1 && _pts[k] ~/ 1000 <= a.$2) [0.40, 0.40, 0.46, 0.47, 0.8, 0],
        ]),
    ];
    _i = end;
    final names = _first ? const ['insect'] : null;
    _first = false;
    return VideoChunk(
      frames: frames,
      done: _i >= _pts.length,
      decoded: frames.length * 6,
      frameWidth: 1920,
      frameHeight: 1080,
      roiPx: const [420, 0, 1080, 1080],
      names: names,
      decodeMs: 3.0 * frames.length,
      convertMs: 1.5 * frames.length,
      inferMs: 20.0 * frames.length,
    );
  }

  @override
  Future<void> close() async {}
}

const _run = VideoRunConfig(modelPath: 'm.tflite', modelName: 'M', confidence: 0.25, iou: 0.45, useGpu: false, analysisFps: 5);

/// Imports [clips] fake clips into a new session under [sessions], analyses them with the fake
/// decoder and finds the track IDs; returns the session folder and the times of the steps.
Future<(Directory, Map<String, int>)> _analysedSession(Directory sessions, Directory cache, int clips, int seconds, {String name = 'video'}) async {
  final times = <String, int>{};
  final sw = Stopwatch()..start();
  final dir = await importVideos(sessionsDir: sessions, sessionName: name, clips: _importClips(cache, clips, seconds));
  times['import'] = sw.elapsedMilliseconds;
  sw.reset();
  final r = await VideoDetector(
    backend: _Backend(seconds),
    thermal: () async => ThermalReading(batteryTempC: 30),
    pausePoll: Duration.zero,
  ).run(dir, config: _run);
  times['analysis (Dart part only)'] = sw.elapsedMilliseconds;
  expect(r.clipsDone, clips);
  sw.reset();
  await VideoTracker.run(dir, const SessionConfig());
  times['find track IDs'] = sw.elapsedMilliseconds;
  return (dir, times);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('many_clips'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the import plan', () {
    for (final s in _sizes) {
      test('${s.clips} camera-named clips: start times, notes and file names', () {
        final clips = _importClips(Directory('${tmp.path}/cache'), s.clips, s.seconds);
        final sw = Stopwatch()..start();
        final plan = planImport(clips);
        final names = clipFileNames(plan);
        final ms = sw.elapsedMilliseconds;
        _say('planImport + clipFileNames, ${s.clips} clips: $ms ms');
        expect(names.values.toSet(), hasLength(s.clips), reason: 'camera names are unique');
        // Every other clip stores a trim day: flagged, but kept at the time of its name.
        expect(plan.where((c) => c.guess.weak), hasLength(s.clips ~/ 2));
        expect(plan.every((c) => c.source == 'file_name'), isTrue);
        expect([for (final c in plan) c.index], [for (var i = 0; i < s.clips; i++) i], reason: 'names sort by time');
        // The import screen runs both on every rebuild (each progress step of the copy).
        expect(ms, lessThan(500));
      });
    }

    // clipFileNames looks for a free name with names.containsValue (a walk over every name so far)
    // and tries _2, _3, ... one by one, so n clips of one name cost about n * n * n / 2 steps:
    // 13 s for 2,000 on the laptop (so about 0.2 s for 500). The import screen runs it on every rebuild,
    // also on each progress step of the copy.
    test('2000 clips that share one name (copied from several folders): file names stay quick', skip: 'BUG: clipFileNames is cubic for repeated names (13 s for 2,000)', () {
      final cache = Directory('${tmp.path}/cache');
      final clips = [
        for (var i = 0; i < 2000; i++)
          ImportClip(
            path: (File('${cache.path}/$i/video.mp4')..createSync(recursive: true)).path,
            name: 'video.mp4',
            sizeBytes: 1000,
            info: const VideoInfo(durationMs: 20000),
            guess: VideoStartGuess(1780000000000 + i * 60000, 'metadata'),
          ),
      ];
      final sw = Stopwatch()..start();
      final names = clipFileNames(planImport(clips));
      final ms = sw.elapsedMilliseconds;
      _say('clipFileNames, 2000 clips of one name: $ms ms');
      expect(names.values.toSet(), hasLength(2000));
      expect(names.values, contains('video_2000.mp4'));
      expect(ms, lessThan(2000));
    });
  });

  group('one session with many clips: import, analysis and every reader', () {
    for (final s in _sizes) {
      test('${s.clips} clips of ${s.seconds} s', () async {
        final sessions = Directory('${tmp.path}/sessions')..createSync();
        final (dir, times) = await _analysedSession(sessions, Directory('${tmp.path}/cache'), s.clips, s.seconds);
        final detFile = File('${dir.path}/${VideoDetector.outputFileName}');
        final trackFile = File('${dir.path}/${VideoTracker.outputFileName}');

        Future<T> timed<T>(String step, Future<T> Function() run) async {
          final sw = Stopwatch()..start();
          final (result, peak) = await _withPeakRss(run);
          times[step] = sw.elapsedMilliseconds;
          times['$step: memory peak MB'] = _mb(peak);
          return result;
        }

        // Find animals in videos: the session list reads every clip's header and both logs.
        await timed('analysis screen session read', () async {
          final files = VideoDetector.clipsOf(dir).where(VideoDetector.isReadableVideo).toList();
          await VideoDetector.clipRecordsFromLog(dir);
          await VideoTracker.readSummary(dir);
          return files;
        });
        final without = await timed('clips without track IDs', () => ClipCleanup.planWithoutVisits(dir));
        // Video tab and the player under the results (one isolate hop in the app).
        final timeline = await timed('Video tab timeline', () async => VideoBoxTimeline.readSync(dir.path));
        // Graphs tab: the phone's readings during the run.
        await timed('Graphs tab run samples', () => VideoRunSamples.parseFile(detFile.path));
        // Summary: the one parse of the session behind every tab.
        final index = await timed(
          'summary index',
          () => SessionLogIndex.parseFile('${dir.path}/session.jsonl', tracksPath: trackFile.path),
        );
        final totals = await timed('summary clip totals', () => VideoClipTotals.read(dir));
        final stats = await timed('Dashboard stats (cold)', () => DashboardStatsCache.forSession(dir));
        await timed('Dashboard stats (warm)', () => DashboardStatsCache.forSession(dir));
        final zipPath = '${tmp.path}/results.zip';
        final zip = await timed('Share results zip', () => VideoTracker.writeResultsZip(dir.path, zipPath));
        final sizes = await timed('Sessions list folder size', () => folderSizesBytes([dir]));
        // The share of "find track IDs" that is only files: track_ids.csv and one MOT file per
        // clip, each written and synced to storage on its own.
        final clipNames = [for (final f in VideoDetector.clipsOf(dir)) f.path.split('/').last];
        await timed('track_ids.csv + mot/ files only', 
          () => TrackExport.write(Directory('${tmp.path}/export_only')..createSync(), visits: const [], clips: clipNames, mot: const {}),
        );
        final summary = (await VideoTracker.readSummary(dir))!;
        final mot = Directory('${dir.path}/mot').listSync().length;
        final csvRows = File('${dir.path}/track_ids.csv').readAsLinesSync().length - 1;
        _say(
          '${s.clips} clips x ${s.seconds} s: ${summary.visits} track IDs in ${summary.clipsWithTrackIds} clips; '
          'files: video_detections ${_mb(detFile.lengthSync())} MB, post_tracks ${_mb(trackFile.lengthSync())} MB, '
          'track_ids.csv $csvRows rows, mot/ $mot files, zip ${_mb(File(zip!).lengthSync())} MB, '
          'session folder ${_mb(sizes[dir.path] ?? 0)} MB (fake 64-byte videos)',
        );
        for (final e in times.entries) {
          _say('  ${s.clips} clips, ${e.key}: ${e.value}${e.key.endsWith('MB') ? '' : ' ms'}');
        }

        // Last: deleting the session (fake 64-byte videos, so this is the cost per file only).
        final del = Stopwatch()..start();
        dir.deleteSync(recursive: true);
        _say('  ${s.clips} clips, delete the session folder: ${del.elapsedMilliseconds} ms');

        expect(timeline.clips, hasLength(s.clips));
        expect(without.deleteNames.length, s.clips - summary.clipsWithTrackIds);
        expect(index.trackSpans, hasLength(summary.visits));
        expect(totals.count, s.clips);
        expect(stats.visits, hasLength(summary.visits));
        expect(csvRows, summary.visits);
        expect(mot, s.clips, reason: 'one MOT file per analysed clip, an empty one without a track ID');
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  });

  test('a month of filming days: 30 sessions of 120 clips in the Sessions list', () async {
    final sessions = Directory('${tmp.path}/sessions')..createSync();
    final cache = Directory('${tmp.path}/cache');
    for (var d = 0; d < 30; d++) {
      // Only the import: the list reads the log and the folder, not the results.
      await importVideos(
        sessionsDir: sessions,
        sessionName: 'video_202606${_two(d + 1)}',
        clips: _importClips(Directory('${cache.path}/$d'), 120, 180),
      );
    }
    final sw = Stopwatch()..start();
    final list = await scanPastSessions(root: sessions, withSizes: false);
    final listMs = sw.elapsedMilliseconds;
    sw.reset();
    final withSizes = await sessionSizes(list);
    final sizesMs = sw.elapsedMilliseconds;
    _say('Sessions list, 30 sessions x 120 clips: list $listMs ms, sizes $sizesMs ms');
    expect(withSizes, hasLength(30));
    expect(withSizes.every((s) => s.hasVideos), isTrue);
    expect(listMs, lessThan(3000), reason: 'Home and Sessions wait for the list');
  });

  group('screens', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    for (final n in [120, if (_all) ...[500, 2000]]) {
      testWidgets('Import videos with $n clips: opens, fits 360 px, the Import button is reachable', (tester) async {
        simulateBottomSystemBar(tester);
        final cache = Directory('${tmp.path}/cache');
        final seconds = n == 120 ? 180 : 20;
        final clips = tester.runAsync(() async => _importClips(cache, n, seconds));
        final picked = [for (final c in (await clips)!) PickedVideo(c.path, c.name, c.sizeBytes)];
        Future<VideoInfo> info(String path) async => VideoInfo(
          durationMs: seconds * 1000,
          width: 1920,
          height: 1080,
          mime: 'video/avc',
          creationEpochMs: _clipStart(int.parse(File(path).parent.path.split('/').last), seconds).millisecondsSinceEpoch + seconds * 1000,
        );
        final open = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(home: VideoImportScreen(files: picked, infoFn: info, sessionsDir: Directory('${tmp.path}/sessions'))),
        );
        for (var i = 0; i < 400 && find.text('Import $n clips').evaluate().isEmpty && find.text('Set all clips…').evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
        final openMs = open.elapsedMilliseconds;
        expect(find.text('Set all clips…'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // One rebuild, as each copied clip's progress step causes during the import.
        final rebuild = Stopwatch()..start();
        tester.element(find.byType(VideoImportScreen)).markNeedsBuild();
        await tester.pump();
        final rebuildMs = rebuild.elapsedMilliseconds;

        final list = find.byType(Scrollable).first;
        final scroll = Stopwatch()..start();
        await tester.scrollUntilVisible(find.text('Import $n clips'), 2000, scrollable: list, maxScrolls: 2000);
        await tester.pump();
        final scrollMs = scroll.elapsedMilliseconds;
        expectAboveBottomInset(tester, find.text('Import $n clips'));
        final height = tester.state<ScrollableState>(list).position.maxScrollExtent;
        _say(
          'Import videos, $n clips: open $openMs ms, one rebuild $rebuildMs ms, scroll to Import $scrollMs ms, '
          'list ${(height / 800).toStringAsFixed(0)} phone screens long (800 px each)',
        );
        expect(tester.takeException(), isNull);
      }, timeout: const Timeout(Duration(minutes: 5)));
    }

    testWidgets('Find animals in videos with 30 sessions of 120 clips: the session list opens', (tester) async {
      final sessions = Directory('${tmp.path}/sessions')..createSync();
      final dirs = (await tester.runAsync(() async {
        final out = <Directory>[];
        for (var d = 0; d < 30; d++) {
          out.add(
            await importVideos(
              sessionsDir: sessions,
              sessionName: 'video_202606${_two(d + 1)}',
              clips: _importClips(Directory('${tmp.path}/cache/$d'), 120, 180),
            ),
          );
        }
        return out;
      }))!;
      final open = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: VideoAnalysisScreen(
            sessionsDir: sessions,
            initialSessionPath: dirs.last.path,
            models: const [ModelEntry(id: 'm', name: 'm.tflite', source: ModelSource.bundled)],
          ),
        ),
      );
      for (var i = 0; i < 2000 && find.textContaining('120 clips').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
      final openMs = open.elapsedMilliseconds;
      _say('Find animals in videos, 30 sessions x 120 clips: open $openMs ms');
      expect(find.textContaining('120 clips'), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(openMs, lessThan(5000), reason: 'the screen shows nothing until every session is read');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
