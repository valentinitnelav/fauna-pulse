// Pollinator Monitor — keep a long recording session alive on Android.
//
// Wraps the native `pollinator/keepalive` method channel (see MainActivity.kt /
// RecordingService.kt). Two jobs, both about surviving multi-hour / multi-day
// field runs without the OS interfering:
//
//  1. A **foreground service** with an ongoing notification — the standard Android
//     way to tell the system "this is important user-visible work, don't kill it".
//     Started when recording begins, stopped when it ends.
//  2. **Battery-optimization exemption** — checking, and (once) asking the user to
//     grant, an exemption so aggressive OEM "battery managers" (notably MIUI /
//     Xiaomi) don't doze or kill the app.
//
// All methods are no-ops on non-Android platforms, and never throw (the channel
// is best-effort: if the native side is missing, recording still works, just
// without the extra protection).

import 'dart:io';

import 'package:flutter/services.dart';

class RecordingKeepAlive {
  RecordingKeepAlive._();

  static const MethodChannel _channel = MethodChannel('pollinator/keepalive');

  /// Starts the recording foreground service (persistent notification + partial
  /// wake lock). Safe to call more than once.
  static Future<void> start() => _invoke('startService');

  /// Stops the recording foreground service.
  static Future<void> stop() => _invoke('stopService');

  /// Whether the app is currently exempt from battery optimization. Returns true
  /// on non-Android platforms (nothing to restrict there).
  static Future<bool> isUnrestricted() async {
    if (!Platform.isAndroid) return true;
    try {
      return (await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog asking the user to allow the app to run without
  /// battery restrictions. Returns whether a system screen could be launched.
  static Future<bool> requestUnrestricted() async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _invoke(String method) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (_) {
      // Best-effort: recording continues even if the keep-alive channel fails.
    }
  }
}
