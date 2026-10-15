// Round 309: the screen-on holds of the video players and the runs of "Find
// animals in videos" (widgets/screen_on.dart). The phone's switch is one for
// the whole app, so one holder letting go must not switch it off for another.

import 'package:fauna_pulse/fauna_pulse/widgets/screen_on.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'video_test_fakes.dart';

void main() {
  test('two holders: letting go of one keeps the screen on, of both lets it sleep', () {
    final wake = FakeWakelock();
    wakelockPlusPlatformInstance = wake;
    final run = Object(), player = Object();

    ScreenOn.hold(run);
    expect(wake.on, isTrue);
    // A player plays, then is paused (its report arrives late, after the run held the screen).
    ScreenOn.hold(player);
    ScreenOn.release(player);
    expect(wake.on, isTrue, reason: 'the run still holds it');
    ScreenOn.release(player); // released twice: no change
    expect(wake.on, isTrue);

    ScreenOn.hold(run); // held twice by one holder: one release is enough
    ScreenOn.release(run);
    expect(wake.on, isFalse);
  });

  test('letting go without holding changes nothing', () {
    final wake = FakeWakelock()..on = true;
    wakelockPlusPlatformInstance = wake;
    ScreenOn.release(Object());
    expect(wake.on, isTrue, reason: 'someone else (the camera) may have switched it on');
  });
}
