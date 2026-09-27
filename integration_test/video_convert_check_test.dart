// FaunaPulse (round 233): on-device check of the video frame conversion
// (cutting out the analysed area, shrinking it and turning the video's colour
// format into RGB) before detection.
//
// Uses one of the owner's clips already pushed for video_decode_check_test.dart
// (see its header), in video_check/videos/, by default the 47.8 MB recording:
// --dart-define=CONVERT_CLIP=VID_20260924_155954.mp4
// Run:  flutter test integration_test/video_convert_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Model: as in video_review_check_test.dart (--dart-define=REVIEW_MODEL=...).
//
// Steps:
//  - the clip is analysed twice with the screen's settings (15 frames per
//    second, whole picture, shrunk to at most about 1280 px): the two runs
//    must give exactly the same boxes;
//  - the boxes are compared with a reference in video_convert_check_ref/
//    (same clip, model and settings): a faster conversion must not change a
//    single box. Without a reference, this run's boxes become the reference,
//    so run the check once before a conversion change and once after;
//  - logs the ms per frame of each step (decode, convert, detect) and the
//    frames per second of every run;
//  - --dart-define=CONVERT_PX=400 shrinks to that size instead of 1280 (a
//    shrink step above 1 on a 720x1280 clip), --dart-define=CONVERT_ROI=0.5,0.6,0.7
//    analyses that square (centre x, centre y, side; fractions); each
//    combination has its own reference;
//  - --dart-define=SIZE_PX=320 adds a run that shrinks to that size (e.g. the
//    model's input size) and compares its boxes and visits. In round 233 it
//    was twice as fast but changed half the boxes; it stays unused until a
//    hand-counted field clip shows which size finds the insects better (the
//    owner's test clips film a laptop screen, so their boxes cannot tell).
// The sessions stay in video_convert_check/ for `adb pull`.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

const _clip = String.fromEnvironment('CONVERT_CLIP', defaultValue: 'VID_20260924_155954.mp4');
const _model = String.fromEnvironment('REVIEW_MODEL', defaultValue: 'arthropod_yolov11_float16.tflite');
const _sizePx = int.fromEnvironment('SIZE_PX');
const _px = int.fromEnvironment('CONVERT_PX', defaultValue: 1280);
const _roiArg = String.fromEnvironment('CONVERT_ROI');
final _roi = _roiArg.isEmpty ? null : [for (final v in _roiArg.split(',')) double.parse(v)];

// ignore: avoid_print
void _log(String s) => print(s);

Future<String> _modelPath() async {
  if (_model.isEmpty) return kLocalYolo26ModelPath;
  final f = File('${(await ModelCatalog.modelsDir()).path}/$_model');
  expect(f.existsSync(), isTrue, reason: 'import $_model in the app first');
  return f.path;
}

/// The last run's settings and its boxes per frame time.
(Map<String, dynamic>, Map<int, List<List<num>>>) _read(File f) {
  var settings = <String, dynamic>{};
  final boxes = <int, List<List<num>>>{};
  for (final line in f.readAsLinesSync()) {
    final r = (jsonDecode(line) as Map).cast<String, dynamic>();
    if (r['type'] == 'video_run_start') {
      settings = (r['settings'] as Map).cast<String, dynamic>()..remove('model');
      boxes.clear();
    }
    if (r['type'] != 'raw_detections') continue;
    boxes[(r['pts_us'] as num).toInt()] = [
      for (final b in r['boxes'] as List) (b as List).cast<num>(),
    ];
  }
  return (settings, boxes);
}

double _iou(List<num> a, List<num> b) {
  final w = min(a[2], b[2]) - max(a[0], b[0]);
  final h = min(a[3], b[3]) - max(a[1], b[1]);
  if (w <= 0 || h <= 0) return 0;
  final inter = w * h;
  return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter);
}

