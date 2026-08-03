// Regression guard for the recurring "cannot see / tap the last element at
// the bottom of the screen" bug class (round 165). The app renders
// edge-to-edge (forced by targetSdk 36 on Android 15+), so two traps keep
// coming back:
//  * a ListView given an EXPLICIT `padding:` loses Flutter's automatic
//    system-inset padding — its last rows scroll under the navigation bar;
//  * a `Positioned(bottom: N)` inside a full-body Stack anchors to the
//    SCREEN bottom, i.e. behind the navigation/gesture bar.
// This test simulates a 48-px bottom system bar and asserts the session
// summary's Graphs tab — where the owner hit it in the field — keeps both
// its floating timeline button and its last scrolled row fully above the
// bar. REUSE [expectAboveBottomInset] (and this fixture pattern) whenever a
// new screen gains bottom-anchored content or an explicitly-padded
// scrollable.
//
// Also here (same round, same button): the floating timeline toggle must
// only exist when there is a REAL, tall timeline (> 10 track lanes) — in
// no-AI sessions the timeline area is just an explanatory note and the
// button confused the user.
//
// Widget-test async traps this file works around (KEEP the patterns):
//  * fixture IO must be SYNC — awaiting real IO outside runAsync hangs the
//    fake-async clock (even the test timeout can't fire);
//  * frames are pumped OUTSIDE short `tester.runAsync` waits — pump inside
//    runAsync deadlocks the fake and real event loops against each other.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';

/// Asserts the widget found by [f] sits fully ABOVE the simulated system
/// bottom inset (from `tester.view.padding`): its bottom edge must not
/// reach into the navigation-bar band at the bottom of the screen.
void expectAboveBottomInset(WidgetTester tester, Finder f, {String? label}) {
  final view = tester.view;
  final logicalHeight = view.physicalSize.height / view.devicePixelRatio;
  final insetLogical = view.padding.bottom / view.devicePixelRatio;
  final bottom = tester.getBottomLeft(f).dy;
  expect(
    bottom,
    lessThanOrEqualTo(logicalHeight - insetLogical + 0.01),
    reason:
        '${label ?? f.toString()} extends into the system navigation bar '
        '(bottom edge $bottom, safe bottom ${logicalHeight - insetLogical})',
  );
}

/// 360×800 logical screen with a 48-px bottom system bar (3-button
/// navigation size — the worst common case).
void simulateBottomSystemBar(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  tester.view.padding = const FakeViewPadding(bottom: 144);
  tester.view.viewPadding = const FakeViewPadding(bottom: 144);
  addTearDown(tester.view.reset);
}

/// Writes a session.jsonl fixture (SYNC on purpose, see header) and returns
/// its File. [lines] go between matching start/end records.
File writeSessionFixture(List<String> lines, {String? startExtra}) {
  final tmp = Directory.systemTemp.createTempSync('summary_inset');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final log = File('${tmp.path}/session.jsonl');
  log.writeAsStringSync([
    '{"type":"start_of_session","time_ms":1000,"model_path":"yolo26n",'
        '"session_id":"t"${startExtra ?? ''}}',
    ...lines,
    '{"type":"end_of_session","time_ms":60000,"ended_normally":true,'
        '"unique_track_count":0}',
  ].join('\n'));
  return log;
}

/// One r69+ batched detections record with [ids] all in one frame.
String detectionsLine(int timeMs, List<int> ids) =>
    '{"type":"detections","time_ms":$timeMs,"frame_ms":$timeMs,"tracks":['
    '${ids.map((id) => '{"track_id":$id,"class_name":"bee","confidence":0.9,'
        '"box_in_roi":{"left":0.1,"top":0.1,"right":0.2,"bottom":0.2}}').join(',')}'
    ']}';

/// Pumps the summary straight onto the Graphs tab and interleaves real
/// async (file IO + the SessionLogIndex worker isolate) with fake-clock
/// frames until the graphs content is on screen.
Future<void> pumpSummaryGraphs(WidgetTester tester, File log) async {
  await tester.pumpWidget(
    MaterialApp(home: SessionSummaryScreen(logFile: log, initialTabIndex: 3)),
  );
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.textContaining('Extra graphs').evaluate().isNotEmpty) break;
  }
  expect(
    find.textContaining('Extra graphs'),
    findsOneWidget,
    reason: 'graphs content never appeared — fixture/load problem',
  );
  // One more frame so the post-frame timeline-visibility check has run.
  await tester.pump();
}

void main() {
  testWidgets(
    'summary Graphs tab: floating button and last row clear the system bar',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);
      // 12 lanes: over the >10-lane threshold, so the floating toggle
      // exists and its position can be asserted.
      final ids = List<int>.generate(12, (i) => i + 1);
      final log = writeSessionFixture([
        detectionsLine(2000, ids),
        detectionsLine(9000, ids),
      ]);

      await pumpSummaryGraphs(tester, log);

      // The floating "Hide timeline" button must not hide behind the bar
      // (it did in the field: Positioned bottom:16 on an edge-to-edge
      // body — round 165).
      expect(find.text('Hide timeline'), findsOneWidget);
      expectAboveBottomInset(
        tester,
        find.text('Hide timeline'),
        label: 'floating timeline button',
      );

      // Scroll the tab to its very end: the last content row (the collapsed
      // "Extra graphs" header) must clear the bar too.
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      expectAboveBottomInset(
        tester,
        find.textContaining('Extra graphs'),
        label: 'last graphs-tab row',
      );

      // Dispose the screen before the fake view resets.
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'no timeline toggle without a collapsible timeline (round 165)',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      simulateBottomSystemBar(tester);

      // A time-lapse session: no track ids by design — the timeline area is
      // an explanatory note, so a "Hide timeline" button would be
      // confusing (the owner's field observation).
      final noAi = writeSessionFixture(
        [
          '{"type":"timelapse_capture","time_ms":2000,"jpeg":"roi_a.jpg",'
              '"captured_at_ms":1990,"burst":0}',
        ],
        startExtra: ',"config":{"captureTrigger":"timelapse"}',
      );
      await pumpSummaryGraphs(tester, noAi);
      expect(find.text('Hide timeline'), findsNothing);
      expect(find.text('Show timeline'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      // An AI session with only a FEW lanes: real timeline, but too short
      // to cause scrolling problems — still no toggle (≤ 10 lanes).
      final fewLanes = writeSessionFixture([
        detectionsLine(2000, [1, 2, 3]),
        detectionsLine(9000, [1, 2, 3]),
      ]);
      await pumpSummaryGraphs(tester, fewLanes);
      expect(find.text('Hide timeline'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
