// FaunaPulse (round 243): on-device check of a clip cut off by a killed app.
//
// First make one: run video_bursts_check_test.dart and stop the app during a burst,
// e.g. `adb shell am force-stop com.faunapulse.app` a few seconds after "RECORDING";
// the open clip stays without its index. Then run this check on that session:
// Run:  flutter test integration_test/video_cut_off_check_test.dart -d <serial> --no-uninstall
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
//
// Steps:
//  - the session has a cut-off clip (VideoDetector.cutOffClipsOf);
//  - the summary's Video tab says so and plays the others (SHOT);
//  - "Run AI on videos" says it is left out and analyses the others; the button
//    under that note deletes it through its own dialog (SHOT).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
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

  testWidgets('a clip cut off by a killed app on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    // The burst check's session (video_burst_check, or _2, _3 … when run again) with a cut-off clip.
    final sessions = Directory('${(await getExternalStorageDirectory())!.path}/sessions');
    final dir = sessions
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.split('/').last.startsWith('video_burst_check') && VideoDetector.cutOffClipsOf(d).isNotEmpty)
        .firstOrNull ?? Directory('${sessions.path}/video_burst_check');
    _log('SESSION ${dir.path.split('/').last}');
    final cut = VideoDetector.cutOffClipsOf(dir);
    final all = VideoDetector.clipsOf(dir);
    _log('CLIPS ${all.length}, cut off: ${cut.map((f) => '${f.uri.pathSegments.last} (${f.lengthSync()} B)').join(', ')}');
    expect(cut, isNotEmpty, reason: 'stop the app during a burst of video_bursts_check_test.dart first');

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

    // 1. The Video tab.
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: SessionSummaryScreen(logFile: File('${dir.path}/session.jsonl'))),
    );
    await waitFor(find.textContaining('cut off: the app stopped while recording'));
    await shot('cut_off_video_tab');

    // 2. Run AI on videos.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: VideoAnalysisScreen(initialSessionPath: dir.path)),
    );
    await waitFor(find.textContaining('was cut off: the app stopped'));
    // The readable clips are analysed as usual.
    final analyse = find.textContaining(RegExp(r'^Analyze \d+ clips?$'));
    if (analyse.evaluate().isNotEmpty) {
      await tester.scrollUntilVisible(analyse, 200, scrollable: list());
      await tester.tap(analyse);
      await waitFor(find.text('All clips analyzed with these settings'), seconds: 600);
      _log('ANALYSED the readable clips');
    }
    await tester.scrollUntilVisible(find.textContaining('was cut off: the app stopped'), -200, scrollable: list());
    await shot('cut_off_analysis');
    final deleteCut = find.textContaining('Delete the cut-off clip');
    // The "Done" snack bar of the analysis covers the bottom of the screen:
    // wait for it to go and bring the button to the middle.
    await tester.pump(const Duration(seconds: 5));
    await tester.scrollUntilVisible(deleteCut, 200, scrollable: list());
    await Scrollable.ensureVisible(tester.element(deleteCut), alignment: 0.5);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(deleteCut);
    await waitFor(find.textContaining(RegExp(r'^Delete the cut-off clips?\?$')));
    await shot('cut_off_dialog');
    await tester.tap(find.textContaining(RegExp(r'^Delete \d+$')));
    await waitFor(find.textContaining('freed.'));
    _log('DELETED; cut off now ${VideoDetector.cutOffClipsOf(dir).length}, clips ${VideoDetector.clipsOf(dir).length}');
    expect(VideoDetector.cutOffClipsOf(dir), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
