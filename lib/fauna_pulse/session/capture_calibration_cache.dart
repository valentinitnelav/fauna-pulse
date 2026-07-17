// FaunaPulse — persistent cache for the slow full-resolution photo-size
// probe (round 121).
//
// The pixel size of a saved full-res photo is a hardware fact of the phone,
// but re-measuring it with a real test photo on EVERY "New session" press
// (up to 6 attempts × 4 s timeouts) was almost all of the "Calibrating…"
// wait. This cache stores the last measured size in shared_preferences so
// the camera screen can apply it instantly and unlock the controls, while
// the real probe still runs in the background and corrects + re-saves the
// cache if the phone ever disagrees (stale-while-revalidate — see
// [CameraDiagnosticsController._probeCaptureResolution]).
//
// Safety rules:
// - Only genuine probe successes are stored; the analysis-frame FALLBACK
//   (used when every capture attempt fails) is never cached.
// - The key includes the device model (an Android backup restored onto a
//   different phone must miss), the app version (cheap insurance against
//   camera-pipeline changes in an update), and the lens zoom (different
//   lenses are different sensors).
// - Stored in shared_preferences, NOT SessionConfig: it is a measurement,
//   not a user setting, and must never travel through the config JSON.

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_error_hooks.dart';

class CaptureCalibrationCache {
  CaptureCalibrationCache._();

  static const String _prefix = 'capture_dims_';

  /// Pure key builder, separated from the platform lookups so tests can
  /// exercise the keying rules deterministically.
  static String buildKey({
    required String model,
    required String appVersion,
    required double lensZoom,
  }) => '$_prefix${model}_${appVersion}_z${lensZoom.toStringAsFixed(2)}';

  /// The cache key for this device + app version + lens. Platform lookups
  /// that fail (or are unavailable, e.g. in unit tests) degrade to
  /// "unknown" — the key stays usable, just less discriminating.
  static Future<String> key(double lensZoom) async {
    var model = 'unknown';
    var version = 'unknown';
    try {
      if (Platform.isAndroid) {
        final a = await DeviceInfoPlugin().androidInfo;
        model = '${a.manufacturer} ${a.model}';
      }
    } catch (e) {
      logSwallowed('capture_cache_device', e);
    }
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (e) {
      logSwallowed('capture_cache_version', e);
    }
    return buildKey(model: model, appVersion: version, lensZoom: lensZoom);
  }

  /// Returns the cached upright (width, height), or null when absent or
  /// unreadable.
  static Future<(int, int)?> load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final parts = raw.split('x');
      if (parts.length != 2) return null;
      final w = int.tryParse(parts[0]);
      final h = int.tryParse(parts[1]);
      if (w == null || h == null || w <= 0 || h <= 0) return null;
      return (w, h);
    } catch (e) {
      logSwallowed('capture_cache_load', e);
      return null;
    }
  }

  /// Stores a measured size and drops entries from other device/version
  /// stems (an app update leaves the old version's keys behind; per-lens
  /// entries of the CURRENT stem are kept).
  static Future<void> save(String key, int w, int h) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stem = key.substring(0, key.lastIndexOf('_z'));
      for (final k in prefs.getKeys()) {
        if (k.startsWith(_prefix) && !k.startsWith(stem)) {
          await prefs.remove(k);
        }
      }
      await prefs.setString(key, '${w}x$h');
    } catch (e) {
      logSwallowed('capture_cache_save', e);
    }
  }
}
