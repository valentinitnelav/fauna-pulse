// FaunaPulse — offline performance summary for session logs (round 162, perf review E1).
//
// Streams one or more `session.jsonl` files (never loads a whole file into
// memory) and prints a comparison table so paired A/B benchmark runs can be
// judged with numbers instead of impressions. Pure Dart on purpose: run it on
// any machine with the Dart SDK, no Flutter needed:
//
//   dart tool/perf_summary.dart <session.jsonl | session-folder> ...
//   dart tool/perf_summary.dart --csv sessions/a/session.jsonl sessions/b/session.jsonl
//
// Options:
//   --csv                 one machine-readable row per session (for R/pandas)
//   --cold=SECONDS        cold-start window measured from the first fps sample
//                         (default 120; excluded from the sustained window)
//   --sustained=SECONDS   sustained window measured back from the last fps
//                         sample (default 600) — thermal behaviour lives here
//
// What it reads (see docs/DATA_GUIDE.md for the full record dictionary):
//   fps records      — camera/detector/pipeline FPS, pre/inf/post/track ms,
//                      applied auto-throttle cap, gate_idle flag
//   thermal records  — battery_temp_c, thermal_headroom, is_charging
//   power records    — power_w, charge_counter_uah, is_charging
//   start/end        — build_mode, app_version, config caps, ended_normally
//   app_error        — counted
// Diagnostics rules honoured: `pipeline_fps ?? fps` (round 85, pre-131 logs),
// inference fields absent while the gate sleeps (round 77 — treated as missing
// data, never as zeros), and power/energy reported ONLY for sessions with no
// charging detected (round 84: plugged-in current measures charging, not
// consumption). Malformed or truncated lines are counted and skipped — a
// crashed session's half-written last line must not kill the summary.

import 'dart:convert';
import 'dart:io';

/// Median and 95th percentile of a series (nearest-rank; empty -> nulls).
class SeriesStats {
  final double? median;
  final double? p95;
  final int count;
  const SeriesStats(this.median, this.p95, this.count);

  static SeriesStats of(List<double> values) {
    if (values.isEmpty) return const SeriesStats(null, null, 0);
    final sorted = List<double>.of(values)..sort();
    final n = sorted.length;
    // Conventional median (midpoint of the two central values for even n);
    // p95 by nearest rank — good enough at diagnostic sample counts.
    final median = n.isOdd
        ? sorted[n ~/ 2]
        : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
    final p95 = sorted[((n - 1) * 0.95).round()];
    return SeriesStats(median, p95, n);
  }
}

/// One diagnostic sample series split into the analysis windows.
class WindowedSeries {
  final List<double> overall = [];
  final List<double> cold = [];
  final List<double> sustained = [];

  void add(double v, {required bool inCold, required bool inSustained}) {
    overall.add(v);
    if (inCold) cold.add(v);
    if (inSustained) sustained.add(v);
  }

  SeriesStats get overallStats => SeriesStats.of(overall);
  SeriesStats get coldStats => SeriesStats.of(cold);
  SeriesStats get sustainedStats => SeriesStats.of(sustained);
}

/// Everything the summary extracts from one session log.
class SessionPerf {
  final String path;

  // Identity / comparability (round 132: never compare across mixed binaries).
  String? sessionId;
  String? device;
  String? appVersion;
  String? appBuild;
  String? buildMode;
  String? model; // config.modelPath basename
  String? captureTrigger;
  String? engine; // last engine seen in fps records ("GPU"/"CPU"/"NPU")
  int? inferenceFpsCap; // config.inferenceFps (0 = uncapped)
  int? cameraFpsCap; // config.cameraFpsCap (0 = device default)
  bool? autoThrottle;
  int? analysisW;
  int? analysisH;

  int? startMs;
  int? endMs; // end record if present, else last record seen
  bool endRecordSeen = false;
  bool? endedNormally;

  // Series (fps records).
  final cameraFps = WindowedSeries();
  final detectorFps = WindowedSeries();
  final pipelineFps = WindowedSeries();
  final preMs = WindowedSeries();
  final infMs = WindowedSeries();
  final postMs = WindowedSeries();
  final trackMs = WindowedSeries();

  int fpsSampleCount = 0;
  int gateIdleSampleCount = 0;

  // Auto-throttle cap trace.
  int capChanges = 0;
  int? capMinApplied; // lowest non-zero applied cap seen
  num? _lastCap;

