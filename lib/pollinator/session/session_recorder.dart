// Pollinator Monitor — recording-session lifecycle, extracted from the camera
// screen (round 73, review item B6b).
//
// Owns everything one recording session puts on disk and keeps alive: the
// session folder, the append-only JSONL logger, the ROI-photo scheduler, the
// screen wakelock + keep-alive foreground service, and the ordered stop
// sequence (critical records first, best-effort diagnostics after). The
// camera screen keeps the UI around it: timers, banners, the REC clock, and
// the start-metadata values that are really screen state.

import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../capture/roi_capture.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../logging/device_thermal.dart';
import '../logging/diagnostics.dart';
import '../logging/session_logger.dart';
import '../models/track.dart';
import '../services/recording_keepalive.dart';

/// Runs the disk/lifecycle side of one recording session. One instance lives
/// as long as the camera screen and is started/stopped once per session.
class SessionRecorder {
  /// The live session logger, or null when not recording. The screen writes
  /// its own periodic records (thermal, fps, power, ROI updates, app errors)
  /// through this.
  SessionLogger? get logger => _logger;
  SessionLogger? _logger;

  RoiCaptureScheduler? _capture;

  /// True while a session is being recorded. Flips false at the very START of
  /// [stop] (plain assignment, no async gap) so the frame path stops logging
  /// instantly — [stop] also runs unawaited from the screen's dispose().
  bool get recording => _recording;
  bool _recording = false;

  /// True while [stop] is mid-flight, so a quick second tap can't fall into
  /// the "start recording" branch while teardown is still running.
  bool get stopping => _stopping;
  bool _stopping = false;

  int _lastFlushMs = 0;

  /// Starts a session: creates the session folder + `roi_frames/`, opens the
  /// logger, routes global uncaught errors into it, writes the start record,
  /// builds the photo scheduler, and turns on wakelock + keep-alive service.
  /// On return, [recording] is true and the frame path may log.
  ///
  /// [startMetadata] is called right before the start record is written and
  /// supplies the screen-state fields (model, ROI, thresholds, config…);
  /// device/battery/storage/thermal are read here. [onStartReadings] hands
  /// the fresh start readings back so the screen can update its gauges.
  /// [captureBuilder] builds the [RoiCaptureScheduler] — its capture
  /// functions and ROI provider are screen wiring. [onLogWriteError] fires
  /// (possibly repeatedly) when the log can no longer be written, e.g.
  /// storage full; an `app_error` line is attempted here either way.
  Future<void> start({
    required String folderName,
    required Map<String, dynamic> Function() startMetadata,
    required RoiCaptureScheduler Function(Directory framesDir, String fileToken)
    captureBuilder,
    required void Function(Object error) onLogWriteError,
    void Function(ThermalReading thermal, StorageReading storage)?
    onStartReadings,
  }) async {
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    // Per-session random token embedded in every photo filename (see
    // roiPhotoFileName): two phones capturing in the same millisecond can
    // only collide if they also drew the same 4 base-36 chars (~1 in 1.7 M).
    // Logged as `file_token` below so photos stay traceable to their session
    // even after folders from several phones are merged.
    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    final rng = Random.secure();
    final fileToken = String.fromCharCodes(
      Iterable.generate(4, (_) => alphabet.codeUnitAt(rng.nextInt(36))),
    );

    final dir = await _resolveSessionDir(folderName);
    final framesDir = Directory('${dir.path}/roi_frames');
    framesDir.createSync(recursive: true);

    final logger = SessionLogger(File('${dir.path}/session.jsonl'))..open();
    // If the storage fills up (or access is revoked) mid-session, the logger
    // swallows the write failure instead of crashing the frame callback
    // (see SessionLogger). Log it best-effort (the line lands if the failure
    // turns out to be transient) and let the screen surface its banner.
    logger.onWriteError = (error) {
      debugPrint('Session log write failed: $error');
      logger.logAppError({
        'source': 'session_log',
        'message': 'Log write failed (storage full or inaccessible): $error',
      });
      onLogWriteError(error);
    };
    // Route global uncaught errors (see app_error_hooks.dart) into this
    // session's JSONL for the whole recording, including the stop sequence.
    appErrorSink = (payload) => logger.logAppError(payload);

    final battery = await _safeBatteryLevel();
    final device = await _safeDeviceDescriptor();
    // Fresh battery/power reading so the start `thermal` block carries an
    // accurate baseline charge counter + voltage (the start↔end
    // charge-counter drop is the ground-truth for the session-total energy
    // estimate).
    final startReading = await DeviceThermal.read();
    // Free storage on the session volume at start: with the periodic samples
    // in the thermal records this gives the session's disk fill rate.
    final startStorage = await DeviceStorage.read(path: dir.path);
    onStartReadings?.call(startReading, startStorage);
    logger.logStart({
      'session_id': sessionId,
      'file_token': fileToken,
      'device': device,
      'battery_percent': battery,
      ...startStorage.toJson(),
      ...startMetadata(),
      'thermal': startReading.toJson(),
    });

    _capture = captureBuilder(framesDir, fileToken);

    await WakelockPlus.enable();
    // Keep the OS from sleeping/killing this long session: a foreground
    // service (with an ongoing notification) protects the process. Ask for
    // the notification permission first (Android 13+) so the notification can
    // show; the service still runs either way.
    await Permission.notification.request();
    await RecordingKeepAlive.start();

    _logger = logger;
    _recording = true;
  }

