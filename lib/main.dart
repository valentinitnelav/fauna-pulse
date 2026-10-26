// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license
//
// FaunaPulse: app entry point, started from the Ultralytics YOLO Flutter
// plugin's example app.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fauna_pulse/fauna_pulse/logging/app_error_hooks.dart';
import 'package:fauna_pulse/fauna_pulse/models/file_download.dart';
import 'package:fauna_pulse/fauna_pulse/models/former_model_names.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart' show deleteVideoImportLeftovers;
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait only (round 124, with android:screenOrientation in the
  // manifest): the capture/rotation math assumes an upright phone
  // (uprightHighResDims, rawRectForUprightRect and its Kotlin mirror), and
  // the preview overlays overflow in landscape. Lift both locks together if
  // landscape support is ever built.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // Route uncaught errors into the active session's JSONL (and keep the app
  // alive on uncaught async errors) — a field crash must always leave a trace.
  installGlobalErrorHooks();
  // Model files downloaded before round 314 get the names of the download
  // list, before any screen looks for them.
  await renameFormerModelFiles();
  // Half downloads cut off by an app kill; awaited so no screen can start
  // a download (whose .part file this would delete) before it is done.
  await deleteLeftoverModelPartFiles();
  // Video copies left by a kill while picking or importing videos (round
  // 319); awaited for the same reason.
  await deleteVideoImportLeftovers();
  runApp(const FaunaPulseApp());
}

class FaunaPulseApp extends StatelessWidget {
  const FaunaPulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // State restoration (round 325): Android closes background apps to free
      // memory (MIUI's cleaner did so seconds after a link opened the
      // browser), and on return the app started over on Home. With a scope
      // id, routes pushed with `restorablePush` (and `RestorableRouteFuture`)
      // reopen from the small note Android keeps for a closed app; swiping
      // the app away deletes that note, so Home stays the fresh start. A
      // restorable route comes back only if every route below it is
      // restorable too.
      restorationScopeId: 'app',
      title: 'FaunaPulse',
      themeMode: ThemeMode.dark,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
