// FaunaPulse (round 361): the summary's temperature graph draws the chip sensors
// (hottest CPU core, GPU) beside the battery line, with a legend, on phones whose
// `thermal` records carry them; without them the graph stays the battery alone.
// The fixture and pump pattern follow summary_bottom_inset_test.dart (sync fixture
// IO, frames pumped outside short runAsync waits).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

File _session({required bool chip}) {
  final tmp = Directory.systemTemp.createTempSync('summary_temps');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  String thermal(int t, double battery) =>
      '{"type":"thermal","time_ms":$t,"battery_temp_c":$battery'
      '${chip ? ',"cpu_temp_c":${battery + 25},"gpu_temp_c":${battery + 15}' : ''}}';
  final log = File('${tmp.path}/session.jsonl');
  log.writeAsStringSync([
    '{"type":"start_of_session","time_ms":1000,"model_path":"yolo26n","session_id":"t"}',
    for (var i = 0; i < 6; i++) thermal(2000 + i * 10000, 30 + i * 0.5),
    '{"type":"end_of_session","time_ms":60000,"ended_normally":true,"unique_track_count":0}',
  ].join('\n'));
  return log;
}

Future<void> _openGraphs(WidgetTester tester, File log) async {
  await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: log, initialTabIndex: 1)));
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    if (find.textContaining('Extra graphs').evaluate().isNotEmpty) break;
  }
  final scrollable = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable));
  await tester.scrollUntilVisible(find.textContaining('Extra graphs'), 300, scrollable: scrollable);
  await tester.drag(scrollable, const Offset(0, -300));
  await tester.pump();
  if (find.textContaining('over the session (°C)').evaluate().isEmpty) {
    await tester.tap(find.textContaining('Extra graphs'));
    await tester.pumpAndSettle();
  }
  await tester.scrollUntilVisible(find.textContaining('over the session (°C)'), 200, scrollable: scrollable);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('chip sensors in the records: three lines, a legend and the battery statistics', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await _openGraphs(tester, _session(chip: true));
    expect(find.text('Temperatures over the session (°C)'), findsOneWidget);
    expect(find.text('● Battery'), findsOneWidget);
    expect(find.text('● CPU'), findsOneWidget);
    expect(find.text('● GPU'), findsOneWidget);
    expect(find.textContaining('The line below is the battery.'), findsOneWidget);
    expect(find.textContaining('min 30.0°C, max 32.5°C'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without chip sensors the graph is the battery alone', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await _openGraphs(tester, _session(chip: false));
    expect(find.text('Battery temperature over the session (°C)'), findsOneWidget);
    expect(find.textContaining('● '), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
