// FaunaPulse (round 319): a SnackBar that its screen closes later.

import 'package:flutter/material.dart';

/// Holds one shown SnackBar so its screen can close it when it no longer
/// fits (Settings opened again, a recording started, the screen left).
///
/// The bar also goes away by itself (its time runs out, a swipe, its button).
/// close() on a bar that is already gone fails in debug builds ('Bad state:
/// No element') and hides whatever other bar shows in release builds, so the
/// bar is forgotten as soon as it closes.
class ClosableSnackBar {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _bar;

  /// The bar is still on screen (or waiting behind another one).
  bool get isShowing => _bar != null;

  void show(ScaffoldMessengerState messenger, SnackBar snackBar) {
    final bar = messenger.showSnackBar(snackBar);
    _bar = bar;
    bar.closed.then((_) {
      if (identical(_bar, bar)) _bar = null;
    });
  }

  /// Closes the bar if it still shows; nothing otherwise.
  void close() {
    final bar = _bar;
    _bar = null;
    bar?.close();
  }

  /// Forgets the bar without closing it (its own button closes it).
  void forget() => _bar = null;
}
