// FaunaPulse (round 239): on-device check of what follows a recording of
// time-lapse video bursts, on the session `video_burst_check` that
// video_bursts_check_test.dart recorded (run that first).
//
// Earlier analysis results of that session are removed first, so the check
// starts from "not analysed". It uses the phone's own "Run AI on videos"
// settings (model, confidence, frames per second).
// Run:  flutter test integration_test/video_bursts_after_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.
//
// Steps:
//  - the summary opens on the Video tab: the clip line, the player, "Not
//    analysed yet" (SHOT);
//  - its "Run AI on videos" button opens the screen with this session, the
//    whole picture chosen and the recorded-clips hint (SHOT); "Analyze N
//    clips" runs the AI and then "Find visits" (SHOT);
//  - back on the summary: the model and visits; Graphs: "While recording" /
//    "While the AI ran" (SHOT);
//  - "Copy videos": every clip lands in Movies/FaunaPulse/video_burst_check
//    (the snack bar counts them; check the Gallery, then delete the album).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recorded video bursts: analyse, review, copy on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    final dir = Directory('${(await getExternalStorageDirectory())!.path}/sessions/video_burst_check');
    expect(VideoDetector.clipsOf(dir), isNotEmpty, reason: 'run video_bursts_check_test.dart first');
    final clips = VideoDetector.clipsOf(dir).length;
    // Start from "not analysed".
    for (final name in [VideoDetector.outputFileName, 'post_tracks.jsonl', 'track_ids.csv']) {
      final f = File('${dir.path}/$name');
      if (f.existsSync()) f.deleteSync();
    }
    for (final f in Directory('${dir.path}/roi_frames').listSync()) {
      f.deleteSync(recursive: true);
    }
    final t0 = await DeviceThermal.read();

    Future<void> waitFor(Finder f, {int seconds = 30}) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (f.evaluate().isNotEmpty) return;
      }
      fail('not found: $f');
    }

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 3));
    }

    Finder list() => find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      skipOffstage: true,
    ).first;

    Future<void> scrollTo(Finder f, double step) async {
      await tester.scrollUntilVisible(f, step, scrollable: list());
      await tester.pump(const Duration(milliseconds: 300));
    }

    // 1. The Video tab before any analysis.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl')),
      ),
    );
    await waitFor(find.byTooltip('Play'));
    await waitFor(find.textContaining('clips ·'));
    final clipLine = (find.textContaining('clips ·').evaluate().first.widget as Text).data;
    _log('CLIP LINE $clipLine');
    expect(find.text('Video'), findsOneWidget);
    await shot('bursts_video_tab');
    await scrollTo(find.text('Not analysed yet'), 200);
    await shot('bursts_not_analysed');

    // 2. "Run AI on videos" from the tab.
    await tester.tap(find.text('Find animals in videos'));
    await waitFor(find.byType(VideoAnalysisScreen));
    await waitFor(find.textContaining('recorded by the app as the camera'));
    await shot('bursts_analysis_screen');
    final start = find.text('Analyze $clips ${clips == 1 ? 'clip' : 'clips'}');
    await scrollTo(start, 200);
    final runStart = DateTime.now();
    await tester.tap(start);
    // The run, then "Find visits" by itself.
    await waitFor(find.text('All clips analyzed with these settings'), seconds: 600);
    final analysedS = DateTime.now().difference(runStart).inMilliseconds / 1000;
    // The result line sits below the screen until scrolled to.
    await waitFor(find.textContaining('(occlusion tolerance', skipOffstage: false), seconds: 60);
    final summary = await VideoTracker.readSummary(dir);
    _log('ANALYSED $clips clips in $analysedS s; track IDs ${summary?.visits}');
    await scrollTo(find.textContaining('(occlusion tolerance'), 200);
    await shot('bursts_analysed');
    Navigator.of(tester.element(find.byType(VideoAnalysisScreen))).pop();
    await tester.pump(const Duration(seconds: 2));

    // 3. Back on the summary: model, visits, graphs.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'), initialTabIndex: 1),
      ),
    );
    await waitFor(find.textContaining('found afterwards in the videos'));
    _log('VISITS ${(find.textContaining('found afterwards in the videos').evaluate().first.widget as Text).data}');
    await scrollTo(find.textContaining('Extra graphs'), 300);
    if (find.text('While recording').evaluate().isEmpty) {
      await tester.tap(find.textContaining('Extra graphs'));
      await tester.pump(const Duration(seconds: 1));
    }
    await scrollTo(find.text('While the detector ran'), 200);
    await shot('bursts_graphs_recording');
    await tester.tap(find.text('While the detector ran'));
    await waitFor(find.text('While the detector ran on the videos'));
    await scrollTo(find.text('While the detector ran on the videos'), 200);
    await shot('bursts_graphs_analysis');

    // 4. Copy the videos to the Gallery.
    await tester.tap(find.text('Video'));
    await tester.pump(const Duration(seconds: 2));
    await scrollTo(find.text('Copy videos'), 300);
    await tester.tap(find.text('Copy videos'));
    await waitFor(find.textContaining('to Gallery?'));
    await tester.tap(find.text('Copy'));
    await waitFor(find.textContaining('to Gallery ▸ Movies/FaunaPulse/video_burst_check'), seconds: 60);
    final msg = (find.textContaining('to Gallery ▸').evaluate().first.widget as Text).data;
    _log('COPY $msg');
    await shot('bursts_copied');
    final t1 = await DeviceThermal.read();
    _log('THERMAL battery ${t0.batteryTempC} -> ${t1.batteryTempC} °C');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
