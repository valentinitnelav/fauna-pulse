// Round 319, part 3 (phone test P2R, a1): "Also identify them" waited for the app in memory (too
// little free memory to load the model in the background); MIUI's cleaner closed the app 62 s
// later, and the tap on "Animals found" opened a new process on Home where nothing started.
// Decided design: the waiting run writes a note (session folder, time, Find screen, attempts 0) in
// the app's files folder; when the app opens, Home takes a note younger than 24 h whose session
// still exists, sets attempts to 1 first, then opens "Identify organisms" and starts the run; a
// note with attempts 1 (the app was closed during that start) only gives one line. The note also
// guards a load in the background, and goes at the run's end, on a stop and with its session.
//
// Round 320 (decided by the owner): every other run writes the note with attempts 1 once it has
// the model, so a run that Android ends after the user left the app gives the same one line at
// the next opening, and nothing starts by itself.
//
// Only channel names, the note's file name and existing Dart names are used, so this file also
// runs against the code before the fix, where it fails (no note is written or read).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show roiPhotoFileName;
import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart' show IdentifyPrefs;
import 'package:fauna_pulse/fauna_pulse/identification/identification_run.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/models_on_phone.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/photo_tracker.dart';
import 'package:fauna_pulse/fauna_pulse/screens/analysis_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_results_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/sessions_screen.dart';
import 'package:fauna_pulse/fauna_pulse/services/analysis_keepalive.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

final _s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': _s0, ...m});

