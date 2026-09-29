// Round 252: the temperature gauge is a labelled scale with a pointer, not a
// bar that fills (it read as a second progress bar under the job's own).

import 'package:fauna_pulse/fauna_pulse/widgets/temperature_gauge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (temp, paused) in [(31.2, false), (44.0, true)]) {
    testWidgets('gauge at $temp °C on a 360-px phone', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: temperatureGauge(temp, 43, paused: paused, limitWhere: 'under Advanced settings'),
            ),
          ),
        ),
      );
      expect(find.text('Phone temperature'), findsOneWidget);
      expect(find.text('${temp.toStringAsFixed(1)} °C'), findsOneWidget);
      expect(find.text('25 °C'), findsOneWidget);
      expect(find.text('pauses at 43 °C'), findsOneWidget);
      expect(find.byKey(const Key('temperature_scale')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Cooling down'), paused ? findsOneWidget : findsNothing);
    });
  }
}
