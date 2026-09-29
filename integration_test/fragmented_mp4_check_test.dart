// FaunaPulse (round 252): on-device check of importing fragmented MP4s (as
// saved by YouTube downloaders: an index without frames, the pictures in many
// small fragments). The phone's player cannot jump in such a file: it stays on
// the first frame while reporting the asked position, so the Video tab drew
// boxes on the wrong picture. The import now rewrites them as plain MP4s.
//
// Push the clips into the app's folder first (adb shell cp works there), e.g.
//   adb shell cp '/sdcard/Download/<folder>/Pollinators (1080p, h264).mp4' \
//     /sdcard/Android/data/com.faunapulse.app/files/frag_check/pollinators.mp4
// Run:  flutter test integration_test/fragmented_mp4_check_test.dart -d <serial> --no-uninstall
//   --dart-define=FRAG_CLIPS=frag_check/pollinators.mp4,frag_check/bumblebee.mp4
// (paths relative to the app's external files folder; they are only read).
//
// Each clip is copied (as the file picker does), imported with the app's own
// importVideos into frag_check/out/sessions/, then played: jumps to a quarter,
// a half and 5 s, and 3 s of play from there. The test prints "SHOT <name>"
// and holds the paused picture 4 s for a screencap loop on the computer (see
// video_review_check_test.dart); compare them with the file's frames at the
// logged positions.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _clips = String.fromEnvironment('FRAG_CLIPS');

// Frame alignment (second test): a plain clip (path as FRAG_CLIPS) and the
// paused positions (ms) to show, e.g. around a scene cut; each is held with
// two SHOTs (1.5 s and 5 s after the jump) to see whether the picture
// changes late.
const _alignClip = String.fromEnvironment('FRAG_ALIGN_CLIP');
const _alignAt = String.fromEnvironment('FRAG_ALIGN_AT');

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fragmented MP4 import on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    // The screen must stay on: a locked phone stops drawing and the check hangs.
    await WakelockPlus.enable();
    final ext = (await getExternalStorageDirectory())!.path;
    final out = Directory('$ext/frag_check/out');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final cache = Directory('${out.path}/cache')..createSync(recursive: true);
    final sessions = Directory('${out.path}/sessions')..createSync();
    var n = 0;
    for (final rel in _clips.split(',').where((s) => s.isNotEmpty)) {
      n++;
      final src = File('$ext/$rel');
      expect(src.existsSync(), isTrue, reason: src.path);
      final name = src.path.split('/').last;
      final copy = src.copySync('${cache.path}/$name');
      final fragmented = isFragmentedMp4(copy);
      final info = await VideoFrameSource.info(copy.path);
      _log('INFO $rel: fragmented $fragmented, duration ${info.durationMs} ms, ${info.frameCount} frames, '
          'first pts ${info.firstPtsUs} us, ${info.width}x${info.height}');
      final sw = Stopwatch()..start();
      final dir = await importVideos(
        sessionsDir: sessions,
        sessionName: 'frag $n',
        clips: [
          ImportClip(
            path: copy.path,
            name: name,
            sizeBytes: copy.lengthSync(),
            info: info,
            guess: guessClipStart(fileName: name, storedMs: info.creationEpochMs, durationMs: info.durationMs, fileModifiedMs: 1),
            fragmented: fragmented,
          ),
        ],
        startExtras: {'build_mode': 'debug'},
      );
      _log('IMPORT $rel took ${sw.elapsedMilliseconds} ms');
      final rec = File('${dir.path}/session.jsonl')
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map)
          .firstWhere((r) => r['type'] == 'video_clip');
      _log('RECORD ${jsonEncode(rec)}');
      final clip = File('${dir.path}/${rec['file']}');
      expect(isFragmentedMp4(clip), isFalse);
      final after = await VideoFrameSource.info(clip.path);
      _log('AFTER ${clip.path.split('/').last}: duration ${after.durationMs} ms, ${after.frameCount} frames, '
          'first pts ${after.firstPtsUs} us');
      expect(after.frameCount, info.frameCount);

      final c = VideoPlayerController.file(clip, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      await c.initialize();
      await c.setVolume(0);
      _log('PLAYER $n: duration ${c.value.duration.inMilliseconds} ms, size ${c.value.size}');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      Future<void> report(String what) async {
        final p = await c.position;
        _log('POS $n $what: value ${c.value.position.inMilliseconds} ms, position() ${p?.inMilliseconds} ms, '
            'playing ${c.value.isPlaying}, error ${c.value.errorDescription}');
      }

      Future<void> shot(String name) async {
        await tester.pump(const Duration(milliseconds: 800));
        await report('shot $name');
        _log('SHOT ${n}_$name');
        await tester.pump(const Duration(seconds: 4));
      }

      final lastMs = info.durationMs ?? 0;
      for (final target in [lastMs ~/ 4, lastMs ~/ 2, 5000]) {
        await c.seekTo(Duration(milliseconds: target));
        await shot('seek_$target');
        final at = await c.position;
        expect((at!.inMilliseconds - target).abs(), lessThan(100), reason: 'the player jumped to $target ms');
      }
      final wall = Stopwatch()..start();
      await c.play();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        await report('play wall ${wall.elapsedMilliseconds} ms');
      }
      await c.pause();
      await shot('after_play');
      await c.dispose();
      await tester.pumpWidget(const SizedBox());
    }
    await WakelockPlus.disable();
  }, skip: _clips.isEmpty);

  testWidgets('paused jumps show the asked frame', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    final ext = (await getExternalStorageDirectory())!.path;
    final clip = File('$ext/$_alignClip');
    expect(clip.existsSync(), isTrue, reason: clip.path);
    final info = await VideoFrameSource.info(clip.path);
    _log('ALIGN ${clip.path}: first pts ${info.firstPtsUs} us, mean ${info.meanFps} fps');
    final c = VideoPlayerController.file(clip, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
    await c.initialize();
    await c.setVolume(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    // After each jump: a SHOT at once (the old picture?), then the player's
    // buffering flag polled until it clears (a SHOT then: the new picture?),
    // and a last SHOT 3 s later.
    for (final ms in _alignAt.split(',').map(int.parse)) {
      final sw = Stopwatch()..start();
      await c.seekTo(Duration(milliseconds: ms));
      await tester.pump(const Duration(milliseconds: 50));
      _log('SHOT align_${ms}_early buffering ${c.value.isBuffering} at ${sw.elapsedMilliseconds} ms');
      await tester.pump(const Duration(milliseconds: 700));
      var sawBuffering = false;
      while (sw.elapsedMilliseconds < 8000) {
        if (c.value.isBuffering) sawBuffering = true;
        if (!c.value.isBuffering) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      _log('SHOT align_${ms}_ready buffering ${c.value.isBuffering} (seen: $sawBuffering) at ${sw.elapsedMilliseconds} ms');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(seconds: 3));
      final p = await c.position;
      _log('SHOT align_${ms}_late position() ${p?.inMilliseconds} ms');
      await tester.pump(const Duration(milliseconds: 700));
    }
    await c.dispose();
    await tester.pumpWidget(const SizedBox());
    await WakelockPlus.disable();
  }, skip: _alignClip.isEmpty);
}