  // Thermal.
  double? tempStartC; // start record's thermal block
  double? tempMaxC;
  final tempC = WindowedSeries();
  double? headroomMax;

  // Power (valid only when no charging was ever seen — round 84).
  bool chargingSeen = false;
  final powerW = WindowedSeries();
  int? chargeCounterFirstUah;
  int? chargeCounterLastUah;

  int appErrorCount = 0;
  int malformedLines = 0;

  SessionPerf(this.path);

  int? get durationMs =>
      (startMs != null && endMs != null) ? endMs! - startMs! : null;

  double? get gateIdleFraction =>
      fpsSampleCount == 0 ? null : gateIdleSampleCount / fpsSampleCount;

  /// Mean power x duration, in Wh — only meaningful when [chargingSeen] is
  /// false and there are samples.
  double? get energyWh {
    final d = durationMs;
    if (chargingSeen || powerW.overall.isEmpty || d == null || d <= 0) {
      return null;
    }
    final mean =
        powerW.overall.reduce((a, b) => a + b) / powerW.overall.length;
    return mean * (d / 3600000.0);
  }

  /// Battery charge drained over the session in mAh (cross-check for
  /// [energyWh]); null when unavailable or the phone was charging.
  double? get chargeDropMah {
    if (chargingSeen ||
        chargeCounterFirstUah == null ||
        chargeCounterLastUah == null) {
      return null;
    }
    return (chargeCounterFirstUah! - chargeCounterLastUah!) / 1000.0;
  }
}

double? _num(dynamic v) => v is num ? v.toDouble() : null;
int? _int(dynamic v) => v is num ? v.toInt() : null;

