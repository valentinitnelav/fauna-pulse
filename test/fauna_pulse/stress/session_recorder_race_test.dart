// Stress test (2026-10-20, races): SessionRecorder.start sets `recording`
// only at its very end, after several waits for the phone (battery, thermal,
// storage, wakelock, keep-alive service). These tests overlap two calls the
// way a quick double tap on REC, or leaving the camera screen while a
// recording starts, would.
//
// The phone's channels answer after a short delay (as on a real phone), so
// the second call arrives while the first one still waits.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The plain path_provider channel refuses getExternalStorageDirectory off Android.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart' show RoiCaptureMode;
import 'package:fauna_pulse/fauna_pulse/session/session_recorder.dart';

import '../video_test_fakes.dart';

/// Every app folder is one temporary folder.
class _FakePaths extends PathProviderPlatform {
  final String path;
  _FakePaths(this.path);

  @override
  Future<String?> getExternalStoragePath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late FakeWakelock wakelock;
  late List<String> keepAliveCalls;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const thermalChannel = MethodChannel('faunapulse/thermal');
  const keepAliveChannel = MethodChannel('faunapulse/keepalive');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('faunapulse_recorder_race');
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    PathProviderPlatform.instance = _FakePaths(tmp.path);
    // A real phone answers in a few milliseconds; the delay lets two calls overlap.
    messenger.setMockMethodCallHandler(thermalChannel, (call) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return null;
    });
    keepAliveCalls = [];
    messenger.setMockMethodCallHandler(keepAliveChannel, (call) async {
      keepAliveCalls.add(call.method);
      return null;
    });
    wakelock = FakeWakelock();
    WakelockPlusPlatformInterface.instance = wakelock;
  });

  tearDown(() {
    for (final c in [pathChannel, thermalChannel, keepAliveChannel]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    tmp.deleteSync(recursive: true);
  });

  RoiCaptureScheduler capture(Directory dir, String token) => RoiCaptureScheduler(
    framesDir: dir,
    sessionToken: token,
    stepMs: 1000,
    durationMs: 5000,
    mode: RoiCaptureMode.fast,
    targetPx: 640,
    fastCaptureFn: () async => Uint8List(0),
    highResCaptureFn: () async => null,
    roiProvider: () => Roi.defaultRoi,
    streamDims: () => (1280, 960),
    highResDims: () => (0, 0),
  );

  Future<void> start(SessionRecorder r) => r.start(
    folderName: 'race',
    startMetadata: () => {'test': true},
    captureBuilder: capture,
    onLogWriteError: (_) {},
  );

  List<Directory> sessionDirs() {
    final base = Directory('${tmp.path}/sessions');
    if (!base.existsSync()) return [];
    return base.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
  }

  List<String> recordTypes(Directory d) {
    final f = File('${d.path}/session.jsonl');
    if (!f.existsSync()) return [];
    return [
      for (final l in f.readAsLinesSync())
        if (l.trim().isNotEmpty) (jsonDecode(l) as Map)['type'] as String,
    ];
  }

  group('stress: SessionRecorder races', () {
    test('one start then one stop: one folder, start and end records, wakelock off (reference)', () async {
      final r = SessionRecorder();
      await start(r);
      expect(r.recording, isTrue);
      expect(wakelock.on, isTrue);
      await r.stop(normal: true, uniqueTrackCount: 0);
      expect(r.recording, isFalse);
      expect(wakelock.on, isFalse);
      final dirs = sessionDirs();
      expect(dirs, hasLength(1));
      // Here the battery and app-info channels are missing; their swallowed
      // failures are logged as app_error lines, so only the other types count.
      final types = recordTypes(dirs.single).where((t) => t != 'app_error').toList();
      expect(types.first, 'start_of_session');
      expect(types.last, 'end_of_session');
    });

    test('two starts that overlap (double tap on REC) make only one session', () async {
      final r = SessionRecorder();
      final first = start(r);
      // The second start is refused, so the screen arms no timers for it.
      await expectLater(start(r), throwsStateError);
      await first;
      expect(r.recording, isTrue);
      await r.stop(normal: true, uniqueTrackCount: 0);
      final dirs = sessionDirs();
      final summary = {for (final d in dirs) d.path.split('/').last: recordTypes(d)};
      expect(dirs, hasLength(1), reason: 'session folders: $summary');
      for (final e in summary.entries) {
        expect(e.value.last, 'end_of_session', reason: '${e.key} has no end record: ${e.value}');
      }
    });

    test('a stop that arrives while start is still running ends the recording', () async {
      final r = SessionRecorder();
      final starting = start(r);
      // The screen's dispose() calls stop only `if (_recording)`; here we call it
      // anyway, to see that even a direct stop cannot win against a running start.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await r.stop(normal: false, uniqueTrackCount: 0);
      await starting;
      expect(r.recording, isFalse, reason: 'the recorder must not be recording after stop');
      expect(wakelock.on, isFalse, reason: 'wakelock left on after stop');
      expect(keepAliveCalls.where((m) => m == 'startService').length,
          keepAliveCalls.where((m) => m == 'stopService').length,
          reason: 'keep-alive service calls: $keepAliveCalls');
    });
  });
}
