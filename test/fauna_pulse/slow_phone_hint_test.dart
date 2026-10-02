// Round 278: the hint for phones too slow for live detection (fewer than 5
// pictures per second, from the work per picture): not in the first 15 s,
// only from the median of 30 pictures, or of 10 s of pictures on a very slow
// phone (one slow picture is not enough), and once.

import 'package:fauna_pulse/fauna_pulse/perf/slow_phone_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds [n] pictures [ms] long, 100 ms apart from [startMs]; true when the
/// hint fired.
bool _feed(SlowPhoneHint h, int startMs, int n, double ms) {
  var fired = false;
  for (var i = 0; i < n; i++) {
    fired = h.add(startMs + i * 100, ms) || fired;
  }
  return fired;
}

void main() {
  test('a slow phone: the hint after the warm-up, once', () {
    final h = SlowPhoneHint();
    expect(_feed(h, 0, 150, 400), isFalse, reason: 'the first 15 s are left out');
    expect(_feed(h, 15000, 29, 400), isFalse, reason: 'not 30 pictures yet');
    expect(h.add(17900, 400), isTrue);
    expect(h.medianMs, 400);
    expect(_feed(h, 18000, 100, 400), isFalse, reason: 'once');
  });

  test('a very slow phone: the hint after 10 s of pictures, not after 30 of them', () {
    final h = SlowPhoneHint();
    var at = 0;
    var fired = -1;
    for (var i = 0; i < 40 && fired < 0; i++, at += 1500) {
      if (h.add(at, 1500)) fired = at;
    }
    // Warm-up to 15 s, then pictures from 15 s to 25.5 s: 8 pictures in 10.5 s.
    expect(fired, 25500);
    expect(h.medianMs, 1500);
  });

  test('a fast phone, or a few slow pictures: no hint', () {
    final fast = SlowPhoneHint();
    expect(_feed(fast, 0, 600, 60), isFalse);
    final mixed = SlowPhoneHint();
    _feed(mixed, 0, 160, 60);
    var fired = false;
    for (var i = 0; i < 300; i++) {
      // One slow picture in four (a hiccup): the median stays fast.
      fired = mixed.add(16000 + i * 100, i % 4 == 0 ? 900 : 80) || fired;
    }
    expect(fired, isFalse);
    expect(SlowPhoneHint().add(0, 0), isFalse, reason: 'no detector result');
  });

  test('exactly 5 pictures per second is not slow', () {
    final h = SlowPhoneHint();
    expect(_feed(h, 0, 300, SlowPhoneHint.slowMs), isFalse);
  });

  testWidgets('the banner: the rate, what to do, OK and Don\'t show again', (tester) async {
    var ok = 0, never = 0;
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlowPhoneBanner(perSecond: 2.5, onOk: () => ok++, onNeverAgain: () => never++),
        ),
      ),
    );
    expect(find.textContaining('fewer than 5 pictures per second (about 2.5)'), findsOneWidget);
    expect(find.textContaining('"Save bursts as: Video"'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.tap(find.text("Don't show again"));
    expect((ok, never), (1, 1));
    expect(tester.takeException(), isNull);
  });
}
