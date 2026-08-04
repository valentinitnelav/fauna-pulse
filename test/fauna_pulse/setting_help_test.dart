// Widget tests for the shared ⓘ help-toggle widgets (round 181): every
// settings control keeps its explanation behind a small ⓘ icon, so the
// screens stay compact until the user asks for an explanation. Same pattern
// as NumericSettingField's round-159 collapsed help (tested separately in
// numeric_setting_field_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/widgets/setting_help.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: ListView(children: [child])));

void main() {
  testWidgets('HelpLabel: helper hidden until the label row is tapped', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const HelpLabel(
          label: 'Capture trigger',
          helperText: 'What causes photos.',
        ),
      ),
    );
    expect(find.text('What causes photos.'), findsNothing);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);

    await tester.tap(find.text('Capture trigger'));
    await tester.pump();
    expect(find.text('What causes photos.'), findsOneWidget);
    expect(find.byIcon(Icons.info), findsOneWidget);

    await tester.tap(find.text('Capture trigger'));
    await tester.pump();
    expect(find.text('What causes photos.'), findsNothing);
  });

  testWidgets(
    'HelpSwitchTile: ⓘ shows the helper without flipping the switch; '
    'a row tap still flips it',
    (tester) async {
      var value = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => HelpSwitchTile(
              title: 'Scheduled recording',
              helperText: 'Records during daily windows.',
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      );
      expect(find.text('Records during daily windows.'), findsNothing);

      // The icon opens the help and must NOT flip the switch.
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pump();
      expect(find.text('Records during daily windows.'), findsOneWidget);
      expect(value, isFalse);

      // Tapping the title (outside the icon) keeps the Android habit:
      // it flips the switch, not the help.
      await tester.tap(find.text('Scheduled recording'));
      await tester.pump();
      expect(value, isTrue);
      expect(find.text('Records during daily windows.'), findsOneWidget);
    },
  );

  testWidgets(
    'HelpSwitchTile: status note stays visible with the help collapsed, '
    'and the ⓘ still works on a disabled tile',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const HelpSwitchTile(
            title: 'Reference photos',
            helperText: 'Saves an ROI photo at a fixed interval.',
            statusText: 'Not used in time-lapse mode.',
            value: false,
            onChanged: null, // greyed out
          ),
        ),
      );
      expect(find.text('Not used in time-lapse mode.'), findsOneWidget);
      expect(
        find.text('Saves an ROI photo at a fixed interval.'),
        findsNothing,
      );

      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pump();
      expect(
        find.text('Saves an ROI photo at a fixed interval.'),
        findsOneWidget,
      );
      expect(find.text('Not used in time-lapse mode.'), findsOneWidget);
    },
  );

  testWidgets('HelpSwitchTile: checkbox variant toggles like a checkbox', (
    tester,
  ) async {
    var value = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => HelpSwitchTile(
            checkbox: true,
            title: 'Re-analyze photos already done',
            helperText: 'Runs every photo again.',
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(find.text('Re-analyze photos already done'));
    await tester.pump();
    expect(value, isTrue);
    expect(find.text('Runs every photo again.'), findsNothing);
  });

  testWidgets('HelpRow: ⓘ reveals the helper under the wrapped control', (
    tester,
  ) async {
    var pressed = false;
    await tester.pumpWidget(
      _host(
        HelpRow(
          helperText: 'Times the model on GPU and CPU.',
          child: OutlinedButton(
            onPressed: () => pressed = true,
            child: const Text('Benchmark engines'),
          ),
        ),
      ),
    );
    expect(find.text('Times the model on GPU and CPU.'), findsNothing);

    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pump();
    expect(find.text('Times the model on GPU and CPU.'), findsOneWidget);
    expect(pressed, isFalse); // the ⓘ never triggers the control

    await tester.tap(find.text('Benchmark engines'));
    expect(pressed, isTrue);
  });

  testWidgets(
    'FoldSection: ⓘ toggles the header helper without expanding the fold; '
    'a header tap still expands it',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const FoldSection(
            title: 'On-screen display',
            subtitle: 'Boxes, info panel.',
            helperText: 'Display choices only.',
            children: [Text('child control')],
          ),
        ),
      );
      expect(find.text('Boxes, info panel.'), findsOneWidget);
      expect(find.text('Display choices only.'), findsNothing);
      expect(find.text('child control'), findsNothing);

      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      expect(find.text('Display choices only.'), findsOneWidget);
      expect(find.text('child control'), findsNothing); // not expanded

      await tester.tap(find.text('On-screen display'));
      await tester.pumpAndSettle();
      expect(find.text('child control'), findsOneWidget);
    },
  );
}
