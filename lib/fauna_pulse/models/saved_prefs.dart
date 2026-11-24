// Reads of saved settings (shared preferences) that never throw.
//
// getDouble, getInt, getString and getBool throw a TypeError when the key holds another type: a
// value written by another app version, or a hand-edited or damaged preferences file. A settings
// loader that throws keeps its screen from opening for good, so loaders read the raw value and
// fall back per key. Numbers are also clamped to the range of their settings box (the caller
// passes the box's min and max: keep them in sync), so a value the box would refuse never
// reaches the job.

import 'package:shared_preferences/shared_preferences.dart';

extension SavedPrefs on SharedPreferences {
  /// The saved number at [key] within [lo]..[hi], else [fallback] (missing, not a number, not
  /// finite).
  double doubleIn(String key, double fallback, double lo, double hi) {
    final v = get(key);
    return v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : fallback;
  }

  /// [doubleIn] for a whole-number setting; a saved decimal is rounded.
  int intIn(String key, int fallback, int lo, int hi) {
    final v = get(key);
    return v is num && v.isFinite ? v.round().clamp(lo, hi) : fallback;
  }

  /// The saved text at [key], else null.
  String? stringOrNull(String key) {
    final v = get(key);
    return v is String ? v : null;
  }

  /// The saved switch at [key], else [fallback].
  bool boolOr(String key, bool fallback) {
    final v = get(key);
    return v is bool ? v : fallback;
  }
}
