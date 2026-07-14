// FaunaPulse — global uncaught-error hooks.
//
// Field sessions run unattended; if the app hits an error nobody caught, the
// default behaviour is either a silent console line (framework errors) or a
// crash (uncaught async errors) — both invisible after a day in the field.
// These hooks route every uncaught error into the active session's JSONL log
// (as an `app_error` line) so a misbehaving session always leaves a trace
// next to its own data.
//
// Installed once from main() before runApp. The camera screen points
// [appErrorSink] at the live SessionLogger while recording and clears it on
// stop, so errors outside a session are only printed, never lost silently.

import 'package:flutter/foundation.dart';

/// Where uncaught errors are reported while a session is recording.
/// Set by the camera session screen (to `SessionLogger.logAppError`) when
/// recording starts; reset to null when it stops. Null = no active session.
void Function(Map<String, dynamic> payload)? appErrorSink;

int _lastReportMs = 0;
int _suppressedSinceLast = 0;

/// Rate-limited forwarder: an error thrown every frame (10–30×/s) must not
/// flood the JSONL, so at most one record every 2 s is written and the number
/// of records dropped in between is carried on the next one.
void _report(String source, String message, StackTrace? stack) {
  final sink = appErrorSink;
  if (sink == null) return;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - _lastReportMs < 2000) {
    _suppressedSinceLast++;
    return;
  }
  final suppressed = _suppressedSinceLast;
  _lastReportMs = now;
  _suppressedSinceLast = 0;
  // The sink writes to disk; if that write itself fails the logger's own
  // guard swallows it — but never let a broken sink take down the handler.
  try {
    sink({
      'source': source,
      'message': message,
      if (stack != null) 'stack': _headLines(stack.toString(), 12),
      if (suppressed > 0) 'suppressed_since_last': suppressed,
    });
  } catch (_) {
    // Reporting is best-effort by definition.
  }
}

// Last debugPrint per call site, so a failure repeating every second (e.g. a
// broken thermal channel polled at 1 Hz) cannot flood logcat.
final Map<String, int> _lastSwallowedPrintMs = {};

/// Call from a `catch` that intentionally swallows a best-effort failure
/// (camera probes, platform channels, cleanup) so it still leaves a trace
/// (review B7). It debugPrints — which lands in logcat and therefore in the
/// session folder's `logcat_end.txt` — at most once per 10 s per [site], and
/// while a session is recording also writes a rate-limited `app_error` JSONL
/// line. So "the lens button did nothing all day" is diagnosable afterwards.
void logSwallowed(String site, Object error, [StackTrace? stack]) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - (_lastSwallowedPrintMs[site] ?? 0) >= 10000) {
    _lastSwallowedPrintMs[site] = now;
    debugPrint('Best-effort $site failed: $error');
  }
  _report(site, '$error', stack);
}

/// Resets the rate-limiter state so tests don't suppress each other.
@visibleForTesting
void resetAppErrorRateLimitsForTest() {
  _lastReportMs = 0;
  _suppressedSinceLast = 0;
  _lastSwallowedPrintMs.clear();
}

String _headLines(String text, int maxLines) {
  final lines = text.split('\n');
  if (lines.length <= maxLines) return text;
  return '${lines.take(maxLines).join('\n')}\n…';
}

/// Installs the two process-wide traps. Call once from main() before runApp.
///
/// - `FlutterError.onError` catches errors thrown inside the Flutter
///   framework (build/layout/paint callbacks).
/// - `PlatformDispatcher.onError` catches every other uncaught error,
///   including errors from `async` code nobody awaited. Returning true tells
///   Flutter the error was handled, so one background hiccup (e.g. a failed
///   photo save) can no longer bring down a running session.
void installGlobalErrorHooks() {
  final previousFlutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    // Keep the default console dump for `flutter run` debugging.
    previousFlutterHandler?.call(details);
    _report('flutter_framework', details.exceptionAsString(), details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught async error: $error\n$stack');
    _report('uncaught_async', '$error', stack);
    return true;
  };
}
