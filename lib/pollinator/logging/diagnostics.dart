// Pollinator Monitor — diagnostics bridge.
//
// Thin wrapper over the native `pollinator/diagnostics` channel. Right now its
// only job is to capture this app's own recent log output ("logcat") so it can
// be bundled into an error report. A non-rooted Android app can only read its
// own process logs, which is exactly what we want for debugging this app.

import 'package:flutter/services.dart';

class Diagnostics {
  static const MethodChannel _channel = MethodChannel('pollinator/diagnostics');

  /// Captures up to [maxLines] of the most recent app log lines (timestamped).
  /// Returns null on any failure (e.g. iOS, or the platform refuses the dump).
  static Future<String?> captureLogcat({int maxLines = 3000}) async {
    try {
      return await _channel.invokeMethod<String>('captureLogcat', {
        'maxLines': maxLines,
      });
    } catch (_) {
      return null;
    }
  }
}
