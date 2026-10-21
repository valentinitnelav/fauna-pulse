// Round 319 part 3 (A1, phone check P2X): the camera's "Settings closed
// without Apply" bar goes away by itself after 8 s since part 2, but the
// screen kept its controller and closed it later (Settings opened again, the
// camera left): 'Bad state: No element' and a crash file in debug builds; in
// release builds close() hid whatever other bar showed then. The screen now
// keeps the bar in a ClosableSnackBar, which forgets it once it has closed.
// The camera screen cannot be built in a widget test (camera plugin), so the
// tests drive the same calls the screen makes.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/widgets/closable_snack_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SnackBar _unappliedBar() => SnackBar(
  content: const Text('Settings closed without Apply: your changes are not used.'),
  duration: const Duration(seconds: 8),
  persist: false,
  action: SnackBarAction(label: 'Apply', onPressed: () {}),
);

Future<ScaffoldMessengerState> _messenger(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
  return tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
}

Future<void> _letItTimeOut(WidgetTester tester) async {
  // Its 8 s count from the end of the show animation.
  await tester.pumpAndSettle();
  expect(find.byType(SnackBar), findsOneWidget);
  await tester.pump(const Duration(seconds: 9));
  await tester.pumpAndSettle();
  expect(find.byType(SnackBar), findsNothing, reason: 'gone by itself after its 8 s');
}

void main() {
  testWidgets('the mechanism: closing a kept controller after its bar timed out fails', (tester) async {
    final messenger = await _messenger(tester);
    // The code before the fix kept this and called close() later.
    final kept = messenger.showSnackBar(_unappliedBar());
    await _letItTimeOut(tester);
    expect(kept.close, throwsA(isA<StateError>()));
  });

  testWidgets('bar timed out, then Settings opened again: close() does nothing', (tester) async {
    final messenger = await _messenger(tester);
    final bar = ClosableSnackBar()..show(messenger, _unappliedBar());
    expect(bar.isShowing, isTrue);
    await _letItTimeOut(tester);
    expect(bar.isShowing, isFalse);
    bar.close();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('bar timed out, another bar shows: close() leaves the other bar alone', (tester) async {
    final messenger = await _messenger(tester);
    final bar = ClosableSnackBar()..show(messenger, _unappliedBar());
    await _letItTimeOut(tester);
    messenger.showSnackBar(const SnackBar(content: Text('Recording started.')));
    await tester.pumpAndSettle();
    bar.close();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Recording started.'), findsOneWidget);
  });

  testWidgets('bar still showing: close() closes it', (tester) async {
    final messenger = await _messenger(tester);
    final bar = ClosableSnackBar()..show(messenger, _unappliedBar());
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    bar.close();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(bar.isShowing, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen left after the bar timed out: the after-frame close does nothing', (tester) async {
    final messenger = await _messenger(tester);
    final bar = ClosableSnackBar()..show(messenger, _unappliedBar());
    await _letItTimeOut(tester);
    // What the camera screen's dispose() does.
    if (bar.isShowing) WidgetsBinding.instance.addPostFrameCallback((_) => bar.close());
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Home'))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // No other place in lib/ keeps a bar's controller to close it later.
  test('lib/ keeps SnackBar and MaterialBanner controllers only in ClosableSnackBar', () {
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      if (f.path.endsWith('closable_snack_bar.dart')) continue;
      if (f.readAsStringSync().contains('ScaffoldFeatureController')) found.add(f.path);
    }
    expect(found, isEmpty);
  });
}
