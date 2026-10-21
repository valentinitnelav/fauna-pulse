// Round 319 (stress test round 318, report items 3, 8, 17 and 18): what
// "Find animals in videos" says on screen.
// - A detector model that cannot be loaded: a plain message, not "could not be
//   read" (item 3).
// - Storage full while the results are written (item 8).
// - The time left when the session log does not give a clip's length: never
//   "~0 s left" (item 17).
// - The Back question during a heat pause (item 18).
//
// The YOLO plugin's channels are stand-ins: the default one, and the one of
// the detector instance the screen makes (named after its id).

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

const _yolo = MethodChannel('yolo_single_image_channel');
const _thermal = MethodChannel('faunapulse/thermal');

File _real(String path) => File.fromRawPath(Uint8List.fromList(utf8.encode(path)));

/// The results file on /dev/full: every write fails with "No space left".
class _FullDiskFile implements File {
  @override
  final String path;
  _FullDiskFile(this.path);

  @override
  bool existsSync() => _real(path).existsSync();

  @override
  Stream<List<int>> openRead([int? start, int? end]) => _real(path).openRead(start, end);

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      _real('/dev/full').openWrite(mode: FileMode.append, encoding: encoding);

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) => _real('/dev/full').openSync(mode: FileMode.writeOnlyAppend);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('$invocation');
}

final class _FullDisk extends IOOverrides {
  @override
  File createFile(String path) => path.endsWith(VideoDetector.outputFileName) ? _FullDiskFile(path) : _real(path);
}

Future<void> _pumpUntil(WidgetTester tester, Finder ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
    if (ready.evaluate().isNotEmpty) break;
  }
  expect(ready, findsWidgets, reason: 'never appeared: $ready');
}