/// Logs how far the boxes of [b] agree with [a]; returns the number of
/// frames whose boxes are exactly the same.
int _compare(String what, Map<int, List<List<num>>> a, Map<int, List<List<num>>> b) {
  expect(b.keys.toSet(), a.keys.toSet(), reason: '$what: the same frames were analysed');
  var nA = 0, nB = 0, matched = 0, lowConf = 0, same = 0;
  var iouSum = 0.0, confDiffSum = 0.0;
  for (final pts in a.keys) {
    if (jsonEncode(a[pts]) == jsonEncode(b[pts])) same++;
    final left = [...b[pts]!];
    nA += a[pts]!.length;
    nB += left.length;
    // Greedy, highest confidence first: same class, overlap IoU >= 0.5.
    for (final box in [...a[pts]!]..sort((x, y) => y[4].compareTo(x[4]))) {
      var best = -1;
      var bestIou = 0.5;
      for (var i = 0; i < left.length; i++) {
        final v = left[i][5] == box[5] ? _iou(box, left[i]) : 0.0;
        if (v >= bestIou) {
          best = i;
          bestIou = v;
        }
      }
      if (best < 0) {
        if (box[4] < 0.4) lowConf++;
        continue;
      }
      matched++;
      iouSum += bestIou;
      confDiffSum += (box[4] - left[best][4]).abs();
      left.removeAt(best);
    }
    lowConf += left.where((x) => x[4] < 0.4).length;
  }
  String pct(int n, int of) => of == 0 ? '-' : '${(100 * n / of).toStringAsFixed(1)} %';
  _log('COMPARE $what: ${a.length} frames, $same exactly the same; boxes $nA vs $nB, matched $matched '
      '(${pct(matched, nA)} and ${pct(matched, nB)}), mean IoU '
      '${matched == 0 ? '-' : (iouSum / matched).toStringAsFixed(3)}, mean |conf diff| '
      '${matched == 0 ? '-' : (confDiffSum / matched).toStringAsFixed(3)}, unmatched below 0.4 conf '
      '$lowConf of ${nA + nB - 2 * matched}');
  return same;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video frame conversion: same boxes, time per step', (tester) async {
    final ext = (await getExternalStorageDirectory())!.path;
    final src = File('$ext/video_check/videos/$_clip');
    expect(src.existsSync(), isTrue, reason: 'push $_clip to $ext/video_check/videos first');
    final out = Directory('$ext/video_convert_check');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final sessions = Directory('${out.path}/sessions')..createSync(recursive: true);
    final refDir = Directory('$ext/video_convert_check_ref')..createSync(recursive: true);
    final info = await VideoFrameSource.info(src.path);
    _log('CLIP $_clip ${info.width}x${info.height} ${info.durationMs} ms, $_px px, area ${_roi ?? 'whole'}');

    Future<Directory> import(String name) async {
      final cache = Directory('${out.path}/cache_$name')..createSync();
      final copy = src.copySync('${cache.path}/$_clip');
      final bytes = copy.lengthSync(); // the import moves the copy
      return importVideos(
        sessionsDir: sessions,
        sessionName: name,
        clips: [
          ImportClip(
            path: copy.path,
            name: _clip,
            sizeBytes: bytes,
            info: info,
            guess: guessClipStart(
              fileName: _clip,
              storedMs: info.creationEpochMs,
              durationMs: info.durationMs,
              fileModifiedMs: src.lastModifiedSync().millisecondsSinceEpoch,
            ),
          ),
        ],
        startExtras: {'build_mode': 'debug'},
      );
    }

    final model = await _modelPath();
    const base = VideoRunConfig(modelPath: '', modelName: '', confidence: 0.25, iou: 0.7, useGpu: true);
    final runs = [('a', _px), if (_sizePx > 0) ('small', _sizePx), ('b', _px)];
    final dirs = {for (final (name, px) in runs) name: await import('$name $px px')};
    final yolo = YOLO(modelPath: model, task: YOLOTask.detect, useMultiInstance: true);
    expect(await yolo.loadModel(), isTrue);

    for (final (name, px) in runs) {
      final r = await VideoDetector(backend: NativeVideoBackend(yolo.instanceId)).run(
        dirs[name]!,
        config: VideoRunConfig(
          modelPath: model,
          modelName: model.split('/').last,
          confidence: base.confidence,
          iou: base.iou,
          useGpu: base.useGpu,
          analysisFps: base.analysisFps,
          roi: _roi,
          maxSidePx: px,
        ),
        thermalLimitC: 45,
      );
      expect(r.clipsDone, 1);
      final done = [
        for (final line in File('${dirs[name]!.path}/${VideoDetector.outputFileName}').readAsLinesSync())
          if (line.contains('"video_clip_done"')) (jsonDecode(line) as Map).cast<String, dynamic>(),
      ].last;
      final n = done['frames_analysed'] as int;
      String ms(String k) => ((done[k] as num) / n).toStringAsFixed(2);
      _log('RUN $name ($px px): $n frames in ${r.elapsed.inMilliseconds} ms, '
          '${(n / (r.elapsed.inMilliseconds / 1000)).toStringAsFixed(1)} fps; per frame decode ${ms('decode_ms')}, '
          'convert ${ms('convert_ms')}, detect ${ms('infer_ms')} ms; battery ${(await DeviceThermal.read()).batteryTempC} °C');
    }
    await yolo.dispose();

    File results(String name) => File('${dirs[name]!.path}/${VideoDetector.outputFileName}');
    final (settingsA, a) = _read(results('a'));
    final (_, b) = _read(results('b'));
    expect(_compare('run a vs run b', a, b), a.length, reason: 'two runs of the same build agree exactly');

    final ref = File('${refDir.path}/${_clip}_${model.split('/').last}_${_px}px_${_roiArg.isEmpty ? 'whole' : _roiArg}.jsonl');
    if (ref.existsSync()) {
      final (settingsRef, r) = _read(ref);
      expect(jsonEncode(settingsRef), jsonEncode(settingsA), reason: 'the reference was made with the same settings');
      _log('REFERENCE from ${ref.lastModifiedSync()}');
      expect(_compare('reference vs run a', r, a), r.length, reason: 'the conversion must not change a box');
    } else {
      results('a').copySync(ref.path);
      _log('REFERENCE none yet: saved run a as ${ref.path}');
    }

    if (_sizePx > 0) {
      _compare('run a vs $_sizePx px', a, _read(results('small')).$2);
      for (final name in ['a', 'small']) {
        _log('VISITS $name: ${(await VideoTracker.run(dirs[name]!, const SessionConfig())).visits}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
