// Pollinator Monitor — append-only session log.
//
// We write one JSON object per line ("JSONL" / newline-delimited JSON). Unlike a
// single big JSON array, JSONL can be *appended* to without rewriting the file,
// so a crash or dead battery never corrupts what was already saved — the file is
// simply missing its final "end_of_session" line, which is exactly how we detect
// an abnormal stop. R reads it with `jsonlines`/`readr::read_lines`; Python with
// the `jsonlines` package or `pandas.read_json(lines=True)`.
//
// Every line carries a `type` ("start_of_session" | "roi_update" |
// "detections" | "end_of_session" | …) plus machine (`time_ms`) and
// human-readable (`time_iso`) timestamps.
//
// Writes never run on the UI thread (round 69). Records are encoded, put in a
// small in-memory queue, and drained by ONE async writer loop: everything a
// frame logged becomes a single `writeString` call, and Dart performs async
// file I/O on the VM's background I/O thread pool — so a slow flash-storage
// moment stalls the writer loop, never the frame callback. Records that ask
// for durability (start/roi/end/error) trigger an fsync after their batch.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Formats [dt] as ISO-8601 with millisecond precision and the local UTC
/// offset, e.g. `2026-06-13T19:03:12.123+02:00`.
String isoWithOffset(DateTime dt) {
  final t = dt.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final datePart =
      '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}';
  final timePart =
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  final off = t.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final offH = two(off.inHours.abs());
  final offM = two(off.inMinutes.abs() % 60);
  return '${datePart}T$timePart$sign$offH:$offM';
}

class SessionLogger {
  final File file;
  RandomAccessFile? _raf;

  // Encoded lines waiting for the writer loop, plus the loop's future (null
  // when no loop is running). Single-isolate, so no locking is needed: the
  // queue is only touched between awaits.
  final List<String> _queue = [];
  Future<void>? _drainFuture;
  bool _flushRequested = false;
  bool _closed = false;

  /// Called (at most once per logger) the first time a write to disk fails —
  /// e.g. the storage filled up mid-session or the OS revoked access. Writes
  /// keep being *attempted* after that (if the user frees space the log simply
  /// resumes), but each failed line is dropped instead of crashing the
  /// per-frame detection callback that logging runs inside of.
  void Function(Object error)? onWriteError;

  /// How many individual log lines were lost to write failures.
  int writeFailures = 0;

  /// True once at least one write has failed (see [onWriteError]).
  bool get hasWriteError => _writeErrorNotified;
  bool _writeErrorNotified = false;

  /// Test seam: when set, every append throws this instead of writing, which
  /// lets tests simulate a full disk without needing one.
  Exception? debugInjectWriteError;

  SessionLogger(this.file);

  /// Opens (or creates) the log file for appending. Safe to call once.
  void open() {
    file.parent.createSync(recursive: true);
    _raf = file.openSync(mode: FileMode.append);
  }

  /// Appends one record: adds `type` and timestamps, encodes, and queues the
  /// line for the async writer loop (see the file header). When [flush] is
  /// true an fsync is requested after the batch containing this line (use for
  /// the important start/roi/end records); high-frequency detection lines
  /// pass false and rely on the periodic [flushNow].
  ///
  /// Never throws on I/O failure: logging is driven from the per-frame
  /// detection callback, where an uncaught "disk full" exception would kill
  /// exactly the long unattended sessions most likely to fill the disk.
  /// Failures are counted and surfaced once via [onWriteError] instead.
  void _append(
    String type,
    Map<String, dynamic> payload, {
    DateTime? at,
    bool flush = true,
  }) {
    if (_closed) {
      // A straggler after the session ended (late platform event, watchdog
      // tick racing the stop sequence): drop it quietly — the file is done.
      return;
    }
    if (_raf == null) {
      throw StateError('SessionLogger.open() must be called before logging');
    }
    final now = at ?? DateTime.now();
    final record = <String, dynamic>{
      'type': type,
      'time_ms': now.millisecondsSinceEpoch,
      'time_iso': isoWithOffset(now),
      ...payload,
    };
    _queue.add(jsonEncode(record));
    if (flush) _flushRequested = true;
    _drainFuture ??= _drain();
  }

  /// Requests an fsync ("force what the OS has buffered onto the actual
  /// flash storage") after the current queue is written. Called about twice
  /// a second from the frame path; awaiting the returned future is only
  /// needed in tests.
  Future<void> flushNow() {
    _flushRequested = true;
    return _drainFuture ??= _drain();
  }

  /// The single writer loop. Starts with a zero-delay yield so every record
  /// the current frame logs joins the same batch (one write call per frame,
  /// not one per record). A failed batch is dropped and counted — the loop
  /// keeps going, so logging resumes by itself if storage frees up.
  Future<void> _drain() async {
    await Future<void>.delayed(Duration.zero);
    while (true) {
      final raf = _raf;
      if (raf == null) break; // closed; close() drains before releasing.
      if (_queue.isEmpty && !_flushRequested) break;
      final lines = List<String>.of(_queue);
      _queue.clear();
      final doFlush = _flushRequested;
      _flushRequested = false;
      try {
        final inject = debugInjectWriteError;
        if (inject != null) throw inject;
        if (lines.isNotEmpty) {
          await raf.writeString('${lines.join('\n')}\n');
        }
        if (doFlush) await raf.flush();
      } catch (e) {
        _onWriteFailure(e, linesLost: lines.length);
      }
    }
    _drainFuture = null;
  }