  /// Ordered so the records that matter most land earliest (B3): when this
  /// runs unawaited from dispose() — or the OS is in the middle of killing
  /// the app — every step it manages to reach must have been more important
  /// than the ones after it. Critical path first (end_of_session on disk,
  /// error routing off, keep-alive service down), best-effort diagnostics
  /// after, and each remaining step guarded so a mid-teardown failure can't
  /// abort the rest.
  ///
  /// [uniqueTrackCount] is the tracker's confirmed-track total for the
  /// end_of_session record (the tracker lives with the screen's frame path).
  ///
  /// [retainKeepAlive] keeps the foreground service + wakelock running after
  /// the session closes. Used between the windows of a scheduled run: the
  /// process must stay protected (and the ongoing notification visible) all
  /// the way to the run's end, or the OS could kill the sleeping app before
  /// the next window. The final stop of the run passes false as usual.
  Future<void> stop({
    required bool normal,
    required int uniqueTrackCount,
    bool retainKeepAlive = false,
  }) async {
    if (_stopping) return;
    _stopping = true;
    // Stop the frame path from logging new records right away.
    _recording = false;
    // End-of-session readings, time-bounded: a hung platform channel (mid
    // camera teardown) must not stall the stop sequence and with it the
    // end_of_session record.
    int? battery;
    var endReading = const ThermalReading();
    try {
      battery = await _safeBatteryLevel().timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      // Fresh closing reading so the end `thermal` block carries the final
      // charge counter — the start↔end drop is the battery-drain estimate.
      endReading = await DeviceThermal.read().timeout(
        const Duration(seconds: 2),
        onTimeout: () => const ThermalReading(),
      );
    } catch (e) {
      // Best-effort: the end record is worth more than its extras.
      logSwallowed('end_thermal_read', e);
    }
    _logger?.logEnd({
      'ended_normally': normal,
      'battery_percent': battery,
      'unique_track_count': uniqueTrackCount,
      'thermal': endReading.toJson(),
    });
    // Waits for the writer queue to drain, so end_of_session is on disk.
    await _logger?.close();
    // The log is closed: stop routing global uncaught errors to it.
    appErrorSink = null;
    // Tear down the keep-alive foreground service + its notification —
    // unless a scheduled run is still going and needs the protection.
    if (!retainKeepAlive) {
      try {
        await RecordingKeepAlive.stop();
      } catch (e) {
        debugPrint('Keep-alive stop failed: $e');
      }
    }
    // Best-effort extras, after the critical path. The logcat capture
    // (throttle-era native logs + persisted PERF lines) writes its own file
    // in the session folder, so it doesn't need the logger to be open.
    try {
      await saveLogcat('logcat_end.txt');
    } catch (e) {
      debugPrint('logcat_end.txt failed: $e');
    }
    if (!retainKeepAlive) {
      try {
        await WakelockPlus.disable();
      } catch (e) {
        logSwallowed('wakelock_disable', e);
      }
    }
    _stopping = false;
  }

  /// Logs every confirmed track this frame — as ONE `detections` record with
  /// a `tracks` array (round 69) — and triggers a shared ROI photo when one
  /// is due. The photo filename is written into the covered tracks' entries
  /// so post-processing can join them directly. Returns true when a photo was
  /// triggered (the screen blinks its capture cue on it). No-op unless
  /// [recording].
  bool recordFrame(List<Track> tracks, Rect roiRect, int ts) {
    if (!_recording) return false;
    final pending = _capture?.evaluate(tracks, ts);
    if (tracks.isNotEmpty) {
      _logger?.logDetections([
        for (final t in tracks)
          {
            'track_id': t.id,
            'class_index': t.classIndex,
            'class_name': t.className,
            'confidence': t.confidence,
            'box_in_roi': _boxInRoi(t.box, roiRect),
            if (pending != null && pending.trackIds.contains(t.id))
              'jpeg': pending.fileName,
          },
      ]);
    }
    // Ask for an fsync at most ~twice a second rather than every frame: the
    // logger's writer loop drains queued lines within the same event-loop
    // turn, so this bounds what a sudden power/battery loss could drop to
    // ~0.5 s without paying a disk sync per frame.
    if (tracks.isNotEmpty && ts - _lastFlushMs >= 500) {
      _logger?.flushNow();
      _lastFlushMs = ts;
    }
    if (pending != null) {
      // Fire-and-forget; the scheduler serializes its own work.
      _capture?.capture(pending);
      return true;
    }
    return false;
  }

