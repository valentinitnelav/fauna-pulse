// Widget tests for NumericSettingField's collapsed-help behaviour (round 159):
// the helper paragraph hides behind an ⓘ icon and appears on a label tap, so
// the settings sheet stays compact until the user asks for an explanation.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/widgets/duration_setting_field.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/numeric_setting_field.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('helper text is hidden until the label row is tapped', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        NumericSettingField(
          label: 'Confidence threshold',
          value: 0.25,
          min: 0.05,
          max: 0.95,
          helperText: 'Minimum score for a detection.',
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('Minimum score for a detection.'), findsNothing);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);

    await tester.tap(find.text('Confidence threshold'));
    await tester.pump();
    expect(find.text('Minimum score for a detection.'), findsOneWidget);
    expect(find.byIcon(Icons.info), findsOneWidget);

    // Tapping again collapses it.
    await tester.tap(find.text('Confidence threshold'));
    await tester.pump();
    expect(find.text('Minimum score for a detection.'), findsNothing);
  });

  testWidgets('no ⓘ icon when a field has no helper text', (tester) async {
    await tester.pumpWidget(
      _host(
        NumericSettingField(
          label: 'Plain field',
          value: 1,
          min: 0,
          max: 10,
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.byIcon(Icons.info_outline), findsNothing);
    expect(find.byIcon(Icons.info), findsNothing);
  });

  testWidgets('typing still commits a clamped value with the help collapsed', (
    tester,
  ) async {
    double? committed;
    await tester.pumpWidget(
      _host(
        NumericSettingField(
          label: 'Camera frame rate cap',
          value: 15,
          min: 0,
          max: 30,
          isInt: true,
          helperText: 'Frames per second the camera captures.',
          onChanged: (v) => committed = v,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '99');
    expect(committed, 30); // clamped to max
  });

  testWidgets('DurationSettingField inherits the collapsed-help behaviour', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        DurationSettingField(
          label: 'Photo duration',
          valueSeconds: 10,
          minSeconds: 1,
          maxSeconds: 86400,
          helperText: 'How long photos keep being saved.',
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.text('How long photos keep being saved.'), findsNothing);
    await tester.tap(find.text('Photo duration'));
    await tester.pump();
    expect(find.text('How long photos keep being saved.'), findsOneWidget);
  });
}
