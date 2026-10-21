// Round 319 part 3, "Identify organisms":
// - A4 (phone check P2R): one track ID gave 'Last run' the line '1 track IDs: 1 to species.';
//   one crop gave '1 of 1 crops could not be identified ...'.
// - A6 (phone check P2R, Mb1): the time per crop kept for the next run's estimate ("Run") was
//   the whole run's time, heat pauses included (5 min 29 s became 7 min 13 s after a pause),
//   while the time left leaves pauses out since part 2.
//
// The plugin and the temperature channel are stand-ins (as in r319b_m_identify_texts_test).

import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/crop_worker.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_run.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

const _photos = ['roi_t_2026-07-14_120000_000.jpg', 'roi_t_2026-07-14_120000_500.jpg', 'roi_t_2026-07-14_120001_000.jpg'];

String _det(int ms, int track, String photo) =>
    '{"type":"detections","time_ms":$ms,"tracks":[{"track_id":$track,"confidence":0.9,'
    '"box_in_roi":{"left":0.1,"top":0.1,"right":0.9,"bottom":0.9},"jpeg":"$photo"}]}';

/// A session log whose photos [photos] all belong to the track IDs [tracks] (same index).
String _log(List<String> photos, List<int> tracks) => [
  '{"type":"start_of_session","time_ms":1000,"config":{},"device":{"model":"TestPhone"}}',
  for (var i = 0; i < photos.length; i++) _det(2000 + 500 * i, tracks[i], photos[i]),
  '{"type":"end_of_session","time_ms":4000,"ended_normally":true}',
  '',
].join('\n');

