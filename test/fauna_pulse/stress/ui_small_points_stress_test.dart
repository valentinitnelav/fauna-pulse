// Small on-screen points found in stress-test screenshots: a duration field
// showed its unit twice ("2.0 s" plus the unit menu "s"), the capture time
// used a colon before the milliseconds (20:59:00:313), and the slow-phone
// banner let the camera chip behind it show through.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/perf/slow_phone_hint.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/duration_setting_field.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/numeric_setting_field.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('DurationSettingField shows its unit once (menu, not box)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        DurationSettingField(
          label: 'Keep time-window',
          valueSeconds: 2,
          minSeconds: 1,
          maxSeconds: 60,
          onChanged: (_) {},
        ),
      ),
    );
    final box = tester.widget<TextField>(find.byType(TextField));
    expect(box.decoration?.suffixText, isNull);
    expect(find.text('s'), findsOneWidget);
  });

  testWidgets('NumericSettingField still shows its unit in the box', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        NumericSettingField(
          label: 'Rate',
          value: 2,
          min: 1,
          max: 10,
          unitSuffix: '/s',
          onChanged: (_) {},
        ),
      ),
    );
    final box = tester.widget<TextField>(find.byType(TextField));
    expect(box.decoration?.suffixText, '/s');
  });

  test('capture time uses a dot before the milliseconds', () {
    final ms = DateTime(2026, 10, 20, 20, 59, 0, 313).millisecondsSinceEpoch;
    expect(formatCaptureStamp(ms), '20:59:00.313');
    expect(formatCaptureStamp(0), 'unknown');
  });

  testWidgets('slow-phone banner background is opaque', (tester) async {
    await tester.pumpWidget(
      _host(SlowPhoneBanner(perSecond: 1.2, onOk: () {}, onNeverAgain: () {})),
    );
    final box = tester.widget<Container>(
      find.descendant(of: find.byType(SlowPhoneBanner), matching: find.byType(Container)).first,
    );
    final color = (box.decoration! as BoxDecoration).color!;
    expect(color.a, 1.0);
  });
}
