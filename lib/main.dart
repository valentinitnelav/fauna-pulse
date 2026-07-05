// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license
//
// Pollinator Monitor — app entry point. Built on the Ultralytics YOLO Flutter
// plugin; the original showcase screens still live under presentation/ for
// reference but are no longer the launch route.

import 'package:flutter/material.dart';
import 'package:pollinator_monitor/pollinator/logging/app_error_hooks.dart';
import 'package:pollinator_monitor/pollinator/screens/home_screen.dart';

void main() {
  // Route uncaught errors into the active session's JSONL (and keep the app
  // alive on uncaught async errors) — a field crash must always leave a trace.
  installGlobalErrorHooks();
  runApp(const PollinatorApp());
}

class PollinatorApp extends StatelessWidget {
  const PollinatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pollinator Monitor',
      themeMode: ThemeMode.dark,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
