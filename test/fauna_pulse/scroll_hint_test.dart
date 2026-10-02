// Round 278: the quiet scroll bar of the home screen. Nothing is drawn while
// the whole page is visible; the bar is at least 48 px and at most a third of
// the height long, and moves from the top to the bottom of its path.

import 'package:fauna_pulse/fauna_pulse/widgets/scroll_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ScrollController> _pumpList(WidgetTester tester, int rows) async {
  final c = ScrollController();
  addTearDown(c.dispose);
  tester.view.physicalSize = const Size(360, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ScrollHint(
          controller: c,
          child: ListView(controller: c, children: [for (var i = 0; i < rows; i++) SizedBox(height: 100, child: Text('row $i'))]),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

RenderObject _hint(WidgetTester tester) =>
    tester.renderObject(find.descendant(of: find.byType(ScrollHint), matching: find.byType(CustomPaint)).last);

void main() {
  test('the bar: a third of the path at most, 48 px at least, and where the page is', () {
    // A page a bit longer than the screen: a third, not most of the path.
    expect(scrollHintBar(trackHeight: 600, viewport: 600, maxScroll: 100, pixels: 0), (top: 0.0, length: 200.0));
    // A very long page: 48 px.
    expect(scrollHintBar(trackHeight: 600, viewport: 600, maxScroll: 60000, pixels: 0)!.length, 48);
    // At the end of the page, the bar is at the end of the path.
    final end = scrollHintBar(trackHeight: 600, viewport: 600, maxScroll: 1200, pixels: 1200)!;
    expect(end.top + end.length, 600);
    expect(scrollHintBar(trackHeight: 600, viewport: 600, maxScroll: 1200, pixels: 600)!.top, closeTo((600 - 200) / 2, 0.01));
    // Overscroll stays on the path; a page that fits has no bar.
    expect(scrollHintBar(trackHeight: 600, viewport: 600, maxScroll: 1200, pixels: -50)!.top, 0);
    expect(scrollHintBar(trackHeight: 600, viewport: 600, maxScroll: 0, pixels: 0), isNull);
  });

  testWidgets('drawn for a long page, and nothing for a page that fits', (tester) async {
    await _pumpList(tester, 30);
    expect(_hint(tester), paints..rrect()..rrect());
    await _pumpList(tester, 3);
    expect(_hint(tester), paintsNothing);
  });

  testWidgets('touches go to the page under it', (tester) async {
    final c = await _pumpList(tester, 30);
    await tester.dragFrom(const Offset(357, 300), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(c.offset, greaterThan(0), reason: 'the drag on the bar scrolled the page');
  });
}
