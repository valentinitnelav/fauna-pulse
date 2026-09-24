// FaunaPulse (round 225): on-device check of offline video analysis.
//
// Push test clips to `videos/` and optional upright reference frames named
// `<clip>.ref.jpg` next to it, in the app's external files folder:
//   adb -s <serial> push <clips>/. /sdcard/Android/data/com.faunapulse.app/files/video_check/videos/
//   adb -s <serial> push <refs>/. /sdcard/Android/data/com.faunapulse.app/files/video_check/
// Run:  flutter test integration_test/video_decode_check_test.dart -d <serial> --no-uninstall
// Other model: add --dart-define=VIDEO_CHECK_MODEL=assets/models/custom/<file>.tflite
// Always pass --no-uninstall: without it flutter uninstalls the app after the
// test, which deletes every session stored on the phone.
//
// Runs the real "AI later" pass (VideoDetector + native decoder) with the
// bundled model, prints decode / convert / detect ms per frame per clip, and
// checks that:
//  - clips named "*tenbit*" are refused with the plain-language 10-bit message;
//  - frame 0's confident boxes match a photo run on the reference frame (colours,
//    rotation and box mapping are right);
//  - a centred ROI square lands where the live photo crop would put it, and
//    its boxes match a photo run on the same crop of the reference frame.
// Results stay in video_check/video_detections.jsonl for `adb pull`.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

typedef Box = List<double>; // l, t, r, b, confidence (box normalized)

const _modelPath = String.fromEnvironment('VIDEO_CHECK_MODEL', defaultValue: kLocalYolo26ModelPath);

double _iou(Box a, Box b) {
  final w = math.max(0.0, math.min(a[2], b[2]) - math.max(a[0], b[0]));
  final h = math.max(0.0, math.min(a[3], b[3]) - math.max(a[1], b[1]));
  final inter = w * h;
  final union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter;
  return union <= 0 ? 0 : inter / union;
}

/// Best IoU of [b] against any box in [others].
double _bestIou(Box b, List<Box> others) => others.fold(0.0, (m, o) => math.max(m, _iou(b, o)));

// The video pass runs at confidence 0.25, the photo pass at 0.15. Boxes near
// 0.25 flip with tiny pixel differences (JPEG vs H.264 decode), so only boxes
// clearly above the threshold (>= 0.35) must appear on the other side.
const _videoConf = 0.25, _photoConf = 0.15, _sure = 0.35;

/// Returns (sure boxes, sure boxes found on the other side at IoU >= 0.7,
/// mean IoU of those).
(int, int, double) _compare(List<Box> video, List<Box> photo) {
  final ious = [
    for (final p in photo.where((b) => b[4] >= _sure)) _bestIou(p, video),
    for (final v in video.where((b) => b[4] >= _sure)) _bestIou(v, photo),
  ];
  final hits = ious.where((v) => v >= 0.7).toList();
  return (ious.length, hits.length, hits.isEmpty ? 0 : hits.reduce((a, b) => a + b) / hits.length);
}

