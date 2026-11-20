// The "Send feedback" screen on a phone-sized screen with the keyboard open: the text box
// stays tall enough to read what is typed, the send buttons stay in reach and nothing
// overflows, also with screenshots attached (the box used to shrink to a line, and the screen
// showed "BOTTOM OVERFLOWED BY 94 PIXELS" with four screenshots). The typed text is kept as a
// draft when the screen is left without sending. A screenshot alone can be sent. "Send by
// email" hands the email app the address, the subject, the text and the zip, and a phone
// without an email app gets the share window at once.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:fauna_pulse/fauna_pulse/logging/crash_store.dart';
import 'package:fauna_pulse/fauna_pulse/logging/error_reporter.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/feedback_screen.dart';

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
  const diagnostics = MethodChannel('faunapulse/diagnostics');
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // The draft lives in a folder of the test (no phone folders here).
  late Directory tmp;
  File draftFile() => File('${tmp.path}/error_reports/description_draft.md');

  /// Lets the screen's real file reads and writes finish. They stand still on the test clock,
  /// and each step of a read or write (folder there? file there? content) needs its own turn
  /// of real time followed by a frame.
  Future<void> settleFiles(WidgetTester tester, {int turns = 12}) async {
    for (var i = 0; i < turns; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('feedback_screen');
    ErrorReporter.debugDirOverride = tmp;
    CrashStore.debugDirOverride = tmp;
    messenger.setMockMethodCallHandler(
      picker,
      (call) async => call.method == 'pickMultiImage'
          ? ['/tmp/1000071322.jpg', '/tmp/1000071156.jpg', '/tmp/1000071155.jpg', '/tmp/1000071157.jpg']
          : null,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(picker, null);
    messenger.setMockMethodCallHandler(diagnostics, null);
    ErrorReporter.debugDirOverride = null;
    CrashStore.debugDirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    simulateBottomSystemBar(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const FeedbackScreen(
          sessions: [(name: 'zenodo15096610_pilot', logPath: '/sessions/zenodo15096610_pilot/session.jsonl')],
        ),
      ),
    );
  }

  /// Taps the screenshots button. The test font is wider than a phone's, so the button can sit
  /// below the visible part of the page: scroll to it first.
  Future<void> attachScreenshots(WidgetTester tester) async {
    final button = find.text('Add screenshots', skipOffstage: false);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  FilledButton emailButton(WidgetTester tester) => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send by email'));
  OutlinedButton shareButton(WidgetTester tester) =>
      tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Share another way'));

  /// The text box is readable and both send buttons can be tapped, all above the keyboard.
  void expectUsableAboveKeyboard(WidgetTester tester) {
    const keyboardTop = 800 - _keyboardPx;
    final box = tester.getRect(find.byType(TextField));
    expect(box.height, greaterThanOrEqualTo(100), reason: 'the text box shrank to ${box.height} px');
    expect(box.top, greaterThanOrEqualTo(56), reason: 'the text box starts under the title bar');
    for (final label in ['Send by email', 'Share another way']) {
      final button = tester.getRect(find.text(label));
      expect(box.bottom, lessThanOrEqualTo(button.top), reason: 'the text box ends behind "$label"');
      expect(button.bottom, lessThanOrEqualTo(keyboardTop), reason: '"$label" is behind the keyboard');
    }
  }

  testWidgets('keyboard open: the text box stays readable and the buttons stay in reach', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Send feedback'), findsOneWidget);
    expect(find.textContaining(ErrorReporter.feedbackEmail), findsOneWidget, reason: 'the screen names the address');
    _openKeyboard(tester);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectUsableAboveKeyboard(tester);

    // A long text grows the box and the page scrolls; the line being typed stays in view.
    await tester.enterText(find.byType(TextField), List.filled(30, 'The detector froze.').join('\n'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(emailButton(tester).onPressed, isNotNull);
  });

  testWidgets('four screenshots and the keyboard: nothing overflows', (tester) async {
    await pumpScreen(tester);
    await attachScreenshots(tester);
    expect(find.text('4 added'), findsOneWidget);

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
    expect(find.text('3 added', skipOffstage: false), findsOneWidget);
    expect(find.bySemanticsLabel('Screenshot 1000071157.jpg'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screenshot alone can be sent; nothing at all cannot', (tester) async {
    await pumpScreen(tester);
    await settleFiles(tester);
    expect(emailButton(tester).onPressed, isNull);
    expect(shareButton(tester).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(emailButton(tester).onPressed, isNull, reason: 'spaces are no text');
    await attachScreenshots(tester);
    expect(emailButton(tester).onPressed, isNotNull);
    expect(shareButton(tester).onPressed, isNotNull);
    // No Markdown tabs any more: one plain box.
    expect(find.text('Preview'), findsNothing);
  });

  testWidgets('the typed text is kept as a draft and comes back; "Clear text" removes it', (tester) async {
    // Typed, then the screen is left without sending (Back, X, Home, or Android closed the app).
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
    expect(emailButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('Clear text'));
    await settleFiles(tester);
    expect(find.text('The detector froze after 5 minutes'), findsNothing);
    expect(find.textContaining('your text from last time'), findsNothing);
    expect(draftFile().existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox());
    await settleFiles(tester);
    expect(draftFile().existsSync(), isFalse);
  });

  group('Send by email', () {
    late Map<Object?, Object?> emailArgs;
    late bool hasEmailApp;

    setUp(() {
      emailArgs = {};
      hasEmailApp = true;
      PackageInfo.setMockInitialValues(
        appName: 'FaunaPulse',
        packageName: 'com.faunapulse.app',
        version: '0.12.0-beta.1',
        buildNumber: '17',
        buildSignature: '',
      );
      messenger.setMockMethodCallHandler(diagnostics, (call) async {
        if (call.method == 'captureLogcat') return 'I/flutter: a log line';
        if (call.method == 'sendEmail') {
          emailArgs = call.arguments as Map<Object?, Object?>;
          return hasEmailApp;
        }
        return null;
      });
    });

    /// Opens the screen from a page below it (where the thank-you bar shows) and types [text].
    Future<void> openAndType(WidgetTester tester, String text) async {
      simulateBottomSystemBar(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showFeedbackScreen(context, trigger: 'test', config: const SessionConfig()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
    }

    /// Taps "Send by email" and lets the report be built (real files, so real time).
    Future<void> tapSend(WidgetTester tester, bool Function() done) async {
      await tester.tap(find.text('Send by email'));
      for (var i = 0; i < 200 && !done(); i++) {
        await settleFiles(tester, turns: 1);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('the email app gets address, subject, text and the zip; the screen closes', (tester) async {
      await openAndType(tester, 'Die Kamera stoppte nach 5 Minuten.');
      await tapSend(tester, () => find.textContaining('Thank you').evaluate().isNotEmpty);
      expect(emailArgs['to'], ErrorReporter.feedbackEmail);
      expect(emailArgs['subject'], matches(RegExp(r'^FaunaPulse feedback 0\.12\.0-beta\.1\+17 [A-Z0-9]{6}$')));
      final id = (emailArgs['subject'] as String).split(' ').last;
      expect(emailArgs['path'], allOf(endsWith('.zip'), contains(id)));
      final body = emailArgs['body'] as String;
      expect(body, startsWith('Die Kamera stoppte nach 5 Minuten.\n\n(Attached: one zip file with the app'));
      final txt = File((emailArgs['path'] as String).replaceAll('.zip', '.txt')).readAsStringSync();
      expect(txt, contains('Report ID: $id'));
      expect(find.byType(FeedbackScreen), findsNothing, reason: 'handed to the email app: the screen closes');
      expect(find.textContaining('press Send in your email app'), findsOneWidget);
      expect(draftFile().existsSync(), isFalse, reason: 'handed over: the next feedback starts empty');
    });

    testWidgets('no email app: the share window opens at once, with no warning window', (tester) async {
      hasEmailApp = false;
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      final shares = <Map<Object?, Object?>>[];
      var shareAnswer = ''; // '' = closed without choosing an app
      messenger.setMockMethodCallHandler(shareChannel, (call) async {
        shares.add(call.arguments as Map<Object?, Object?>);
        return shareAnswer;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(shareChannel, null));

      await openAndType(tester, 'An idea');
      await tapSend(tester, () => shares.isNotEmpty);
      expect(emailArgs['to'], ErrorReporter.feedbackEmail, reason: 'the email app was tried first');
      expect(find.byType(AlertDialog), findsNothing);
      expect(shares, hasLength(1));
      expect(shares.single['title'], 'Pick your email app');
      expect(shares.single['text'], endsWith(ErrorReporter.feedbackEmail));
      // Closed without choosing an app: nothing left the phone, the screen stays with the text.
      expect(find.byType(FeedbackScreen), findsOneWidget);
      expect(find.text('An idea'), findsOneWidget);

      // Chosen an app this time: the screen closes.
      shareAnswer = 'com.example.mail/.Compose';
      await tapSend(tester, () => find.byType(FeedbackScreen).evaluate().isEmpty);
      expect(shares, hasLength(2));
      expect(find.byType(FeedbackScreen), findsNothing);
      expect(find.text('Thank you for the feedback.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
