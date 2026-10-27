// FaunaPulse (round 333): what saving photos costs live detection on this phone, and whether small
// squares around each detected organism cost less than photos of the whole yellow square (ROI).
// Asked before deciding on more photos per track ID (a shorter Photo step) or an "organisms only"
// photo option.
//
// The live camera and the detector run as on the camera screen (the phone's saved stream size,
// detector rate cap, GPU/CPU choice), with the yellow square as the largest centred square. No
// animals are needed: photos are asked on a timer, through the same native call as the app's fast
// photos (`captureRoiFromFrame`), and written to files/photo_cost_check/ (emptied after each part).
// As in the app, one photo moment at a time: a moment due while the previous one is still being
// saved waits for it. No session is recorded and no setting is saved.
//
// Parts of PART_S seconds (default 40), run ROUNDS times (default 2) in the order A to F, since
// the phone warms up from part to part:
//   A  no photos (baseline)
//   B  yellow square every 1 s (the default Photo step)
//   C  yellow square every 0.5 s
//   D  yellow square every 0.2 s (a busy flower: 5 track IDs, each on its own 1 s photo clock)
//   E  3 organism squares every 0.5 s
//   F  5 organism squares every 0.2 s (a busy flower, organism squares only)
// Organism squares are BOX_PX on the camera picture (default 256, snapped to 32 like the native
// crop), at fixed spots inside the yellow square.
// Lines "COST <part> round <r>: ..." per part, then "COST_TABLE" lines averaged over the rounds.
// Model: files/models/<COST_MODEL> (default flatbug-n_640_fp16.tflite).
// Run:  flutter test integration_test/photo_cost_check_test.dart -d <device-id> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why). On a MIUI phone, whose
// "Install via USB?" question can be refused, do not let flutter install: when an install is
// refused, flutter uninstalls the app (every session on the phone is lost) even with
// --no-uninstall. Instead: flutter build apk --debug -t integration_test/photo_cost_check_test.dart,
// adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk (adb never uninstalls),
// adb -s <device-id> shell am start -n com.faunapulse.app/com.ultralytics.yolo.MainActivity, read
// adb -s <device-id> logcat -s flutter:I, then rebuild and install -r the normal debug app.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _model = String.fromEnvironment('COST_MODEL', defaultValue: 'flatbug-n_640_fp16.tflite');
const _boxPx = int.fromEnvironment('BOX_PX', defaultValue: 256);
const _partSeconds = int.fromEnvironment('PART_S', defaultValue: 40);
const _rounds = int.fromEnvironment('ROUNDS', defaultValue: 2);

// ignore: avoid_print
void _log(String s) => print(s);

double _quantile(List<num> v, double q) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  return s[((s.length - 1) * q).round()].toDouble();
}

String _f(double v, [int digits = 1]) => v.isNaN ? '-' : v.toStringAsFixed(digits);

class _Part {
  final String id;
  final String what;

  /// Time between photo moments; 0 = no photos.
  final int stepMs;

  /// 0 = one photo of the whole yellow square per moment, else that many organism squares.
  final int squares;
  const _Part(this.id, this.what, this.stepMs, this.squares);
}

const _parts = [
  _Part('A', 'no photos', 0, 0),
  _Part('B', 'yellow square every 1 s', 1000, 0),
  _Part('C', 'yellow square every 0.5 s', 500, 0),
  _Part('D', 'yellow square every 0.2 s', 200, 0),
  _Part('E', '3 organism squares every 0.5 s', 500, 3),
  _Part('F', '5 organism squares every 0.2 s', 200, 5),
];

class _Stats {
  int frames = 0;
  final nativeFps = <double>[];
  final workMs = <double>[];
  final cameraFps = <double>[];
  int moments = 0;
  int failed = 0;
  final waitMs = <int>[];
  final momentMs = <double>[];
  final fileMs = <double>[];
  final bytes = <int>[];
  double tempStart = double.nan;
  double tempEnd = double.nan;

  void onData(Map<String, dynamic> data) {
    if (data['fps'] == null || data['noModel'] == true || data['gateIdle'] == true) return;
    frames++;
    nativeFps.add((data['fps'] as num).toDouble());
    workMs.add(
      [data['preMs'], data['inferenceMs'], data['postMs']].fold<double>(0, (s, v) => s + ((v as num?) ?? 0)),
    );
    final cam = (data['cameraFps'] as num?)?.toDouble();
    if (cam != null && cam > 0) cameraFps.add(cam);
  }

