// Round 319 (L5e): the gauge's helper line no longer repeats the title
// ("Battery temperature") or the scale's "pauses at" label; it adds only the
// resume temperature and where the limit is set.

import 'package:fauna_pulse/fauna_pulse/widgets/temperature_gauge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('helper line names only the resume temperature and the limit place', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: temperatureGauge(38, 43, paused: false, limitWhere: 'Advanced settings')),
        ),
      ),
    );
    expect(find.text('Battery temperature'), findsOneWidget);
    expect(find.textContaining('Battery temperature;'), findsNothing);
    expect(find.text('pauses at 43 °C'), findsOneWidget);
    expect(find.text('After a heat pause, the run goes on by itself below 40 °C. To change the limit, open Advanced settings after the run.'), findsOneWidget);
    // The title words appear once only, in the title itself.
    expect(find.textContaining('Battery temperature'), findsOneWidget);
  });
}
