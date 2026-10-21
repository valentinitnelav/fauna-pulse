// Stress test (2026-10-20, races): "Identify organisms". The phone has ONE
// native identification model (ImageEmbedder: load replaces it, close
// releases it for everyone). Found bug (fixed): after Back the job went on;
// when the screen was opened again and started, two jobs shared the one
// native model, and the first job's end (embedderClose, wakelock off) cut the
// second one. Now dispose() cancels the job and a new run waits for it.
//
// The plugin channel is a stand-in: embedderLoad answers at once, each
// embedderRun waits until the test releases it.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;
  late FakeWakelock wake;
  late List<String> calls;
  late List<Completer<void>> heldRuns;
  late bool hold;
  late bool failRuns;
  final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('identify_race');
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    wakelockPlusPlatformInstance = wake = FakeWakelock();
    PackageInfo.setMockInitialValues(
      appName: 'FaunaPulse',
      packageName: 'test',
      version: '0.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    calls = [];
    heldRuns = [];
    hold = true;
    failRuns = false;
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'embedderLoad':
          return {'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': pack.dim, 'loadMs': 1.0};
        case 'embedderRun':
          final n = ((call.arguments as Map)['images'] as List).length;
          final held = Completer<void>();
          heldRuns.add(held);
          if (!hold) held.complete();
          await held.future;
          // The native side answers this when its model was closed under the run (phone log).
          if (failRuns) throw PlatformException(code: 'NO_EMBEDDER', message: 'No embedder loaded; call embedderLoad first');
          // Every crop is pack row 0.
          return {
            'dim': pack.dim,
            'count': n,
            'vectors': Float32List.fromList([for (var i = 0; i < n; i++) ...pack.matrix.sublist(0, pack.dim)]),
            'ms': 1.0,
          };
        case 'embedderClose':
          return null;
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(yoloChannel, null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory makeSession() {
    final models = Directory('${tmp.path}/identification/models')..createSync(recursive: true);
    final packs = Directory('${tmp.path}/identification/packs')..createSync(recursive: true);
    File('${models.path}/test-model.tflite').writeAsBytesSync([0]);
    File('test/fauna_pulse/fixtures/tiny_pack.fpack').copySync('${packs.path}/tiny_pack.fpack');
    final dir = Directory('${tmp.path}/sessions/meadow')..createSync(recursive: true);
    File('${dir.path}/session.jsonl').writeAsStringSync(_log);
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    File('${frames.path}/roi_t_2026-07-14_120000_000.jpg').writeAsBytesSync(_jpeg(220, 30, 30));
    File('${frames.path}/roi_t_2026-07-14_120000_500.jpg').writeAsBytesSync(_jpeg(200, 40, 40));
    File('${frames.path}/roi_t_2026-07-14_120001_000.jpg').writeAsBytesSync(_jpeg(30, 30, 220));
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

  Future<void> releaseAll(WidgetTester tester) async {
    hold = false;
    for (var round = 0; round < 20; round++) {
      for (final h in heldRuns) {
        if (!h.isCompleted) h.complete();
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> setUpScreen(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'identify_model': 'test-model.tflite',
      'identify_pack': 'tiny_pack.fpack',
    });
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('stress: Identify organisms races', () {
    testWidgets('one run loads, embeds and closes the model once (reference)', (tester) async {
      await setUpScreen(tester);
      final session = makeSession();
      await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
      await pumpUntil(tester, () => calls.contains('embedderRun'), 'the run reaches embedding');
      expect(wake.on, isTrue);
      await releaseAll(tester);
      await pumpUntil(tester, () => calls.contains('embedderClose'), 'the run ends');
      expect(calls.where((c) => c == 'embedderLoad').length, 1);
      expect(wake.on, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
      'Back during a run stops the job',
      (tester) async {
        await setUpScreen(tester);
        final session = makeSession();
        await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
        await pumpUntil(tester, () => calls.contains('embedderRun'), 'the run reaches embedding');
        // The screen goes away (Back) while the native model embeds.
        await tester.pumpWidget(const SizedBox());
        final runsAtBack = calls.where((c) => c == 'embedderRun').length;
        await releaseAll(tester);
        await pumpUntil(tester, () => calls.contains('embedderClose'), 'the job ends');
        expect(calls.where((c) => c == 'embedderRun').length, runsAtBack,
            reason: 'the job embedded more crops after Back: $calls');
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets(
      'system Back during a run asks first; Stop and leave closes the page and stops the job',
      (tester) async {
        await setUpScreen(tester);
        final session = makeSession();
        await tester.pumpWidget(MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => IdentificationScreen(sessionDir: session, autoStart: true)),
              ),
              child: const Text('open'),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await pumpUntil(tester, () => calls.contains('embedderRun'), 'the run reaches embedding');
        // The system Back gesture: the page must stay and ask.
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Identification is still running'), findsOneWidget);
        expect(find.byType(IdentificationScreen), findsOneWidget);
        await tester.tap(find.text('Stop and leave'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(IdentificationScreen), findsNothing);
        final runsAtLeave = calls.where((c) => c == 'embedderRun').length;
        await releaseAll(tester);
        await pumpUntil(tester, () => calls.contains('embedderClose'), 'the job ends');
        expect(calls.where((c) => c == 'embedderRun').length, runsAtLeave,
            reason: 'the job embedded more crops after Stop and leave: $calls');
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets(
      'a second run started after Back is not cut by the end of the first',
      (tester) async {
        await setUpScreen(tester);
        final session = makeSession();
        await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
        await pumpUntil(tester, () => calls.contains('embedderRun'), 'run 1 reaches embedding');
        await tester.pumpWidget(const SizedBox());
        // The screen is opened again and starts again (one-Start path).
        await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
        // Run 2 waits until run 1 has stopped and closed the model, so run 1's
        // embedding call (heldRuns[0]) returns first.
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        heldRuns[0].complete();
        await pumpUntil(
          tester,
          () => calls.where((c) => c == 'embedderRun').length >= 2,
          'run 2 reaches embedding',
        );
        final run2Started = calls.lastIndexOf('embedderLoad');
        expect(calls.sublist(0, run2Started), contains('embedderClose'),
            reason: 'run 2 loaded the model while run 1 still used it: $calls');
        // Run 1's embedding calls return now (every held call but run 2's
        // first, heldRuns[1]); run 2 is still busy with its first batch.
        for (var i = 0; i < 40; i++) {
          for (var j = 0; j < heldRuns.length; j++) {
            if (j != 1 && !heldRuns[j].isCompleted) heldRuns[j].complete();
          }
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        final afterRun2Started = calls.sublist(run2Started);
        // ignore: avoid_print
        print('plugin calls: $calls; wakelock on: ${wake.on}');
        expect(afterRun2Started.contains('embedderClose'), isFalse,
            reason: 'run 1 closed the native model under run 2: $calls');
        expect(wake.on, isTrue, reason: 'run 1 switched the screen-on lock off while run 2 runs');
        await releaseAll(tester);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets(
      'a run whose crops all fail says so and does not open empty results',
      (tester) async {
        await setUpScreen(tester);
        final session = makeSession();
        failRuns = true;
        hold = false;
        await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
        await pumpUntil(tester, () => calls.contains('embedderClose'), 'the run ends');
        await releaseAll(tester);
        // The one-Start path stays on the screen (no results page) and names the failed crops
        // ("Last run" is at the end of the list, built only when scrolled to).
        expect(find.byType(IdentificationScreen), findsOneWidget);
        // Round 319 (decision D5): the words for a run where every crop failed.
        final warning = find.textContaining('No crop could be identified: the model stopped with an error each time.');
        await tester.scrollUntilVisible(warning, 300, scrollable: find.byType(Scrollable).first);
        expect(warning, findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets(
      'two quick taps on Start start one run',
      (tester) async {
        await setUpScreen(tester);
        final session = makeSession();
        await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session)));
        final start = find.text('Start');
        await pumpUntil(
          tester,
          () => find.textContaining('Name list tiny-test', skipOffstage: false).evaluate().isNotEmpty && start.evaluate().isNotEmpty,
          'the model, the name list and the Start button',
        );
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.ensureVisible(start);
        await tester.pump();
        // Start first saves the settings and reads this session's stored crops
        // (files; slow for a large session on a phone) before it marks the
        // screen busy; its _starting guard must ignore a second tap in that gap.
        // Here the files are small, so the second tap comes before the next frame.
        await tester.tap(start);
        await tester.tap(start, warnIfMissed: false);
        await releaseAll(tester);
        expect(calls.where((c) => c == 'embedderLoad').length, 1, reason: 'plugin calls: $calls');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  });
}
