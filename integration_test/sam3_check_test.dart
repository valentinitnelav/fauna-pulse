// FaunaPulse (round 257, sam3 branch): on-device check of SAM 3 (Sam3Detector.kt).
//
// Needs the SAM 3 files in the app's private folder `files/sam3/` and the test
// pictures in `files/sam3_check/` (copied with adb run-as, see docs/SAM3.md).
// 1. Loads SAM 3 with the prompt "insect" (picture model on the GPU when it
//    fits, head on the CPU) and checks the prompt's token numbers. The
//    picture model may be split into parts (tool/sam3/split_tflite.py);
//    "insect" may come from prompts/ (tool/sam3/make_prompts.py).
// 2. Detects on a 1008 x 1008 frame (no resizing on the phone, so any
//    difference is the model's) and compares with the PC run of the same files
//    (ai-edge-litert on the CPU): same boxes, probabilities within 0.05.
// 3. Times two more frames and prints the app's memory.
// 4. Loads again with the head on the GPU and the prompt
//    "flower-visiting insect" (tokenizer check with a hyphen and two words;
//    the model card says LiteRT before 2.2.0 mis-runs the head on phone GPUs)
//    and compares with the PC run. That prompt is encoded on the phone (text
//    model) unless an earlier run remembered it in prompts/.
// Run:  flutter test integration_test/sam3_check_test.dart -d <serial> --no-uninstall
//       [--dart-define=SAM3_CPU=true]  (round 259: picture model on the CPU, one part at a
//       time; steps 1 to 3 only. The Xiaomi's GPU gives NaN, see docs/SAM3.md)
// Always pass --no-uninstall (see video_decode_check_test.dart for why).

import 'dart:io';
import 'dart:math';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

const _cpu = bool.fromEnvironment('SAM3_CPU');

/// PC reference (ai-edge-litert 2.2.0, CPU) on bumblebees_6s_1008.png:
/// probability and box (left, top, right, bottom) in pixels.
const _pcInsect = [
  (0.911, [279.0, 405.0, 621.0, 557.0]),
  (0.529, [470.0, 802.0, 504.0, 833.0]),
  (0.268, [750.0, 671.0, 808.0, 692.0]),
];
const _pcFlowerVisiting = [
  (0.117, [46.0, 365.0, 918.0, 878.0]),
  (0.090, [558.0, 157.0, 732.0, 266.0]),
  (0.082, [279.0, 403.0, 620.0, 558.0]),
];

double _iou(List<double> a, List<double> b) {
  final iw = max(0.0, min(a[2], b[2]) - max(a[0], b[0]));
  final ih = max(0.0, min(a[3], b[3]) - max(a[1], b[1]));
  final inter = iw * ih;
  final union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter;
  return union > 0 ? inter / union : 0;
}

String _memory() {
  final status = File('/proc/self/status').readAsLinesSync();
  String field(String name) => status.firstWhere((l) => l.startsWith(name), orElse: () => '$name ?').trim();
  return '${field('VmRSS')}, ${field('VmHWM')}';
}

/// Each reference box must be found with IoU >= 0.9 and a probability within 0.05.
void _compare(String label, Sam3Result r, List<(double, List<double>)> reference) {
  for (final (p, box) in reference) {
    final best = r.boxes.map((b) => (b, _iou(b, box))).reduce((a, b) => a.$2 >= b.$2 ? a : b);
    _log(
      '$label PC p=${p.toStringAsFixed(3)} box=$box -> phone p=${best.$1[4].toStringAsFixed(3)} '
      'box=${best.$1.take(4).map((v) => v.round()).toList()} IoU=${best.$2.toStringAsFixed(3)}',
    );
    expect(best.$2, greaterThanOrEqualTo(0.9), reason: '$label box $box');
    expect((best.$1[4] - p).abs(), lessThan(0.05), reason: '$label probability of $box');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SAM 3 on this phone matches the PC', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final base = (await getApplicationSupportDirectory()).path;
    final dir = '$base/sam3';
    final pics = '$base/sam3_check';
    expect(
      File('$dir/sam3_vision.tflite').existsSync() || File('$dir/sam3_vision_part1.tflite').existsSync(),
      isTrue,
      reason: 'copy the SAM 3 files first',
    );

    // 1 + 2: prompt "insect", head on the CPU. (Round 257, Xiaomi: the GPU's
    // picture model gives only NaN, so the detection below throws.)
    _log('memory before: ${_memory()}  battery ${(await DeviceThermal.read()).batteryTempC} °C');
    var info = await Sam3Detector.load(dir, 'insect', useGpu: !_cpu);
    _log(
      'LOAD insect: ${(info.loadMs / 1000).toStringAsFixed(1)} s, vision ${info.visionAccelerator}'
      '${info.visionNote == null ? '' : ' (${info.visionNote})'}, head ${info.headAccelerator}, '
      'ids ${info.tokenIds.where((v) => v != 0).toList()}; memory ${_memory()}',
    );
    expect(info.tokenIds.take(4).toList(), [49406, 21297, 49407, 0]);
    var r = await Sam3Detector.detectFile('$pics/bumblebees_6s_1008.png', confidence: 0.05);
    _log(
      'DETECT 1008 png: presence ${r.presence.toStringAsFixed(3)}, vision ${(r.visionMs / 1000).toStringAsFixed(1)} s, '
      'head ${(r.headMs / 1000).toStringAsFixed(1)} s, ${r.boxes.length} boxes',
    );
    _compare('insect/CPU head', r, _pcInsect);

    // 3: timing on the original frames (the phone stretches them to 1008 x 1008).
    for (final name in ['bumblebees_6s.jpg', 'onflower_3s.jpg']) {
      final sw = Stopwatch()..start();
      r = await Sam3Detector.detectFile('$pics/$name', confidence: 0.3);
      _log(
        'DETECT $name ${r.width}x${r.height}: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s '
        '(vision ${(r.visionMs / 1000).toStringAsFixed(1)} s, head ${(r.headMs / 1000).toStringAsFixed(1)} s), '
        'presence ${r.presence.toStringAsFixed(3)}, boxes ${[for (final b in r.boxes) '${b.take(4).map((v) => v.round()).toList()} p=${b[4].toStringAsFixed(2)}']}',
      );
    }
    _log('memory after detecting: ${_memory()}  battery ${(await DeviceThermal.read()).batteryTempC} °C');
    await Sam3Detector.close();
    if (_cpu) return;

    // 4: head on the GPU, two-word prompt with a hyphen.
    info = await Sam3Detector.load(dir, 'flower-visiting insect', headOnGpu: true);
    _log(
      'LOAD flower-visiting insect: ${(info.loadMs / 1000).toStringAsFixed(1)} s, vision ${info.visionAccelerator}, '
      'head ${info.headAccelerator}, ids ${info.tokenIds.where((v) => v != 0).toList()}',
    );
    expect(info.tokenIds.take(7).toList(), [49406, 4055, 268, 4680, 21297, 49407, 0]);
    r = await Sam3Detector.detectFile('$pics/bumblebees_6s_1008.png', confidence: 0.05);
    _log(
      'DETECT 1008 png (head ${info.headAccelerator}): presence ${r.presence.toStringAsFixed(3)} (PC 0.356), '
      'head ${(r.headMs / 1000).toStringAsFixed(1)} s',
    );
    try {
      _compare('flower-visiting/${info.headAccelerator} head', r, _pcFlowerVisiting);
    } finally {
      await Sam3Detector.close();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
