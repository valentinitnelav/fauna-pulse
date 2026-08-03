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

void main() {
  testWidgets(
    'summary Graphs tab: floating button and last row clear the system bar',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 360×800 logical screen with a 48-px bottom system bar (3-button
      // navigation size — the worst common case).
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      tester.view.padding = const FakeViewPadding(bottom: 144);
      tester.view.viewPadding = const FakeViewPadding(bottom: 144);
      addTearDown(tester.view.reset);

      // SYNC file IO on purpose: the testWidgets body runs under a fake
      // async clock, so awaiting real IO here (outside runAsync) hangs the
      // whole test — sync calls block instead of waiting on the event loop.
      final tmp = Directory.systemTemp.createTempSync('summary_inset');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final log = File('${tmp.path}/session.jsonl');
      log.writeAsStringSync([
        '{"type":"start_of_session","time_ms":1000,"model_path":"yolo26n",'
            '"session_id":"t"}',
        '{"type":"detections","time_ms":2000,"frame_ms":2000,"tracks":['
            '{"track_id":1,"class_name":"bee","confidence":0.9,'
            '"box_in_roi":{"left":0.1,"top":0.1,"right":0.2,"bottom":0.2}}]}',
        '{"type":"detections","time_ms":9000,"frame_ms":9000,"tracks":['
            '{"track_id":1,"class_name":"bee","confidence":0.9,'
            '"box_in_roi":{"left":0.1,"top":0.1,"right":0.2,"bottom":0.2}}]}',
        '{"type":"end_of_session","time_ms":10000,"ended_normally":true,'
            '"unique_track_count":1}',
      ].join('\n'));

      // Real file IO (head/tail stats) and the SessionLogIndex worker
      // isolate cannot complete under the widget test's fake async clock.
      // Canonical interleave: give them real event-loop time inside SHORT
      // runAsync windows, and pump frames OUTSIDE them (calling pump inside
      // runAsync deadlocks the two event loops against each other).
      await tester.pumpWidget(
        MaterialApp(
          home: SessionSummaryScreen(logFile: log, initialTabIndex: 3),
        ),
      );
      for (var i = 0; i < 250; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.textContaining('Extra graphs').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(
        find.textContaining('Extra graphs'),
        findsOneWidget,
        reason: 'graphs content never appeared — fixture/load problem',
      );
      // One more frame so the post-frame timeline-visibility check has run
      // and the floating button is in the tree.
      await tester.pump();

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
}
