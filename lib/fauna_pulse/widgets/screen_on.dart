// FaunaPulse (round 309): keeping the screen on for the video players and the
// runs of "Find animals in videos".
//
// The phone's "keep the screen on" (a wake-lock, WakelockPlus) is one switch
// for the whole app: whoever turns it off turns it off for everyone. Since the
// videos play on "Find animals in videos" too, a player that was paused just
// before a run started could switch it off while the run needed it on. So each
// of them holds the screen on here instead: it stays on while at least one
// holds it, and goes back to the phone's own screen timeout once none does.

import 'package:wakelock_plus/wakelock_plus.dart';

import '../logging/app_error_hooks.dart';

class ScreenOn {
  ScreenOn._();

  static final _owners = <Object>{};

  /// Keeps the screen on for [owner]; holding again changes nothing.
  static void hold(Object owner) {
    if (_owners.add(owner) && _owners.length == 1) _set(true);
  }

  /// Lets go of [owner]'s hold (none held: nothing happens).
  static void release(Object owner) {
    if (_owners.remove(owner) && _owners.isEmpty) _set(false);
  }

  /// Best effort: a run goes on even if the phone refuses.
  static void _set(bool on) =>
      WakelockPlus.toggle(enable: on).catchError((Object e) => logSwallowed('screen_on', e));
}
