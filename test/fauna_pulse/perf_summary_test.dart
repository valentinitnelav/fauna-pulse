// Tests for tool/perf_summary.dart (round 162, perf review E1) — the offline
// benchmark parser. Synthetic session.jsonl fixtures only; no real field data.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/perf_summary.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('perf_summary_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File writeLog(List<Map<String, dynamic>> records, {String? trailing}) {
    final f = File('${tmp.path}/session.jsonl');
    final sink = StringBuffer();
    for (final r in records) {
      sink.writeln(jsonEncode(r));
    }
    if (trailing != null) sink.write(trailing);
    f.writeAsStringSync(sink.toString());
    return f;
  }

  Map<String, dynamic> start({int timeMs = 0, bool charging = false}) => {
    'type': 'start_of_session',
    'time_ms': timeMs,
    'session_id': 'session_test',
    'device': 'TestPhone',
    'app_version': '0.6.4',
    'app_build': '10',
    'build_mode': 'debug',
    'config': {
      'modelPath': 'assets/models/yolo26n_int8.tflite',
      'captureTrigger': 'detector',
      'inferenceFps': 10,
      'cameraFpsCap': 15,
      'autoThrottle': true,
    },
    'thermal': {'battery_temp_c': 30.0, 'is_charging': charging},
  };

  Map<String, dynamic> fpsRec(
    int timeMs, {
    double? pipeline,
    double? inf,
    double? legacyFps,
    bool gateIdle = false,
    num cap = 10,
  }) => {
    'type': 'fps',
    'time_ms': timeMs,
    if (gateIdle) 'gate_idle': true,
    if (!gateIdle && pipeline != null) ...{
      'fps': legacyFps ?? pipeline,
      'detector_fps': pipeline,
      'pipeline_fps': pipeline,
      'pre_ms': 5.0,
      'inf_ms': inf ?? 50.0,
      'post_ms': 3.0,
      'track_ms': 1.0,
    },
    if (gateIdle == false && pipeline == null && legacyFps != null)
      // Legacy (pre-r131) record: only `fps`, no pipeline_fps.
      'fps': legacyFps,
    'camera_fps': 15.0,
    'engine': 'CPU',
    'analysis_w': 640,
    'analysis_h': 480,
    'applied_cap_fps': cap,
  };

  Map<String, dynamic> thermalRec(int timeMs, double temp, {double? headroom}) => {
    'type': 'thermal',
    'time_ms': timeMs,
    'battery_temp_c': temp,
    'thermal_headroom': ?headroom,
    'is_charging': false,
  };

  Map<String, dynamic> powerRec(
    int timeMs,
    double watts, {
    bool charging = false,
    int? chargeUah,
  }) => {
    'type': 'power',
    'time_ms': timeMs,
    'power_w': watts,
    'is_charging': charging,
    'charge_counter_uah': ?chargeUah,
  };

  test('full session: identity, series, caps, energy, errors, end', () async {
    final f = writeLog([
      start(),
      fpsRec(1000, pipeline: 10.0, inf: 50.0),
      fpsRec(6000, pipeline: 9.0, inf: 60.0, cap: 8), // cap change 10 -> 8
      fpsRec(11000, gateIdle: true, cap: 8),
      thermalRec(2000, 31.0, headroom: 0.5),
      thermalRec(12000, 40.0, headroom: 0.9),
      powerRec(3000, 4.0, chargeUah: 3000000),
      powerRec(13000, 6.0, chargeUah: 2990000),
      {'type': 'app_error', 'time_ms': 14000, 'message': 'x'},
      {
        'type': 'end_of_session',
        'time_ms': 3600000,
        'ended_normally': true,
        'thermal': {'is_charging': false},
      },
    ]);
    final s = await summarizeSession(f);

    expect(s.sessionId, 'session_test');
    expect(s.buildMode, 'debug');
    expect(s.model, 'yolo26n_int8.tflite');
    expect(s.captureTrigger, 'detector');
    expect(s.inferenceFpsCap, 10);
    expect(s.cameraFpsCap, 15);
    expect(s.autoThrottle, true);
    expect(s.engine, 'CPU');
    expect(s.durationMs, 3600000);
    expect(s.endRecordSeen, true);
    expect(s.endedNormally, true);

    expect(s.fpsSampleCount, 3);
    expect(s.gateIdleSampleCount, 1);
    expect(s.gateIdleFraction, closeTo(1 / 3, 1e-9));
    // Gate-idle sample contributes camera fps but NO inference numbers.
    expect(s.cameraFps.overall.length, 3);
    expect(s.infMs.overall, [50.0, 60.0]);
    expect(s.pipelineFps.overallStats.median, closeTo(9.5, 0.6));

    expect(s.capChanges, 1);
    expect(s.capMinApplied, 8);

    expect(s.tempStartC, 30.0);
    expect(s.tempMaxC, 40.0);
    expect(s.headroomMax, 0.9);

    expect(s.chargingSeen, false);
    // Mean 5 W over 1 h = 5 Wh.
    expect(s.energyWh, closeTo(5.0, 1e-6));
    expect(s.chargeDropMah, closeTo(10.0, 1e-6));

    expect(s.appErrorCount, 1);
    expect(s.malformedLines, 0);
  });

  test('malformed and truncated lines are counted, not fatal', () async {
    final f = writeLog([
      start(),
      fpsRec(1000, pipeline: 10.0),
    ], trailing: 'not json at all\n[1,2,3]\n{"type":"end_of_ses');
    final s = await summarizeSession(f);
    expect(s.malformedLines, 3);
    expect(s.fpsSampleCount, 1);
    expect(s.endRecordSeen, false); // truncated end never parsed
  });

  test('charging anywhere withholds power and energy (round 84)', () async {
    final f = writeLog([
      start(),
      powerRec(1000, 4.0, chargeUah: 3000000),
      powerRec(2000, 5.0, charging: true, chargeUah: 2999000),
      {'type': 'end_of_session', 'time_ms': 60000, 'ended_normally': true},
    ]);
    final s = await summarizeSession(f);
    expect(s.chargingSeen, true);
    expect(s.energyWh, isNull);
    expect(s.chargeDropMah, isNull);
    expect(formatMarkdown([s]), contains('charging'));
  });

  test('legacy fps records feed pipeline series via `fps` (round 85)', () async {
    final f = writeLog([
      start(),
      {
        'type': 'fps',
        'time_ms': 1000,
        'fps': 7.5,
        'camera_fps': 15.0,
      },
    ]);
    final s = await summarizeSession(f);
    expect(s.pipelineFps.overall, [7.5]);
    expect(s.detectorFps.overall, [7.5]);
  });

  test('cold and sustained windows split the series', () async {
    // Samples at t = 0..9 s; cold = first 2 s, sustained = last 2 s.
    final f = writeLog([
      start(),
      for (var i = 0; i < 10; i++)
        fpsRec(i * 1000, pipeline: i.toDouble(), inf: 50.0),
    ]);
    final s = await summarizeSession(f, coldSeconds: 2, sustainedSeconds: 2);
    expect(s.pipelineFps.cold, [0.0, 1.0]);
    expect(s.pipelineFps.sustained, [7.0, 8.0, 9.0]);
    expect(s.pipelineFps.overall.length, 10);
  });

  test('sustained window never reaches into the cold window', () async {
    // 3 s of samples but a 60 s sustained request: sustained must start at the
    // cold boundary, not before it.
    final f = writeLog([
      start(),
      for (var i = 0; i < 4; i++)
        fpsRec(i * 1000, pipeline: i.toDouble()),
    ]);
    final s = await summarizeSession(f, coldSeconds: 2, sustainedSeconds: 60);
    expect(s.pipelineFps.cold, [0.0, 1.0]);
    expect(s.pipelineFps.sustained, [2.0, 3.0]);
  });

  test('SeriesStats median (midpoint) and p95 (nearest rank)', () {
    final stats = SeriesStats.of(
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((e) => e.toDouble()).toList(),
    );
    expect(stats.median, 5.5);
    expect(stats.p95, 10.0);
    expect(SeriesStats.of([]).median, isNull);
    expect(SeriesStats.of([3.0]).median, 3.0);
    expect(SeriesStats.of([1.0, 2.0, 3.0]).median, 2.0);
  });

  test('formatCsv: one header + one row per session, stable fields', () async {
    final f = writeLog([
      start(),
      fpsRec(1000, pipeline: 10.0),
      {'type': 'end_of_session', 'time_ms': 120000, 'ended_normally': true},
    ]);
    final s = await summarizeSession(f);
    final csv = formatCsv([s, s]).trim().split('\n');
    expect(csv.length, 3);
    expect(csv.first, startsWith('session,build_mode'));
    expect(csv[1], contains('session_test'));
    expect(csv[1], contains('debug'));
    expect(csv[1].split(',').length, csv.first.split(',').length);
  });

  test('formatMarkdown flags missing end record and debug builds', () async {
    final f = writeLog([start(), fpsRec(1000, pipeline: 10.0)]);
    final s = await summarizeSession(f);
    final md = formatMarkdown([s]);
    expect(md, contains('NO END RECORD'));
    expect(md, contains('debug build'));
  });

  test('resolveSessionFile accepts the session folder', () {
    writeLog([start()]);
    expect(resolveSessionFile(tmp.path)!.path, endsWith('session.jsonl'));
    expect(resolveSessionFile('${tmp.path}/session.jsonl'), isNotNull);
    expect(resolveSessionFile('${tmp.path}/nope'), isNull);
  });
}
