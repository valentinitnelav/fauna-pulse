// The "Describe the problem" screen on a phone-sized screen with the keyboard open: the text
// box stays tall enough to read what is typed, Continue stays in reach and nothing overflows,
// also with screenshots attached (the box used to shrink to a line, and the screen showed
// "BOTTOM OVERFLOWED BY 94 PIXELS" with four screenshots). And the typed text is kept as a
// draft when the screen is left without making a report.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/error_reporter.dart';
import 'package:fauna_pulse/fauna_pulse/screens/problem_description_screen.dart';

import 'summary_bottom_inset_test.dart' show simulateBottomSystemBar;

/// The keyboard of the test: 300 of the screen's 800 logical pixels (3 physical pixels each).
const _keyboardPx = 300.0;

/// Opens the keyboard: Android then reports no system bar below the app.
void _openKeyboard(WidgetTester tester) {
  tester.view.viewInsets = const FakeViewPadding(bottom: _keyboardPx * 3);
  tester.view.padding = FakeViewPadding.zero;
}

void main() {
  // The photo picker answers with four files, named as a phone's gallery names them.
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  // The draft lives in a folder of the test (no phone folders here).
  late Directory tmp;
  File draftFile() => File('${tmp.path}/error_reports/description_draft.md');

  /// Lets the draft's real file reads and writes finish. They stand still on the test clock,
  /// and each step of a read or write (folder there? file there? content) needs its own turn
  /// of real time followed by a frame.
  Future<void> settleFiles(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('describe_problem');
    ErrorReporter.debugDirOverride = tmp;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      picker,
      (call) async => call.method == 'pickMultiImage'
          ? ['/tmp/1000071322.jpg', '/tmp/1000071156.jpg', '/tmp/1000071155.jpg', '/tmp/1000071157.jpg']
          : null,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(picker, null);
    ErrorReporter.debugDirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    simulateBottomSystemBar(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const ProblemDescriptionScreen(
          sessions: [(name: 'zenodo15096610_pilot', logPath: '/sessions/zenodo15096610_pilot/session.jsonl')],
        ),
      ),
    );
  }

  /// Taps the screenshots button. The test font is wider than a phone's, so the button can sit
  /// below the visible part of the page: scroll to it first.
  Future<void> attachScreenshots(WidgetTester tester) async {
    final button = find.textContaining('Attach screenshots', skipOffstage: false);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// The text box is readable and Continue can be tapped, both above the keyboard.
  void expectUsableAboveKeyboard(WidgetTester tester) {
    const keyboardTop = 800 - _keyboardPx;
    final box = tester.getRect(find.byType(TextField));
    expect(box.height, greaterThanOrEqualTo(100), reason: 'the text box shrank to ${box.height} px');
    expect(box.top, greaterThanOrEqualTo(56), reason: 'the text box starts under the title bar');
    final buttons = tester.getRect(find.widgetWithText(FilledButton, 'Continue'));
    expect(box.bottom, lessThanOrEqualTo(buttons.top), reason: 'the text box ends behind the buttons');
    expect(buttons.bottom, lessThanOrEqualTo(keyboardTop), reason: 'Continue is behind the keyboard');
  }

  testWidgets('keyboard open: the text box stays readable and Continue stays in reach', (tester) async {
    await pumpScreen(tester);
    _openKeyboard(tester);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectUsableAboveKeyboard(tester);

    // A long text grows the box and the page scrolls; the line being typed stays in view.
    await tester.enterText(find.byType(TextField), List.filled(30, 'The detector froze.').join('\n'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue')).onPressed, isNotNull);
  });

  testWidgets('four screenshots and the keyboard: nothing overflows', (tester) async {
    await pumpScreen(tester);
    await attachScreenshots(tester);
    expect(find.text('4 attached'), findsOneWidget);

    _openKeyboard(tester);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectUsableAboveKeyboard(tester);

    // The lower rows are reached by scrolling.
    await tester.scrollUntilVisible(find.textContaining('Pick the session'), 100, scrollable: find.byType(Scrollable).first);
    // Each screenshot is a small picture with its own remove button.
    expect(find.bySemanticsLabel('Screenshot 1000071157.jpg'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove this screenshot').last);
    await tester.pumpAndSettle();
    expect(find.text('3 attached'), findsOneWidget);
    expect(find.bySemanticsLabel('Screenshot 1000071157.jpg'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the typed text is kept as a draft and comes back; "Clear text" removes it', (tester) async {
    // Typed, then the screen is left without Continue (Back, X, Home, or Android closed the app).
    await pumpScreen(tester);
    await settleFiles(tester);
    expect(find.textContaining('your text from last time'), findsNothing);
    await tester.enterText(find.byType(TextField), 'The detector froze');
    await tester.pump(const Duration(seconds: 1)); // a moment after the last keystroke
    await settleFiles(tester);
    expect(draftFile().readAsStringSync(), 'The detector froze');
    await tester.enterText(find.byType(TextField), 'The detector froze after 5 minutes');
    await tester.pumpWidget(const SizedBox()); // closed before the next save was due
    await settleFiles(tester);
    expect(draftFile().readAsStringSync(), 'The detector froze after 5 minutes');

    // Opened again: the text is back, with a line that says so.
    await pumpScreen(tester);
    await settleFiles(tester);
    expect(find.text('The detector froze after 5 minutes'), findsOneWidget);
    expect(find.textContaining('your text from last time'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue')).onPressed, isNotNull);

    await tester.tap(find.text('Clear text'));
    await settleFiles(tester);
    expect(find.text('The detector froze after 5 minutes'), findsNothing);
    expect(find.textContaining('your text from last time'), findsNothing);
    expect(draftFile().existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox());
    await settleFiles(tester);
    expect(draftFile().existsSync(), isFalse);
  });

  testWidgets('Preview shows the formatted text; Continue returns text, screenshots and session', (tester) async {
    ProblemDescriptionResult? result;
    simulateBottomSystemBar(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showProblemDescriptionEditor(
              context,
              sessions: [(name: 'session', logPath: '/sessions/session/session.jsonl')],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue')).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '  It **froze** after 5 minutes.  ');
    await attachScreenshots(tester);
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('froze', findRichText: true), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await settleFiles(tester); // Continue stores the text as the draft first
    await tester.pumpAndSettle();
    expect(result?.description, 'It **froze** after 5 minutes.');
    // Until the report is shared, the text stays as the draft.
    expect(draftFile().readAsStringSync(), '  It **froze** after 5 minutes.  ');
    expect(result?.screenshotPaths, hasLength(4));
    expect(result?.sessionLogPath, '/sessions/session/session.jsonl');
  });
}
