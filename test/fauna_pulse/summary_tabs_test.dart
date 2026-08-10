// Round 187 regression tests for the reorganized session summary:
//  * the Overview tab is gone — the Setup tab leads with the Overview rows
//    and hides the full settings record behind a tap-to-show header, where
//    mode-inapplicable settings are listed anyway (dimmed + a "not
//    applicable" note) instead of hidden;
//  * the Photos tab auto-loads a RANDOM sample of at most 10 photos and
//    offers "Show all N photos".
//
// Follows summary_bottom_inset_test.dart's async recipe (sync fixture IO,
// runAsync/pump interleave — see that file's header for why).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';

/// Interleaves real async (file IO + the SessionLogIndex worker isolate)
/// with fake-clock frames until [ready] finds something.
Future<void> pumpUntilFound(WidgetTester tester, Finder ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (ready.evaluate().isNotEmpty) break;
  }
  expect(ready, findsWidgets, reason: 'content never appeared: $ready');
}

/// A session folder whose log records [photoCount] time-lapse photos, each
/// with a real (tiny) JPEG on disk.
Directory writeTimeLapseSession(int photoCount, {String? configExtra}) {
  final tmp = Directory.systemTemp.createTempSync('summary_tabs');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final im = img.Image(width: 32, height: 32);
  img.fill(im, color: img.ColorRgb8(40, 120, 40));
  final jpegBytes = img.encodeJpg(im, quality: 90);
  Directory('${tmp.path}/roi_frames').createSync();
  final captureLines = <String>[];
  for (var i = 0; i < photoCount; i++) {
    final name =
        'roi_t3st_2026-08-05_10${(i ~/ 60).toString().padLeft(2, '0')}'
        '${(i % 60).toString().padLeft(2, '0')}_000.jpg';
    File('${tmp.path}/roi_frames/$name').writeAsBytesSync(jpegBytes);
    captureLines.add(
      '{"type":"timelapse_capture","time_ms":${2000 + i * 1000},'
      '"jpeg":"$name","captured_at_ms":${1990 + i * 1000},"burst":0}',
    );
  }
  File('${tmp.path}/session.jsonl').writeAsStringSync([
    '{"type":"start_of_session","time_ms":1000,"session_id":"t",'
        '"battery_percent":80,'
        '"config":{"captureTrigger":"timelapse"${configExtra ?? ''}}}',
    ...captureLines,
    '{"type":"end_of_session","time_ms":60000,"ended_normally":true,'
        '"battery_percent":78,"unique_track_count":0}',
  ].join('\n'));
  return tmp;
}