/// Streams [file] and aggregates one [SessionPerf].
///
/// Two passes are avoided by buffering only the fps/thermal/power SAMPLE
/// TIMESTAMPS + values (a few thousand numbers even for an 8 h session), never
/// the raw lines: the cold/sustained windows depend on the last sample's time,
/// which is only known at the end.
Future<SessionPerf> summarizeSession(
  File file, {
  int coldSeconds = 120,
  int sustainedSeconds = 600,
}) async {
  final perf = SessionPerf(file.path);

  // Buffered samples: (time_ms, record map) for the three periodic types.
  final fpsSamples = <MapEntry<int, Map<String, dynamic>>>[];
  final thermalSamples = <MapEntry<int, Map<String, dynamic>>>[];
  final powerSamples = <MapEntry<int, Map<String, dynamic>>>[];

  final lines = file
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> rec;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        perf.malformedLines++;
        continue;
      }
      rec = decoded;
    } catch (_) {
      perf.malformedLines++; // truncated final line of a crashed session etc.
      continue;
    }

    final timeMs = _int(rec['time_ms']);
    if (timeMs != null) {
      perf.endMs = timeMs; // provisional: last record seen wins until the end record
    }

    switch (rec['type']) {
      case 'start_of_session':
        perf.startMs = timeMs ?? perf.startMs;
        perf.sessionId = rec['session_id'] as String?;
        perf.device = rec['device']?.toString();
        perf.appVersion = rec['app_version']?.toString();
        perf.appBuild = rec['app_build']?.toString();
        perf.buildMode = rec['build_mode'] as String?;
        final config = rec['config'];
        if (config is Map<String, dynamic>) {
          final modelPath = config['modelPath'] as String?;
          perf.model = modelPath?.split('/').last;
          perf.captureTrigger = config['captureTrigger'] as String?;
          perf.inferenceFpsCap = _int(config['inferenceFps']);
          perf.cameraFpsCap = _int(config['cameraFpsCap']);
          perf.autoThrottle = config['autoThrottle'] as bool?;
        }
        final thermal = rec['thermal'];
        if (thermal is Map<String, dynamic>) {
          perf.tempStartC = _num(thermal['battery_temp_c']);
          if (thermal['is_charging'] == true) perf.chargingSeen = true;
        }
      case 'fps':
        if (timeMs != null) fpsSamples.add(MapEntry(timeMs, rec));
      case 'thermal':
        if (timeMs != null) thermalSamples.add(MapEntry(timeMs, rec));
      case 'power':
        if (timeMs != null) powerSamples.add(MapEntry(timeMs, rec));
      case 'app_error':
        perf.appErrorCount++;
      case 'end_of_session':
        perf.endRecordSeen = true;
        perf.endedNormally = rec['ended_normally'] as bool?;
        final thermal = rec['thermal'];
        if (thermal is Map<String, dynamic> && thermal['is_charging'] == true) {
          perf.chargingSeen = true;
        }
      default:
        break; // detections / captures / roi etc. are not perf records
    }
  }

  // Window boundaries hang off the fps samples (the perf clock of the log);
  // fall back to thermal samples for no-fps sessions (e.g. r148-window logs).
  final clockSamples = fpsSamples.isNotEmpty ? fpsSamples : thermalSamples;
  int? firstSampleMs;
  int? lastSampleMs;
  if (clockSamples.isNotEmpty) {
    firstSampleMs = clockSamples.first.key;
    lastSampleMs = clockSamples.last.key;
  }
  final coldEndMs =
      firstSampleMs == null ? null : firstSampleMs + coldSeconds * 1000;
  var sustainedStartMs =
      lastSampleMs == null ? null : lastSampleMs - sustainedSeconds * 1000;
  // The sustained window must not reach into the cold window on short runs.
  if (sustainedStartMs != null &&
      coldEndMs != null &&
      sustainedStartMs < coldEndMs) {
    sustainedStartMs = coldEndMs;
  }
  bool inCold(int t) => coldEndMs != null && t < coldEndMs;
  bool inSustained(int t) =>
      sustainedStartMs != null && t >= sustainedStartMs;

  for (final entry in fpsSamples) {
    final t = entry.key;
    final rec = entry.value;
    final cold = inCold(t), sustained = inSustained(t);
    perf.fpsSampleCount++;
    if (rec['gate_idle'] == true) perf.gateIdleSampleCount++;

    void series(WindowedSeries s, double? v) {
      if (v != null) s.add(v, inCold: cold, inSustained: sustained);
    }

    series(perf.cameraFps, _num(rec['camera_fps']));
    series(perf.detectorFps, _num(rec['detector_fps'] ?? rec['fps']));
    // Round 85: pre-131 sessions have no pipeline_fps; `fps` is the honest stand-in.
    series(perf.pipelineFps, _num(rec['pipeline_fps'] ?? rec['fps']));
    series(perf.preMs, _num(rec['pre_ms']));
    series(perf.infMs, _num(rec['inf_ms']));
    series(perf.postMs, _num(rec['post_ms']));
    series(perf.trackMs, _num(rec['track_ms']));

    final engine = rec['engine'] as String?;
    if (engine != null && engine.isNotEmpty) perf.engine = engine;
    perf.analysisW = _int(rec['analysis_w']) ?? perf.analysisW;
    perf.analysisH = _int(rec['analysis_h']) ?? perf.analysisH;

    final cap = rec['applied_cap_fps'];
    if (cap is num) {
      if (perf._lastCap != null && cap != perf._lastCap) perf.capChanges++;
      perf._lastCap = cap;
      if (cap > 0 &&
          (perf.capMinApplied == null || cap < perf.capMinApplied!)) {
        perf.capMinApplied = cap.toInt();
      }
    }
  }

  for (final entry in thermalSamples) {
    final t = entry.key;
    final rec = entry.value;
    final temp = _num(rec['battery_temp_c']);
    if (temp != null) {
      perf.tempC.add(temp, inCold: inCold(t), inSustained: inSustained(t));
      if (perf.tempMaxC == null || temp > perf.tempMaxC!) perf.tempMaxC = temp;
    }
    final headroom = _num(rec['thermal_headroom']);
    if (headroom != null &&
        (perf.headroomMax == null || headroom > perf.headroomMax!)) {
      perf.headroomMax = headroom;
    }
    if (rec['is_charging'] == true) perf.chargingSeen = true;
  }

  for (final entry in powerSamples) {
    final t = entry.key;
    final rec = entry.value;
    if (rec['is_charging'] == true) perf.chargingSeen = true;
    final w = _num(rec['power_w']);
    if (w != null) {
      perf.powerW.add(w, inCold: inCold(t), inSustained: inSustained(t));
    }
    final charge = _int(rec['charge_counter_uah']);
    if (charge != null) {
      perf.chargeCounterFirstUah ??= charge;
      perf.chargeCounterLastUah = charge;
    }
  }

  return perf;
}

String _fmt(double? v, {int digits = 1}) =>
    v == null ? 'n/a' : v.toStringAsFixed(digits);

String _fmtStats(SeriesStats s, {int digits = 1}) => s.count == 0
    ? 'n/a'
    : '${_fmt(s.median, digits: digits)} / ${_fmt(s.p95, digits: digits)}';