void main() {
  late List<String> calls;
  late Object? openError;
  late int? clipLengthMs;
  late double tempC;
  final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 64, height: 48)));
  var nextPts = 0;

  Future<Object?> instance(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'loadModel':
        return true;
      case 'videoInfo':
        return {'durationMs': clipLengthMs, 'width': 640, 'height': 480, 'frameCount': 9000, 'firstPtsUs': 0};
      case 'videoThumbnail':
        return jpeg;
      case 'videoOpen':
        nextPts = 0;
        if (openError case final e?) throw e;
        return null;
      case 'videoNext':
        // Some real time per chunk, so "ms per frame" is above 0, and a wait
        // on the test's clock, so the screen gets to draw between chunks.
        sleep(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final pts = nextPts;
        nextPts += 200000;
        return {
          'frames': [
            {'pts': pts, 'frame': pts ~/ 33333, 'boxes': <Object>[]},
          ],
          'done': false,
          'decoded': 6,
          'frameWidth': 640,
          'frameHeight': 480,
          'names': ['insect'],
        };
    }
    return null;
  }

  setUp(() {
    VideoPlayerPlatform.instance = FakeVideoPlayer();
    wakelockPlusPlatformInstance = FakeWakelock();
    DeviceThermal.resetForTesting();
    calls = [];
    openError = null;
    clipLengthMs = 300000;
    tempC = 30;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_yolo, (call) async {
      if (call.method == 'createInstance') {
        final id = (call.arguments as Map)['instanceId'] as String;
        messenger.setMockMethodCallHandler(MethodChannel('yolo_single_image_channel_$id'), instance);
        return null;
      }
      if (call.method == 'inspectModel') return {'task': 'detect'};
      return instance(call);
    });
    messenger.setMockMethodCallHandler(_thermal, (call) async => {'batteryTempC': tempC});
  });
  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_yolo, null);
    messenger.setMockMethodCallHandler(_thermal, null);
    DeviceThermal.resetForTesting();
  });

  /// One imported clip; [withLength]: its length is in session.jsonl.
  Directory session(Directory tmp, {required bool withLength}) {
    final dir = Directory('${tmp.path}/Echium');
    Directory('${dir.path}/videos').createSync(recursive: true);
    File('${dir.path}/videos/a.mp4').writeAsStringSync('video');
    File('${dir.path}/session.jsonl').writeAsStringSync(
      [
        '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}',
        jsonEncode({'type': 'video_clip', 'time_ms': 1000, 'file': 'videos/a.mp4', if (withLength) 'duration_ms': 300000, 'width': 640, 'height': 480}),
        '{"type":"end_of_session","time_ms":31000,"ended_normally":true}',
      ].join('\n'),
    );
    return dir;
  }

  /// Opens the screen (behind a first page, so Back can leave it) and taps
  /// Start.
  Future<void> start(WidgetTester tester, {bool withLength = true}) async {
    SharedPreferences.setMockInitialValues({'find_also_identify': false});
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tmp = Directory.systemTemp.createTempSync('r319_l2_video_screen');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final dir = session(tmp, withLength: withLength);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VideoAnalysisScreen(
                    initialSessionPath: dir.path,
                    sessionsDir: tmp,
                    models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final button = find.text('Analyze 1 clip');
    await _pumpUntil(tester, find.text('Area to analyze'));
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    await tester.tap(button);
  }

  /// Closes the screen (which stops a run that is still going) and lets the
  /// run end.
  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(seconds: 1));
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets('item 3: a model that cannot be loaded is said plainly, not as unreadable clips', (tester) async {
    openError = PlatformException(code: 'model_error', message: 'Failed to compile model');
    await start(tester);
    await _pumpUntil(tester, find.byType(SnackBar));
    expect(
      find.text(
        'The detector model could not be loaded. The file may be damaged. On the "Download & import models" '
        'screen, delete it, then download or import it again.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('could not be read'), findsNothing);
    expect(find.textContaining('Failed to compile'), findsNothing, reason: 'no raw error text');
    await stop(tester);
  });

  testWidgets('item 8: storage full while writing the results', (tester) async {
    await IOOverrides.runWithIOOverrides(() async {
      await start(tester);
      await _pumpUntil(tester, find.byType(SnackBar));
      expect(find.text('Storage full: the analysis stopped. What is done is kept. Free some space, then press Continue.'), findsOneWidget);
      expect(find.textContaining('FileSystemException'), findsNothing);
      await stop(tester);
    }, _FullDisk());
  });

  testWidgets('item 17: the time left uses the clip\'s own length when the session log has none', (tester) async {
    await start(tester, withLength: false);
    await _pumpUntil(tester, find.textContaining('ms per frame'));
    await _pumpUntil(tester, find.textContaining(' left'));
    final line = tester.widget<Text>(find.textContaining('ms per frame')).data!;
    expect(line, isNot(contains('~0 s left')), reason: line);
    expect(line, contains('5:00'), reason: 'the clip length is shown: $line');
    await stop(tester);
  });

  testWidgets('item 17: no number when the clip length cannot be read at all', (tester) async {
    clipLengthMs = null;
    await start(tester, withLength: false);
    await _pumpUntil(tester, find.textContaining('ms per frame'));
    final line = tester.widget<Text>(find.textContaining('ms per frame')).data!;
    expect(line, isNot(contains('~0 s left')), reason: line);
    expect(line, contains('time left not known yet'), reason: line);
    await stop(tester);
  });

  testWidgets('item 18: Back during a heat pause says it is paused', (tester) async {
    tempC = 45;
    await start(tester);
    await _pumpUntil(tester, find.textContaining('Paused: Phone warm'));
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('The analysis is paused'), findsOneWidget);
    expect(
      find.text(
        'The phone is cooling down, so the analysis is paused. Leaving stops it. What is done is kept, '
        'and Continue goes on from there.',
      ),
      findsOneWidget,
    );
    expect(find.text('The detector is still running'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Stop and leave'), findsOneWidget);
    await tester.tap(find.text('Stop and leave'));
    await tester.pump();
    await stop(tester);
  });
}
