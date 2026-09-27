// FaunaPulse (round 226): how many CPU threads should the AI use by default?
//
// Run:  flutter test integration_test/cpu_threads_check_test.dart -d <serial> --no-uninstall
// Other model (e.g. the BioCLIP image tower, slow: fewer runs):
//   --dart-define=THREADS_CHECK_MODEL=<absolute .tflite path> --dart-define=THREADS_CHECK_RUNS=5
// Always pass --no-uninstall: without it flutter uninstalls the app after the
// test, which deletes every session stored on the phone.
//
// Times the bundled detectors with the engine benchmark (the same one behind
// Settings -> AI -> "Benchmark engines"): GPU, then the CPU with the engine's own
// default thread count (0) and with 1, 2, 4 and 8 threads. The CPU variants run
// twice, the second time in reverse order, so a phone that warms up and slows
// down during the run does not favour whichever variant came first.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

const _model = String.fromEnvironment('THREADS_CHECK_MODEL');
const _runs = int.fromEnvironment('THREADS_CHECK_RUNS', defaultValue: 20);
const _bundled = [
  'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
  'assets/models/custom/MDV6-yolov10-c_float16_320.tflite',
  'assets/models/custom/ArthroNat_flatbug_yolo11n_int8_640.tflite',
  'assets/models/yolo26n_int8.tflite',
];
const _variants = [0, 1, 2, 4, 8];
const _models = _model == '' ? _bundled : [_model];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CPU thread count vs speed on this phone', (tester) async {
    await tester.runAsync(() async {
      for (final model in _models) {
        for (final order in [_variants, _variants.reversed.toList()]) {
          final rows = await YOLO.benchmarkAccelerators(model, iterations: _runs, cpuThreadVariants: order);
          for (final r in rows) {
            // ignore: avoid_print
            print('BENCH ${model.split('/').last} ${r['label']} acc=${r['accelerator']} '
                'avg=${(r['avgMs'] as num?)?.toStringAsFixed(1)} min=${(r['minMs'] as num?)?.toStringAsFixed(1)} '
                'compile=${(r['compileMs'] as num?)?.toStringAsFixed(0)} ${r['error'] ?? ''}');
          }
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