/// The headline comparison table (one row per session) plus per-session
/// detail blocks — Markdown, meant to be pasted into review docs.
String formatMarkdown(List<SessionPerf> sessions) {
  final b = StringBuffer();
  b.writeln('## Session comparison');
  b.writeln();
  b.writeln(
    '| session | build | model | trigger | dur min | cam fps med (sust) '
    '| pipe fps med (sust) | inf ms med/p95 (sust) | temp start→max °C '
    '| gate idle % | cap chg | power W med | energy Wh | errors | ended |',
  );
  b.writeln(
    '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|',
  );
  for (final s in sessions) {
    final dur = s.durationMs;
    final power = s.chargingSeen
        ? 'n/a (charging)'
        : _fmt(s.powerW.sustainedStats.median, digits: 2);
    final energy = s.chargingSeen ? 'n/a (charging)' : _fmt(s.energyWh, digits: 2);
    final gate = s.gateIdleFraction;
    b.writeln(
      '| ${s.sessionId ?? s.path.split(Platform.pathSeparator).last} '
      '| ${s.buildMode ?? '?'} ${s.appVersion ?? ''}+${s.appBuild ?? '?'} '
      '| ${s.model ?? '?'} '
      '| ${s.captureTrigger ?? '?'} '
      '| ${dur == null ? 'n/a' : (dur / 60000).toStringAsFixed(1)} '
      '| ${_fmt(s.cameraFps.sustainedStats.median)} '
      '| ${_fmt(s.pipelineFps.sustainedStats.median)} '
      '| ${_fmtStats(s.infMs.sustainedStats)} '
      '| ${_fmt(s.tempStartC)}→${_fmt(s.tempMaxC)} '
      '| ${gate == null ? 'n/a' : (gate * 100).toStringAsFixed(0)} '
      '| ${s.capChanges} '
      '| $power | $energy '
      '| ${s.appErrorCount} '
      '| ${s.endRecordSeen ? (s.endedNormally == true ? 'normal' : 'abnormal') : 'NO END RECORD'} |',
    );
  }

  for (final s in sessions) {
    b.writeln();
    b.writeln('### ${s.sessionId ?? s.path}');
    b.writeln();
    if (s.buildMode != null && s.buildMode != 'release' && s.buildMode != 'profile') {
      b.writeln(
        '> ⚠ ${s.buildMode} build — do not quote these numbers as device '
        'speed (docs/PERFORMANCE_BENCHMARKING.md).',
      );
      b.writeln();
    }
    if (s.chargingSeen) {
      b.writeln(
        '> ⚠ charging detected — power/energy withheld (round 84 rule).',
      );
      b.writeln();
    }
    b.writeln(
      '- device: ${s.device ?? '?'} · engine: ${s.engine ?? 'n/a'} · '
      'stream: ${s.analysisW ?? '?'}x${s.analysisH ?? '?'} · '
      'caps: inference ${s.inferenceFpsCap ?? '?'} / camera ${s.cameraFpsCap ?? '?'} '
      '· auto-throttle: ${s.autoThrottle ?? '?'}'
      '${s.capMinApplied == null ? '' : ' · lowest applied cap: ${s.capMinApplied}'}',
    );
    b.writeln(
      '- samples: ${s.fpsSampleCount} fps · gate idle '
      '${s.gateIdleFraction == null ? 'n/a' : '${(s.gateIdleFraction! * 100).toStringAsFixed(0)}%'}'
      ' · malformed lines skipped: ${s.malformedLines}'
      '${s.chargeDropMah == null ? '' : ' · battery drop: ${_fmt(s.chargeDropMah)} mAh'}',
    );
    b.writeln();
    b.writeln('| series | overall med/p95 | cold med/p95 | sustained med/p95 |');
    b.writeln('|---|---|---|---|');
    void row(String name, WindowedSeries series, {int digits = 1}) {
      b.writeln(
        '| $name | ${_fmtStats(series.overallStats, digits: digits)} '
        '| ${_fmtStats(series.coldStats, digits: digits)} '
        '| ${_fmtStats(series.sustainedStats, digits: digits)} |',
      );
    }

    row('camera fps', s.cameraFps);
    row('detector fps', s.detectorFps);
    row('pipeline fps', s.pipelineFps);
    row('pre ms', s.preMs);
    row('inference ms', s.infMs);
    row('post ms', s.postMs);
    row('tracking ms', s.trackMs);
    row('temp °C', s.tempC);
    row('power W', s.powerW, digits: 2);
  }
  return b.toString();
}

