// Reads of saved settings (shared preferences) that never throw.
//
// getDouble, getInt, getString, getBool and getStringList throw a TypeError when the key holds
// another type: a value written by another app version, or a hand-edited or damaged preferences
// file. A settings loader that throws keeps its screen from opening for good, so every read in the
// app goes through these (saved_prefs_test.dart fails on a typed get elsewhere in lib/). Numbers
// are also clamped to the range of their settings box (the caller passes the box's min and max:
// keep them in sync), so a value the box would refuse never reaches the job.

import 'package:shared_preferences/shared_preferences.dart';

extension SavedPrefs on SharedPreferences {
  /// The saved number at [key], else null (missing, not a number, not finite).
  double? doubleOrNull(String key) {
    final v = get(key);
    return v is num && v.isFinite ? v.toDouble() : null;
  }

  /// [doubleOrNull] within [lo]..[hi], else [fallback].
  double doubleIn(String key, double fallback, double lo, double hi) =>
      doubleOrNull(key)?.clamp(lo, hi) ?? fallback;

  /// [doubleOrNull] for a whole-number setting; a saved decimal is rounded.
  int? intOrNull(String key) => doubleOrNull(key)?.round();

  /// [intOrNull] within [lo]..[hi], else [fallback].
  int intIn(String key, int fallback, int lo, int hi) =>
      doubleOrNull(key)?.clamp(lo.toDouble(), hi.toDouble()).round() ?? fallback;

  /// The saved text at [key], else null.
  String? stringOrNull(String key) {
    final v = get(key);
    return v is String ? v : null;
  }

  /// The saved list of texts at [key], else null (also when one entry is not a text: the list is
  /// damaged, and dropping that entry would shift the others).
  List<String>? stringListOrNull(String key) {
    final v = get(key);
    return v is List && v.every((e) => e is String) ? v.cast<String>().toList() : null;
  }

  /// The saved switch at [key], else [fallback].
  bool boolOr(String key, bool fallback) {
    final v = get(key);
    return v is bool ? v : fallback;
  }
}