Uint8List _jpeg(int r, int g, int b) {
  final im = img.Image(width: 320, height: 320, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

const _kb = 1024;

/// P2R a1: the 3.6 GB Redmi, BioCLIP 2 on the CPU (free 935 MB, need 1249 MB): it waits.
Map<String, Object> _redmi() => {
      'fileBytes': 609000000,
      'needBytes': (609000000 * 2.15).round(),
      'onGpu': false,
      'availMem': 1000000 * _kb,
      'threshold': 471 * 1024 * _kb,
      'totalMem': 3761000000,
      'lowMemory': false,
      'memAvailable': 957000 * _kb,
    };

/// A phone with plenty free: it loads in the background.
Map<String, Object> _roomy() => {..._redmi(), 'availMem': 3600000 * _kb, 'totalMem': 7400000000, 'memAvailable': 3500000 * _kb};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const yoloChannel = MethodChannel('yolo_single_image_channel');
  const keepAliveChannel = MethodChannel('faunapulse/keepalive');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final pack = LabelPack.parseBytes(File('test/fauna_pulse/fixtures/tiny_pack.fpack').readAsBytesSync());
  late Directory tmp;
  late List<String> calls;
  late List<String> keepCalls;
  late Map<String, Object> memory;

  /// The note's place: the app's files folder (path_provider's answer here).
  File note() => File('${tmp.path}/identify_waiting.json');
  Map<String, dynamic> readNote() => jsonDecode(note().readAsStringSync()) as Map<String, dynamic>;

  /// The note's attempts when the model load was asked for (null: no note then), and its text.
  late List<Object?> attemptsAtLoad;
  String? noteAtLoad;

  /// Awaited by each embedding call when set (holds a run at a known point).
  Future<void> Function()? onRun;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319c_b_note');
    IdentificationRun.resetForTest();
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    wakelockPlusPlatformInstance = FakeWakelock();
    PackageInfo.setMockInitialValues(appName: 'FaunaPulse', packageName: 'test', version: '0.0.0', buildNumber: '1', buildSignature: '');
    SharedPreferences.setMockInitialValues({
      'identify_model': 'test-model.tflite',
      'identify_pack': 'tiny_pack.fpack',
      'find_also_identify': true,
    });
    AnalysisKeepAlive.resetForTest();
    AnalysisKeepAlive.debugIsAndroid = true;
    keepCalls = [];
    messenger.setMockMethodCallHandler(keepAliveChannel, (call) async {
      switch (call.method) {
        case 'startAnalysis':
          keepCalls.add('start');
        case 'stopAnalysis':
          keepCalls.add('stop');
        case 'showIdentifyReminder':
          keepCalls.add('reminder');
        default:
          keepCalls.add(call.method);
      }
      return true;
    });
    memory = _redmi();
    calls = [];
    attemptsAtLoad = [];
    noteAtLoad = null;
    onRun = null;
    messenger.setMockMethodCallHandler(yoloChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'embedderMemory':
          return memory;
        case 'embedderLoad':
          attemptsAtLoad.add(note().existsSync() ? readNote()['attempts'] : null);
          noteAtLoad = note().existsSync() ? note().readAsStringSync() : null;
          return {'accelerator': 'CPU', 'inputWidth': 32, 'inputHeight': 32, 'dim': pack.dim, 'loadMs': 1.0};
        case 'embedderRun':
          await onRun?.call();
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
    AnalysisKeepAlive.debugIsAndroid = null;
    for (final c in [pathChannel, yoloChannel, keepAliveChannel]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A time-lapse session, every photo analyzed, one insect with its track ID found (as
  /// r319b_m_identify_memory_test).
  Future<Directory> photoSession(WidgetTester tester, [String name = 'Salvia']) async {
    final m = Directory('${tmp.path}/identification/models')..createSync(recursive: true);
    final p = Directory('${tmp.path}/identification/packs')..createSync(recursive: true);
    File('${m.path}/test-model.tflite').writeAsBytesSync([0]);
    File('test/fauna_pulse/fixtures/tiny_pack.fpack').copySync('${p.path}/tiny_pack.fpack');
    final dir = Directory('${tmp.path}/sessions/$name')..createSync(recursive: true);
    final times = [for (var t = 0; t < 4000; t += 200) t];
    String photo(int t) => roiPhotoFileName(_s0 + t, 'tok');
    File('${dir.path}/session.jsonl').writeAsStringSync('${[
      _rec('start_of_session', {
        'file_token': 'tok',
        'config': {'captureTrigger': 'timelapse', 'stepSeconds': 0.2, 'durationSeconds': 4.0},
      }),
      for (final t in times) ...[
        _rec('timelapse_capture', {'jpeg': photo(t), 'captured_at_ms': _s0 + t}),
        _rec('capture', {'file': photo(t), 'captured_at_ms': _s0 + t, 'saved_px': 640}),
      ],
      _rec('end_of_session', {'time_ms': _s0 + 5000, 'ended_normally': true}),
    ].join('\n')}\n');
    File('${dir.path}/post_detections.jsonl').writeAsStringSync('${[
      _rec('post_start', {'model': 'm.tflite', 'model_name': 'm', 'confidence': 0.25, 'iou': 0.7}),
      for (final t in times)
        _rec('post_detection', {
          'jpeg': photo(t),
          'captured_at_ms': _s0 + t,
          'boxes': [
            if (t >= 1000 && t <= 3000)
              {
                'class_name': 'bee',
                'conf': 0.8,
                'box': [0.3, 0.3, 0.6, 0.6],
              },
          ],
        }),
    ].join('\n')}\n');
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    final jpeg = _jpeg(200, 60, 40);
    for (final t in times) {
      File('${frames.path}/${photo(t)}').writeAsBytesSync(jpeg);
    }
    await tester.runAsync(() => PhotoTracker.run(dir, const SessionConfig()));
    return dir;
  }

  Future<void> settle(WidgetTester tester, [int rounds = 30]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done, String what, {int rounds = 300}) async {
    for (var i = 0; i < rounds && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: 'never happened: $what; plugin calls: $calls; keepalive: $keepCalls');
  }

  void toBackground(WidgetTester tester) {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void toForeground(WidgetTester tester) {
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void writeNote(Directory dir, {required int attempts, Duration age = const Duration(minutes: 1)}) {
    note().writeAsStringSync(jsonEncode({
      'session_dir': dir.path,
      'created': DateTime.now().subtract(age).toUtc().toIso8601String(),
      'chain': 'videos',
      'attempts': attempts,
    }));
  }

  /// Home as the app opens (a new process after Android closed the app).
  Future<void> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final downloads = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
    toForeground(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          scan: () async => const [],
          countModels: () async => const ModelsOnPhone(),
          loadDownloads: () async => downloads,
          modelFiles: () async => const ModelFilesOnPhone(),
          modelChoice: (_) async => (detector: null, idModel: null, nameList: null),
          saveChoice: ({detector, idModel, nameList}) async {},
        ),
      ),
    );
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('waits in the background: the note is written before the service goes, and goes when the '
      'run ends in front', (tester) async {
    final dir = await photoSession(tester);
    toBackground(tester);
    final before = DateTime.now();
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => keepCalls.contains('reminder'), 'the run waits');
    expect(note().existsSync(), isTrue, reason: 'a kill now must not lose the run');
    final n = readNote();
    expect(n['session_dir'], dir.path);
    expect(n['attempts'], 0);
    final created = DateTime.parse(n['created'] as String);
    expect(created.isBefore(before.subtract(const Duration(seconds: 5))), isFalse);
    expect(n.containsKey('chain'), isTrue);

    toForeground(tester); // the in-memory wait ends: the run starts here, the note stays to its end
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(attemptsAtLoad, [0], reason: 'a kill during the load after the wait is covered too');
    expect(run.result?.embedded, greaterThan(0));
    expect(note().existsSync(), isFalse, reason: 'deleted at the end of the run');
  });

  testWidgets('loads in the background (enough free memory): the note is on disk during the load, gone at '
      'the end', (tester) async {
    final dir = await photoSession(tester);
    memory = _roomy();
    toBackground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(attemptsAtLoad, [0]);
    expect(note().existsSync(), isFalse);
    toForeground(tester);
  });

  testWidgets('the app in front: the note says attempts 1 during the load (no start by itself), gone at '
      'the end', (tester) async {
    final dir = await photoSession(tester);
    toForeground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(attemptsAtLoad, [1]);
    expect(calls, isNot(contains('embedderMemory')), reason: 'the app is in front');
    expect(note().existsSync(), isFalse, reason: 'deleted at the end of the run');
  });

  testWidgets('Start on the Identify page: the note says attempts 1 during the load, gone at the end',
      (tester) async {
    final dir = await photoSession(tester);
    toForeground(tester);
    final prefs = (await tester.runAsync(IdentifyPrefs.load))!;
    final run = IdentificationRun.start(
      dir,
      model: File('${tmp.path}/identification/models/test-model.tflite'),
      pack: File('${tmp.path}/identification/packs/tiny_pack.fpack'),
      packHeader: null,
      isClassList: false,
      prefs: prefs,
      restart: true,
    );
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(run.result?.embedded, greaterThan(0));
    expect(attemptsAtLoad, [1]);
    expect(jsonDecode(noteAtLoad!), containsPair('session_dir', dir.path));
    expect(note().existsSync(), isFalse, reason: 'deleted at the end of the run');
  });

  testWidgets('Stop, then Start again before the stopped run has ended: the new run keeps its note',
      (tester) async {
    final dir = await photoSession(tester);
    toForeground(tester);
    final prefs = (await tester.runAsync(IdentifyPrefs.load))!;
    IdentificationRun start(bool restart) => IdentificationRun.start(
          dir,
          model: File('${tmp.path}/identification/models/test-model.tflite'),
          pack: File('${tmp.path}/identification/packs/tiny_pack.fpack'),
          packHeader: null,
          isClassList: false,
          prefs: prefs,
          restart: restart,
        );
    final first = Completer<void>(), second = Completer<void>();
    int loads() => calls.where((c) => c == 'embedderLoad').length;
    onRun = () => loads() == 1 ? first.future : second.future;
    final a = start(true);
    await pumpUntil(tester, () => calls.contains('embedderRun'), 'the first run embeds');
    a.cancel();
    final b = start(false); // waits for the model
    await settle(tester, 5);
    expect(loads(), 1);
    first.complete();
    await pumpUntil(tester, () => a.finished && calls.where((c) => c == 'embedderRun').length >= 2, 'the second run embeds');
    await settle(tester, 10);
    expect(note().existsSync(), isTrue, reason: 'the stopped run must not delete the note of the next run');
    expect(readNote()['attempts'], 1);
    second.complete();
    await pumpUntil(tester, () => b.finished, 'the second run ends');
    expect(note().existsSync(), isFalse);
  });

  testWidgets('left during a run started in front, then Android closes the app: the next opening only '
      'shows the line', (tester) async {
    final dir = await photoSession(tester);
    toForeground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => calls.contains('embedderLoad'), 'the model loads');
    toBackground(tester);
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(note().existsSync(), isFalse);
    // Android closes the app during the run: its note stays as it was during the load.
    note().writeAsStringSync(noteAtLoad!);
    IdentificationRun.resetForTest();
    calls.clear();
    await openApp(tester);
    await pumpUntil(tester, () => !note().existsSync(), 'the note is deleted');
    await settle(tester, 10);
    expect(calls, isNot(contains('embedderLoad')), reason: 'nothing starts by itself');
    expect(find.byType(IdentificationScreen), findsNothing);
    expect(find.textContaining('The identification of "Salvia" stopped when FaunaPulse was closed.'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('stopped while waiting: the note goes', (tester) async {
    final dir = await photoSession(tester);
    toBackground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => keepCalls.contains('reminder'), 'the run waits');
    expect(note().existsSync(), isTrue);
    run.cancel();
    await pumpUntil(tester, () => run.finished, 'the run ends');
    expect(note().existsSync(), isFalse);
    expect(calls, isNot(contains('embedderLoad')));
    toForeground(tester);
  });

  testWidgets('"Find animals in photos" writes which Find screen started the run', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = await photoSession(tester);
    toForeground(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          initialSessionPath: dir.path,
          sessionsDir: dir.parent,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    final button = find.text('Identify the animals found');
    await pumpUntil(tester, () => find.textContaining('Salvia').evaluate().isNotEmpty, 'the session');
    await settle(tester, 10);
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    toBackground(tester);
    await tester.pump();
    await tester.tap(button);
    await pumpUntil(tester, () => keepCalls.contains('reminder'), 'the run waits');
    expect(readNote()['chain'], 'photos');
    toForeground(tester);
    await pumpUntil(tester, () => find.byType(IdentificationResultsScreen).evaluate().isNotEmpty, 'the results');
    expect(note().existsSync(), isFalse);
    await leave(tester);
  });

  testWidgets('the app opens with a note (attempts 0): attempts 1 first, then Identify organisms runs it; '
      'the notification goes, then the note', (tester) async {
    final dir = await photoSession(tester);
    writeNote(dir, attempts: 0);
    await openApp(tester);
    await pumpUntil(tester, () => find.byType(IdentificationResultsScreen).evaluate().isNotEmpty, 'the run ends on the results');
    expect(attemptsAtLoad, [1], reason: 'attempts is saved as 1 before the model loads');
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1));
    expect(calls, isNot(contains('embedderMemory')), reason: 'the app is in front');
    expect(keepCalls, contains('cancelIdentifyReminder'));
    expect(keepCalls, isNot(contains('reminder')));
    expect(note().existsSync(), isFalse, reason: 'deleted at the end of the run');
    expect(Directory('${dir.path}/identification').existsSync(), isTrue);
    await leave(tester);
  });

  testWidgets('the app opens with a note of attempts 1: no start, the note goes, one line says how to go on',
      (tester) async {
    final dir = await photoSession(tester);
    writeNote(dir, attempts: 1);
    await openApp(tester);
    await pumpUntil(tester, () => !note().existsSync(), 'the note is deleted');
    await settle(tester, 10);
    expect(calls, isNot(contains('embedderLoad')));
    expect(find.byType(IdentificationScreen), findsNothing);
    expect(keepCalls, contains('cancelIdentifyReminder'));
    expect(
      find.text('The identification of "Salvia" stopped when FaunaPulse was closed. To continue: on the Sessions '
          'screen, tap ⋮ next to this session, then "Identify organisms". It goes on where it stopped.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await leave(tester);
  });

  testWidgets('a note older than 24 h, or of a session that is gone: ignored and deleted', (tester) async {
    final dir = await photoSession(tester);
    writeNote(dir, attempts: 0, age: const Duration(hours: 25));
    await openApp(tester);
    await pumpUntil(tester, () => !note().existsSync(), 'the old note is deleted');
    await settle(tester, 10);
    expect(calls, isNot(contains('embedderLoad')));
    expect(find.byType(IdentificationScreen), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    await leave(tester);

    writeNote(Directory('${tmp.path}/sessions/deleted_meanwhile'), attempts: 0);
    await openApp(tester);
    await pumpUntil(tester, () => !note().existsSync(), 'the note of a missing session is deleted');
    await settle(tester, 10);
    expect(calls, isNot(contains('embedderLoad')));
    expect(find.byType(IdentificationScreen), findsNothing);
    await leave(tester);
  });

  testWidgets('a run waits in this process when the app comes back: Home starts no second one',
      (tester) async {
    final dir = await photoSession(tester);
    await openApp(tester);
    await settle(tester, 5);
    toBackground(tester);
    final run = IdentificationRun.autoStart(dir);
    await pumpUntil(tester, () => keepCalls.contains('reminder'), 'the run waits');
    toForeground(tester);
    await pumpUntil(tester, () => run.finished, 'the run ends');
    await settle(tester, 10);
    expect(calls.where((c) => c == 'embedderLoad'), hasLength(1), reason: 'one run only: $calls');
    expect(find.byType(IdentificationScreen), findsNothing, reason: 'Home opened no page of its own');
    expect(note().existsSync(), isFalse);
    await leave(tester);
  });

  testWidgets('deleting the session deletes its note; a note of another session stays', (tester) async {
    final root = Directory('${tmp.path}/sessions')..createSync(recursive: true);
    for (final (i, name) in ['a_first', 'b_second'].indexed) {
      final d = Directory('${root.path}/$name')..createSync();
      File('${d.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":${1000000 * (i + 1)},"config":{}}\n'
        '{"type":"end_of_session","time_ms":${1000000 * (i + 1) + 60000},"ended_normally":true}\n',
      );
    }
    writeNote(Directory('${root.path}/b_second'), attempts: 0);
    await tester.pumpWidget(MaterialApp(home: SessionsScreen(scan: () => scanPastSessions(root: root))));
    await pumpUntil(tester, () => find.text('a_first').evaluate().isNotEmpty, 'the sessions');

    Future<void> deleteOne(String name) async {
      await tester.tap(find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(SessionTile)).first,
        matching: find.byTooltip('Session actions'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await pumpUntil(tester, () => find.text(name).evaluate().isEmpty, '$name is deleted');
    }

    await deleteOne('a_first');
    expect(note().existsSync(), isTrue, reason: 'the note is of b_second');
    await deleteOne('b_second');
    await settle(tester, 5);
    expect(note().existsSync(), isFalse);
  });
}
