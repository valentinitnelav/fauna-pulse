// Round 319 part 3 (A3, phone check P2X): Sessions > ⋮ > Rename session >
// Cancel with the keyboard open gave a red screen ('_dependents.isEmpty') and
// the crash file 'A TextEditingController was used after being disposed'.
// The text field's controller was disposed as soon as showDialog returned,
// while the closing dialog still rebuilt the field (the keyboard going down
// changes the screen insets). The dialog now owns its controller.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Host extends StatefulWidget {
  const _Host(this.session);
  final PastSession session;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SessionActions<_Host> {
  @override
  Future<void> reloadSessions() async {}

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: () => askRenameSession(widget.session), child: const Text('open')),
    ),
  );
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('r319c_a_rename'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> openDialog(WidgetTester tester) async {
    final dir = Directory('${tmp.path}/meadow_1')..createSync();
    final s = PastSession('meadow_1', File('${dir.path}/data_log.jsonl'), DateTime(2026, 10, 21));
    await tester.pumpWidget(MaterialApp(home: _Host(s)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Rename session'), findsOneWidget);
    // The field has the focus (autofocus) and the keyboard is up.
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>(), isNotNull);
    tester.view.viewInsets = const FakeViewPadding(bottom: 800);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
  }

  Future<void> closeKeyboardWhileClosing(WidgetTester tester) async {
    // The keyboard goes down while the dialog's closing animation runs.
    await tester.pump(const Duration(milliseconds: 30));
    tester.view.resetViewInsets();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('Cancel with the keyboard open closes the dialog without an error', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('Cancel'));
    await closeKeyboardWhileClosing(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Rename session'), findsNothing);
  });

  testWidgets('the X with the keyboard open closes the dialog without an error', (tester) async {
    await openDialog(tester);
    await tester.tap(find.byTooltip('Close'));
    await closeKeyboardWhileClosing(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Rename session'), findsNothing);
  });

  testWidgets('Rename still renames the folder and says so', (tester) async {
    await openDialog(tester);
    await tester.enterText(find.byType(TextField), 'meadow#north');
    await tester.runAsync(() async {
      await tester.tap(find.text('Rename'));
      for (var i = 0; i < 50 && !Directory('${tmp.path}/meadow_north').existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await closeKeyboardWhileClosing(tester);
    expect(tester.takeException(), isNull);
    expect(Directory('${tmp.path}/meadow_north').existsSync(), isTrue);
    expect(find.text('Session renamed to "meadow_north".'), findsOneWidget);
  });
}
