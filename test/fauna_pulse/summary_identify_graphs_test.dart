// FaunaPulse (round 363): the summary's extra graphs offer "While identification
// ran" for a session that was identified. With the readings file
// (identification/phone_during_identification.jsonl) the graphs of the video
// analysis draw the Identify runs; a session identified before the readings
// were saved says "not measured"; a session never identified has no choice at
// all. 360 px wide with a system bar, as every summary test (the chips of the
// choice must not overflow, and the last row stays above the bar). Fixture and
// pump pattern: summary_bottom_inset_test.dart (sync IO, short runAsync waits).

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;
import 'summary_tabs_test.dart' show expectSummaryRowValue;

const _gb = 1024 * 1024 * 1024;
const _t0 = 1794225600000;

String _rec(String type, int t, [Map<String, dynamic> fields = const {}]) =>
    jsonEncode({'type': type, 'time_ms': t, ...fields});

/// The records of one sample, as IdentifyPhoneLog writes them.
List<String> _sampleAt(int s, double temp, String step, {Map<String, dynamic>? speed, bool paused = false}) => [
  _rec('thermal', _t0 + s * 1000, {
    'battery_temp_c': temp,
    'thermal_status': 'none',
    'cpu_temp_c': temp + 20,
    'gpu_temp_c': temp + 10,
    'mem_total_bytes': 8 * _gb,
    'mem_free_bytes': 3 * _gb,
    'app_cpu_cores': 2.5,
    'step': step,
    if (paused) 'paused': true,
  }),
  _rec('power', _t0 + s * 1000, {
    'power_w': 1.6,
    'battery_current_ua': -400000,
    'battery_voltage_mv': 4000,
    'is_charging': false,
    'is_plugged': false,
  }),
  if (speed != null) _rec('identify_speed', _t0 + s * 1000, {'step': step, ...speed}),
];

/// A live session with its own temperature records; [identified]: with
/// identification results; [readings]: with the phone readings of one Identify
/// run of 54 s (40 s on the crops with a 13 s heat pause, 14 s on the results).
File _session({required bool identified, required bool readings}) {
  final tmp = Directory.systemTemp.createTempSync('summary_identify_graphs');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final log = File('${tmp.path}/session.jsonl');
  log.writeAsStringSync([
    '{"type":"start_of_session","time_ms":1000,"model_path":"yolo26n","session_id":"t","config":{"captureTrigger":"detector"}}',
    for (var i = 0; i < 6; i++) '{"type":"thermal","time_ms":${2000 + i * 10000},"battery_temp_c":${30 + i * 0.5}}',
    '{"type":"end_of_session","time_ms":60000,"ended_normally":true,"unique_track_count":0}',
  ].join('\n'));
  if (identified) {
    Directory('${tmp.path}/identification').createSync();
    File('${tmp.path}/identification/summary_pack1.json').writeAsStringSync(
      jsonEncode({'generated_iso': '2026-11-09T10:00:00.000', 'pack_id': 'pack1', 'tracks_total': 0, 'tracks': []}),
    );
  }
  if (readings) {
    File('${tmp.path}/identification/phone_during_identification.jsonl').writeAsStringSync(
      '${[
        _rec('identify_run_start', _t0, {'model': 'bioclip-2_224_fp16.tflite', 'step': 'crops', 'sample_s': 10}),
        ..._sampleAt(0, 30, 'crops'),
        ..._sampleAt(10, 31, 'crops', speed: {'crops': 2, 'crops_per_s': 0.2, 'model_ms': 300.0}),
        _rec('identify_thermal_pause', _t0 + 12000, {'temp_c': 44}),
        ..._sampleAt(20, 44, 'crops', paused: true, speed: {'crops': 0, 'crops_per_s': 0.0, 'paused_ms': 8000}),
        _rec('identify_thermal_resume', _t0 + 25000, {'paused_ms': 13000}),
        ..._sampleAt(30, 39, 'crops', speed: {'crops': 3, 'crops_per_s': 0.3, 'model_ms': 320.0, 'paused_ms': 5000}),
        ..._sampleAt(40, 38, 'crops', speed: {'crops': 4, 'crops_per_s': 0.4, 'model_ms': 310.0}),
        ..._sampleAt(50, 37, 'results'),
        ..._sampleAt(54, 37, 'results'),
        _rec('identify_run_end', _t0 + 54000, {'cancelled': false}),
      ].join('\n')}\n',
    );
  }
  return log;
}

Future<void> _pumpUntil(WidgetTester tester, Finder ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    if (ready.evaluate().isNotEmpty) break;
  }
  expect(ready, findsWidgets, reason: 'content never appeared: $ready');
}

