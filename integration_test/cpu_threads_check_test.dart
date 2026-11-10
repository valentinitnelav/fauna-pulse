// FaunaPulse (round 226): how many CPU threads should the AI use by default?
// Round 366: and is 16-bit CPU maths faster than 32-bit for a detector?
//
// Run:  flutter test integration_test/cpu_threads_check_test.dart -d <device-id> --no-uninstall
// Other models (absolute .tflite paths on the phone, separated by commas; for slow ones, e.g.
// the BioCLIP image tower, ask for fewer runs):
//   --dart-define=THREADS_CHECK_MODEL=<path>[,<path>] --dart-define=THREADS_CHECK_RUNS=5
// Other thread counts:               --dart-define=THREADS_CHECK_VARIANTS=2,4,8
// 16-bit CPU maths next to 32-bit:   --dart-define=THREADS_CHECK_FP16=true
// Always pass --no-uninstall: without it flutter uninstalls the app after the
// test, which deletes every session stored on the phone.
//
// Times the bundled detectors with the engine benchmark (the same one behind
// Settings -> AI -> "Benchmark engines"): GPU, then the CPU with the engine's own
// default thread count (0) and with 1, 2, 4 and 8 threads. Every pass runs
// twice, the second time in reverse order, so a phone that warms up and slows
// down during the run does not favour whichever variant came first. The GPU row
// comes with every pass: the same engine timed again and again shows that drift.

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _model = String.fromEnvironment('THREADS_CHECK_MODEL');
const _runs = int.fromEnvironment('THREADS_CHECK_RUNS', defaultValue: 20);
const _variantsArg = String.fromEnvironment('THREADS_CHECK_VARIANTS', defaultValue: '0,1,2,4,8');
const _fp16 = bool.fromEnvironment('THREADS_CHECK_FP16');
const _bundled = [
  'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
  'assets/models/custom/MDV6-yolov10-c_float16_320.tflite',
  'assets/models/custom/ArthroNat_flatbug_yolo11n_int8_640.tflite',
  'assets/models/yolo26n_int8.tflite',
];

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CPU thread count vs speed on this phone', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final models = _model == '' ? _bundled : _model.split(',');
    final variants = [for (final v in _variantsArg.split(',')) int.parse(v)];
    // One pass = the thread counts in one order, in one kind of maths.
    final passes = [
      for (final fp16 in [false, if (_fp16) true]) (variants, fp16),
    ];
    await tester.runAsync(() async {
      for (final model in models) {
        final name = model.split('/').last;
        for (final (order, fp16) in [...passes, for (final p in passes.reversed) (p.$1.reversed.toList(), p.$2)]) {
          final t = await DeviceThermal.read();
          _log('BENCH $name pass starts at battery ${t.batteryTempC} cpu ${t.cpuTempC} gpu ${t.gpuTempC} °C');
          final rows = await YOLO.benchmarkAccelerators(model, iterations: _runs, cpuThreadVariants: order, cpuFp16: fp16);
          for (final r in rows) {
            _log('BENCH $name ${r['label']} acc=${r['accelerator']} '
                'avg=${(r['avgMs'] as num?)?.toStringAsFixed(1)} min=${(r['minMs'] as num?)?.toStringAsFixed(1)} '
                'compile=${(r['compileMs'] as num?)?.toStringAsFixed(0)} ${r['error'] ?? ''}');
          }
        }
      }
      _log('BENCH DONE');
    });
  }, timeout: const Timeout(Duration(minutes: 40)));
}
