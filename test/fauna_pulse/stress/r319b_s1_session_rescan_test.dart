// Round 319 part 2 (S1a, phone test PB2 11:56 and monkey crash 2026-10-21 11:50:55):
// "Find animals in videos" > a session chosen > "Import other videos…" > Back out of
// the system picker without choosing. The screen read the sessions again but kept the
// chosen one from before the read, an object no longer in the list, and the session
// list failed ("There should be exactly one item with [DropdownButton]'s value").

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../video_test_fakes.dart';

class _FakePaths extends PathProviderPlatform {
  final String path;
  _FakePaths(this.path);

  @override
  Future<String?> getTemporaryPath() async => path;

  @override
  Future<String?> getExternalStoragePath() async => path;
}

/// The system picker left with Back: nothing chosen.
class _BackPicker extends ImagePickerPlatform {
  var opened = 0;

  @override
  Future<List<XFile>> getMultiVideoWithOptions({MultiVideoPickerOptions options = const MultiVideoPickerOptions()}) async {
    opened++;
    return const [];
  }
}

const _thermal = MethodChannel('faunapulse/thermal');

Directory _session(Directory root, String name) {
  final dir = Directory('${root.path}/$name');
  Directory('${dir.path}/videos').createSync(recursive: true);
  File('${dir.path}/videos/a.mp4').writeAsStringSync('video');
  File('${dir.path}/session.jsonl').writeAsStringSync(
    [
      '{"type":"start_of_session","time_ms":1000,"source":"imported_video"}',
      jsonEncode({'type': 'video_clip', 'time_ms': 1000, 'file': 'videos/a.mp4', 'duration_ms': 30000, 'width': 640, 'height': 480}),
      '{"type":"end_of_session","time_ms":31000,"ended_normally":true}',
    ].join('\n'),
  );
  return dir;
}

void main() {
  late Directory tmp;
  late _BackPicker picker;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319b_s1_rescan');
    Directory('${tmp.path}/cache').createSync();
    PathProviderPlatform.instance = _FakePaths('${tmp.path}/cache');
    picker = _BackPicker();
    ImagePickerPlatform.instance = picker;
    VideoPlayerPlatform.instance = FakeVideoPlayer();
    wakelockPlusPlatformInstance = FakeWakelock();
    DeviceThermal.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _thermal,
      (call) async => {'freeBytes': 20 << 30, 'totalBytes': 64 << 30, 'batteryTempC': 30.0},
    );
    SharedPreferences.setMockInitialValues({'find_also_identify': false});
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_thermal, null);
    DeviceThermal.resetForTesting();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('Back out of "Import other videos…": the chosen session stays chosen, no failure', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = Directory('${tmp.path}/sessions')..createSync();
    _session(sessions, 'Echium');
    final chosen = _session(sessions, 'Salvia');
    await tester.pumpWidget(
      MaterialApp(
        home: VideoAnalysisScreen(
          initialSessionPath: chosen.path,
          sessionsDir: sessions,
          models: const [ModelEntry(id: 'test_model', name: 'test_model.tflite', source: ModelSource.bundled)],
        ),
      ),
    );
    await settle(tester);
    expect(find.textContaining('Salvia (1 clip'), findsOneWidget);

    await tester.tap(find.text('Import other videos…'));
    await settle(tester);

    expect(picker.opened, 1);
    expect(tester.takeException(), isNull);
    // Still Salvia, and the screen goes on working with it.
    expect(find.textContaining('Salvia (1 clip'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Analyze 1 clip'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Analyze 1 clip'), findsOneWidget);
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await tester.pump();

    // Picking another session afterwards works too.
    await tester.tap(find.textContaining('Salvia (1 clip'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.textContaining('Echium (1 clip').last);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Echium (1 clip'), findsOneWidget);
  });
}
