// FaunaPulse (round 363): the phone's readings while Identify runs
// (identify_phone_log.dart): which records one run writes, how the speed
// periods and the heat pauses are counted, that a later run appends, and that
// the parser of the video analysis (VideoRunSamples) reads the file and makes
// its table. The clock is a variable of the test, so every number is exact.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identify_phone_log.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_run_samples.dart';
import 'package:flutter_test/flutter_test.dart';

const gb = 1024 * 1024 * 1024;
const model = 'bioclip-2_224_fp16.tflite';

void main() {
  // "Update results" reads the phone through the app's own channel, which answers nothing in a test.
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory session;
  late IdentificationPaths paths;
  late DateTime t;
  late double temp;

  setUp(() {
    session = Directory.systemTemp.createTempSync('identify_phone_log');
    paths = IdentificationPaths(session);
    t = DateTime.utc(2026, 11, 9, 12);
    temp = 30;
  });
  tearDown(() => session.deleteSync(recursive: true));

  Future<ThermalReading> phone() async => ThermalReading(
    batteryTempC: temp,
    thermalStatus: 'none',
    batteryCurrentUa: -400000,
    batteryVoltageMv: 4000,
    isCharging: false,
    isPlugged: false,
    cpuTempC: temp + 20,
    gpuTempC: temp + 10,
    memTotalBytes: 8 * gb,
    memFreeBytes: 3 * gb,
    appMemoryBytes: gb,
    appCpuCores: 2.5,
    cpuCount: 8,
  );

  // The timer never fires within a test at this interval: every sample below is asked for.
  IdentifyPhoneLog newLog() => IdentifyPhoneLog(session, thermal: phone, now: () => t);
  void wait(int seconds) => t = t.add(Duration(seconds: seconds));
  List<Map<String, dynamic>> records() => [
    for (final line in paths.phoneJsonl.readAsLinesSync()) jsonDecode(line) as Map<String, dynamic>,
  ];

  /// One run of 54 s: 40 s on the crops with a heat pause of 13 s, 14 s on the results.
  Future<void> oneRun() async {
    final log = newLog();
    await log.start({'model': model, 'pack': 'europe.fpack', 'crops_pending': 5});
    wait(10);
    await log.sample(); // no crop finished yet: no speed record, the period goes on
    log.addCrops(2, 9000);
    wait(10);
    await log.sample();
    wait(2);
    temp = 44;
    log.pauseStarted(44, 43);
    log.pauseStarted(44.5, 43); // a later reading of the same wait
    wait(8);
    await log.sample();
    wait(5);
    temp = 39;
    log.pauseEnded(39);
    log.addCrops(3, 6000);
    wait(5);
    await log.beginStep('results');
    wait(10);
    await log.sample();
    wait(4);
    await log.end();
  }

  test('one run: the records, the speed periods, the heat pause and both steps', () async {
    final t0 = t.millisecondsSinceEpoch;
    await oneRun();
    final recs = records();
    expect(recs.map((r) => '${(r['time_ms'] as int) - t0} ${r['type']}'), [
      '0 identify_run_start',
      '0 thermal',
      '0 power',
      '10000 thermal',
      '10000 power',
      '20000 thermal',
      '20000 power',
      '20000 identify_speed',
      '22000 identify_thermal_pause',
      '30000 thermal',
      '30000 power',
      '30000 identify_speed',
      '35000 identify_thermal_resume',
      '40000 thermal',
      '40000 power',
      '40000 identify_speed',
      '50000 thermal',
      '50000 power',
      '54000 thermal',
      '54000 power',
      '54000 identify_run_end',
    ]);
    expect(recs.first, containsPair('sample_s', 10));
    expect(recs.first, containsPair('model', model));
    expect(recs.first, containsPair('step', 'crops'));
    // The reading as the other files hold it, with the step the phone was in.
    expect(recs[1], containsPair('battery_temp_c', 30.0));
    expect(recs[1], containsPair('cpu_temp_c', 50.0));
    expect(recs[1], containsPair('mem_free_bytes', 3 * gb));
    expect(recs[1], containsPair('step', 'crops'));
    expect(recs[2], containsPair('power_w', closeTo(1.6, 1e-9)));
    Map<String, dynamic> speed(int i) => recs.where((r) => r['type'] == 'identify_speed').elementAt(i)..remove('time_ms');
    // Two crops in the 20 s since the start: the sample without a crop did not cut the period.
    expect(speed(0), {'type': 'identify_speed', 'step': 'crops', 'period_ms': 20000, 'crops': 2, 'crops_per_s': 0.1, 'model_ms': 4500.0});
    // Waiting to cool down since 22 s.
    expect(speed(1), {'type': 'identify_speed', 'step': 'crops', 'period_ms': 10000, 'crops': 0, 'crops_per_s': 0.0, 'paused_ms': 8000});
    // The rest of the pause, then three crops; written where the step ends.
    expect(speed(2), {'type': 'identify_speed', 'step': 'crops', 'period_ms': 10000, 'crops': 3, 'crops_per_s': 0.3, 'model_ms': 2000.0, 'paused_ms': 5000});
    expect(recs[8], containsPair('resume_below_c', 40.0));
    expect(recs[9], containsPair('paused', true));
    expect(recs[12], containsPair('paused_ms', 13000));
    expect(recs[16], containsPair('step', 'results'));
    expect(recs.last, containsPair('cancelled', false));
  });

  test('the parser of the video analysis reads the file; the table has one row per sample', () async {
    final t0 = t.millisecondsSinceEpoch;
    await oneRun();
    final s = (await VideoRunSamples.parseFile(paths.phoneJsonl.path))!;
    expect(s.runs, 1);
    expect(s.sampleSeconds, [10]);
    expect(s.runMs, 54000);
    expect(s.frames, 5, reason: 'crops, added up from the speed records');
    expect(s.pauses, [(22000, 35000)]);
    expect(s.pausedMs, 13000);
    expect(s.msOf('crops'), 40000);
    expect(s.msOf('results'), 14000);
    expect(s.samples.map((x) => x.clip), ['crops', 'crops', 'crops', 'crops', 'crops', 'results', 'results']);
    expect(s.temps.map((p) => p.$2), [30, 30, 30, 44, 39, 39, 39]);
    expect(s.framesPerS, [(20000, 0.1), (30000, 0.0), (40000, 0.3)]);
    expect(s.framesPerSRunning, [(20000, 0.1)], reason: 'periods with a pause are left out');
    expect(s.detectMs, [(20000, 4500.0), (40000, 2000.0)]);
    expect(s.power.first.isPlugged, isFalse);

    const tail = '8589934592,3221225472,1073741824,2.5';
    String row(int s, String step, double temp, String speed, {bool paused = false}) =>
        '1,$s.0,${t0 + s * 1000},$model,$step,$temp,,none,1.6,-400000,4000,false,false,$speed,$paused,,$tail,${temp + 20},${temp + 10}';
    final csv = paths.phoneCsv.readAsStringSync();
    expect(csv, s.toIdentifyCsv(), reason: 'written at the end of the run');
    expect(csv.trimRight().split('\n'), [
      VideoRunSamples.identifyCsvHeader,
      row(0, 'crops', 30, ',,'),
      row(10, 'crops', 30, ',,'),
      row(20, 'crops', 30, '0.1,2,4500.0'),
      row(30, 'crops', 44, '0.0,0,', paused: true).replaceFirst('true,,', 'true,8000,'),
      row(40, 'crops', 39, '0.3,3,2000.0').replaceFirst('false,,$tail', 'false,5000,$tail'),
      row(50, 'results', 39, ',,'),
      row(54, 'results', 39, ',,'),
    ]);
  });

  test('a run that was closed keeps its lines; the next run appends and repairs a cut last line', () async {
    final first = newLog();
    await first.start({'model': model});
    first.addCrops(4, 400);
    wait(10);
    await first.sample();
    first.close(); // the app was closed: no end record, no table
    expect(paths.phoneCsv.existsSync(), isFalse);
    // The last line was cut in the middle of a write.
    paths.phoneJsonl.writeAsStringSync('{"type":"thermal","time_ms":17', mode: FileMode.append);

    wait(3600);
    final second = newLog();
    await second.start({'model': 'other.tflite'}, step: 'results');
    wait(7);
    await second.end(cancelled: true);

    for (final line in paths.phoneJsonl.readAsLinesSync()) {
      expect(() => jsonDecode(line), returnsNormally, reason: line);
    }
    final s = (await VideoRunSamples.parseFile(paths.phoneJsonl.path))!;
    expect(s.runs, 2);
    expect(s.samples.map((x) => (x.run, x.model, x.clip)), [
      (1, model, 'crops'),
      (1, model, 'crops'),
      (2, 'other.tflite', 'results'),
      (2, 'other.tflite', 'results'),
    ]);
    // The gap between the runs is the parser's, not the hour that passed.
    expect(s.samples.map((x) => x.ms), [0, 10000, 10000 + s.runGapMs, 17000 + s.runGapMs]);
    expect(s.msOf('crops'), 10000);
    expect(s.msOf('results'), 7000);
    expect(records().last, containsPair('cancelled', true));
    expect(paths.phoneCsv.readAsLinesSync().length, 5, reason: 'both runs, written when the second ended');
  });

  test('the timer saves a sample at every interval and stops with the run', () async {
    final log = IdentifyPhoneLog(session, thermal: phone, every: const Duration(milliseconds: 20));
    await log.start({'model': model});
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await log.end();
    final samples = records().where((r) => r['type'] == 'thermal').length;
    // The first and the last sample plus the timer's (12 at most in 250 ms; a loaded machine gives fewer).
    expect(samples, greaterThanOrEqualTo(5));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(records().where((r) => r['type'] == 'thermal').length, samples, reason: 'no sample after the end');
    log.close(); // safe to call again
  });

  test('"Update results" is a run of its own, also when the scoring fails', () async {
    expect(await IdentifyPhoneLog.during(session, run: {'model': model}, work: () async => 7), 7);
    await expectLater(
      IdentifyPhoneLog.during<int>(session, run: {'model': model}, work: () async => throw StateError('no embeddings')),
      throwsStateError,
    );
    final recs = records();
    expect(recs.where((r) => r['type'] == 'identify_run_start').map((r) => r['step']), ['results', 'results']);
    expect(recs.last['error'], contains('no embeddings'));
  });

  test('a folder that cannot be written: the run goes on unmeasured', () async {
    // A file where the identification folder should be.
    File('${session.path}/identification').writeAsStringSync('x');
    final log = newLog();
    await log.start({'model': model});
    log.addCrops(1, 10);
    log.pauseStarted(44, 43);
    log.pauseEnded(40);
    await log.sample();
    await log.beginStep('results');
    await log.end();
    expect(File('${session.path}/identification').readAsStringSync(), 'x');
  });
}