  void _onWriteFailure(Object error, {int linesLost = 1}) {
    writeFailures += linesLost;
    if (_writeErrorNotified) return;
    _writeErrorNotified = true;
    onWriteError?.call(error);
  }

  /// First record: session-wide metadata and the initial ROI.
  void logStart(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('start_of_session', payload, at: at);

  /// Recorded whenever the user moves/resizes the ROI mid-session.
  void logRoiUpdate(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('roi_update', payload, at: at);

  /// Motion-gate transition (state: "idle" when the detector went to sleep,
  /// "awake" when it resumed, plus the idle duration on wake). Gated periods
  /// carry no detection entries by design; these lines make that auditable
  /// when validating gated sessions against always-on ones.
  void logMotionGate(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('motion_gate', payload, at: at);

  /// All active detections of one processed frame, as a single record with a
  /// `tracks` array — one entry per tracked insect (track id, class, box
  /// relative to the ROI, and any JPEG saved for it at this moment). One
  /// record per frame instead of one per track (round 69): concurrent tracks
  /// used to mean several encode+write calls per frame on the UI thread.
  /// (Sessions from round 68 and earlier carry per-track `detection` records
  /// instead — postprocessing should accept both.)
  /// Not flushed per line; [flushNow] handles durability every ~0.5 s.
  void logDetections(List<Map<String, dynamic>> tracks, {DateTime? at}) =>
      _append('detections', {'tracks': tracks}, at: at, flush: false);

  /// A motion-only-mode photo trigger: the saved JPEG's name plus the motion
  /// score that fired it. The detector never runs in that mode, so there are
  /// no tracks/boxes — the `capture` record that follows carries timing/size/
  /// saved_px as usual. The photo key is named `jpeg` on purpose, matching the
  /// link detections records use, so postprocessing joins the same way.
  void logMotionCapture(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('motion_capture', payload, at: at);

  /// A time-lapse-mode photo trigger (round 97): the saved JPEG's name plus
  /// the burst cycle it belongs to. Clock-driven — no detector, no motion
  /// check; the `capture` record that follows carries timing/size as usual.
  /// Same `jpeg` key convention as motion/detections records.
  void logTimeLapseCapture(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('timelapse_capture', payload, at: at);

  /// A periodic phone-temperature sample taken during the session (battery °C
  /// and OS thermal status), so heat can be correlated with the recording.
  void logThermal(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('thermal', payload, at: at);

  /// A periodic frame-rate sample for the end-of-session FPS graph. Logged on its
  /// own (separately from [logThermal]) so the two can be sampled at independent
  /// intervals. Sampled off the inference path, so flushing each line is fine.
  void logFps(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('fps', payload, at: at);

  /// A periodic battery-power sample (watts now, plus current/voltage and the
  /// remaining charge counter) for the end-of-session energy graphs. Logged on
  /// its own timer so the cadence is independent of temperature/FPS. Off the
  /// inference path, so flushing each line is fine.
  void logPower(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('power', payload, at: at);

  /// A single ROI-photo save event: how long the grab+crop+write took, the byte
  /// size, whether it was a full-resolution still, and the track ids it covered.
  /// Lets the end-of-session diagnostics tell whether photo-saving contributes to
  /// any frame-rate dip. Off the inference path, so flushing each line is fine.
  void logCapture(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('capture', payload, at: at);

  /// Any error surfaced to the user during a recording (the red banner, a
  /// native detector error, …). Field sessions run unattended and banners can
  /// be brief — writing them here means "I saw an error flash but couldn't
  /// read it" can always be answered from the session file (round 65).
  void logAppError(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('app_error', payload, at: at);

  /// Final record. `ended_normally: true` is written only on a clean stop;
  /// its absence (the line never got written) signals a crash.
  void logEnd(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('end_of_session', payload, at: at);

  /// Drains everything still queued (`end_of_session` included), then closes
  /// the file handle. Best-effort: a failing flush must not prevent the
  /// handle from being released (or the stop sequence from finishing).
  Future<void> close() async {
    // From here on new appends are dropped (see _append); what's already
    // queued still gets drained below.
    _closed = true;
    _flushRequested = true;
    while (_drainFuture != null) {
      await _drainFuture;
    }
    try {
      await _raf?.flush();
    } catch (e) {
      _onWriteFailure(e, linesLost: 0);
    }
    try {
      await _raf?.close();
    } catch (e) {
      // Nothing useful left to do with a handle that won't close — and this
      // logger is the one shutting down, so a print is the only trace left.
      debugPrint('Best-effort session_log_close failed: $e');
    }
    _raf = null;
  }
}
