// Round 230 (video plan 1d): which analysis rate is enough to count visits?
// Analyse the videos once at a high rate, then re-run "Find visits" (the
// app's own VideoTracker) on the frames a lower rate would have looked at,
// for both trackers. Each run's visits.csv lands in the output folder, named
// visits_<tracker>_<fps>fps.csv, for tool/video_eval/evaluate_visits.py to
// compare with a hand count (docs/VIDEO_ANALYSIS.md, "Which frame rate?").
//
//   flutter test test/fauna_pulse/video_fps_sweep_test.dart \
//       --dart-define=SWEEP_SESSION=/absolute/path/to/session_folder \
//       [--dart-define=SWEEP_FPS=15,10,5,2,1] \
//       [--dart-define=SWEEP_OUT=/absolute/path/to/output_folder]
//
// The session folder is a copy of the phone's session folder or the unzipped
// "Share results" file (it needs video_detections.jsonl and session.jsonl).
// The output folder defaults to <session>/fps_sweep. The occlusion tolerance
// and minimum visit length are those of the session's last "Find visits"
// (the app defaults when it has none). Without SWEEP_SESSION this file only
// runs its unit tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/track_export.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';

/// The `raw_detections` frames an analysis at [fps] would have looked at,
/// per clip; every other line is kept. Same rule as the phone's frame picker
/// (PtsSampler in VideoFrameSource.kt): a frame is taken once its time stamp
/// reaches the next deadline, with 1/10 of the interval as tolerance, and
/// after a long gap the grid restarts at the taken frame.
List<String> thinVideoDetections(List<String> lines, double fps) {
  final intervalUs = (1e6 / fps).round();
  final nextDueUs = <String, int>{};
  final kept = <String>[];
  for (final line in lines) {
    if (!line.contains('"raw_detections"')) {
      kept.add(line);
      continue;
    }
    final Map rec;
    try {
      rec = jsonDecode(line) as Map;
    } catch (_) {
      continue; // a half-written line after a kill
    }
    final clip = '${rec['clip']}';
    final pts = (rec['pts_us'] as num?)?.toInt();
    if (pts == null) continue;
    final due = nextDueUs[clip];
    if (due != null && pts < due - intervalUs ~/ 10) continue;
    nextDueUs[clip] = due == null || pts - due >= intervalUs ? pts + intervalUs : due + intervalUs;
    kept.add(line);
  }
  return kept;
}

String _raw(String clip, int ptsUs) =>
    jsonEncode({'type': 'raw_detections', 'clip': clip, 'pts_us': ptsUs, 'frame_ms': ptsUs ~/ 1000, 'boxes': []});

void main() {
  group('thinVideoDetections', () {
    List<int> keptPts(List<String> lines) => [
      for (final l in lines)
        if (l.contains('"raw_detections"')) (jsonDecode(l) as Map)['pts_us'] as int,
    ];

    test('30 fps thinned to 10 fps keeps every third frame, per clip', () {
      final lines = [
        '{"type":"video_run_start"}',
        for (var i = 0; i < 9; i++) _raw('a.mp4', (i * 1e6 / 30).round()),
        for (var i = 0; i < 4; i++) _raw('b.mp4', (i * 1e6 / 30).round()),
      ];
      final out = thinVideoDetections(lines, 10);
      expect(out.first, '{"type":"video_run_start"}');
      expect(keptPts(out), [0, 100000, 200000, 0, 100000]);
    });

    test('a long gap restarts the grid instead of catching up', () {
      final out = thinVideoDetections([
        for (final ms in [0, 500, 3000, 3033, 3067, 3100, 3500]) _raw('a.mp4', ms * 1000),
      ], 2);
      expect(keptPts(out), [0, 500000, 3000000, 3500000]);
    });

    test('a rate at or above the analysed one keeps every frame', () {
      final lines = [for (var i = 0; i < 6; i++) _raw('a.mp4', (i * 1e6 / 15).round())];
      expect(thinVideoDetections(lines, 15), lines);
    });
  });

  const sessionPath = String.fromEnvironment('SWEEP_SESSION');
  test(
    'sweep the analysis rate and the tracker over a real session',
    () async {
      final session = Directory(sessionPath);
      final input = File('${session.path}/${VideoDetector.outputFileName}');
      expect(input.existsSync(), isTrue, reason: 'No ${VideoDetector.outputFileName} in $sessionPath');
      final lines = input.readAsLinesSync();
      final analysedFps = lines
          .where((l) => l.contains('"video_run_start"'))
          .map((l) => ((jsonDecode(l) as Map)['settings'] as Map?)?['analysis_fps'] as num?)
          .firstWhere((v) => v != null, orElse: () => null)
          ?.toDouble();

      var config = const SessionConfig();
      final previous = await VideoTracker.readSummary(session);
      if (previous != null) {
        config = config.copyWith(
          occlusionSeconds: previous.occlusionSeconds,
          minHitsSeconds: previous.minHitsSeconds,
        );
      }
      final rates = const String.fromEnvironment('SWEEP_FPS', defaultValue: '15,10,5,2,1')
          .split(',')
          .map((s) => double.parse(s.trim()))
          .toList();
      final outPath = const String.fromEnvironment('SWEEP_OUT');
      final out = Directory(outPath.isEmpty ? '${session.path}/fps_sweep' : outPath)..createSync(recursive: true);
      final log = File('${session.path}/session.jsonl');
      if (log.existsSync()) log.copySync('${out.path}/session.jsonl'); // clip names and lengths

      // ignore: avoid_print
      print(
        'Analysed at ${analysedFps ?? '?'} fps; occlusion tolerance ${config.occlusionSeconds} s, '
        'minimum visit length ${config.minHitsSeconds} s.\n'
        'tracker     fps  frames  visits',
      );
      for (final fps in rates) {
        if (analysedFps != null && fps > analysedFps) {
          // ignore: avoid_print
          print('(skipped $fps fps: the videos were analysed at $analysedFps fps)');
          continue;
        }
        final fpsLabel = fps == fps.roundToDouble() ? fps.toInt().toString() : '$fps';
        for (final alg in TrackerAlgorithm.values) {
          final tmp = Directory.systemTemp.createTempSync('fps_sweep_');
          try {
            File('${tmp.path}/${VideoDetector.outputFileName}').writeAsStringSync('${thinVideoDetections(lines, fps).join('\n')}\n');
            final r = await VideoTracker.run(tmp, config.copyWith(trackerAlgorithm: alg));
            File('${tmp.path}/${TrackExport.visitsFileName}').copySync('${out.path}/visits_${alg.name}_${fpsLabel}fps.csv');
            // ignore: avoid_print
            print('${alg.name.padRight(10)} ${fpsLabel.padLeft(4)}  ${'${r.frames}'.padLeft(6)}  ${'${r.visits}'.padLeft(6)}');
          } finally {
            tmp.deleteSync(recursive: true);
          }
        }
      }
      // ignore: avoid_print
      print('visits_<tracker>_<fps>fps.csv written to ${out.path}');
    },
    skip: sessionPath.isEmpty ? 'no SWEEP_SESSION defined' : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
