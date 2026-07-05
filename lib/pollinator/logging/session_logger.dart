// Pollinator Monitor — append-only session log.
//
// We write one JSON object per line ("JSONL" / newline-delimited JSON). Unlike a
// single big JSON array, JSONL can be *appended* to without rewriting the file,
// so a crash or dead battery never corrupts what was already saved — the file is
// simply missing its final "end_of_session" line, which is exactly how we detect
// an abnormal stop. R reads it with `jsonlines`/`readr::read_lines`; Python with
// the `jsonlines` package or `pandas.read_json(lines=True)`.
//
// Every line carries a `type` ("start_of_session" | "roi_update" | "detection" |
// "end_of_session") plus machine (`time_ms`) and human-readable (`time_iso`)
// timestamps. After each write we flush to disk for durability.

import 'dart:convert';
import 'dart:io';

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

  /// Appends one record: adds `type` and timestamps, encodes, writes a line.
  /// When [flush] is true the line is forced to disk immediately (use for the
  /// important start/roi/end records). High-frequency detection lines pass
  /// false and are flushed once per frame via [flushNow] to avoid an fsync on
  /// every detection at 30 fps.
  ///
  /// Never throws on I/O failure: this runs inside the per-frame detection
  /// callback, where an uncaught "disk full" exception would kill exactly the
  /// long unattended sessions most likely to fill the disk. Failures are
  /// counted and surfaced once via [onWriteError] instead.
  void _append(
    String type,
    Map<String, dynamic> payload, {
    DateTime? at,
    bool flush = true,
  }) {
    final raf = _raf;
    if (raf == null) {
      throw StateError('SessionLogger.open() must be called before logging');
    }
    final now = at ?? DateTime.now();
    final record = <String, dynamic>{
      'type': type,
      'time_ms': now.millisecondsSinceEpoch,
      'time_iso': isoWithOffset(now),
      ...payload,
    };
    try {
      final inject = debugInjectWriteError;
      if (inject != null) throw inject;
      raf.writeStringSync('${jsonEncode(record)}\n');
      if (flush) raf.flushSync();
    } catch (e) {
      _onWriteFailure(e);
    }
  }

  /// Forces any buffered writes to disk. Call once per processed frame after
  /// the frame's detection lines. Guarded like [_append]: a failed fsync must
  /// not crash the frame callback.
  void flushNow() {
    try {
      _raf?.flushSync();
    } catch (e) {
      _onWriteFailure(e);
    }
  }

  void _onWriteFailure(Object error) {
    writeFailures++;
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

  /// One active detection (track id, class, box relative to the ROI, and any
  /// JPEG saved at this moment). Not flushed per line; [flushNow] flushes the
  /// whole frame's worth at once.
  void logDetection(Map<String, dynamic> payload, {DateTime? at}) =>
      _append('detection', payload, at: at, flush: false);

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

  /// Closes the file handle. Best-effort: a failing flush must not prevent
  /// the handle from being released (or the stop sequence from finishing).
  void close() {
    try {
      _raf?.flushSync();
    } catch (e) {
      _onWriteFailure(e);
    }
    try {
      _raf?.closeSync();
    } catch (_) {
      // Nothing useful left to do with a handle that won't close.
    }
    _raf = null;
  }
}
