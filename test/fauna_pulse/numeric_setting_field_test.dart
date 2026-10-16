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

  testWidgets('a number outside the range is not taken: the box says what is allowed (r313)', (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      _host(
        NumericSettingField(
          label: 'Camera frame rate cap',
          value: 15,
          min: 0,
          max: 30,
          isInt: true,
          unitSuffix: 'FPS',
          helperText: 'Frames per second the camera captures.',
          onChanged: committed.add,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '99');
    await tester.pump();
    expect(committed, isEmpty, reason: 'never clamped to 30 behind the user\'s back');
    expect(find.text('Allowed: 0 to 30 FPS.'), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(find.text('15'), findsOneWidget, reason: 'the stored value is shown again');
    expect(find.text('Not changed: allowed is 0 to 30 FPS.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '20');
    await tester.pump();
    expect(committed, [20]);
    expect(find.textContaining('llowed'), findsNothing, reason: 'cleared by a valid number');
  });

  testWidgets('a refused number puts the old value back at once, also when the box then disappears (r313 review)', (tester) async {
    var stored = 30.0;
    var shown = true;
    late StateSetter outer;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          outer = setState;
          return _host(
            shown
                ? NumericSettingField(label: 'Wake', value: stored, min: 5, max: 60, isInt: true, onChanged: (v) => setState(() => stored = v))
                : const SizedBox(),
          );
        },
      ),
    );
    await tester.enterText(find.byType(TextField), '6');
    await tester.pump();
    expect(stored, 6, reason: 'valid on the way');
    await tester.enterText(find.byType(TextField), '61');
    await tester.pump();
    expect(stored, 30, reason: 'refused: the value from before the edit is back at once');
    // An emptied box starts a new entry: after "45", emptied, "99" goes
    // back to 45, not to the 30 from before the box got the focus.
    await tester.enterText(find.byType(TextField), '45');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '99');
    await tester.pump();
    expect(stored, 45);
    await tester.enterText(find.byType(TextField), '61');
    await tester.pump();
    expect(stored, 45);
    // A fold closes (or a switch hides the box) while it still has focus:
    // no blur ever comes, and the stored value must still be the kept one.
    outer(() => shown = false);
    await tester.pump();
    expect(stored, 45);
  });

  testWidgets('a comma is a decimal point, and no more decimals than shown can be typed (r313)', (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      _host(NumericSettingField(label: 'New-track confidence', value: 0.5, min: 0.05, max: 0.95, onChanged: committed.add)),
    );
    await tester.enterText(find.byType(TextField), '0,4');
    expect(committed.last, 0.4);
    await tester.enterText(find.byType(TextField), '0.455');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '0,4', reason: 'a third decimal is refused');
    final whole = <double>[];
    await tester.pumpWidget(
      _host(NumericSettingField(key: const ValueKey(2), label: 'Days', value: 1, min: 1, max: 14, decimals: 0, onChanged: whole.add)),
    );
    await tester.enterText(find.byType(TextField), '1.5');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isNot(contains('.')),
        reason: 'decimals: 0 takes whole numbers only, so the box never shows a rounded value');
  });

  testWidgets('when the screen stores another number than the one typed, the box says so (r313)', (tester) async {
    var stored = 15.0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => _host(
          NumericSettingField(
            label: 'Camera frame rate cap',
            value: stored,
            min: 0,
            max: 30,
            isInt: true,
            // A host rule: 1 to 4 count as 5.
            onChanged: (v) => setState(() => stored = v > 0 && v < 5 ? 5 : v),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '3');
    await tester.pump();
    expect(stored, 5);
    expect(find.text('Saved as 5'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '12');
    await tester.pump();
    expect(find.text('Saved as 5'), findsNothing);
  });

  testWidgets('zeroMeans allows 0 below the range; warning and enabled (r313)', (tester) async {
    final committed = <double>[];
    await tester.pumpWidget(
      _host(
        NumericSettingField(
          label: 'Tile size',
          value: 640,
          min: 128,
          max: 2048,
          isInt: true,
          unitSuffix: 'px',
          zeroMeans: 'automatic',
          warning: 'Used: 640 px.',
          onChanged: committed.add,
        ),
      ),
    );
    expect(find.text('Used: 640 px.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1');
    await tester.pump();
    expect(committed, isEmpty, reason: 'a 1 px tile while typing 1024 is refused');
    expect(find.text('Allowed: 0 (automatic) or 128 to 2048 px.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '0');
    expect(committed, [0]);
    await tester.pumpWidget(
      _host(NumericSettingField(key: const ValueKey(2), label: 'Off', value: 1, min: 0, max: 2, enabled: false, onChanged: committed.add)),
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
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