Future<List<Box>> _photoBoxes(YOLO yolo, List<int> jpeg) async {
  final r = await yolo.predict(Uint8List.fromList(jpeg), confidenceThreshold: _photoConf, iouThreshold: 0.5, includeAnnotatedImage: false);
  return [
    for (final d in (r['detections'] as List).cast<Map>())
      [
        for (final k in ['left', 'top', 'right', 'bottom']) ((d['normalizedBox'] as Map)[k] as num).toDouble(),
        (d['confidence'] as num).toDouble(),
      ],
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('offline video analysis on this phone', (tester) async {
    await tester.runAsync(() async {
      final root = Directory('${(await getExternalStorageDirectory())!.path}/video_check');
      final clips = VideoDetector.clipsOf(root);
      expect(clips, isNotEmpty, reason: 'push clips to ${root.path}/videos first');

      final yolo = YOLO(modelPath: _modelPath, task: YOLOTask.detect, useMultiInstance: true);
      expect(await yolo.loadModel(), isTrue);
      final config = VideoRunConfig(
        modelPath: _modelPath,
        modelName: _modelPath.split('/').last,
        confidence: _videoConf,
        iou: 0.5,
        useGpu: true,
      );

      // 1. The real pass over every clip.
      final run = await VideoDetector(
        backend: NativeVideoBackend(yolo.instanceId),
      ).run(root, config: config, startOver: true);
      // ignore: avoid_print
      print('RUN frames=${run.framesAnalysed} done=${run.clipsDone} failed=${run.clipsFailed} ${run.elapsed.inMilliseconds} ms');

      final recs = File('${root.path}/${VideoDetector.outputFileName}')
          .readAsLinesSync()
          .map((l) => (jsonDecode(l) as Map).cast<String, dynamic>())
          .toList();
      for (final clip in clips.map((f) => f.path.split('/').last)) {
        final start = recs.firstWhere((r) => r['type'] == 'video_clip_start' && r['clip'] == clip, orElse: () => {});
        final end = recs.lastWhere((r) => r['clip'] == clip && '${r['type']}'.startsWith('video_clip_'));
        // ignore: avoid_print
        print('CLIP $clip ${start['mime']} ${start['width']}x${start['height']} rot=${start['rotation']} '
            'fps=${start['mean_fps']} start=${start['start_time_source']} '
            '${start['start_epoch_ms'] == null ? '' : DateTime.fromMillisecondsSinceEpoch(start['start_epoch_ms'] as int)}');
        if (clip.contains('tenbit')) {
          expect(end['type'], 'video_clip_error', reason: clip);
          expect(end['error'], contains('10-bit'));
          continue;
        }
        expect(end['type'], 'video_clip_done', reason: '$clip: ${end['error']}');
        final n = (end['frames_analysed'] as num).toInt();
        // ignore: avoid_print
        print('  frames=$n decoded=${end['frames_decoded']} size=${end['frame_width']}x${end['frame_height']} '
            'ms/frame decode=${(end['decode_ms'] / n).toStringAsFixed(1)} convert=${(end['convert_ms'] / n).toStringAsFixed(1)} '
            'detect=${(end['infer_ms'] / n).toStringAsFixed(1)} wall=${(end['elapsed_ms'] / n).toStringAsFixed(1)}');
        final expected = (start['duration_ms'] as num) / 1000 * 15;
        expect(n, closeTo(expected, 2), reason: '$clip frames at 15 fps');

        // 2. Frame 0 vs a photo run on the reference frame.
        final ref = File('${root.path}/$clip.ref.jpg');
        if (!ref.existsSync()) continue;
        final frame0 = recs.firstWhere((r) => r['type'] == 'raw_detections' && r['clip'] == clip && r['frame'] == 0);
        final video = [for (final b in frame0['boxes'] as List) (b as List).take(5).map((v) => (v as num).toDouble()).toList()];
        final photo = await _photoBoxes(yolo, ref.readAsBytesSync());
        final (sure, found, meanIou) = _compare(video, photo);
        // ignore: avoid_print
        print('  frame0 boxes video=${video.length} photo=${photo.length} sure=$sure found=$found meanIoU=${meanIou.toStringAsFixed(3)}');
        expect(found, sure, reason: '$clip frame 0 vs photo');

        // 3. Centred ROI square vs the same crop of the reference frame.
        await VideoFrameSource.open(
          clips.firstWhere((f) => f.path.endsWith(clip)).path,
          instanceId: yolo.instanceId,
          confidence: _videoConf,
          iou: 0.5,
          roi: const [0.5, 0.5, 0.5],
        );
        final chunk = await VideoFrameSource.next(maxFrames: 1);
        await VideoFrameSource.close();
        final w = chunk.frameWidth, h = chunk.frameHeight;
        final px = ((0.5 * w / 32).round() * 32).clamp(32, (math.min(w, h) ~/ 32) * 32);
        final x = (0.5 * w - px / 2).round().clamp(0, w - px), y = (0.5 * h - px / 2).round().clamp(0, h - px);
        expect(chunk.roiPx, [x, y, px, px], reason: '$clip ROI square');
        final crop = img.copyCrop(img.decodeJpg(ref.readAsBytesSync())!, x: x, y: y, width: px, height: px);
        final cropBoxes = [
          for (final b in await _photoBoxes(yolo, img.encodeJpg(crop, quality: 95)))
            [(x + b[0] * px) / w, (y + b[1] * px) / h, (x + b[2] * px) / w, (y + b[3] * px) / h, b[4]],
        ];
        final roiBoxes = [for (final b in chunk.frames.first.boxes) b.take(5).map((v) => v.toDouble()).toList()];
        final (sure2, found2, iou2) = _compare(roiBoxes, cropBoxes);
        // ignore: avoid_print
        print('  roi ${chunk.roiPx} boxes video=${roiBoxes.length} photo=${cropBoxes.length} sure=$sure2 found=$found2 meanIoU=${iou2.toStringAsFixed(3)}');
        expect(found2, sure2, reason: '$clip ROI vs photo crop');
      }
      await yolo.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