void main() {
  testWidgets(
    'Setup Overview starts with capture mode and reports a model only for AI',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cases = <({String trigger, String label, bool usesAi})>[
        (trigger: 'detector', label: 'AI detector', usesAi: true),
        (
          trigger: 'motion',
          label: 'Motion-triggered photos (no AI)',
          usesAi: false,
        ),
        (
          trigger: 'timelapse',
          label: 'Time-lapse photo bursts (no AI)',
          usesAi: false,
        ),
      ];

      for (final c in cases) {
        final tmp = Directory.systemTemp.createTempSync(
          'summary_overview_${c.trigger}',
        );
        addTearDown(() {
          try {
            tmp.deleteSync(recursive: true);
          } catch (_) {}
        });
        const modelPath = '/models/field_detector.tflite';
        File('${tmp.path}/session.jsonl').writeAsStringSync(
          [
            '{"type":"start_of_session","time_ms":1000,"session_id":"t",'
                '"model_path":"$modelPath","accelerator":"GPU",'
                '"config":{"captureTrigger":"${c.trigger}",'
                '"modelPath":"$modelPath"}}',
            '{"type":"end_of_session","time_ms":60000,'
                '"ended_normally":true,"unique_track_count":0}',
          ].join('\n'),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SessionSummaryScreen(
              logFile: File('${tmp.path}/session.jsonl'),
              initialTabIndex: 2,
            ),
          ),
        );
        await pumpUntilFound(tester, find.text('Overview'));

        expect(find.text(c.label), findsOneWidget);
        expect(
          find.text(
            c.usesAi ? modelPath : 'Not applicable (no AI detector used)',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Inference engine'),
          c.usesAi ? findsOneWidget : findsNothing,
        );
        expect(
          tester.getTopLeft(find.text('Capture mode')).dy,
          lessThan(tester.getTopLeft(find.text('Date')).dy),
        );

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );

  testWidgets(
    'Photos tab auto-loads a random sample of 10 and "Show all" loads the rest',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tmp = writeTimeLapseSession(15);

      await tester.pumpWidget(
        MaterialApp(
          home: SessionSummaryScreen(
            logFile: File('${tmp.path}/session.jsonl'),
            initialTabIndex: 0, // Photos
          ),
        ),
      );
      await pumpUntilFound(tester, find.textContaining('saved photo'));
      expect(
        find.textContaining(
          'Showing 10 of 15 saved photos this session — picked at random',
        ),
        findsOneWidget,
      );

      // 15 photos is under the slowness-warning threshold: the button loads
      // everything without a confirmation dialog.
      await tester.tap(find.text('Show all 15 photos'));
      await pumpUntilFound(tester, find.textContaining('Showing 15 of 15'));
      expect(find.text('Show all 15 photos'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Setup tab: Overview rows lead; the full record unfolds with every '
    'setting listed and mode-inapplicable ones marked',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      // A time-lapse session that ALSO carries detector/gate settings in its
      // config (as every real config block does): those must be listed after
      // the reveal, under "not applicable" notes — not hidden (round 187).
      final tmp = writeTimeLapseSession(
        1,
        configExtra:
            ',"modelPath":"yolo26n","confidenceThreshold":0.25,'
            '"autoThrottle":true,"motionGateEnabled":true,'
            '"timeLapseGapSeconds":30',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SessionSummaryScreen(
            logFile: File('${tmp.path}/session.jsonl'),
            initialTabIndex: 2, // Setup
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Overview'));
      expect(find.text('Battery used'), findsOneWidget);
      expect(find.text('Session storage'), findsOneWidget);
      // The full record is collapsed by default.
      expect(find.text('Model & detection'), findsNothing);

      // The reveal header (and later rows) may sit below the lazy ListView's
      // fold — scroll each target into view first.
      final scrollable = find.descendant(
        of: find.byType(ListView).first,
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.textContaining('All session settings'),
        200,
        scrollable: scrollable,
      );
      await tester.tap(find.textContaining('All session settings'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Model & detection'),
        200,
        scrollable: scrollable,
      );
      expect(find.textContaining('the detector never ran'), findsOneWidget);
      // The detector settings are listed anyway (dimmed), not hidden.
      await tester.scrollUntilVisible(
        find.text('Confidence threshold'),
        200,
        scrollable: scrollable,
      );
      await tester.scrollUntilVisible(
        find.textContaining('Motion gate — not used in time-lapse mode'),
        200,
        scrollable: scrollable,
      );
      await tester.scrollUntilVisible(
        find.text('Time between bursts'),
        200,
        scrollable: scrollable,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'plugged-but-not-charging session hides the power graph (round 188)',
    (tester) async {
      // A power bank with a full battery reports NOT_CHARGING while plugged:
      // is_charging false, is_plugged true. The energy series must still be
      // invalidated (the sensor sees the charger's load, not consumption).
      SharedPreferences.setMockInitialValues({'extra_graphs_expanded': true});
      final tmp = Directory.systemTemp.createTempSync('summary_plugged');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      File('${tmp.path}/session.jsonl').writeAsStringSync([
        '{"type":"start_of_session","time_ms":1000,"session_id":"t",'
            '"config":{"captureTrigger":"detector"}}',
        '{"type":"power","time_ms":2000,"battery_current_ua":500000,'
            '"battery_voltage_mv":3900,"power_w":1.95,'
            '"is_charging":false,"is_plugged":true}',
        '{"type":"power","time_ms":12000,"battery_current_ua":500000,'
            '"battery_voltage_mv":3900,"power_w":1.95,'
            '"is_charging":false,"is_plugged":true}',
        '{"type":"end_of_session","time_ms":60000,"ended_normally":true,'
            '"unique_track_count":0}',
      ].join('\n'));

      await tester.pumpWidget(
        MaterialApp(
          home: SessionSummaryScreen(
            logFile: File('${tmp.path}/session.jsonl'),
            initialTabIndex: 1, // Graphs
          ),
        ),
      );
      await pumpUntilFound(tester, find.textContaining('Visit timeline'));

      final scrollable = find.descendant(
        of: find.byType(ListView).first,
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.textContaining('Not shown: the phone was plugged in'),
        200,
        scrollable: scrollable,
      );
      // And no W caption was computed from the meaningless samples.
      expect(find.textContaining('Average power'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Setup tab, AI session: time-lapse settings listed as not applicable',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tmp = Directory.systemTemp.createTempSync('summary_tabs_ai');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      File('${tmp.path}/session.jsonl').writeAsStringSync([
        '{"type":"start_of_session","time_ms":1000,"session_id":"t",'
            '"config":{"captureTrigger":"detector","modelPath":"yolo26n",'
            '"timeLapseGapSeconds":30}}',
        '{"type":"end_of_session","time_ms":60000,"ended_normally":true,'
            '"unique_track_count":0}',
      ].join('\n'));

      await tester.pumpWidget(
        MaterialApp(
          home: SessionSummaryScreen(
            logFile: File('${tmp.path}/session.jsonl'),
            initialTabIndex: 2, // Setup
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Overview'));
      final scrollable = find.descendant(
        of: find.byType(ListView).first,
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.textContaining('All session settings'),
        200,
        scrollable: scrollable,
      );
      await tester.tap(find.textContaining('All session settings'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.textContaining('Time-lapse settings — not applicable'),
        200,
        scrollable: scrollable,
      );
      await tester.scrollUntilVisible(
        find.text('Time between bursts'),
        200,
        scrollable: scrollable,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