/// Opens the Graphs tab with the extra graphs unfolded; returns its scrollable.
Future<Finder> _openGraphs(WidgetTester tester, File log) async {
  simulateBottomSystemBar(tester); // 360 px wide
  SharedPreferences.setMockInitialValues({'extra_graphs_expanded': true});
  await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: log, initialTabIndex: 1)));
  await _pumpUntil(tester, find.textContaining('over the session (°C)', skipOffstage: false));
  return find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
}

/// Taps the choice [label]; returns where the list was scrolled to at the tap.
Future<double> _choose(WidgetTester tester, Finder scrollable, String label) async {
  await tester.scrollUntilVisible(find.text(label), 200, scrollable: scrollable);
  await tester.pump();
  final at = tester.state<ScrollableState>(scrollable).position.pixels;
  await tester.tap(find.text(label));
  await tester.pump();
  return at;
}

void main() {
  testWidgets('an identified session with readings: the third choice draws the Identify run', (tester) async {
    final scrollable = await _openGraphs(tester, _session(identified: true, readings: true));
    // The recording's graphs first, as before; no detector choice without videos.
    expect(find.text('While recording', skipOffstage: false), findsOneWidget);
    expect(find.text('While the detector ran', skipOffstage: false), findsNothing);

    final tappedAt = await _choose(tester, scrollable, 'While identification ran');
    expect(tappedAt, greaterThan(0));
    await _pumpUntil(tester, find.text('Identification time', skipOffstage: false));
    // The page is shorter while the readings are read; afterwards it is back where the choice
    // was tapped, so the choice is still on the screen, with its graphs below it.
    await tester.pump();
    expect(tester.state<ScrollableState>(scrollable).position.pixels, tappedAt);
    expect(find.widgetWithText(ChoiceChip, 'While identification ran').hitTestable(), findsOneWidget);
    expect(find.textContaining('over the session (°C)', skipOffstage: false), findsNothing);
    expect(find.textContaining('Measured every 10 s while "Identify organisms" ran', skipOffstage: false), findsOneWidget);
    await expectSummaryRowValue(tester, scrollable, label: 'Identification time', value: '0m 54s');
    await expectSummaryRowValue(tester, scrollable, label: 'Identifying crops', value: '0m 40s');
    await expectSummaryRowValue(tester, scrollable, label: 'Combining results', value: '0m 14s');
    await expectSummaryRowValue(tester, scrollable, label: 'Crops identified', value: '9');
    await expectSummaryRowValue(tester, scrollable, label: 'Cooling pauses', value: '1 (0m 13s in total)');
    // 1.6 W over 54 s.
    await expectSummaryRowValue(tester, scrollable, label: 'Energy used', value: '≈ 0.02 Wh (on battery)');
    for (final title in ['Temperatures (°C)', 'Crops identified per second', 'Model time per crop (ms)']) {
      await tester.scrollUntilVisible(find.text(title), 200, scrollable: scrollable);
      expect(find.text('Not enough samples.', skipOffstage: false), findsNothing);
    }
    // The periods with a part of the heat pause (0 and 0.3 crops per second) are left out.
    // Looked for here, just above the title in view: the list builds only the rows near the screen.
    expect(
      find.text('Without the cooling pauses: median 0.30 crops per second; min 0.20, max 0.40.', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Frames analyzed per second', skipOffstage: false), findsNothing);
    await tester.scrollUntilVisible(find.text('Power draw (W)'), 200, scrollable: scrollable);
    expect(find.text('Not enough samples.', skipOffstage: false), findsNothing);
    final list = tester.state<ScrollableState>(scrollable);
    list.position.jumpTo(list.position.maxScrollExtent);
    await tester.pump();
    expectAboveBottomInset(tester, find.textContaining('No track IDs in this session'), label: 'last row');
    expect(tester.takeException(), isNull);

    // Back to the recording (the choice is above: search from the top again).
    list.position.jumpTo(0);
    await tester.pump();
    await _choose(tester, scrollable, 'While recording');
    await _pumpUntil(tester, find.textContaining('over the session (°C)', skipOffstage: false));
    expect(find.text('Identification time', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a session identified before the readings were saved says "not measured"', (tester) async {
    final scrollable = await _openGraphs(tester, _session(identified: true, readings: false));
    await _choose(tester, scrollable, 'While identification ran');
    await _pumpUntil(tester, find.textContaining('Not measured: when this session was identified', skipOffstage: false));
    expect(find.text('Identification time', skipOffstage: false), findsNothing);
    expect(find.textContaining('over the session (°C)', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a session that was never identified has no choice above its graphs', (tester) async {
    await _openGraphs(tester, _session(identified: false, readings: false));
    expect(find.byType(ChoiceChip, skipOffstage: false), findsNothing);
    expect(find.text('While identification ran', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
