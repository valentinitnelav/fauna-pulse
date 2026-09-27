// FaunaPulse (round 232): the phone's state while the AI ran on the videos.
//
// Reads the samples VideoDetector writes into video_detections.jsonl
// (`thermal`, `power`, `analysis_speed`, `video_thermal_pause` /
// `video_thermal_resume`) and places them on one "analysis clock": the time
// the phone spent analysing, run after run. A stop and Continue leaves a gap
// of [VideoRunSamples.runGapMs] between two runs, wide enough that the
// summary graphs break their lines there instead of drawing a straight line
// across the hours the phone did something else.
//
// The summary's Graphs tab uses the series; "Share results" writes [toCsv]
// as phone_during_analysis.csv. session.jsonl is not read: these samples
// belong to the derived file, like the boxes they were measured with.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import '../logging/session_log_index.dart' show IndexedPowerSample;

/// Everything written at one sample time (the three records share `time_ms`).
class VideoPhoneSample {
  /// 1-based run number (one "Run AI on videos" start to stop).
  final int run;
  final int epochMs;

  /// Position on the analysis clock (ms).
  final int ms;

  String? clip;
  double? tempC;
  double? headroom;
  String? thermalStatus;
  double? powerW;
  int? currentUa;
  int? voltageMv;
  int? chargeUah;
  bool? charging;
  bool? plugged;
  double? framesPerS;

  /// Frames analysed since the previous sample, and the part of that time
  /// spent cooling down (null: no pause).
  int? frames;
  int? pausedMs;
  double? decodeMs;
  double? convertMs;
  double? detectMs;

  /// The run was waiting for the phone to cool down at this moment.
  bool paused = false;

  VideoPhoneSample(this.run, this.epochMs, this.ms);
}

class VideoRunSamples {
  static const csvFileName = 'phone_during_analysis.csv';

  final List<VideoPhoneSample> samples;

  /// Cooling pauses as (from, to) on the analysis clock.
  final List<(int, int)> pauses;

  /// Length of the analysis clock, gaps between runs included.
  final int totalMs;

  /// Time the runs took (gaps excluded), and the part spent cooling down.
  final int runMs;
  final int pausedMs;
  final int runs;

  /// Frames analysed, counted from the `raw_detections` records.
  final int frames;

  /// Gap between two runs on the analysis clock.
  final int runGapMs;

  /// The runs' "Measure the phone every" settings (s), sorted, no repeats.
  final List<int> sampleSeconds;

  const VideoRunSamples({
    required this.samples,
    required this.pauses,
    required this.totalMs,
    required this.runMs,
    required this.pausedMs,
    required this.runs,
    required this.frames,
    required this.runGapMs,
    this.sampleSeconds = const [],
  });

  bool get isEmpty => samples.isEmpty;

  List<(int, double)> _series(double? Function(VideoPhoneSample s) f) => [
    for (final s in samples)
      if (f(s) case final v?) (s.ms, v),
  ];

  List<(int, double)> get temps => _series((s) => s.tempC);
  List<(int, double)> get headroom => _series((s) => s.headroom);
  List<(int, double)> get framesPerS => _series((s) => s.framesPerS);

  /// [framesPerS] of the periods without a cooling pause.
  List<(int, double)> get framesPerSRunning => _series((s) => s.pausedMs == null ? s.framesPerS : null);
  List<(int, double)> get detectMs => _series((s) => s.detectMs);

  /// Battery samples in the shape the summary's energy series takes.
  List<IndexedPowerSample> get power => [
    for (final s in samples)
      if (s.currentUa != null || s.chargeUah != null || s.powerW != null)
        IndexedPowerSample(
          ms: s.ms,
          currentUa: s.currentUa,
          voltageMv: s.voltageMv,
          chargeUah: s.chargeUah,
          loggedW: s.powerW,
          isCharging: s.charging,
          isPlugged: s.plugged,
        ),
  ];

  /// Frames per second while the AI was running (cooling pauses excluded).
  double? get meanFramesPerS {
    final running = runMs - pausedMs;
    return running > 0 && frames > 0 ? frames * 1000 / running : null;
  }

  /// Reads [file] off the UI isolate; null when it is missing or unreadable.
  static Future<VideoRunSamples?> read(File file) {
    final path = file.path;
    return Isolate.run(() => parseFile(path));
  }

