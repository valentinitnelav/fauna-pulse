// FaunaPulse (round 285, owner): a house at the right of every screen's title
// bar (all but the home screen and the camera) goes back to the home screen
// in one tap. Deep paths such as Sessions → a session → Identify organisms →
// Identification otherwise take four Back presses.
import 'package:flutter/material.dart';

class HomeButton extends StatelessWidget {
  const HomeButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.home_outlined),
    tooltip: 'Home screen',
    onPressed: () => goHome(Navigator.of(context)),
  );
}

/// Closes the screens one by one down to the first one (the home screen), as
/// that many Back presses would. A screen that asks before it closes (an
/// analysis still running, a selection) asks as it does for Back, and the
/// way home stops there.
Future<void> goHome(NavigatorState nav) async {
  while (nav.mounted && nav.canPop()) {
    final top = _top(nav);
    await nav.maybePop();
    if (!nav.mounted || identical(_top(nav), top)) return; // that screen stayed
  }
}

/// The screen on top, read without closing anything (the stop rule holds at
/// once).
Route<dynamic>? _top(NavigatorState nav) {
  Route<dynamic>? top;
  nav.popUntil((r) {
    top = r;
    return true;
  });
  return top;
}

/// A one-line title that shrinks to fit beside the house instead of being cut
/// ("Download & import mod…" with a large system font size, seen on the
/// Xiaomi).
class FitTitle extends StatelessWidget {
  final String text;
  const FitTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(text));
}
