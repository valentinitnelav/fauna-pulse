// FaunaPulse (round 300): on-device check of the FaunaLapse photo-session import. Needs a
// FaunaLapse "Pack" zip pushed into the app's own folder first, e.g.
//   adb -s <serial> push <session>.zip /sdcard/Android/data/com.faunapulse.app/files/faunalapse_check/
// The check imports every zip there in a background isolate (as the Sessions menu does),
// then checks that the session is listed as a time-lapse with every photo in its index, and
// opens its summary (SHOT summary). The imported session stays; the zips are deleted.
// Run:  flutter test integration_test/faunalapse_import_check_test.dart -d <serial> --no-uninstall

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/faunalapse_import.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a FaunaLapse zip becomes a time-lapse session', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final base = (await getExternalStorageDirectory())!.path;
    final inbox = Directory('$base/faunalapse_check');
    final zips = inbox.existsSync()
        ? [for (final f in inbox.listSync().whereType<File>()) if (f.path.endsWith('.zip')) f.path]
        : <String>[];
    expect(zips, isNotEmpty, reason: 'push a FaunaLapse zip into $base/faunalapse_check first');
    final root = await sessionsRoot();
    final sw = Stopwatch()..start();
    final r = await importFaunaLapseZipsInBackground(zips, root);
    _log('IMPORTED ${r.folder}: ${r.photos} photos, ${r.missingPhotos} missing, ${r.sitePhotos} site photos in ${sw.elapsedMilliseconds} ms');
    final listed = (await scanPastSessions()).where((s) => s.name == r.folder).toList();
    expect(listed, hasLength(1));
    expect(listed.single.kind, RecordingKind.timeLapse);
    final index = await SessionLogIndex.build(listed.single.logFile);
    _log('INDEX photos ${index.photoOrder.length}');
    expect(index.photoOrder, hasLength(r.photos));
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: SessionSummaryScreen(logFile: listed.single.logFile)),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    _log('SHOT summary');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpWidget(const SizedBox());
    inbox.deleteSync(recursive: true);
    _log('CHECK PASSED');
  });
}
