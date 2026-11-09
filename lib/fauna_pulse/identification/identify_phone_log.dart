// FaunaPulse (round 363): the phone's state while Identify ran.
//
// Before, the identification showed the temperature live and saved nothing.
// This writes the phone's readings (the one DeviceThermal reading:
// temperatures, heat level, power, memory, processor cores) into
// identification/phone_during_identification.jsonl every
// [kIdentifySampleEvery], through both steps of a run ("crops": the crops go
// through the model; "results": the crops are combined per track ID) and
// through the heat pauses. The records have the shapes VideoDetector writes
// for a video analysis (`thermal`, `power`, a speed record, pause and resume),
// so one parser (VideoRunSamples) reads both files and the summary draws both
// with the same graphs.
//
// The file is appended to, run after run: a run that was stopped, or closed
// by Android, keeps its lines, and the next run adds its own
// `identify_run_start`. The readings never stop an identification: without
// the file, or after a failed write, the run goes on unmeasured.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/app_error_hooks.dart';
import '../logging/device_thermal.dart';
import '../logging/thermal_pause.dart';
import '../postprocess/video_detector.dart' show VideoDetector;
import '../postprocess/video_run_samples.dart';
import 'identification_store.dart';

/// Time between two saved readings of an Identify run: the live camera's and
/// the video analysis's default, so the graphs of the three compare. Fixed,
/// not a setting (owner's choice); every run's start record carries it
/// (`sample_s`), so a setting can come later without a change to the file.
const kIdentifySampleEvery = Duration(seconds: 10);

class IdentifyPhoneLog {
  final IdentificationPaths _paths;
  final ThermalFn _thermal;
  final Duration every;
  final DateTime Function() _now;

  /// Null before [start], after [close], and after a failed write.
  RandomAccessFile? _out;
  Timer? _timer;
  bool _started = false;
  String _step = 'crops';
  DateTime? _pauseStart;

  // What the next speed record reports: the crops since the previous one.
  DateTime _periodStart = DateTime.fromMillisecondsSinceEpoch(0);
  int _crops = 0, _pausedMs = 0;
  double _modelMs = 0;

  IdentifyPhoneLog(
    Directory sessionDir, {
    ThermalFn? thermal,
    this.every = kIdentifySampleEvery,
    DateTime Function()? now,
  }) : _paths = IdentificationPaths(sessionDir),
       _thermal = thermal ?? DeviceThermal.read,
       _now = now ?? DateTime.now;

  /// Runs [work], a scoring without the model (the "Update results" button),
  /// as a run of its own in the readings file.
  static Future<T> during<T>(
    Directory sessionDir, {
    required Map<String, dynamic> run,
    required Future<T> Function() work,
  }) async {
    final log = IdentifyPhoneLog(sessionDir);
    await log.start(run, step: 'results');
    String? error;
    try {
      return await work();
    } catch (e) {
      error = '$e';
      rethrow;
    } finally {
      await log.end(error: error);
    }
  }

  /// Opens the file, writes the run's start record ([run]: model, name list
  /// and so on) and the first sample, and starts the clock of the samples.
  ///
  /// A timer, not the job's own readings: the job reads the phone once per
  /// photo, which is many seconds apart with a slow model on the CPU, and the
  /// "results" step has no loop on this isolate at all. All readings share
  /// the one native call (DeviceThermal caches it for 0.9 s).
  Future<void> start(Map<String, dynamic> run, {String step = 'crops'}) async {
    if (_started) return;
    _started = true;
    _step = step;
    try {
      _paths.dir.createSync(recursive: true);
      final out = _paths.phoneJsonl.openSync(mode: FileMode.append);
      _out = out;
      VideoDetector.endOnWholeLine(out);
    } catch (e) {
      logSwallowed('identify_phone_log', e);
      close();
      return;
    }
    _periodStart = _now();
    _write('identify_run_start', {...run, 'step': step, 'sample_s': every.inSeconds});
    await sample();
    if (_out != null) _timer = Timer.periodic(every, (_) => unawaited(sample()));
  }

  void _write(String type, Map<String, dynamic> rec, {int? atMs}) {
    final out = _out;
    if (out == null) return;
    try {
      // One synchronous write per record, as in VideoDetector: a failed write
      // (storage full) shows here, and no line is left half-written in a buffer.
      out.writeStringSync('${jsonEncode({'type': type, 'time_ms': atMs ?? _now().millisecondsSinceEpoch, ...rec})}\n');
    } catch (e) {
      logSwallowed('identify_phone_log', e);
      close();
    }
  }

