// Tests for finding visits afterwards in the photos of a time-lapse or motion
// session (round 237, photo_tracker.dart): which sessions qualify, what is
// written, and that the summary index, the dashboard and identification read
// the result like visits found in videos.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show roiPhotoFileName;
import 'package:fauna_pulse/fauna_pulse/identification/identification_choice.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/logging/dashboard_stats.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';
import 'package:fauna_pulse/fauna_pulse/logging/track_source.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/photo_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/track_export.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;
import 'video_screens_test.dart' show idChoice;

final s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': s0, ...m});

/// A time-lapse session (photo every [stepS]) with two 10-s bursts 60 s
/// apart; [insect] says in which photos (ms after the session start) the
/// analysis found a resting insect. Photos carry a 640-px `capture` record.
Directory _session({
  double stepS = 0.2,
  String trigger = 'timelapse',
  required bool Function(int ms) insect,
  Set<int> failed = const {},
}) {
  final dir = Directory.systemTemp.createTempSync('photo_tracker_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final stepMs = (stepS * 1000).round();
  final times = [
    for (var t = 0; t < 10000; t += stepMs) t,
    for (var t = 70000; t < 80000; t += stepMs) t,
  ];
  final log = [
    _rec('start_of_session', {
      'file_token': 'tok',
      'config': {'captureTrigger': trigger, 'stepSeconds': stepS, 'durationSeconds': 10.0},
    }),
    for (final t in times) ...[
      _rec('timelapse_capture', {'jpeg': roiPhotoFileName(s0 + t, 'tok'), 'captured_at_ms': s0 + t}),
      _rec('capture', {'file': roiPhotoFileName(s0 + t, 'tok'), 'captured_at_ms': s0 + t, 'saved_px': 640}),
    ],
    _rec('end_of_session', {'time_ms': s0 + 90000, 'ended_normally': true}),
  ];
  File('${dir.path}/session.jsonl').writeAsStringSync('${log.join('\n')}\n');
  final post = [
    _rec('post_start', {'model': 'm.tflite', 'model_name': 'm', 'confidence': 0.25, 'iou': 0.7}),
    for (final t in times)
      _rec('post_detection', {
        'jpeg': roiPhotoFileName(s0 + t, 'tok'),
        'captured_at_ms': s0 + t,
        if (failed.contains(t)) 'error': 'unreadable',
        'boxes': [
          if (insect(t) && !failed.contains(t))
            {
              'class_name': 'bee',
              'conf': 0.8,
              'box': [0.4, 0.4, 0.5, 0.5],
            },
        ],
      }),
  ];
  File('${dir.path}/post_detections.jsonl').writeAsStringSync('${post.join('\n')}\n');
  return dir;
}

/// Gives every photo of [dir] a (tiny) file, as a real session has.
void _photoFiles(Directory dir) {
  Directory('${dir.path}/roi_frames').createSync();
  for (final l in File('${dir.path}/session.jsonl').readAsLinesSync()) {
    final r = jsonDecode(l) as Map;
    if (r['type'] == 'capture') File('${dir.path}/roi_frames/${r['file']}').writeAsStringSync('jpeg');
  }
}

/// The screen turns the wakelock off when it closes; tests have no plugin.
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

List<Map<String, dynamic>> _records(Directory d, String type) => [
  for (final l in File('${d.path}/$postTracksFileName').readAsLinesSync())
    if ((jsonDecode(l) as Map)['type'] == type) (jsonDecode(l) as Map).cast<String, dynamic>(),
];

void main() {
  const config = SessionConfig(); // occlusion 3 s, minimum visit 0.2 s

  test('which sessions can be followed from photo to photo', () async {
    final close = await PhotoTracker.trackability(_session(insect: (_) => false));
    expect([close.trackedLive, close.tooSparse, close.possible], [false, false, true]);
    expect(close.analysedPhotos, 100);

    final sparse = await PhotoTracker.trackability(_session(stepS: 1, insect: (_) => false));
    expect([sparse.tooSparse, sparse.possible], [true, false]);

    final live = await PhotoTracker.trackability(_session(trigger: 'detector', insect: (_) => false));
    expect([live.trackedLive, live.possible], [true, false]);
  });

  test('one resting insect is one track ID; photos, times and burst time are written', () async {
    // In the first burst from 2 s to 5 s; one photo in between failed.
    final dir = _session(insect: (t) => t >= 2000 && t <= 5000, failed: {3000});
    final r = await PhotoTracker.run(dir, config);
    expect(r.visits, 1);
    expect(r.frames, 99); // the failed photo is left out

    final start = _records(dir, 'post_track_start').single;
    expect(start['source'], 'photos');
    expect(start['photo_step_s'], 0.2);
    expect(start['photos'], 99);
    expect(start['clips'], isEmpty);
    // Two bursts of 50 photos, each covering 10 s.
    expect(start['observed_ms'], 20000);
    expect(start['detection_settings'], containsPair('model', 'm.tflite'));
    expect(start['detections_run_ms'], s0);

    final dets = _records(dir, 'detections');
    final named = [
      for (final d in dets)
        for (final t in d['tracks'] as List)
          if ((t as Map)['jpeg'] != null) t['jpeg'],
    ];
    // Each photo with the insect names itself, from confirmation on.
    expect(named, isNotEmpty);
    expect(named.toSet(), hasLength(named.length));
    expect(named, everyElement(startsWith('roi_tok_')));
    expect(_records(dir, 'post_track_end').single['track_ids'], 1);

    final row = File('${dir.path}/${TrackExport.visitsFileName}').readAsLinesSync()[1].split(',');
    expect(row[1], ''); // no clip
    expect(double.parse(row[3]), closeTo(2.0, 0.01)); // seconds from the session start
    expect(double.parse(row[4]), closeTo(5.0, 0.01));

    // The file reads like video visits: summary, track source, dashboard.
    final summary = (await VideoTracker.readSummary(dir))!;
    expect(summary.visits, 1);
    expect(trackSourceOf(dir), TrackSource.afterwards);
    final stats = await DashboardStatsCache.forSession(dir);
    expect(stats.visits, hasLength(1));
    expect(stats.recordedMs, 20000);
  });

  test('a motion session counts its whole span as watched', () async {
    final dir = _session(trigger: 'motion', insect: (t) => t >= 2000 && t <= 5000);
    await PhotoTracker.run(dir, config);
    expect(_records(dir, 'post_track_start').single.containsKey('observed_ms'), isFalse);
  });

  test('the summary index keeps the photos\' own records and adds the track IDs', () async {
    final dir = _session(insect: (t) => t >= 2000 && t <= 5000);
    await PhotoTracker.run(dir, config);
    final index = await SessionLogIndex.build(File('${dir.path}/session.jsonl'));
    expect(index.trackSource, TrackSource.afterwards);
    final photo = index.photos[roiPhotoFileName(s0 + 4000, 'tok')]!;
    expect(photo.resW, 640); // from session.jsonl's capture record
    expect(photo.trackIds, hasLength(1));
    expect(photo.boxes.single.left, closeTo(0.4, 1e-9));
    expect(index.trackSpans, hasLength(1));
    expect(index.photos, hasLength(100));
  });

  test('identification plans crops per track ID from the photos', () async {
    final dir = _session(insect: (t) => t >= 2000 && t <= 5000);
    Directory('${dir.path}/roi_frames').createSync();
    for (final t in [for (var t = 0; t < 10000; t += 200) t]) {
      File('${dir.path}/roi_frames/${roiPhotoFileName(s0 + t, 'tok')}').writeAsStringSync('jpeg');
    }
    await PhotoTracker.run(dir, config);
    final tasks = await IdentificationJob.planSession(dir, maxCropsPerTrack: 10);
    expect(tasks, hasLength(10));
    expect({for (final t in tasks) t.trackId}, hasLength(1));
    expect(await IdentificationJob.currentVisitsRunId(dir), (await VideoTracker.readSummary(dir))!.runId);
  });

  test('a high-res photo and its companion are one moment; the companion fills in', () async {
    final dir = _session(insect: (_) => false);
    // Every photo of the first burst gets a `_live` companion that sees the
    // insect from 2 s to 5 s while the high-res photo itself does not.
    final extra = [
      for (var t = 0; t < 10000; t += 200)
        _rec('post_detection', {
          'jpeg': roiPhotoFileName(s0 + t, 'tok').replaceFirst('.jpg', '_live.jpg'),
          'captured_at_ms': s0 + t,
          'boxes': [
            if (t >= 2000 && t <= 5000)
              {
                'class_name': 'bee',
                'conf': 0.7,
                'box': [0.4, 0.4, 0.5, 0.5],
              },
          ],
        }),
    ];
    File('${dir.path}/post_detections.jsonl').writeAsStringSync('${extra.join('\n')}\n', mode: FileMode.append);
    final r = await PhotoTracker.run(dir, config);
    expect(r.visits, 1);
    expect(r.frames, 100); // one frame per moment, not per file
    final named = {
      for (final d in _records(dir, 'detections'))
        for (final t in d['tracks'] as List)
          if ((t as Map)['jpeg'] != null) t['jpeg'] as String,
    };
    expect(named, isNotEmpty);
    expect(named.where((n) => n.endsWith('_live.jpg')), isEmpty); // named by the photo itself
  });

  group('screens', () {
    setUp(() => wakelockPlusPlatformInstance = _FakeWakelock());
    const models = [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)];

    Future<Finder> openAnalysis(WidgetTester tester, Directory session, {IdentificationChoice? choice}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AnalysisScreen(
            initialSessionPath: session.path,
            sessionsDir: session.parent,
            models: models,
            identificationChoice: choice,
          ),
        ),
      );
      await _pumpUntil(tester, find.textContaining(session.path.split('/').last));
      // Let the session's results load, then scroll to the section.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Track IDs'), 200, scrollable: list);
      return list;
    }

    /// Round 273: the settings of the Find screens sit in closed folds.
    Future<void> openFold(WidgetTester tester, Finder list, String title) async {
      await tester.scrollUntilVisible(find.text(title), 200, scrollable: list);
      await tester.pump();
      await tester.tap(find.text(title));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('"Find animals in photos" finds the track IDs of close photos (360 px)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      final dir = _session(insect: (t) => t >= 2000 && t <= 5000);
      _photoFiles(dir);
      final list = await openAnalysis(tester, dir);
      await tester.scrollUntilVisible(find.text('Find track IDs'), 200, scrollable: list);
      // Round 273: folded, with the values in use on the fold's line.
      expect(find.text('Occlusion tolerance'), findsNothing);
      expect(find.text('Occlusion tolerance 3.0 s, minimum track 0.2 s'), findsOneWidget);
      await openFold(tester, list, 'Track ID settings');
      expect(find.text('Occlusion tolerance'), findsOneWidget);
      expect(find.text('Minimum track length'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Find track IDs'), 200, scrollable: list);
      await tester.pump();
      await tester.tap(find.text('Find track IDs'));
      await _pumpUntil(tester, find.textContaining('1 track ID (occlusion tolerance 3.0 s, minimum track 0.2 s).'));
      expect(find.text('Find track IDs again'), findsOneWidget);
      expect(find.textContaining('Found 1 track ID in 100 photos.'), findsOneWidget);
      expect(File('${dir.path}/$postTracksFileName').existsSync(), isTrue);
      expect(tester.takeException(), isNull);
      final last = find.textContaining('A stopped run resumes where it left off.');
      await tester.scrollUntilVisible(last, 200, scrollable: list);
      await tester.drag(list, const Offset(0, -2000));
      await tester.pump();
      expectAboveBottomInset(tester, last);

      // The summary names where the visits come from.
      await tester.pumpWidget(
        MaterialApp(home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'), initialTabIndex: 1)),
      );
      await _pumpUntil(tester, find.text('1 (found afterwards in the photos)'));
      expect(find.textContaining('Found afterwards in the photos with "Find track IDs"'), findsOneWidget);
      expect(find.textContaining('Time between bursts was not photographed.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Find animals in photos" shows session, model and Start; settings folded (r273)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      final dir = _session(insect: (t) => t >= 2000 && t <= 5000);
      _photoFiles(dir);
      final list = await openAnalysis(tester, dir);
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Small-insect tiling (SAHI)'), findsNothing);
      expect(find.text('Confidence 0.25, IoU 0.70, small-insect tiling off'), findsOneWidget);
      await openFold(tester, list, 'Advanced settings');
      expect(find.text('Confidence threshold: 0.25'), findsOneWidget);
      expect(find.text('IoU threshold: 0.70'), findsOneWidget);
      expect(find.text('Small-insect tiling (SAHI)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Also identify them": with every photo analyzed, Start only identifies (r274)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      final dir = _session(insect: (t) => t >= 2000 && t <= 5000);
      _photoFiles(dir);
      final list = await openAnalysis(tester, dir, choice: idChoice(Directory.systemTemp.createTempSync('id_choice')));
      await tester.scrollUntilVisible(find.text('Also identify them'), -200, scrollable: list);
      expect(find.text('Model (.tflite)'), findsOneWidget);
      final start = find.text('Identify the animals found');
      await tester.scrollUntilVisible(start, 200, scrollable: list);
      final button = tester.widget<FilledButton>(
        find.ancestor(of: start, matching: find.byWidgetPredicate((w) => w is FilledButton)),
      );
      expect(button.onPressed, isNotNull);
      // Off: back to the detector-only button.
      await tester.ensureVisible(find.text('Also identify them'));
      await tester.pump();
      await tester.tap(find.text('Also identify them'));
      await tester.pump();
      await tester.scrollUntilVisible(find.textContaining('All photos already analyzed'), 200, scrollable: list);
      expect(tester.takeException(), isNull);
    });

    testWidgets('photos 1 s apart are explained, not tracked', (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      final dir = _session(stepS: 1, insect: (t) => t >= 2000 && t <= 5000);
      _photoFiles(dir);
      final list = await openAnalysis(tester, dir);
      await tester.scrollUntilVisible(find.textContaining('Photos 1 s apart are too far apart'), 200, scrollable: list);
      expect(find.text('Find track IDs'), findsNothing);
      expect(find.text('Occlusion tolerance'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
