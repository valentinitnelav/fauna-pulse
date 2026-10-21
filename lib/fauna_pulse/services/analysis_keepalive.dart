// FaunaPulse — keep a long analysis alive while the app is in the background.
//
// Round 319 (stress test 2026-10-20, items 2 and 5): Identify was killed by MIUI 22 s after
// Home (the app used about 1.6 GB of a 3.6 GB phone), and "Find animals in videos" / "in photos"
// ran without protection too. While a hold is taken, the native AnalysisService (a foreground
// service with a silent notification and a partial wake lock, see AnalysisService.kt) tells
// Android the work is user-visible, so the run goes on in the background or with the screen off.
//
// Holds are counted: two jobs at once (or a Find run handing over to "Also identify them") keep
// the service until the last hold is released. The notification shows the newest hold's words.
// Android 12+ refuses to START a foreground service from the background, so a job must take its
// hold while the app is on screen (the tap on Start); a chained job takes its own hold BEFORE the
// first job releases, so the service never stops in between and never starts from the background.
//
// Never throws; a no-op off Android. Failures are logged with logSwallowed.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:permission_handler/permission_handler.dart';

import '../logging/app_error_hooks.dart';

/// The notification's second line, the same for every job.
const String kAnalysisKeepAliveText =
    'It continues while you use other apps or the screen is off. Open FaunaPulse to see the progress or to stop it.';
const String kFindVideosKeepAliveTitle = 'FaunaPulse is finding animals in videos';
const String kFindPhotosKeepAliveTitle = 'FaunaPulse is finding animals in photos';
const String kIdentifyKeepAliveTitle = 'FaunaPulse is identifying animals';

/// Round 319, part 2: the ordinary notification shown when "Also identify them" waits for the
/// app, because the phone has too little free memory to load the model in the background.
const String kIdentifyReminderTitle = 'Animals found';
const String kIdentifyReminderText =
    'Open FaunaPulse to identify them. The phone has too little free memory to do it in the background. '
    'If it does not start, use "Identify organisms" in the session\'s ⋮ menu on the Sessions screen.';

/// One job's claim on the analysis service. [release] is safe to call more than once.
class AnalysisKeepAliveHold {
  AnalysisKeepAliveHold._(this.title, this.text);

  final String title;
  final String text;
  bool _released = false;

  bool get released => _released;

  void release() {
    if (_released) return;
    _released = true;
    AnalysisKeepAlive._holds.remove(this);
    AnalysisKeepAlive._schedule();
  }
}

class AnalysisKeepAlive {
  AnalysisKeepAlive._();

  static const MethodChannel _channel = MethodChannel('faunapulse/keepalive');
  static final List<AnalysisKeepAliveHold> _holds = [];

  /// What the native side was last told: null = stopped, else (title, text).
  static (String, String)? _sent;
  static Future<void> _queue = Future<void>.value();

  /// Tests on the laptop set this to true to see the channel calls.
  @visibleForTesting
  static bool? debugIsAndroid;

  static bool get _android => debugIsAndroid ?? Platform.isAndroid;

  /// Takes a hold for one job (call it while the app is on screen). Returns at once; the
  /// native call follows in order with the other holds' calls.
  static AnalysisKeepAliveHold acquire({required String title, String text = kAnalysisKeepAliveText}) {
    final hold = AnalysisKeepAliveHold._(title, text);
    _holds.add(hold);
    _schedule();
    unawaited(_askNotificationPermission());
    return hold;
  }

  static bool _notificationsAsked = false;

  /// Round 319, part 3: on Android 13+ the notifications of Find and Identify (the progress,
  /// "Animals found") show only with the notification permission, which only a recording asked
  /// for. Asked once per app start, when a job starts while the app is on screen (the system
  /// dialog cannot show otherwise); the job never waits for the answer. Not asked when Android
  /// says it is denied for good: it would show no dialog.
  static Future<void> _askNotificationPermission() async {
    if (_notificationsAsked || !_android) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    _notificationsAsked = true;
    try {
      if (!(await Permission.notification.status).isDenied) return;
      await Permission.notification.request();
    } catch (e) {
      logSwallowed('analysis_notification_permission', e);
    }
  }

  /// Round 319, part 2: shows the "Animals found" notification (a tap opens the app). False when
  /// it could not be shown (no notification permission, not Android); never throws.
  static Future<bool> showIdentifyReminder() async {
    if (!_android) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('showIdentifyReminder', {
        'title': kIdentifyReminderTitle,
        'text': kIdentifyReminderText,
      });
      if (ok != true) logSwallowed('identify_reminder_show', 'the notification could not be shown');
      return ok == true;
    } catch (e) {
      logSwallowed('identify_reminder_show', e);
      return false;
    }
  }

  /// Removes that notification (safe when none is shown); never throws.
  static Future<void> cancelIdentifyReminder() async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<bool>('cancelIdentifyReminder');
    } catch (e) {
      logSwallowed('identify_reminder_cancel', e);
    }
  }

  /// Number of holds not released yet.
  static int get activeHolds => _holds.length;

  /// Completes when every native call asked for so far has been answered.
  @visibleForTesting
  static Future<void> get settled => _queue;

  /// Forgets every hold and what was sent (tests only).
  @visibleForTesting
  static void resetForTest() {
    _holds.clear();
    _sent = null;
    _notificationsAsked = false;
    _queue = Future<void>.value();
  }

  /// One call at a time, in order. Each run compares what is wanted NOW with what was sent, so a
  /// hand-over (new hold, then the old one released) and a hold released before its call went
  /// out cost no extra start or stop.
  static void _schedule() {
    _queue = _queue.then((_) => _sync());
  }

  static Future<void> _sync() async {
    if (!_android) return;
    final top = _holds.isEmpty ? null : _holds.last;
    final want = top == null ? null : (top.title, top.text);
    if (want == _sent) return;
    try {
      if (want == null) {
        await _channel.invokeMethod<bool>('stopAnalysis');
      } else {
        final ok = await _channel.invokeMethod<bool>('startAnalysis', {'title': want.$1, 'text': want.$2});
        // False: Android refused the start (the app was not on screen). The job runs on, unprotected.
        if (ok == false) logSwallowed('analysis_keepalive_start', 'the system did not allow the service');
      }
      _sent = want;
    } catch (e) {
      // Unknown native state: the next change sends again.
      _sent = (r'?', r'?');
      logSwallowed(want == null ? 'analysis_keepalive_stop' : 'analysis_keepalive_start', e);
    }
  }
}
