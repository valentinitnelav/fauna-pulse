// FaunaPulse (round 273): on-device check of the simpler "Find animals in
// videos" screen and its default area, the largest square in the middle.
//
// Uses the small synthetic clips already pushed for
// video_decode_check_test.dart (see its header), in video_check/videos/:
// h264_1080p.mp4 (landscape) and h264_portrait_rot90.mp4 (stored landscape,
// shown upright as portrait). Each is imported as a copy into its own session
// in video_area_check/, so nothing else is touched.
// Run:  flutter test integration_test/video_default_area_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Model: as in video_review_check_test.dart (--dart-define=REVIEW_MODEL=...).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.
//
// Steps:
//  - landscape session never analysed: the screen shows session, model, the
//    proposed middle square on the first frame with the outside darker, and
//    Start; the numbers sit in the closed Advanced fold (SHOT);
//  - "Change…": the square editor plays the clip at 4× (SHOT), then 10×
//    (SHOT); "Use this square" keeps the proposal;
//  - Start on the screen: the run's `video_run_start` holds that square;
//  - portrait session: the square of its upright picture is proposed.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _model = String.fromEnvironment('REVIEW_MODEL', defaultValue: 'arthropod_yolov11_float16.tflite');

// ignore: avoid_print
void _log(String s) => print(s);

Future<String> _modelPath() async {
  if (_model.isEmpty) return kLocalYolo26ModelPath;
  final f = File('${(await ModelCatalog.modelsDir()).path}/$_model');
  expect(f.existsSync(), isTrue, reason: 'import $_model in the app first');
  return f.path;
}

/// Imports a copy of [source] as a session of its own; returns its folder
/// and the clip's upright size.
Future<(Directory, VideoInfo)> _importOne(File source, Directory sessions, Directory cache, String name) async {
  final file = source.path.split('/').last;
  final info = await VideoFrameSource.info(source.path);
  final copy = source.copySync('${cache.path}/$file');
  final dir = await importVideos(
    sessionsDir: sessions,
    sessionName: name,
    clips: [
      ImportClip(
        path: copy.path,
        name: file,
        sizeBytes: copy.lengthSync(),
        info: info,
        guess: guessClipStart(
          fileName: file,
          storedMs: info.creationEpochMs,
          durationMs: info.durationMs,
          fileModifiedMs: source.lastModifiedSync().millisecondsSinceEpoch,
        ),
      ),
    ],
    startExtras: {'build_mode': 'debug'},
  );
  return (dir, info);
}

/// What the screen shows for the proposed square of a [width] x [height] video.
String _squareText(int width, int height) {
  final roi = Roi.largestCentredSquare(width, height)!;
  final px = snapToMultipleOf32(roi.sideFraction * width);
  return 'Square $px × $px px.';
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('default video area on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    final ext = (await getExternalStorageDirectory())!.path;
    final videos = '$ext/video_check/videos';
    final landscapeSource = File('$videos/h264_1080p.mp4');
    final portraitSource = File('$videos/h264_portrait_rot90.mp4');
    expect(landscapeSource.existsSync() && portraitSource.existsSync(), isTrue,
        reason: 'push the synthetic clips to $videos first');
    final out = Directory('$ext/video_area_check');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final cache = Directory('${out.path}/cache')..createSync(recursive: true);
    final sessions = Directory('${out.path}/sessions')..createSync();
    final (landscape, wide) = await _importOne(landscapeSource, sessions, cache, 'area check landscape');
    final (portrait, tall) = await _importOne(portraitSource, sessions, cache, 'area check portrait');
    _log('CLIPS landscape ${wide.width}x${wide.height}, portrait ${tall.width}x${tall.height} (upright)');
    final model = await _modelPath();
    final models = [ModelEntry(id: model, name: model.split('/').last, source: ModelSource.imported)];

    Future<void> waitFor(Finder f, {int seconds = 20}) async {
      for (var i = 0; i < seconds * 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (f.evaluate().isNotEmpty) return;
      }
      fail('not found: $f');
    }

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 4));
    }

    // 1. Landscape, never analysed: the middle square is proposed.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VideoAnalysisScreen(initialSessionPath: landscape.path, sessionsDir: sessions, models: models),
      ),
    );
    final wideText = _squareText(wide.width, wide.height);
    await waitFor(find.text(wideText));
    await tester.pump(const Duration(seconds: 2)); // the first frame loads
    expect(find.byType(Slider), findsNothing, reason: 'the numbers sit in the closed fold');
    final area = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>).first);
    expect(area.selected, {true}, reason: 'a square by default');
    _log('LANDSCAPE proposed: $wideText');
    await shot('video_area_proposed');

    // 2. The square editor plays the clip fast.
    await tester.tap(find.text('Change…'));
    await waitFor(find.byTooltip('Pause'));
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '4×')).selected, isTrue);
    _log('EDITOR playing at 4×');
    await shot('video_square_editor_4x');
    await tester.tap(find.text('10×'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byTooltip('Pause'), findsOneWidget, reason: 'still playing at 10×');
    _log('EDITOR playing at 10×');
    await shot('video_square_editor_10x');
    await tester.tap(find.text('Use this square'));
    await waitFor(find.text(wideText));

    // 3. Start on the screen: the run uses that square.
    final list = find.byType(Scrollable).first;
    final start = find.text('Analyze 1 clip');
    await tester.scrollUntilVisible(start, 300, scrollable: list);
    await tester.tap(start);
    await waitFor(find.text('All clips analyzed with these settings'), seconds: 300);
    final runStart = File('${landscape.path}/${VideoDetector.outputFileName}')
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .firstWhere((r) => r['type'] == 'video_run_start');
    final roi = (runStart['settings'] as Map)['roi'] as List;
    final expected = Roi.largestCentredSquare(wide.width, wide.height)!;
    _log('RUN roi $roi, expected [0.5, 0.5, ${expected.sideFraction}]');
    expect(roi[0], closeTo(0.5, 1e-9));
    expect(roi[1], closeTo(0.5, 1e-9));
    expect(roi[2], closeTo(expected.sideFraction, 1e-9));
    await shot('video_area_done');

    // 4. Portrait: the square of its upright picture.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VideoAnalysisScreen(initialSessionPath: portrait.path, sessionsDir: sessions, models: models),
      ),
    );
    final tallText = _squareText(tall.width, tall.height);
    await waitFor(find.text(tallText));
    _log('PORTRAIT proposed: $tallText');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    await WakelockPlus.disable();
  });
}