/// One CSV row per session (stable column order, for R / pandas).
String formatCsv(List<SessionPerf> sessions) {
  final b = StringBuffer();
  b.writeln(
    'session,build_mode,app_version,app_build,device,model,trigger,engine,'
    'duration_min,camera_fps_med_sust,pipeline_fps_med_sust,'
    'inf_ms_med_sust,inf_ms_p95_sust,pre_ms_med_sust,post_ms_med_sust,'
    'track_ms_med_sust,temp_start_c,temp_max_c,headroom_max,'
    'gate_idle_pct,cap_changes,charging_seen,power_w_med_sust,energy_wh,'
    'charge_drop_mah,app_errors,malformed_lines,ended_normally',
  );
  String c(Object? v) {
    final s = v?.toString() ?? '';
    return s.contains(',') ? '"$s"' : s;
  }

  for (final s in sessions) {
    final dur = s.durationMs;
    b.writeln(
      [
        c(s.sessionId ?? s.path),
        c(s.buildMode),
        c(s.appVersion),
        c(s.appBuild),
        c(s.device),
        c(s.model),
        c(s.captureTrigger),
        c(s.engine),
        c(dur == null ? null : (dur / 60000).toStringAsFixed(2)),
        c(s.cameraFps.sustainedStats.median?.toStringAsFixed(2)),
        c(s.pipelineFps.sustainedStats.median?.toStringAsFixed(2)),
        c(s.infMs.sustainedStats.median?.toStringAsFixed(2)),
        c(s.infMs.sustainedStats.p95?.toStringAsFixed(2)),
        c(s.preMs.sustainedStats.median?.toStringAsFixed(2)),
        c(s.postMs.sustainedStats.median?.toStringAsFixed(2)),
        c(s.trackMs.sustainedStats.median?.toStringAsFixed(2)),
        c(s.tempStartC?.toStringAsFixed(1)),
        c(s.tempMaxC?.toStringAsFixed(1)),
        c(s.headroomMax?.toStringAsFixed(2)),
        c(s.gateIdleFraction == null
            ? null
            : (s.gateIdleFraction! * 100).toStringAsFixed(1)),
        c(s.capChanges),
        c(s.chargingSeen),
        c(s.chargingSeen
            ? null
            : s.powerW.sustainedStats.median?.toStringAsFixed(2)),
        c(s.energyWh?.toStringAsFixed(2)),
        c(s.chargeDropMah?.toStringAsFixed(1)),
        c(s.appErrorCount),
        c(s.malformedLines),
        c(s.endRecordSeen ? s.endedNormally : 'no_end_record'),
      ].join(','),
    );
  }
  return b.toString();
}

/// Resolves an argument to a session.jsonl file (accepts the folder too).
File? resolveSessionFile(String arg) {
  if (FileSystemEntity.isDirectorySync(arg)) {
    final f = File('$arg${Platform.pathSeparator}session.jsonl');
    return f.existsSync() ? f : null;
  }
  final f = File(arg);
  return f.existsSync() ? f : null;
}

Future<void> main(List<String> args) async {
  var csv = false;
  var coldSeconds = 120;
  var sustainedSeconds = 600;
  final paths = <String>[];
  for (final a in args) {
    if (a == '--csv') {
      csv = true;
    } else if (a.startsWith('--cold=')) {
      coldSeconds = int.tryParse(a.substring(7)) ?? coldSeconds;
    } else if (a.startsWith('--sustained=')) {
      sustainedSeconds = int.tryParse(a.substring(12)) ?? sustainedSeconds;
    } else {
      paths.add(a);
    }
  }
  if (paths.isEmpty) {
    stderr.writeln(
      'Usage: dart tool/perf_summary.dart [--csv] [--cold=S] [--sustained=S] '
      '<session.jsonl | session-folder> ...',
    );
    exitCode = 64;
    return;
  }

  final sessions = <SessionPerf>[];
  for (final p in paths) {
    final f = resolveSessionFile(p);
    if (f == null) {
      stderr.writeln('skipped (no session.jsonl found): $p');
      continue;
    }
    sessions.add(
      await summarizeSession(
        f,
        coldSeconds: coldSeconds,
        sustainedSeconds: sustainedSeconds,
      ),
    );
  }
  if (sessions.isEmpty) {
    stderr.writeln('No readable sessions.');
    exitCode = 66;
    return;
  }
  stdout.write(csv ? formatCsv(sessions) : formatMarkdown(sessions));
}
