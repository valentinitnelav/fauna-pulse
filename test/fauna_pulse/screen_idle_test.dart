// Round 293: the rule that lets a recording's screen go dark N minutes after the last touch.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/session/screen_idle.dart';

void main() {
  test('lets the screen go once, at the time after the last touch', () {
    final s = ScreenIdle(afterMs: 180000, nowMs: 0);
    expect(s.tick(179999), isFalse);
    expect(s.tick(180000), isTrue);
    expect(s.released, isTrue);
    expect(s.tick(200000), isFalse, reason: 'only once');
  });

  test('a touch restarts the count; after a let-go it asks to hold the screen again', () {
    final s = ScreenIdle(afterMs: 60000, nowMs: 0);
    expect(s.touch(50000), isFalse, reason: 'still held: nothing to take back');
    expect(s.tick(100000), isFalse);
    expect(s.tick(110000), isTrue);
    expect(s.touch(120000), isTrue);
    expect(s.released, isFalse);
    expect(s.tick(179999), isFalse);
    expect(s.tick(180000), isTrue);
  });

  test('0 means never', () {
    final s = ScreenIdle(afterMs: 0, nowMs: 0);
    expect(s.tick(1 << 40), isFalse);
    expect(s.released, isFalse);
  });

  test('setting: default 0 (never), saved and loaded, clamped to 0..10', () {
    expect(const SessionConfig().screenOffAfterMin, 0);
    final j = const SessionConfig().copyWith(screenOffAfterMin: 3).toJson();
    expect(j['screenOffAfterMin'], 3);
    expect(SessionConfig.fromJson(j).screenOffAfterMin, 3);
    expect(SessionConfig.fromJson({...j, 'screenOffAfterMin': 99}).screenOffAfterMin, 10);
    expect(SessionConfig.fromJson(const {}).screenOffAfterMin, 0);
  });
}
