// FaunaPulse (round 227): on-device check of the video import pieces.
//
// Uses the clips and `<clip>.ref.jpg` upright reference frames already pushed
// for video_decode_check_test.dart (see its header), in video_check/.
// Run:  flutter test integration_test/video_import_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
//
// Checks that:
//  - the first-frame picture used to place the square comes out upright: it
//    matches the upright reference frame better than any turned copy of it;
//  - each clip's start-time guess (printed, to compare with the file names);
//  - importing copies of the clips logs one video_clip record each, and the
//    analysis pass (1 frame per second) takes the imported start times over.
// The clips in video_check/ are left untouched; the import and the first-frame
// pictures stay in video_import_check/ for `adb pull`.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

// ignore: avoid_print
void _log(String s) => print(s);

/// Mean brightness difference (0..255) of two pictures on a 64 × 64 grid.
double _diff(img.Image a, img.Image b) {
  final sa = img.copyResize(a, width: 64, height: 64);
  final sb = img.copyResize(b, width: 64, height: 64);
  var sum = 0.0;
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      final p = sa.getPixel(x, y), q = sb.getPixel(x, y);
      sum += (0.299 * (p.r - q.r) + 0.587 * (p.g - q.g) + 0.114 * (p.b - q.b)).abs();
    }
  }
  return sum / (64 * 64);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video import pieces on this phone', (tester) async {
    await tester.runAsync(() async {
      final ext = (await getExternalStorageDirectory())!.path;
      final clips = VideoDetector.clipsOf(Directory('$ext/video_check'));
      expect(clips, isNotEmpty, reason: 'push clips to $ext/video_check/videos first');
      final out = Directory('$ext/video_import_check');
      if (out.existsSync()) out.deleteSync(recursive: true);
      final cache = Directory('${out.path}/cache')..createSync(recursive: true);

      // 1. First-frame picture and start-time guess per clip.
      final toImport = <ImportClip>[];
      for (final f in clips) {
        final name = f.path.split('/').last;
        final info = await VideoFrameSource.info(f.path);
        final guess = guessClipStart(
          fileName: name,
          storedMs: info.creationEpochMs,
          durationMs: info.durationMs,
          fileModifiedMs: f.lastModifiedSync().millisecondsSinceEpoch,
        );
        _log(
          'CLIP $name ${info.width}x${info.height} rot=${info.rotation} ${info.durationMs} ms '
          'stored=${info.creationEpochMs == null ? '-' : DateTime.fromMillisecondsSinceEpoch(info.creationEpochMs!)} '
          'guess=${DateTime.fromMillisecondsSinceEpoch(guess.epochMs)} ${guess.source}${guess.weak ? ' (weak)' : ''}',
        );
        if (info.unsupportedReason != null) {
          _log('  refused: ${info.unsupportedReason}');
          continue;
        }

        final t0 = DateTime.now();
        final jpeg = await VideoFrameSource.thumbnail(f.path);
        final ms = DateTime.now().difference(t0).inMilliseconds;
        File('${out.path}/$name.thumb.jpg').writeAsBytesSync(jpeg);
        final thumb = img.decodeJpg(jpeg)!;
        _log('  thumbnail ${thumb.width}x${thumb.height} in $ms ms');
        expect(math.max(thumb.width, thumb.height), lessThanOrEqualTo(720), reason: name);
        final aspect = info.width / info.height;
        expect(thumb.width / thumb.height, closeTo(aspect, aspect * 0.03), reason: '$name upright size');

        final ref = File('${f.parent.parent.path}/$name.ref.jpg');
        if (ref.existsSync()) {
          final refImg = img.decodeJpg(ref.readAsBytesSync())!;
          final diffs = {for (final a in [0, 90, 180, 270]) a: _diff(thumb, img.copyRotate(refImg, angle: a))};
          _log('  vs reference turned 0/90/180/270: ${diffs.values.map((d) => d.toStringAsFixed(1)).join(' / ')}');
          final best = diffs.entries.reduce((a, b) => a.value <= b.value ? a : b);
          expect(best.key, 0, reason: '$name first frame is not upright');
        }

        final copy = f.copySync('${cache.path}/$name');
        toImport.add(
          ImportClip(
            path: copy.path,
            name: name,
            sizeBytes: copy.lengthSync(),
            info: info,
            guess: guessClipStart(
              fileName: name,
              storedMs: info.creationEpochMs,
              durationMs: info.durationMs,
              fileModifiedMs: f.lastModifiedSync().millisecondsSinceEpoch,
            ),
          ),
        );
      }

      // 2. Import the copies.
      for (final c in planImport(toImport)) {
        _log('PLAN ${c.name} ${DateTime.fromMillisecondsSinceEpoch(c.startMs)} ${c.source}');
      }
      final dir = await importVideos(
        sessionsDir: Directory('${out.path}/sessions')..createSync(),
        sessionName: 'import check',
        clips: toImport,
        startExtras: {'build_mode': 'debug'},
      );
      expect(cache.listSync(), isEmpty, reason: 'clips moved, not copied');
      final logged = await VideoDetector.clipStartsFromLog(dir);
      expect(logged.length, toImport.length);

      // 3. The analysis pass takes the imported start times over.
      final yolo = YOLO(modelPath: kLocalYolo26ModelPath, task: YOLOTask.detect, useMultiInstance: true);
      expect(await yolo.loadModel(), isTrue);
      final run = await VideoDetector(backend: NativeVideoBackend(yolo.instanceId)).run(
        dir,
        config: const VideoRunConfig(
          modelPath: kLocalYolo26ModelPath,
          modelName: 'yolo26',
          confidence: 0.25,
          iou: 0.7,
          useGpu: true,
          analysisFps: 1,
        ),
      );
      await yolo.dispose();
      _log('RUN frames=${run.framesAnalysed} done=${run.clipsDone} failed=${run.clipsFailed} ${run.elapsed.inMilliseconds} ms');
      expect(run.clipsFailed, 0);
      final starts = File('${dir.path}/${VideoDetector.outputFileName}')
          .readAsLinesSync()
          .map((l) => (jsonDecode(l) as Map).cast<String, dynamic>())
          .where((r) => r['type'] == 'video_clip_start');
      for (final r in starts) {
        expect(r['start_time_source'], 'session_log', reason: '${r['clip']}');
        expect(r['start_epoch_ms'], logged[r['clip']], reason: '${r['clip']}');
      }
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
