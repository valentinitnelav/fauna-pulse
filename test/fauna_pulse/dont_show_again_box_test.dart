// Round 330: the shared "Don't show again" tick box, here in the setup tips window.

import 'package:fauna_pulse/fauna_pulse/widgets/session_info_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<bool?> closeWindow(WidgetTester tester, {required bool tick}) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final result = showDialog<bool>(context: context, builder: (_) => const SessionInfoDialog());
    await tester.pumpAndSettle();
    // The words are part of the tap target.
    if (tick) await tester.tap(find.text("Don't show again"));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Close without the tick keeps the window', (tester) async {
    expect(await closeWindow(tester, tick: false), isFalse);
  });

  testWidgets('Close with the tick hides it', (tester) async {
    expect(await closeWindow(tester, tick: true), isTrue);
  });
}
