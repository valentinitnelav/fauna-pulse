// FaunaPulse (round 358): do the detectors still give the same boxes after a runtime change?
//
// Runs every bundled detector on the GPU and on the CPU over a fixed set of pictures already on
// the phone and prints one line per box (class, box as fractions of the picture, confidence),
// so two builds (for example LiteRT 2.1.5 and 2.3.2) can be compared line by line on the PC.
// Model time is not measured here (cpu_threads_check_test.dart does that).
// Run:  flutter test integration_test/detector_outputs_check_test.dart -d <serial> --no-uninstall
//         --dart-define=OUTPUTS_PICTURES=<folder on the phone with .jpg files>
//         --dart-define=OUTPUTS_COUNT=40
//         --dart-define=OUTPUTS_MODELS=<absolute .tflite path on the phone>[,<path>]
// Always pass --no-uninstall (see video_decode_check_test.dart for why). Without OUTPUTS_PICTURES
// the folder detector_outputs_check/ in the app's external files directory is used; without
// OUTPUTS_MODELS the bundled detectors.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _folder = String.fromEnvironment('OUTPUTS_PICTURES');
const _count = int.fromEnvironment('OUTPUTS_COUNT', defaultValue: 40);
const _modelsArg = String.fromEnvironment('OUTPUTS_MODELS');
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

  testWidgets('Detector boxes on fixed pictures, GPU and CPU', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final folder = _folder.isNotEmpty
        ? _folder
        : '${(await getExternalStorageDirectory())!.path}/detector_outputs_check';
    final all = Directory(folder).listSync().whereType<File>().where((f) => f.path.endsWith('.jpg')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(all, isNotEmpty, reason: 'no .jpg in $folder');
    // Spread the sample over the folder so that different kinds of pictures are seen.
    final step = all.length <= _count ? 1 : all.length ~/ _count;
    final pictures = [for (var i = 0; i < all.length && i ~/ step < _count; i += step) all[i]];
    _log('PICTURES ${pictures.length} of ${all.length} in $folder');
    final bytes = [for (final p in pictures) await p.readAsBytes()];
    for (final model in _modelsArg == '' ? _bundled : _modelsArg.split(',')) {
      final name = model.split('/').last;
      for (final gpu in [true, false]) {
        final acc = gpu ? 'GPU' : 'CPU';
        final yolo = YOLO(modelPath: model, task: YOLOTask.detect, useGpu: gpu, useMultiInstance: true);
        var boxes = 0;
        for (var i = 0; i < pictures.length; i++) {
          final pic = pictures[i].path.split('/').last;
          final r = await yolo.predict(bytes[i], confidenceThreshold: 0.25, iouThreshold: 0.7, includeAnnotatedImage: false);
          final list = (r['boxes'] as List? ?? const []).cast<Map>();
          boxes += list.length;
          for (final b in list) {
            final cls = b['class'] ?? b['className'] ?? b['classIndex'] ?? '?';
            final coords = [for (final k in ['x1_norm', 'y1_norm', 'x2_norm', 'y2_norm']) (b[k] as num).toStringAsFixed(4)];
            _log('BOX $name $acc $pic $cls ${coords.join(' ')} ${(b['confidence'] as num).toStringAsFixed(4)}');
          }
          _log('NBOX $name $acc $pic ${list.length}');
        }
        await yolo.dispose();
        _log('TOTAL $name $acc $boxes boxes on ${pictures.length} pictures');
      }
    }
    _log('OUTPUTS DONE');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
