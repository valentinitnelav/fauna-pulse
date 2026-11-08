// Round 252: the temperature gauge is a labelled scale with a pointer, not a
// bar that fills (it read as a second progress bar under the job's own).
// Round 346: the memory scale follows the same rule, and the processor line
// names the app and the engine, so neither reads as the whole phone's load.

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/temperature_gauge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gb = 1024 * 1024 * 1024;

  testWidgets('memory scale and processor line on a 360-px phone', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const reading = ThermalReading(
      memTotalBytes: 4 * gb,
      memFreeBytes: gb,
      lowMemoryBytes: gb ~/ 2,
      appMemoryBytes: gb + gb ~/ 5,
      appCpuCores: 2.0,
      cpuCount: 8,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [...memoryGauge(reading), ...appCpuLine(reading, engine: 'CPU')],
          ),
        ),
      ),
    );
    expect(find.text('Memory in use, whole phone'), findsOneWidget);
    expect(find.text('3.0 GB'), findsOneWidget);
    expect(find.text('0 GB'), findsOneWidget);
    expect(find.text('Android closes apps at 3.5 GB'), findsOneWidget);
    expect(find.textContaining('FaunaPulse holds 1.2 GB of it'), findsOneWidget);
    expect(find.byKey(const Key('memory_scale')), findsOneWidget);
    expect(find.text('FaunaPulse: 2.0 of 8 processor cores busy (model on the CPU).'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull); // no right overflow at 360 px
  });

  test('round 361: the chip label names the sensors the phone let the app read', () {
    expect(const ThermalReading(cpuTempC: 55.4, gpuTempC: 48).chipLabel, 'CPU 55 °C · GPU 48 °C');
    expect(const ThermalReading(gpuTempC: 48).chipLabel, 'GPU 48 °C');
    expect(const ThermalReading().chipLabel, isNull);
  });

  testWidgets('round 361: the temperature gauge shows the chip sensors when given', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ...temperatureGauge(31.0, 43.0, paused: false, limitWhere: 'Settings'),
              ...temperatureGauge(31.0, 43.0, paused: false, limitWhere: 'Settings', chipLabel: 'CPU 55 °C · GPU 48 °C'),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('Chip sensors: CPU 55 °C · GPU 48 °C'), findsOneWidget);
    expect(find.text('Battery temperature'), findsNWidgets(2));
  });

  test('nothing without the phone\'s figures, no engine bracket without an engine', () {
    expect(memoryGauge(const ThermalReading()), isEmpty);
    expect(appCpuLine(const ThermalReading(appCpuCores: 1.0)), isEmpty); // no core count
    final line = appCpuLine(const ThermalReading(appCpuCores: 0.4, cpuCount: 8));
    expect(line, hasLength(1));
    expect(((line.single as Padding).child as Text).data, 'FaunaPulse: 0.4 of 8 processor cores busy.');
  });

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
              children: temperatureGauge(temp, 43, paused: paused, limitWhere: 'Advanced settings'),
            ),
          ),
        ),
      );
      expect(find.text('Battery temperature'), findsOneWidget);
      expect(find.text('${temp.toStringAsFixed(1)} °C'), findsOneWidget);
      expect(find.text('25 °C'), findsOneWidget);
      expect(find.text('pauses at 43 °C'), findsOneWidget);
      expect(find.byKey(const Key('temperature_scale')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Cooling down'), paused ? findsOneWidget : findsNothing);
    });
  }
}