Uint8List _jpeg(int g) {
  final im = img.Image(width: 320, height: 320, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(200, g, 40));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  const thermalChannel = MethodChannel('faunapulse/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319c_a_identify');
    IdentificationRun.resetForTest();
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    wakelockPlusPlatformInstance = FakeWakelock();
    PackageInfo.setMockInitialValues(appName: 'FaunaPulse', packageName: 'test', version: '0.0.0', buildNumber: '1', buildSignature: '');
    SharedPreferences.setMockInitialValues({'identify_model': 'test-model.tflite', 'identify_pack': 'tiny_pack.fpack'});
    var ticks = 0;
    DeviceThermal.resetForTesting();
    DeviceThermal.now = () => Duration(minutes: ticks++);
    messenger.setMockMethodCallHandler(thermalChannel, (call) async => {'batteryTempC': 30.0});
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      switch (call.method) {
        case 'embedderLoad':
          return {'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': pack.dim, 'loadMs': 1.0};
        case 'embedderRun':
          final n = ((call.arguments as Map)['images'] as List).length;
          return {
            'dim': pack.dim,
            'count': n,
            'vectors': Float32List.fromList([for (var i = 0; i < n; i++) ...pack.matrix.sublist(0, pack.dim)]),
            'ms': 1.0,
          };
      }
      return null;
    });
  });
  tearDown(() {
    DeviceThermal.resetForTesting();
    for (final c in [pathChannel, yoloChannel, thermalChannel]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// The session: [photos] of the track IDs [tracks]; [damaged] photos hold text, not a JPEG.
  Directory makeSession(List<String> photos, List<int> tracks, {Set<int> damaged = const {}}) {
    final models = Directory('${tmp.path}/identification/models')..createSync(recursive: true);
    final packs = Directory('${tmp.path}/identification/packs')..createSync(recursive: true);
    File('${models.path}/test-model.tflite').writeAsBytesSync([0]);
    File('test/fauna_pulse/fixtures/tiny_pack.fpack').copySync('${packs.path}/tiny_pack.fpack');
    final dir = Directory('${tmp.path}/sessions/meadow')..createSync(recursive: true);
    File('${dir.path}/session.jsonl').writeAsStringSync(_log(photos, tracks));
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    for (var i = 0; i < photos.length; i++) {
      File('${frames.path}/${photos[i]}').writeAsBytesSync(damaged.contains(i) ? 'not a photo'.codeUnits : _jpeg(40 * i));
    }
    return dir;
  }

  List<String> texts() => [
    for (final e in find.byType(Text, skipOffstage: false).evaluate()) (e.widget as Text).data ?? '',
  ];

  /// Starts the run as "Also identify them" does and waits for "Last run".
  Future<List<String>> runToEnd(WidgetTester tester, Directory dir) async {
    tester.view.physicalSize = const Size(360, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    IdentificationRun.autoStart(dir);
    await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: dir)));
    bool done() => find.text('Last run', skipOffstage: false).evaluate().isNotEmpty;
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: 'the run never ended: ${texts()}');
    final all = texts();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    return all;
  }

  group('A4: counts of one', () {
    testWidgets('one track ID: "1 track ID:"', (tester) async {
      final all = await runToEnd(tester, makeSession(_photos.take(2).toList(), [1, 1]));
      final line = all.firstWhere((t) => RegExp(r'^\d+ track ID').hasMatch(t), orElse: () => '');
      expect(line, startsWith('1 track ID: '), reason: '$all');
    });

    testWidgets('two track IDs: "2 track IDs:"', (tester) async {
      final all = await runToEnd(tester, makeSession(_photos, [1, 1, 2]));
      final line = all.firstWhere((t) => RegExp(r'^\d+ track ID').hasMatch(t), orElse: () => '');
      expect(line, startsWith('2 track IDs: '), reason: '$all');
    });

    testWidgets('one crop, its photo unreadable: "1 of 1 crop"', (tester) async {
      final all = await runToEnd(tester, makeSession(_photos.take(1).toList(), [1], damaged: {0}));
      expect(
        all,
        contains('1 of 1 crop could not be identified because its photo could not be read (the file may be '
            'damaged). It is missing from the results.'),
      );
    });
  });

  test('A6: the time per crop kept for the estimate leaves a heat pause out', () async {
    final dir = makeSession(_photos, [1, 1, 2]);
    var reads = 0;
    final job = IdentificationJob(
      embed: (rgb) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return [for (final _ in rgb) Float32List.fromList(pack.matrix.sublist(0, pack.dim))];
      },
      crop: (a) async => cropBatchSync(a),
      // Warm at the second photo's check, cool at the next one: one pause of one poll.
      thermal: () async => ThermalReading(batteryTempC: ++reads == 2 ? 45.0 : 30.0),
      pausePoll: const Duration(milliseconds: 1500),
    );
    final r = await job.run(
      dir,
      settings: const IdentifyRunSettings(
        modelName: 'fake_model.tflite',
        modelId: 'fake',
        packName: 'tiny_pack.fpack',
        inputSize: 32,
        dim: 4,
        accelerator: 'CPU',
        minCropPx: 16,
        batchSize: 1,
      ),
      packFile: File('test/fauna_pulse/fixtures/tiny_pack.fpack'),
      onProgress: (_) {},
    );
    expect((r.embedded, r.thermalPauses), (3, 1));
    expect(r.pausedTime, greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
    // What was kept before: the 1.5 s pause spread over the 3 crops.
    final withPause = r.elapsed.inMilliseconds / r.embedded;
    expect(withPause, greaterThan(500));
    // Three crops at about 20 ms each, reading and scoring included; the pause is not in it.
    expect(r.msPerCrop, lessThan(400), reason: 'msPerCrop ${r.msPerCrop}, with the pause $withPause');
    expect(r.msPerCrop, greaterThan(0));
    // The run's record says how long it paused.
    final end = Directory('${dir.path}/identification')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('embeddings_') && f.path.endsWith('.jsonl'))
        .expand((f) => f.readAsLinesSync())
        .lastWhere((l) => l.contains('"identify_end"'));
    expect(RegExp(r'"paused_ms":(\d+)').firstMatch(end)?.group(1), isNotNull, reason: end);
  });

  test('A6: the screen reads the time per crop the run keeps (IdentifyResult.msPerCrop)', () {
    // identification_run.dart keeps r.msPerCrop under IdentifyPrefs.msPerCropKey.
    final src = File('lib/fauna_pulse/identification/identification_run.dart').readAsStringSync();
    expect(src, contains('final wallMs = r.msPerCrop;'));
    const r = IdentifyResult(
      planned: 4,
      embedded: 4,
      skipped: 0,
      failed: 0,
      resumedDone: 0,
      thermalPauses: 1,
      elapsed: Duration(seconds: 10),
      pausedTime: Duration(seconds: 6),
      cancelled: false,
    );
    expect(r.msPerCrop, 1000);
  });
}
