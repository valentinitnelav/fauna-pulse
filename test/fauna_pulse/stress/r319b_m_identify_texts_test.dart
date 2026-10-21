// Round 319, part 2 (phone tests of part 1), "Identify organisms":
// - Mb1: during a heat pause the time left grew ("about 8 min 38 s left", then "about 9 min 46 s
//   left" at the same 74 of 192 crops): it divided the time since the first crop, pause included,
//   by the crops done. Heat pauses are now left out, as on "Find animals in videos". "Last run"
//   said "1 heat pauses".
// - Mb2: crops whose photos could not be read were reported as "(the model stopped with an
//   error)" with the promise that "Continue / re-run" tries them again; the store counts them as
//   done (only a model error stays pending), so a re-run never tries them.
//
// The plugin and the temperature channels are stand-ins (as in identification_screen_race_test).

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

// Three photos, one crop each: two of track 1, one of track 2.
const _photos = ['roi_t_2026-07-14_120000_000.jpg', 'roi_t_2026-07-14_120000_500.jpg', 'roi_t_2026-07-14_120001_000.jpg'];
const _log = '''
{"type":"start_of_session","time_ms":1000,"config":{},"device":{"model":"TestPhone"}}
{"type":"detections","time_ms":2000,"tracks":[{"track_id":1,"confidence":0.9,"box_in_roi":{"left":0.1,"top":0.1,"right":0.9,"bottom":0.9},"jpeg":"roi_t_2026-07-14_120000_000.jpg"}]}
{"type":"detections","time_ms":2500,"tracks":[{"track_id":1,"confidence":0.8,"box_in_roi":{"left":0.1,"top":0.1,"right":0.9,"bottom":0.9},"jpeg":"roi_t_2026-07-14_120000_500.jpg"}]}
{"type":"detections","time_ms":3000,"tracks":[{"track_id":2,"confidence":0.7,"box_in_roi":{"left":0.1,"top":0.1,"right":0.9,"bottom":0.9},"jpeg":"roi_t_2026-07-14_120001_000.jpg"}]}
{"type":"end_of_session","time_ms":4000,"ended_normally":true}
''';