  double get totalMb => bytes.fold<int>(0, (s, b) => s + b) / 1e6;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('photo cost: yellow-square photos vs organism squares during live detection', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    final support = await getApplicationSupportDirectory();
    final model = File('${support.path}/models/$_model');
    expect(model.existsSync(), isTrue, reason: 'no detector at ${model.path} (set COST_MODEL)');
    final scratch = Directory('${support.path}/photo_cost_check');
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    scratch.createSync(recursive: true);
    addTearDown(() {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    });

    final config = await SessionConfig.load();
    final savedPx = config.targetRoiSavedPx;
    final controller = YOLOViewController();
    _Stats? current;
    var imageW = 0, imageH = 0;
    String accelerator = '?';
    final firstFrame = Completer<void>();

    // The largest centred square, as a fraction of the upright frame width (the native crop
    // caps it to the frame's short side and snaps it to 32 px).
    const roiCx = 0.5, roiCy = 0.5, roiSide = 1.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: YOLOView(
            modelPath: model.path,
            task: YOLOTask.detect,
            controller: controller,
            useGpu: config.useGpu,
            cpuThreads: config.cpuThreads,
            // Fast photos only, so no zero-shutter-lag buffer (as the camera screen's _stillZslFor).
            stillZeroShutterLag: false,
            confidenceThreshold: config.confidenceThreshold,
            iouThreshold: config.iouThreshold,
            streamingConfig: YOLOStreamingConfig.custom(
              inferenceFrequency: config.effectiveInferenceFps,
              includeOriginalImage: false,
              analysisResolution: Size(config.streamWidth.toDouble(), config.streamHeight.toDouble()),
            ),
            onModelLoad: (_, _) {
              controller.setShowOverlays(false);
              controller.setInferenceRoi(cx: roiCx, cy: roiCy, side: roiSide);
              controller.setCameraFpsCap(config.cameraFpsCap);
            },
            onStreamingData: (data) {
              final w = (data['imageWidth'] as num?)?.toInt();
              final h = (data['imageHeight'] as num?)?.toInt();
              if (w != null && h != null && w > 0 && h > 0) (imageW, imageH) = (w, h);
              if (data['accelerator'] is String) accelerator = data['accelerator'] as String;
              if (data['fps'] != null && !firstFrame.isCompleted) {
                // Sent again on the first frame, as the camera screen's start-up sequence does:
                // the camera frame-rate cap sent at model load was not applied (the 11T Pro's
                // camera then ran at 30 fps instead of 15).
                controller.setInferenceRoi(cx: roiCx, cy: roiCy, side: roiSide);
                controller.setCameraFpsCap(config.cameraFpsCap);
                firstFrame.complete();
              }
              current?.onData(data);
            },
          ),
        ),
      ),
    );

    Future<void> pumpFor(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    final waitEnd = DateTime.now().add(const Duration(seconds: 60));
    while (!firstFrame.isCompleted && DateTime.now().isBefore(waitEnd)) {
      await pumpFor(const Duration(seconds: 1));
    }
    expect(firstFrame.isCompleted, isTrue, reason: 'the detector never ran (camera, model or permission)');
    await pumpFor(const Duration(seconds: 15)); // warm-up: GPU delegate, camera exposure

    // Upright portrait frame: the short side is the width.
    final frameW = math.min(imageW, imageH), frameH = math.max(imageW, imageH);
    final roiPx = math.min((roiSide * frameW / 32).round() * 32, (frameW ~/ 32) * 32);
    final boxSide = _boxPx / frameW;
    // Centre, then the four quarter points of the yellow square (y offsets turned into
    // fractions of the frame height).
    final offsets = [(0.0, 0.0), (-0.25, -0.25), (0.25, 0.25), (0.25, -0.25), (-0.25, 0.25)];
    List<(double, double, double)> squaresOf(_Part p) => p.squares == 0
        ? [(roiCx, roiCy, roiSide)]
        : [
            for (final (dx, dy) in offsets.take(p.squares))
              (roiCx + dx * roiPx / frameW, roiCy + dy * roiPx / frameH, boxSide),
          ];
    _log(
      'COST setup: stream asked ${config.streamWidth}x${config.streamHeight}, delivered ${imageW}x$imageH, '
      'model $_model on $accelerator, detector cap ${config.effectiveInferenceFps}/s, camera cap '
      '${config.cameraFpsCap}, yellow square $roiPx px saved at ${math.min(roiPx, savedPx)} px, organism squares '
      '$_boxPx px, $_partSeconds s per part, $_rounds rounds',
    );

    var fileNo = 0;
    Future<void> photoLoop(_Part p, _Stats s, Stopwatch clock, int endMs) async {
      final squares = squaresOf(p);
      var dueMs = 0;
      while (clock.elapsedMilliseconds < endMs) {
        final now = clock.elapsedMilliseconds;
        if (now < dueMs) {
          await Future<void>.delayed(Duration(milliseconds: math.min(dueMs - now, 20)));
          continue;
        }
        s.moments++;
        s.waitMs.add(now - dueMs);
        // The next moment is due one step after this one began (TrackKeepRule's clock), so a
        // slow save delays it rather than skipping it.
        dueMs = now + p.stepMs;
        final moment = Stopwatch()..start();
        for (final (cx, cy, side) in squares) {
          final one = Stopwatch()..start();
          final jpeg = await controller.captureRoiFromFrame(cx: cx, cy: cy, side: side, maxPx: savedPx);
          if (jpeg == null) {
            s.failed++;
            continue;
          }
          await File('${scratch.path}/${p.id}_${fileNo++}.jpg').writeAsBytes(jpeg);
          s.fileMs.add(one.elapsedMicroseconds / 1000);
          s.bytes.add(jpeg.length);
        }
        s.momentMs.add(moment.elapsedMicroseconds / 1000);
      }
    }

    final results = <String, List<_Stats>>{};
    for (var round = 1; round <= _rounds; round++) {
      for (final p in _parts) {
        final s = _Stats();
        s.tempStart = (await DeviceThermal.read()).batteryTempC ?? double.nan;
        final clock = Stopwatch()..start();
        current = s;
        final loop = p.stepMs == 0 ? Future<void>.value() : photoLoop(p, s, clock, _partSeconds * 1000);
        await pumpFor(Duration(seconds: _partSeconds));
        await loop;
        current = null;
        final seconds = clock.elapsedMilliseconds / 1000;
        s.tempEnd = (await DeviceThermal.read()).batteryTempC ?? double.nan;
        for (final f in scratch.listSync()) {
          f.deleteSync();
        }
        (results[p.id] ??= []).add(s);
        _log(
          'COST ${p.id} round $round (${p.what}): detector ${_f(s.frames / seconds)} pictures/s '
          '(native ${_f(_quantile(s.nativeFps, 0.5))}), work ${_f(_quantile(s.workMs, 0.5))} ms/picture, camera '
          '${_f(_quantile(s.cameraFps, 0.5))} fps; moments ${s.moments}, files ${s.bytes.length}, failed ${s.failed}, '
          'moment ${_f(_quantile(s.momentMs, 0.5))} ms (90 % ${_f(_quantile(s.momentMs, 0.9))}), file '
          '${_f(_quantile(s.fileMs, 0.5))} ms (90 % ${_f(_quantile(s.fileMs, 0.9))}), waited 90 % '
          '${_f(_quantile(s.waitMs, 0.9), 0)} ms, ${_f(_quantile(s.bytes, 0.5) / 1000)} kB/file, '
          '${_f(s.totalMb / seconds * 3600, 0)} MB/h; battery ${_f(s.tempStart)} -> ${_f(s.tempEnd)} °C',
        );
      }
    }

    // Averages over the rounds; "vs A" compares the detector rate with the baseline of the same rounds.
    double mean(Iterable<double> v) => v.isEmpty ? double.nan : v.reduce((a, b) => a + b) / v.length;
    final baseRate = mean(results['A']!.map((s) => s.frames / _partSeconds));
    _log('COST_TABLE part | detector/s | vs A | work ms | camera fps | files/s | ms/file | kB/file | MB/h');
    for (final p in _parts) {
      final runs = results[p.id]!;
      final rate = mean(runs.map((s) => s.frames / _partSeconds));
      _log(
        'COST_TABLE ${p.id} ${p.what} | ${_f(rate)} | ${_f((rate / baseRate - 1) * 100, 0)} % | '
        '${_f(mean(runs.map((s) => _quantile(s.workMs, 0.5))))} | ${_f(mean(runs.map((s) => _quantile(s.cameraFps, 0.5))))} | '
        '${_f(mean(runs.map((s) => s.bytes.length / _partSeconds)))} | '
        '${_f(mean(runs.where((s) => s.fileMs.isNotEmpty).map((s) => _quantile(s.fileMs, 0.5))))} | '
        '${_f(mean(runs.where((s) => s.bytes.isNotEmpty).map((s) => _quantile(s.bytes, 0.5) / 1000)))} | '
        '${_f(mean(runs.map((s) => s.totalMb / _partSeconds * 3600)), 0)}',
      );
    }
    _log('COST_DONE');

    for (final p in _parts.skip(1)) {
      for (final s in results[p.id]!) {
        expect(s.failed, 0, reason: '${p.id}: a photo was refused (no fresh camera frame)');
      }
    }
    await tester.pumpWidget(const SizedBox());
    await pumpFor(const Duration(seconds: 2));
  }, timeout: Timeout(Duration(seconds: 120 + _rounds * _parts.length * (_partSeconds + 10))));
}
