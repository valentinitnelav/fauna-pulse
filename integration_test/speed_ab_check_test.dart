// FaunaPulse (round 330): speed of "AI later" on this phone, to compare two builds (the same file
// runs on both), for example before and after a round that touched the photo, video or import
// code. Works on copies only: nothing in sessions/ is read or written.
// Old build: `git archive <commit> | tar -x -C <dir>`, copy this file into <dir>/integration_test/
// and run it from there. Alternate old, new, old, new: the phone warms up from run to run.
// Inputs in the app's external files folder (adb push to
// /sdcard/Android/data/com.faunapulse.app/files/speed_check/...):
//   speed_check/photos/roi_frames/*.jpg  photos of a time-lapse session (plain run and SAHI)
//   speed_check/big/roi_frames/*.jpg     large photos (SAHI with many tiles)
//   speed_check/video/videos/*.mp4       clips of a video session
//   speed_check/faunalapse/*.zip         one FaunaLapse zip (import only)
// Model: files/models/<SPEED_MODEL> on the GPU. Each step runs REPS times; the lines
// "SPEED <step> rep <i>: ..." give the wall time and a summary of the boxes (to see that both
// builds find the same boxes).
// Run:  flutter test integration_test/speed_ab_check_test.dart -d <device-id> --no-uninstall

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/faunalapse_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/post_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/sahi.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _model = String.fromEnvironment('SPEED_MODEL', defaultValue: 'flatbug-n_640_fp16.tflite');
const _reps = int.fromEnvironment('REPS', defaultValue: 3);

// ignore: avoid_print
void _log(String s) => print(s);

/// Box count and a rounded sum of all coordinates and confidences in a results file.
String _boxSummary(File f, String type) {
  var n = 0;
  var sum = 0.0;
  for (final line in f.readAsLinesSync()) {
    final rec = jsonDecode(line) as Map<String, dynamic>;
    if (rec['type'] != type) continue;
    for (final b in (rec['boxes'] as List? ?? const [])) {
      n++;
      for (final v in (b is Map ? b.values : b as List)) {
        if (v is num) sum += v;
      }
    }
  }
  return 'boxes $n, sum ${sum.toStringAsFixed(2)}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AI later: time per step on this phone', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final ext = (await getExternalStorageDirectory())!.path;
    final root = Directory('$ext/speed_check');
    final model = File('${(await ModelCatalog.modelsDir()).path}/$_model');
    expect(model.existsSync(), isTrue, reason: 'import $_model in the app first');

    final yolo = YOLO(modelPath: model.path, task: YOLOTask.detect, useGpu: true, useMultiInstance: true);
    expect(await yolo.loadModel(), isTrue);
    Future<Map<String, dynamic>> base(bytes) =>
        yolo.predict(bytes, confidenceThreshold: 0.25, iouThreshold: 0.7, includeAnnotatedImage: false);
    PredictFn sahi() => sahiPredictFn(
      base: base,
      tiledPredict: (bytes, tiles, fullPass) =>
          yolo.predictTiled(bytes, tiles: tiles, fullPass: fullPass, confidenceThreshold: 0.25, iouThreshold: 0.7),
      options: const SahiOptions(enabled: true),
      modelInputPx: 640,
    );

    Future<void> photos(String step, String folder, PredictFn Function() predict) async {
      final dir = Directory('${root.path}/$folder');
      final out = File('${dir.path}/${PostDetector.outputFileName}');
      for (var i = 1; i <= _reps; i++) {
        if (out.existsSync()) out.deleteSync();
        final t = (await DeviceThermal.read()).batteryTempC;
        final r = await PostDetector(predict: predict()).run(
          dir,
          config: PostRunConfig(modelPath: model.path, modelName: _model, confidence: 0.25, iou: 0.7, useGpu: true),
          force: true,
        );
        final ms = r.elapsed.inMilliseconds;
        _log('SPEED $step rep $i: ${r.processed} photos (${r.failed} failed) in $ms ms, '
            '${(ms / r.processed).toStringAsFixed(1)} ms per photo, ${_boxSummary(out, 'post_detection')}, battery $t °C');
      }
    }

    await photos('photos-plain', 'photos', () => base);
    await photos('photos-sahi', 'photos', sahi);
    await photos('big-sahi', 'big', sahi);

    final video = Directory('${root.path}/video');
    for (var i = 1; i <= _reps; i++) {
      final t = (await DeviceThermal.read()).batteryTempC;
      final r = await VideoDetector(backend: NativeVideoBackend(yolo.instanceId)).run(
        video,
        config: VideoRunConfig(modelPath: model.path, modelName: _model, confidence: 0.25, iou: 0.7, useGpu: true),
        startOver: true,
      );
      final ms = r.elapsed.inMilliseconds;
      _log('SPEED video rep $i: ${r.framesAnalysed} frames (${r.clipsFailed} clips failed) in $ms ms, '
          '${(ms / r.framesAnalysed).toStringAsFixed(1)} ms per frame, '
          '${_boxSummary(File('${video.path}/${VideoDetector.outputFileName}'), 'raw_detections')}, battery $t °C');
    }
    await yolo.dispose();

    final zips = Directory('${root.path}/faunalapse').listSync().whereType<File>().map((f) => f.path).toList();
    for (var i = 1; i <= _reps; i++) {
      final into = Directory('${root.path}/faunalapse_out');
      if (into.existsSync()) into.deleteSync(recursive: true);
      into.createSync();
      final sw = Stopwatch()..start();
      final r = await importFaunaLapseZipsInBackground(zips, into);
      _log('SPEED faunalapse-import rep $i: ${r.photos} photos (${r.damagedPhotos} damaged) in '
          '${sw.elapsedMilliseconds} ms');
      into.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