  /// Reads the phone and writes one sample: `thermal` and `power` as in
  /// video_detections.jsonl, and `identify_speed` when a crop was finished or
  /// the run waited to cool down since the previous speed record. Called by
  /// the timer and where a step ends. Never throws.
  Future<void> sample() async {
    if (_out == null) return;
    ThermalReading? r;
    try {
      r = await _thermal();
    } catch (e) {
      logSwallowed('identify_phone_read', e);
    }
    if (_out == null) return; // closed while the phone was read
    final t = _now();
    final at = t.millisecondsSinceEpoch;
    final pauseStart = _pauseStart;
    if (r != null) {
      _write('thermal', {...r.toJson(), 'step': _step, if (pauseStart != null) 'paused': true}, atMs: at);
      _write('power', {
        'power_w': r.powerW,
        'battery_current_ua': r.batteryCurrentUa,
        'battery_voltage_mv': r.batteryVoltageMv,
        'charge_counter_uah': r.chargeCounterUah,
        'is_charging': r.isCharging,
        'is_plugged': r.isPlugged,
      }, atMs: at);
    }
    final pausedMs = _pausedMs + (pauseStart == null ? 0 : _since(pauseStart, t));
    // A period without a finished crop writes nothing and goes on: with a slow
    // model a crop takes longer than the sample interval, and periods cut at
    // every sample would read as a speed that jumps between zero and too high.
    if (_crops == 0 && pausedMs == 0) return;
    final periodMs = t.difference(_periodStart).inMilliseconds;
    _write('identify_speed', {
      'step': _step,
      'period_ms': periodMs,
      'crops': _crops,
      'crops_per_s': periodMs > 0 ? (_crops * 1000000 / periodMs).round() / 1000 : 0,
      if (_crops > 0) 'model_ms': (_modelMs / _crops * 10).round() / 10,
      if (pausedMs > 0) 'paused_ms': pausedMs,
    }, atMs: at);
    _periodStart = t;
    _crops = _pausedMs = 0;
    _modelMs = 0;
  }

  /// The part of a pause that began at [from] inside the current speed period.
  int _since(DateTime from, DateTime to) => to.difference(from.isAfter(_periodStart) ? from : _periodStart).inMilliseconds;

  /// [crops] went through the model in [modelMs].
  void addCrops(int crops, double modelMs) {
    _crops += crops;
    _modelMs += modelMs;
  }

  /// The run waits for the phone to cool down (called with every reading of
  /// the wait; only the first one starts the pause).
  void pauseStarted(double? tempC, double limitC) {
    if (_pauseStart != null) return;
    _pauseStart = _now();
    _write('identify_thermal_pause', {'temp_c': tempC, 'limit_c': limitC, 'resume_below_c': limitC - thermalResumeGapC});
  }

  void pauseEnded(double? tempC, {bool cancelled = false}) {
    final from = _pauseStart;
    if (from == null) return;
    final t = _now();
    _pausedMs += _since(from, t);
    _pauseStart = null;
    _write('identify_thermal_resume', {
      'temp_c': tempC,
      'paused_ms': t.difference(from).inMilliseconds,
      if (cancelled) 'cancelled': true,
    });
  }

  /// The step [step] begins. The sample taken here is the last one of the
  /// step that ends (a sample names the step the phone was in up to it), so
  /// every step has its end point however short it was.
  Future<void> beginStep(String step) async {
    await sample();
    _step = step;
  }

  /// The run's last sample and its end record; then the table is written
  /// again from the whole file. Never throws.
  Future<void> end({bool cancelled = false, String? error}) async {
    if (_out == null) {
      close();
      return;
    }
    _timer?.cancel();
    await sample();
    _write('identify_run_end', {'cancelled': cancelled, 'error': ?error});
    close();
    await writeCsv(_paths);
  }

  /// Stops the samples and closes the file; safe to call again. The run calls
  /// it when a failure skipped [end], so no timer outlives the run.
  void close() {
    _timer?.cancel();
    _timer = null;
    final out = _out;
    _out = null;
    try {
      out?.closeSync();
    } catch (e) {
      logSwallowed('identify_phone_log', e);
    }
  }

  /// Writes phone_during_identification.csv from the readings file: every run
  /// so far, one row per sample. After a run that Android closed the table
  /// lacks that run until the next run ends (the readings file has it).
  ///
  /// Read on this isolate, as a stream: the file is small (about 0.3 MB per
  /// hour of run) and is parsed piece by piece, so no isolate is needed.
  static Future<void> writeCsv(IdentificationPaths paths) async {
    try {
      final samples = await VideoRunSamples.parseFile(paths.phoneJsonl.path);
      if (samples == null || samples.isEmpty) return;
      await paths.phoneCsv.writeAsString(samples.toIdentifyCsv(), flush: true);
    } catch (e) {
      logSwallowed('identify_phone_csv', e);
    }
  }
}