  /// Motion-only capture mode counterpart of [recordFrame]: called once per
  /// awake motion event from the stream (the detector never runs, so there are
  /// no tracks). Triggers a scheduler photo when one is due and logs a
  /// `motion_capture` record for it. Returns true when a photo was triggered
  /// (the screen blinks its capture cue on it). No-op unless [recording].
  bool recordMotionFrame(int ts, {required double motionScore}) {
    if (!_recording) return false;
    final pending = _capture?.evaluateMotion(ts);
    if (pending == null) return false;
    _logger?.logMotionCapture({
      'jpeg': pending.fileName,
      'motion_score': motionScore,
    });
    // Fire-and-forget; the scheduler serializes its own work.
    _capture?.capture(pending);
    return true;
  }

  /// Motion-only capture mode: the gate just went idle, so the current motion
  /// event is over — re-arm the scheduler so the next wake starts a fresh
  /// photo burst. `_capture` only exists while recording; no-op otherwise.
  void onMotionGateIdle() => _capture?.resetMotionWindow();

  /// Time-lapse mode (round 97): a new burst cycle begins — re-arm the shared
  /// capture window so the burst's first photo fires immediately.
  void beginTimeLapseBurst() => _capture?.resetMotionWindow();

  /// Time-lapse mode: one call per driving-timer tick while a burst is
  /// active. The scheduler's shared window (same one motion mode uses)
  /// provides the first-photo-immediately / step / duration cadence, so timer
  /// jitter cannot double-photograph. Logs a `timelapse_capture` record per
  /// trigger. Returns true when a photo was triggered. No-op unless
  /// [recording].
  bool recordTimeLapseFrame(int ts, {required int burstIndex}) {
    if (!_recording) return false;
    final pending = _capture?.evaluateMotion(ts);
    if (pending == null) return false;
    _logger?.logTimeLapseCapture({
      'jpeg': pending.fileName,
      'burst': burstIndex,
    });
    // Fire-and-forget; the scheduler serializes its own work.
    _capture?.capture(pending);
    return true;
  }

  /// Saves the app's own recent logcat to a file in the session folder, so an
  /// *uncoupled* run (no `flutter run`) still preserves the native engine
  /// decision (e.g. "GPU… falling back to CPU: Failed to compile model") and
  /// the per-second PERF lines. Best-effort; silently skips if the platform
  /// refuses (e.g. iOS) or no logger/dir is available.
  Future<void> saveLogcat(String fileName, {int maxLines = 5000}) async {
    final dir = _logger?.file.parent;
    if (dir == null) return;
    final text = await Diagnostics.captureLogcat(maxLines: maxLines);
    if (text == null || text.isEmpty) return;
    try {
      await File('${dir.path}/$fileName').writeAsString(text, flush: true);
    } catch (e) {
      // Diagnostics are best-effort; never let them break a recording.
      logSwallowed('save_logcat', e);
    }
  }

  /// Expresses a normalized frame box as coordinates inside the ROI (0..1),
  /// per CLAUDE.md (boxes are stored relative to the ROI they were found in).
  static Map<String, double> _boxInRoi(Rect box, Rect roi) {
    final rw = roi.width == 0 ? 1.0 : roi.width;
    final rh = roi.height == 0 ? 1.0 : roi.height;
    return {
      'left': (box.left - roi.left) / rw,
      'top': (box.top - roi.top) / rh,
      'right': (box.right - roi.left) / rw,
      'bottom': (box.bottom - roi.top) / rh,
    };
  }

  /// Creates `…/Android/data/<pkg>/files/sessions/<folder>/` (USB-visible).
  /// A numeric suffix is added if the folder already exists.
  Future<Directory> _resolveSessionDir(String folderName) async {
    final base =
        (await getExternalStorageDirectory()) ??
        await getApplicationDocumentsDirectory();
    final safe = folderName.trim().isEmpty
        ? 'session'
        : folderName.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '_');
    var dir = Directory('${base.path}/sessions/$safe');
    var i = 2;
    while (dir.existsSync()) {
      dir = Directory('${base.path}/sessions/${safe}_$i');
      i++;
    }
    dir.createSync(recursive: true);
    return dir;
  }

  Future<int?> _safeBatteryLevel() async {
    try {
      return await Battery().batteryLevel;
    } catch (e) {
      logSwallowed('battery_level', e);
      return null;
    }
  }

  Future<Map<String, dynamic>> _safeDeviceDescriptor() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return {
          'platform': 'android',
          'model': a.model,
          'manufacturer': a.manufacturer,
          'id': a.id,
          'android_sdk': a.version.sdkInt,
        };
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        return {
          'platform': 'ios',
          'model': i.utsname.machine,
          'name': i.name,
          'id': i.identifierForVendor,
        };
      }
    } catch (e) {
      logSwallowed('device_info', e);
    }
    return {'platform': Platform.operatingSystem};
  }
}
