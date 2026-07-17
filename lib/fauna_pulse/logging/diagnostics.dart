// FaunaPulse — diagnostics bridge.
//
// Thin wrapper over the native `faunapulse/diagnostics` channel: captures
// this app's own recent log output ("logcat") for error reports, and opens
// an email app with a report file attached. A non-rooted Android app can
// only read its own process logs, which is exactly what we want for
// debugging this app.

import 'package:flutter/services.dart';

import 'app_error_hooks.dart';

class Diagnostics {
  static const MethodChannel _channel = MethodChannel('faunapulse/diagnostics');

  /// Captures up to [maxLines] of the most recent app log lines (timestamped).
  /// Returns null on any failure (e.g. iOS, or the platform refuses the dump).
  static Future<String?> captureLogcat({int maxLines = 3000}) async {
    try {
      return await _channel.invokeMethod<String>('captureLogcat', {
        'maxLines': maxLines,
      });
    } catch (e) {
      logSwallowed('logcat_capture', e);
      return null;
    }
  }

  /// Opens an email app with [to], [subject] and the file at [path] already
  /// attached. Needed because the share sheet cannot pre-fill a recipient.
  /// Returns false when no email app could be opened.
  static Future<bool> sendEmail({
    required String path,
    required String to,
    required String subject,
    required String body,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('sendEmail', {
            'path': path,
            'to': to,
            'subject': subject,
            'body': body,
          }) ??
          false;
    } catch (e) {
      logSwallowed('report_send_email', e);
      return false;
    }
  }
}
