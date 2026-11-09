// The bar charts' value axis (round 362): ticks at round numbers that follow the tallest bar,
// and a chart that paints at any size without an error.

import 'package:fauna_pulse/fauna_pulse/widgets/mini_bar_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the tick step is a round number that follows the tallest bar', () {
    // tallest bar -> step: tens for tens, hundreds for hundreds, thousands for thousands.
    const cases = {0: 1, 1: 1, 3: 1, 7: 2, 12: 5, 37: 10, 130: 50, 450: 200, 1300: 500, 9252: 5000, 40000: 10000};
    cases.forEach((tallest, step) => expect(barChartTickStep(tallest), step, reason: 'tallest bar $tallest'));
    // Never more than 7 tick lines (the chart is about 100 px high), never fewer than 2.
    for (var tallest = 1; tallest <= 20000; tallest++) {
      final step = barChartTickStep(tallest);
      final lines = (tallest / step).ceil() + 1;
      expect(lines, inInclusiveRange(2, 7), reason: 'tallest bar $tallest, step $step');
    }
  });

  testWidgets('paints with and without an axis name, also when squeezed', (tester) async {
    Future<void> pump(Size size, {String? yLabel, List<int> values = const [0, 3, 1281, 40, 0, 7]}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.fromSize(
              size: size,
              child: MiniBarChart(values: values, xLabelFor: (i) => i.isEven ? '$i h' : null, yLabel: yLabel),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    }

    await pump(const Size(328, 120), yLabel: 'Track IDs');
    await pump(const Size(328, 120));
    await pump(const Size(328, 120), yLabel: 'Track IDs', values: const [0, 0, 0]);
    await pump(const Size(328, 120), yLabel: 'Track IDs', values: const []);
    // Narrower than its own axis, or lower than its label bands: nothing to draw, no error.
    await pump(const Size(20, 120), yLabel: 'Track IDs');
    await pump(const Size(328, 20), yLabel: 'Track IDs');
  });
}