Uint8List _jpeg(int r, int g, int b) {
  final im = img.Image(width: 320, height: 320, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

/// What the phone test wrote over two photos (PB2 step d): text, not a picture.
final _damaged = Uint8List.fromList('this file is not a photo any more'.codeUnits);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  const thermalChannel = MethodChannel('faunapulse/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
  late Directory tmp;
  late List<String> calls;
  late int embedRuns;
  // Model calls (counted from 0) that fail as a closed model does on the phone.
  late Set<int> failingRuns;
  // The battery is warm from the second photo on until the test cools it.
  late bool heatAfterFirst;
  late bool cooled;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319b_identify_texts');
    IdentificationRun.resetForTest();
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    wakelockPlusPlatformInstance = FakeWakelock();
    PackageInfo.setMockInitialValues(appName: 'FaunaPulse', packageName: 'test', version: '0.0.0', buildNumber: '1', buildSignature: '');
    SharedPreferences.setMockInitialValues({'identify_model': 'test-model.tflite', 'identify_pack': 'tiny_pack.fpack'});
    calls = [];
    embedRuns = 0;
    failingRuns = {};
    heatAfterFirst = false;
    cooled = false;
    // Every read reaches the channel (no shared reading between two reads).
    var ticks = 0;
    DeviceThermal.resetForTesting();
    DeviceThermal.now = () => Duration(minutes: ticks++);
    messenger.setMockMethodCallHandler(thermalChannel, (call) async {
      final warm = heatAfterFirst && embedRuns >= 1 && !cooled;
      return {'batteryTempC': warm ? 45.0 : 30.0};
    });
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'embedderLoad':
          return {'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': pack.dim, 'loadMs': 1.0};
        case 'embedderRun':
          if (failingRuns.contains(embedRuns++)) throw PlatformException(code: 'NO_EMBEDDER', message: 'No embedder loaded');
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

  /// The session; the photos at [damaged] (indexes into [_photos]) hold text instead of a JPEG.
  Directory makeSession({Set<int> damaged = const {}}) {
    final models = Directory('${tmp.path}/identification/models')..createSync(recursive: true);
    final packs = Directory('${tmp.path}/identification/packs')..createSync(recursive: true);
    File('${models.path}/test-model.tflite').writeAsBytesSync([0]);
    File('test/fauna_pulse/fixtures/tiny_pack.fpack').copySync('${packs.path}/tiny_pack.fpack');
    final dir = Directory('${tmp.path}/sessions/meadow')..createSync(recursive: true);
    File('${dir.path}/session.jsonl').writeAsStringSync(_log);
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    for (var i = 0; i < _photos.length; i++) {
      File('${frames.path}/${_photos[i]}').writeAsBytesSync(damaged.contains(i) ? _damaged : _jpeg(200, 40 * i, 40));
    }
    return dir;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done, String what) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    if (!done()) {
      // ignore: avoid_print
      print([for (final e in find.byType(Text).evaluate()) (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()].join(' | '));
    }
    expect(done(), isTrue, reason: 'never happened: $what; plugin calls: $calls');
  }

  // The page is tall, so "Last run" is built without scrolling (a ListView builds only what is
  // near the screen).

  /// Starts the run as "Also identify them" does, shows the page (which stays on "Last run": it
  /// was not opened by a Find screen) and waits for the end.
  Future<void> runToEnd(WidgetTester tester, Directory dir) async {
    tester.view.physicalSize = const Size(360, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    IdentificationRun.autoStart(dir);
    await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: dir)));
    await pumpUntil(tester, () => find.text('Last run', skipOffstage: false).evaluate().isNotEmpty, 'the run ends');
  }

  /// The texts of the "Last run" part of the page.
  List<String> texts(WidgetTester tester) => [
    for (final e in find.byType(Text, skipOffstage: false).evaluate()) (e.widget as Text).data ?? '',
  ];

  String? leftText(WidgetTester tester) {
    final line = texts(tester).firstWhere((t) => t.startsWith('Elapsed '), orElse: () => '');
    return RegExp(r'about (.+?) left').firstMatch(line)?.group(1);
  }

  group('Mb1: heat pause and time left', () {
    testWidgets('a heat pause does not make the time left grow; "1 heat pause" and crop counts', (tester) async {
      final dir = makeSession();
      heatAfterFirst = true;
      tester.view.physicalSize = const Size(360, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      IdentificationRun.autoStart(dir);
      await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: dir)));
      await pumpUntil(tester, () => find.textContaining('Paused: Phone warm').evaluate().isNotEmpty, 'the heat pause');
      expect(find.textContaining('1 of 3 crops'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      final before = leftText(tester);
      expect(before, isNotNull, reason: 'the time left is shown during the pause: ${texts(tester)}');
      // The phone stays warm for a while: real time goes on (the old estimate counted it) and the
      // page redraws each second.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
        await tester.pump(const Duration(seconds: 1));
      }
      final stillPaused = find.textContaining('Paused: Phone warm').evaluate().isNotEmpty;
      final after = leftText(tester);
      // Cooled down: the next check (every 15 s) lets the run go on (and end, also when the
      // checks below fail, so the next test finds the model free).
      cooled = true;
      await tester.pump(const Duration(seconds: 16));
      await pumpUntil(tester, () => find.text('Last run', skipOffstage: false).evaluate().isNotEmpty, 'the run ends');
      expect(stillPaused, isTrue);
      expect(after, before, reason: 'the time left changed during the heat pause');
      final summary = texts(tester).firstWhere((t) => t.contains('identified now'));
      expect(summary, startsWith('3 crops identified now (0 done earlier, 0 skipped, 0 failed, 1 heat pause) in '));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('one crop identified: "1 crop" in "Last run"', (tester) async {
      final dir = makeSession(damaged: {1, 2});
      await runToEnd(tester, dir);
      final all = texts(tester);
      expect(all.firstWhere((t) => t.contains('identified now')), startsWith('1 crop identified now (0 done earlier, '));
      expect(all.firstWhere((t) => t.contains('identified now')), contains(', 0 heat pauses) in '));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  test('the job leaves a heat pause out of the time it reports for the crops', () async {
    final dir = makeSession();
    var reads = 0;
    final seen = <IdentifyProgress>[];
    final job = IdentificationJob(
      embed: (rgb) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return [for (final _ in rgb) Float32List.fromList(pack.matrix.sublist(0, pack.dim))];
      },
      crop: (a) async => cropBatchSync(a),
      // Warm at the second photo's check, cool at the next one: one pause of one poll.
      thermal: () async => ThermalReading(batteryTempC: ++reads == 2 ? 45.0 : 30.0),
      pausePoll: const Duration(milliseconds: 800),
    );
    final clock = Stopwatch()..start();
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
      scoreAfter: false,
      onProgress: seen.add,
    );
    expect(r.thermalPauses, 1);
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(800));
    final paused = seen.where((p) => p.stage == 'paused').toList();
    expect(paused, isNotEmpty);
    final lastEmbedding = seen.lastWhere((p) => p.stage == 'embedding');
    expect(lastEmbedding.done, 3);
    // Three photos at about 20 ms each; the 800 ms pause is not in it.
    expect(lastEmbedding.activeMs, lessThan(600), reason: 'activeMs ${lastEmbedding.activeMs}');
    expect(lastEmbedding.activeMs, greaterThanOrEqualTo(paused.first.activeMs));
  });

  group('Mb2: the reason for crops that could not be identified', () {
    testWidgets('two unreadable photos: no model error, no promise to try them again', (tester) async {
      final dir = makeSession(damaged: {0, 2});
      await runToEnd(tester, dir);
      final all = texts(tester);
      expect(all.where((t) => t.contains('the model stopped with an error')), isEmpty, reason: '$all');
      expect(
        all,
        contains('2 of 3 crops could not be identified because their photos could not be read (the files may be '
            'damaged). They are missing from the results.'),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('one unreadable photo and one model error in one run: counted apart', (tester) async {
      final dir = makeSession(damaged: {0});
      failingRuns = {0}; // the first crop that reaches the model (photo 2)
      await runToEnd(tester, dir);
      final all = texts(tester);
      expect(
        all,
        contains('1 of 3 crops could not be identified because its photo could not be read (the file may be '
            'damaged). It is missing from the results.'),
      );
      expect(
        all,
        contains('1 of 3 crops could not be identified (the model stopped with an error). It is missing from the '
            'results. "Continue / re-run" tries it again.'),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('one unreadable photo, a model error for the two others: "for every photo it could read"', (
      tester,
    ) async {
      final dir = makeSession(damaged: {0});
      failingRuns = {0, 1};
      await runToEnd(tester, dir);
      final all = texts(tester);
      expect(
        all.where(
          (t) => t.startsWith('No crop could be identified: the model stopped with an error for every photo it could read.'),
        ),
        hasLength(1),
        reason: '$all',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('every photo unreadable: not "the model stopped with an error each time"', (tester) async {
      final dir = makeSession(damaged: {0, 1, 2});
      await runToEnd(tester, dir);
      final all = texts(tester);
      expect(all.where((t) => t.contains('the model stopped with an error')), isEmpty, reason: '$all');
      expect(
        all,
        contains('3 of 3 crops could not be identified because their photos could not be read (the files may be '
            'damaged). They are missing from the results.'),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    test('a re-run does not try a crop again whose photo could not be read (why the line promises nothing)', () async {
      final dir = makeSession(damaged: {0});
      final job = IdentificationJob(
        embed: (rgb) async => [for (final _ in rgb) Float32List.fromList(pack.matrix.sublist(0, pack.dim))],
        crop: (a) async => cropBatchSync(a),
        thermal: () async => const ThermalReading(batteryTempC: 30),
      );
      const settings = IdentifyRunSettings(
        modelName: 'fake_model.tflite',
        modelId: 'fake',
        packName: 'tiny_pack.fpack',
        inputSize: 32,
        dim: 4,
        accelerator: 'CPU',
        minCropPx: 16,
        batchSize: 1,
      );
      final packFile = File('test/fauna_pulse/fixtures/tiny_pack.fpack');
      final first = await job.run(dir, settings: settings, packFile: packFile, scoreAfter: false);
      expect((first.embedded, first.failed), (2, 1));
      // Even with the photo repaired, "Continue / re-run" leaves it out.
      File('${dir.path}/roi_frames/${_photos[0]}').writeAsBytesSync(_jpeg(200, 0, 40));
      final second = await job.run(dir, settings: settings, packFile: packFile, scoreAfter: false);
      expect((second.embedded, second.failed), (0, 0));
    });
  });
}
