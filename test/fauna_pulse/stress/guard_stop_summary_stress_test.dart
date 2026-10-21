// Stress finding (2026-10-20): when the storage or battery guard stopped a
// recording, the summary said only "Ended normally: Yes", so a user could
// believe the session ran for its whole planned time. The Setup Overview now
// adds a "Stopped by itself" row from the `guard_stop` record, and shows no
// such row for a session the user stopped.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';

Future<void> _pumpSummary(WidgetTester tester, List<String> lines) async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('guard_stop_summary');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final log = File('${tmp.path}/session.jsonl')..writeAsStringSync(lines.join('\n'));
  await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(logFile: log, initialTabIndex: 2)));
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    if (find.text('Ended normally').evaluate().isNotEmpty) break;
  }
  expect(find.text('Ended normally'), findsOneWidget);
}

const _start =
    '{"type":"start_of_session","time_ms":1000,"session_id":"t",'
    '"config":{"captureTrigger":"timelapse","storageReserveMb":200,"lowBatteryStopPercent":15}}';
const _end = '{"type":"end_of_session","time_ms":7000,"ended_normally":true,"unique_track_count":0}';

void main() {
  testWidgets('storage guard stop is explained next to "Ended normally"', (tester) async {
    await _pumpSummary(tester, [
      _start,
      '{"type":"guard_stop","time_ms":6900,"reason":"storage_low",'
          '"battery_percent":null,"free_storage_bytes":146489344}',
      _end,
    ]);
    expect(find.text('Stopped by itself'), findsOneWidget);
    expect(find.text('Yes: storage almost full (140 MB free, limit 200 MB)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('battery guard stop is explained with level and limit', (tester) async {
    await _pumpSummary(tester, [
      _start,
      '{"type":"guard_stop","time_ms":6900,"reason":"low_battery",'
          '"battery_percent":14,"free_storage_bytes":5000000000}',
      _end,
    ]);
    expect(find.text('Yes: battery low (14 %, limit 15 %)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a session without a guard stop shows no "Stopped by itself" row', (tester) async {
    await _pumpSummary(tester, [_start, _end]);
    expect(find.text('Stopped by itself'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
