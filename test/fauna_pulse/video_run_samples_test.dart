import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_run_samples.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_detector_test.dart' show FakeBackend, config;

const t0 = 1000000000;

String rec(String type, int t, [Map<String, dynamic> fields = const {}]) =>
    jsonEncode({'type': type, 'time_ms': t, ...fields});

/// The three records of one sample, as VideoDetector writes them.
List<String> sampleAt(int t, {double temp = 30, bool paused = false, Map<String, dynamic>? speed, bool plugged = false}) => [
  rec('thermal', t, {'battery_temp_c': temp, 'thermal_status': 'none', 'thermal_headroom': null, if (paused) 'paused': true}),
  rec('power', t, {
    'power_w': 2.0,
    'battery_current_ua': -500000,
    'battery_voltage_mv': 4000,
    'charge_counter_uah': 3000000,
    'is_charging': false,
    'is_plugged': plugged,
  }),
  if (speed != null) rec('analysis_speed', t, {'clip': 'a.mp4', ...speed}),
];

void main() {
  test('runs are placed back to back on the analysis clock, with a gap between them', () {
    const t1 = t0 + 3600000; // continued an hour later
    final s = VideoRunSamples.parse([
      rec('video_run_start', t0, {'sample_s': 10}),
      ...sampleAt(t0),
      for (var i = 0; i < 4; i++) rec('raw_detections', t0 + 1000 + i, {'boxes': []}),
      ...sampleAt(t0 + 10000, speed: {'frames_per_s': 12.5, 'frames': 125, 'detect_ms': 40.0}),
      rec('video_thermal_pause', t0 + 12000, {'temp_c': 40}),
      ...sampleAt(t0 + 20000, temp: 39, paused: true, speed: {'frames_per_s': 2.0, 'paused_ms': 8000}),
      rec('video_thermal_resume', t0 + 25000, {'paused_ms': 13000}),
      rec('video_run_end', t0 + 30000),
      rec('video_run_start', t1, {'sample_s': 30}),
      ...sampleAt(t1),
      ...sampleAt(t1 + 30000, speed: {'frames_per_s': 10.0, 'detect_ms': 42.0}),
      rec('raw_detections', t1 + 31000, {'boxes': []}), // then the app was killed
      '{"type":"thermal","time_ms":${t1 + 32000},"battery_te', // half-written line
      // Nothing left to analyse: takes no room.
      rec('video_run_start', t1 + 7200000, {'sample_s': 10}),
      rec('video_run_end', t1 + 7200001),
    ]);

    expect(s.runs, 2);
    expect(s.sampleSeconds, [10, 30]);
    // Gap: 5 intervals of the longest setting, at least a minute.
    expect(s.runGapMs, 150000);
    expect(s.temps.map((p) => p.$1), [0, 10000, 20000, 180000, 210000]);
    expect(s.temps.map((p) => p.$2), [30, 30, 39, 30, 30]);
    expect(s.samples.map((x) => x.run), [1, 1, 1, 2, 2]);
    expect(s.framesPerS, [(10000, 12.5), (20000, 2.0), (210000, 10.0)]);
    // The period with a cooling pause is left out of the "while running" figures.
    expect(s.framesPerSRunning, [(10000, 12.5), (210000, 10.0)]);
    expect(s.samples[2].pausedMs, 8000);
    expect(s.detectMs, [(10000, 40.0), (210000, 42.0)]);
    expect(s.samples[1].frames, 125);
    expect(s.samples[2].paused, isTrue);
    expect(s.pauses, [(12000, 25000)]);
    // The killed run ends at its last box.
    expect(s.totalMs, 180000 + 31000);
    expect(s.runMs, 30000 + 31000);
    expect(s.pausedMs, 13000);
    expect(s.frames, 5);
    expect(s.meanFramesPerS, closeTo(5 * 1000 / (61000 - 13000), 1e-9));
    expect(s.power.map((p) => p.ms), [0, 10000, 20000, 180000, 210000]);
    expect(s.power.first.currentUa, -500000);
    expect(s.power.first.isPlugged, isFalse);
  });

  test('a run killed while cooling down ends its pause at its last record', () {
    final s = VideoRunSamples.parse([
      rec('video_run_start', t0, {'sample_s': 10}),
      ...sampleAt(t0),
      rec('video_thermal_pause', t0 + 5000),
      ...sampleAt(t0 + 10000, paused: true, plugged: true),
    ]);
    expect(s.pauses, [(5000, 10000)]);
    expect(s.meanFramesPerS, isNull);
    expect(s.power.last.isPlugged, isTrue);
  });

  test('no file, or no samples: nothing to show', () async {
    final dir = Directory.systemTemp.createTempSync('video_run_samples_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(await VideoRunSamples.parseFile('${dir.path}/none.jsonl'), isNull);
    final f = File('${dir.path}/v.jsonl')..writeAsStringSync('${rec('video_run_start', t0)}\n${rec('video_run_end', t0 + 5)}\n');
    expect((await VideoRunSamples.parseFile(f.path))!.isEmpty, isTrue);
  });

  test('phone_during_analysis.csv from two real runs (golden file), and in Share results', () async {
    final dir = Directory.systemTemp.createTempSync('video_run_samples_csv');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/videos').createSync();
    File('${dir.path}/videos/a.mp4').writeAsStringSync('x');

    var t = DateTime.utc(2026, 9, 25, 12);
    final temps = [30.0, 45.0, 44.0, 36.0];
    var reads = 0;
    VideoDetector detector(Map<String, int> clips) => VideoDetector(
      backend: FakeBackend(clips, onNext: () => t = t.add(const Duration(seconds: 1))),
      thermal: () async => ThermalReading(
        batteryTempC: reads < temps.length ? temps[reads++] : 30.5,
        thermalStatus: 'none',
        batteryCurrentUa: -412345,
        batteryVoltageMv: 8812, // a Xiaomi's two-cell voltage, logged raw
        isCharging: false,
        isPlugged: false,
      ),
      now: () => t,
      sleep: (d) async => t = t.add(d),
    );
    await detector({'a.mp4': 6}).run(dir, config: config, sampleEvery: const Duration(seconds: 5));
    // Continued an hour later with a new clip whose name needs quoting.
    t = t.add(const Duration(hours: 1));
    File('${dir.path}/videos/c, late.mp4').writeAsStringSync('x');
    await detector({'a.mp4': 6, 'c, late.mp4': 3}).run(dir, config: config, sampleEvery: const Duration(seconds: 5));

    final samples = await VideoRunSamples.parseFile('${dir.path}/${VideoDetector.outputFileName}');
    final csv = samples!.toCsv();
    final golden = File('test/fauna_pulse/fixtures/phone_during_analysis.csv');
    if (autoUpdateGoldenFiles) golden.writeAsStringSync(csv);
    expect(csv, golden.readAsStringSync());

    final zipPath = '${dir.path}/results.zip';
    expect(await VideoTracker.writeResultsZip(dir.path, zipPath), zipPath);
    final zipped = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync()).findFile(VideoRunSamples.csvFileName);
    expect(utf8.decode(zipped!.content as List<int>), csv);
  });
}
