// FaunaPulse (round 241): on-device check of comparing the live AI with "Run
// AI on videos" on the clips of a live AI session, on the session
// `live_video_check_2` that live_video_check_test.dart recorded (session B:
// live AI + ROI video; run that first).
//
// Earlier analysis results of that session are removed first. It uses the
// phone's own "Run AI on videos" settings.
// Run:  flutter test integration_test/live_video_after_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.
//
// Steps:
//  - the Video tab in live view: "Compare with the AI afterwards" (SHOT);
//  - its button opens "Run AI on videos": the comparison note, no kept frames
//    (SHOT); "Analyze 1 clip", then "Find visits" by itself;
//  - back on the Video tab: "Live AI | AI afterwards", both views (SHOT);
//  - Graphs: the afterwards count next to the live one (SHOT);
//  - roi_frames/ (the live photos) is unchanged.

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

  testWidgets('live detection vs Detection afterwards on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    final dir = Directory('${(await getExternalStorageDirectory())!.path}/sessions/live_video_check_2');
    expect(VideoDetector.clipsOf(dir), isNotEmpty, reason: 'run live_video_check_test.dart first');
    for (final name in [VideoDetector.outputFileName, 'post_tracks.jsonl', 'track_ids.csv']) {
      final f = File('${dir.path}/$name');
      if (f.existsSync()) f.deleteSync();
    }
    List<String> photos() => Directory('${dir.path}/roi_frames').existsSync()
        ? (Directory('${dir.path}/roi_frames').listSync().map((e) => e.path.split('/').last).toList()..sort())
        : const [];
    final photosBefore = photos();
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

    // 1. Live view.
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))),
    );
    await waitFor(find.byTooltip('Play'));
    expect(find.text("Videos with live detection's boxes"), findsOneWidget);
    await scrollTo(find.text('Compare with detection afterwards'), 200);
    await shot('live_compare_prompt');

    // 2. Run AI on videos from there.
    await tester.tap(find.widgetWithText(FilledButton, 'Find animals in videos'));
    await waitFor(find.byType(VideoAnalysisScreen));
    await waitFor(find.textContaining('recorded by the app as the camera'));
    final start = find.text('Analyze 1 clip');
    await scrollTo(start, 200);
    final runStart = DateTime.now();
    await tester.tap(start);
    await waitFor(find.text('All clips analyzed with these settings'), seconds: 600);
    final analysedS = DateTime.now().difference(runStart).inMilliseconds / 1000;
    await waitFor(find.textContaining('(occlusion tolerance', skipOffstage: false), seconds: 60);
    await scrollTo(find.textContaining('No frames are kept for these track IDs'), 200);
    expect(find.text('Keep frames of each track ID'), findsNothing);
    await shot('live_analysis_screen');
    final summary = await VideoTracker.readSummary(dir);
    _log('ANALYSED 1 clip in $analysedS s; afterwards track IDs ${summary?.visits}, kept ${summary?.keptFrames}');
    expect(summary?.keep, isNull);
    Navigator.of(tester.element(find.byType(VideoAnalysisScreen))).pop();
    await tester.pump(const Duration(seconds: 2));

    // 3. Both views on the Video tab.
    await waitFor(find.text('Detection afterwards', skipOffstage: false));
    await scrollTo(find.text('Detection afterwards'), -300);
    await shot('live_switch_live');
    await tester.tap(find.text('Detection afterwards'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('All boxes', skipOffstage: false), findsOneWidget);
    await shot('live_switch_after');

    // 4. Graphs.
    await tester.tap(find.text('Graphs'));
    await waitFor(find.text('Track IDs found afterwards in the videos'));
    await shot('live_graphs');
    await scrollTo(find.textContaining('Extra graphs'), 300);
    if (find.text('While recording').evaluate().isEmpty) {
      await tester.tap(find.textContaining('Extra graphs'));
      await tester.pump(const Duration(seconds: 1));
    }
    await scrollTo(find.text('While the detector ran'), 200);
    await tester.tap(find.text('While the detector ran'));
    await waitFor(find.text('While the detector ran on the videos'));

    final photosAfter = photos();
    _log('PHOTOS ${photosBefore.length} before, ${photosAfter.length} after');
    expect(photosAfter, photosBefore, reason: 'the live photos stay as they were');
    final t1 = await DeviceThermal.read();
    _log('THERMAL battery ${t0.batteryTempC} -> ${t1.batteryTempC} °C');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
