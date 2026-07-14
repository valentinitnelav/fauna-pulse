// Widget tests for the "Delete all sessions" type-to-confirm dialog.
//
// Includes regression coverage for the round-104 field crash: confirming the
// dialog pops it while the keyboard still holds focus, and the home screen
// pushes a progress dialog in the same event turn. The original round-103
// implementation disposed the text controller from the caller while the dialog
// was still animating out, tripping InheritedElement's `_dependents.isEmpty`
// assertion (framework.dart:6268).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';

/// Pumps a host app whose button opens the dialog and — exactly like the home
/// screen — pushes a "Deleting…" progress dialog in the same turn the confirm
/// dialog pops with `true`.
Future<void> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                final sure = await showDialog<bool>(
                  context: context,
                  builder: (_) => const DeleteAllSessionsDialog(
                    count: 3,
                    totalBytes: 123 * 1024 * 1024,
                  ),
                );
                if (sure == true && context.mounted) {
                  showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) =>
                        const AlertDialog(content: Text('Deleting…')),
                  );
                }
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TextButton deleteAllButton(WidgetTester tester) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Delete all'));

  testWidgets('Delete all stays disabled until the exact word is typed', (
    tester,
  ) async {
    await _pumpHost(tester);
    expect(deleteAllButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'DELET');
    await tester.pump();
    expect(deleteAllButton(tester).onPressed, isNull);

    // Case and surrounding whitespace are forgiven — only the word matters.
    await tester.enterText(find.byType(TextField), ' Delete ');
    await tester.pump();
    expect(deleteAllButton(tester).onPressed, isNotNull);
  });

  testWidgets('Cancel closes without triggering the deletion path', (
    tester,
  ) async {
    await _pumpHost(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Deleting…'), findsNothing);
  });

  testWidgets(
    'confirming survives the pop + immediate progress dialog (r104 regression)',
    (tester) async {
      await _pumpHost(tester);
      await tester.enterText(find.byType(TextField), 'delete');
      await tester.pump();
      await tester.tap(find.text('Delete all'));
      // Drive the confirm dialog's exit animation to completion with the
      // progress dialog already pushed — this is where round 103 asserted.
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Deleting…'), findsOneWidget);
    },
  );
}
