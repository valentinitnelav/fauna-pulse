import 'package:fauna_pulse/fauna_pulse/widgets/home_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A screen with a title bar and the house, which opens [next] on a tap.
Widget _page(String title, {Widget? next, bool canPop = true, VoidCallback? onAsked}) => Builder(
  builder: (context) => PopScope(
    canPop: canPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) onAsked?.call();
    },
    child: Scaffold(
      appBar: AppBar(title: Text(title), actions: const [HomeButton()]),
      body: next == null
          ? null
          : TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => next)),
              child: Text('open ${title}2'),
            ),
    ),
  ),
);

Future<void> _openStack(WidgetTester tester, Widget second) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => second)),
            child: const Text('home'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('home'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(TextButton).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the house closes every screen down to the home screen', (tester) async {
    await _openStack(tester, _page('Session', next: _page('Identify', next: _page('Results'))));
    await tester.tap(find.byType(TextButton).last);
    await tester.pumpAndSettle();
    expect(find.text('Results'), findsOneWidget);
    await tester.tap(find.byTooltip('Home screen'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing, reason: 'three screens closed');
  });

  testWidgets('a screen that asks before closing stops the way home there, as Back does', (tester) async {
    var asked = 0;
    await _openStack(tester, _page('Analysis', canPop: false, onAsked: () => asked++, next: _page('Results')));
    expect(find.text('Results'), findsOneWidget);
    await tester.tap(find.byTooltip('Home screen'));
    await tester.pumpAndSettle();
    expect(find.text('Analysis'), findsOneWidget, reason: 'Results closed, Analysis stays');
    expect(asked, 1);
    expect(find.text('home'), findsNothing);
  });

  testWidgets('a long title shrinks to fit beside the house instead of being cut', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const title = 'Download & import models';
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 640), textScaler: TextScaler.linear(1.3)),
          child: Scaffold(appBar: AppBar(title: const FitTitle(title), actions: const [HomeButton()])),
        ),
      ),
    );
    final text = tester.renderObject<RenderBox>(find.text(title));
    expect(text.size.width, closeTo(text.getMaxIntrinsicWidth(double.infinity), 0.5), reason: 'the whole title is drawn');
    expect(tester.getRect(find.text(title)).right, lessThanOrEqualTo(tester.getRect(find.byTooltip('Home screen')).left));
  });
}
