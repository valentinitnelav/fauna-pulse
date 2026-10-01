// FaunaPulse (round 264): on-device speed of detector files made by
// tool/detector_export/export_detector.py, next to the bundled live detector.
//
// Times every .tflite in the app's files/detector_check/ folder (copy them there with
//   adb push X.tflite /data/local/tmp/ && adb shell run-as com.faunapulse.app cp /data/local/tmp/X.tflite files/detector_check/)
// with the plugin's engine benchmark (the one behind Settings -> AI -> "Benchmark engines"):
// the GPU, then the CPU with the automatic thread count; 3 warm-up runs, then the average
// and the fastest of --dart-define=ITERATIONS runs (default 10). Model time only (random
// input at the model's size): no camera, cropping, box decoding or tracking.
// Boxes: when files/detector_check/ also holds check.jpg, every file detects on it once (GPU,
// confidence 0.25) and the boxes are printed as fractions of the picture, to compare with the
// PC (export_detector.py's check): the app must decode each file's boxes the same way.
// Run:  flutter test integration_test/detector_speed_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _iterations = int.fromEnvironment('ITERATIONS', defaultValue: 10);
const _baseline = 'assets/models/custom/ArthroNat_flatbug_yolo11n_int8_640.tflite';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Detector files: time per picture on GPU and CPU', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/detector_check');
    final files = dir.existsSync()
        ? (dir.listSync().whereType<File>().where((f) => f.path.endsWith('.tflite')).map((f) => f.path).toList()
          ..sort())
        : <String>[];
    expect(files, isNotEmpty, reason: 'copy .tflite files into files/detector_check/ first');
    final picture = File('${dir.path}/check.jpg');
    for (final path in [_baseline, ...files]) {
      final t0 = await DeviceThermal.read();
      final rows = await YOLO.benchmarkAccelerators(path, iterations: _iterations, cpuThreadVariants: const [0]);
      final t1 = await DeviceThermal.read();
      final name = path.split('/').last;
      for (final r in rows) {
        final dims = (r['inputDims'] as List?)?.join('x') ?? '?';
        _log(r['error'] != null
            ? 'SPEED $name ${r['label']}: ${r['error']}'
            : 'SPEED $name ${r['label']} on ${r['accelerator']}: input $dims, '
                  'mean ${(r['avgMs'] as num).toStringAsFixed(0)} ms, fastest ${(r['minMs'] as num).toStringAsFixed(0)} ms, '
                  'setup ${((r['compileMs'] as num) / 1000).toStringAsFixed(1)} s');
      }
      _log('SPEED $name battery ${t0.batteryTempC} -> ${t1.batteryTempC} °C');
      if (picture.existsSync()) {
        final yolo = YOLO(modelPath: path, task: YOLOTask.detect, useMultiInstance: true);
        final r = await yolo.predict(await picture.readAsBytes(), confidenceThreshold: 0.25, includeAnnotatedImage: false);
        await yolo.dispose();
        final boxes = [
          for (final b in (r['boxes'] as List? ?? const []).cast<Map>())
            '[${[for (final k in ['x1_norm', 'y1_norm', 'x2_norm', 'y2_norm']) (b[k] as num).toStringAsFixed(3)].join(', ')}] '
                '${(b['confidence'] as num).toStringAsFixed(2)}',
        ];
        _log('BOXES $name: ${boxes.isEmpty ? 'none' : boxes.join('; ')}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