  /// Same as [read], on the caller's isolate (tests).
  static Future<VideoRunSamples?> parseFile(String path) async {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      return parse(await f.openRead().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).toList());
    } catch (_) {
      return null;
    }
  }

  static const _rawPrefix = '{"type":"raw_detections","time_ms":';

  static VideoRunSamples parse(Iterable<String> lines) {
    final runs = <_Run>[];
    var frames = 0;
    for (final line in lines) {
      // Boxes are most of the file: count them, and read their time (the
      // end of a killed run), without decoding them.
      if (line.startsWith(_rawPrefix)) {
        frames++;
        final comma = line.indexOf(',', _rawPrefix.length);
        final t = comma < 0 ? null : int.tryParse(line.substring(_rawPrefix.length, comma));
        if (t != null && runs.isNotEmpty) runs.last.endMs = t;
        continue;
      }
      Map<String, dynamic> rec;
      try {
        rec = (jsonDecode(line) as Map).cast<String, dynamic>();
      } catch (_) {
        continue; // a half-written last line after a kill
      }
      final type = rec['type'];
      final t = (rec['time_ms'] as num?)?.toInt();
      if (t == null) continue;
      if (type == 'video_run_start') {
        runs.add(_Run(t, (rec['sample_s'] as num?)?.toInt()));
        continue;
      }
      if (runs.isEmpty) continue;
      final run = runs.last..endMs = t;
      switch (type) {
        case 'thermal':
          final s = run.at(t);
          s.tempC = (rec['battery_temp_c'] as num?)?.toDouble();
          s.headroom = (rec['thermal_headroom'] as num?)?.toDouble();
          s.thermalStatus = rec['thermal_status'] as String?;
          s.paused = rec['paused'] == true;
          s.clip ??= rec['clip'] as String?;
        case 'power':
          final s = run.at(t);
          s.powerW = (rec['power_w'] as num?)?.toDouble();
          s.currentUa = (rec['battery_current_ua'] as num?)?.toInt();
          s.voltageMv = (rec['battery_voltage_mv'] as num?)?.toInt();
          s.chargeUah = (rec['charge_counter_uah'] as num?)?.toInt();
          s.charging = rec['is_charging'] as bool?;
          s.plugged = rec['is_plugged'] as bool?;
        case 'analysis_speed':
          final s = run.at(t);
          s.clip = rec['clip'] as String? ?? s.clip;
          s.framesPerS = (rec['frames_per_s'] as num?)?.toDouble();
          s.frames = (rec['frames'] as num?)?.toInt();
          s.pausedMs = (rec['paused_ms'] as num?)?.toInt();
          s.decodeMs = (rec['decode_ms'] as num?)?.toDouble();
          s.convertMs = (rec['convert_ms'] as num?)?.toDouble();
          s.detectMs = (rec['detect_ms'] as num?)?.toDouble();
        case 'video_thermal_pause':
          run.pauses.add((t, null));
        case 'video_thermal_resume':
          if (run.pauses.isNotEmpty && run.pauses.last.$2 == null) {
            run.pauses.last = (run.pauses.last.$1, t);
          }
      }
    }

    // A run without samples (nothing left to analyse) takes no room.
    final used = runs.where((r) => r.byTime.isNotEmpty).toList();
    final longestSampleS = used.map((r) => r.sampleS ?? 10).fold(10, max);
    final gapMs = max(60000, 5 * 1000 * longestSampleS);
    final samples = <VideoPhoneSample>[];
    final pauses = <(int, int)>[];
    var offset = 0, runMs = 0, pausedMs = 0;
    for (var i = 0; i < used.length; i++) {
      final r = used[i];
      if (i > 0) offset += gapMs;
      for (final e in r.byTime.entries) {
        final src = e.value;
        samples.add(
          VideoPhoneSample(i + 1, e.key, offset + e.key - r.startMs)
            ..clip = src.clip
            ..tempC = src.tempC
            ..headroom = src.headroom
            ..thermalStatus = src.thermalStatus
            ..powerW = src.powerW
            ..currentUa = src.currentUa
            ..voltageMv = src.voltageMv
            ..chargeUah = src.chargeUah
            ..charging = src.charging
            ..plugged = src.plugged
            ..framesPerS = src.framesPerS
            ..frames = src.frames
            ..pausedMs = src.pausedMs
            ..decodeMs = src.decodeMs
            ..convertMs = src.convertMs
            ..detectMs = src.detectMs
            ..paused = src.paused,
        );
      }
      for (final (from, to) in r.pauses) {
        final end = to ?? r.endMs; // killed while cooling
        pauses.add((offset + from - r.startMs, offset + end - r.startMs));
        pausedMs += end - from;
      }
      final length = r.endMs - r.startMs;
      runMs += length;
      offset += length;
    }
    return VideoRunSamples(
      samples: samples,
      pauses: pauses,
      totalMs: offset,
      runMs: runMs,
      pausedMs: pausedMs,
      runs: used.length,
      frames: frames,
      runGapMs: gapMs,
      sampleSeconds: ({for (final r in used) ?r.sampleS}.toList()..sort()),
    );
  }

  static const csvHeader =
      'run,time_s,epoch_ms,clip,temp_c,headroom,thermal_status,power_w,'
      'battery_current_ua,battery_voltage_mv,charging,plugged,frames_per_s,'
      'frames,decode_ms,convert_ms,detect_ms,paused,paused_ms';

  /// One row per sample; `time_s` is the analysis clock of the graphs. Empty
  /// cells are values the phone did not report (or no frames in the period).
  String toCsv() {
    String cell(Object? v) {
      if (v == null) return '';
      final s = '$v';
      return s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final b = StringBuffer('$csvHeader\n');
    for (final s in samples) {
      b.writeln(
        [
          s.run,
          (s.ms / 1000).toStringAsFixed(1),
          s.epochMs,
          s.clip,
          s.tempC,
          s.headroom,
          s.thermalStatus,
          s.powerW == null ? null : (s.powerW! * 1000).round() / 1000,
          s.currentUa,
          s.voltageMv,
          s.charging,
          s.plugged,
          s.framesPerS,
          s.frames,
          s.decodeMs,
          s.convertMs,
          s.detectMs,
          s.paused,
          s.pausedMs,
        ].map(cell).join(','),
      );
    }
    return b.toString();
  }
}

class _Run {
  final int startMs;
  final int? sampleS;
  int endMs;
  final byTime = <int, VideoPhoneSample>{};
  final pauses = <(int, int?)>[];

  _Run(this.startMs, this.sampleS) : endMs = startMs;

  VideoPhoneSample at(int t) => byTime.putIfAbsent(t, () => VideoPhoneSample(0, t, 0));
}
