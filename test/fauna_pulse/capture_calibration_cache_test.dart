// Tests for the persistent full-res photo-size cache (round 121):
// keying rules, save/load round-trip, stale-stem cleanup, and rejection of
// malformed stored values.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fauna_pulse/fauna_pulse/session/capture_calibration_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildKey', () {
    test('separates device, version and lens', () {
      final a = CaptureCalibrationCache.buildKey(
        model: 'Xiaomi 2107113SG',
        appVersion: '0.6.4',
        lensZoom: 1.0,
      );
      final otherLens = CaptureCalibrationCache.buildKey(
        model: 'Xiaomi 2107113SG',
        appVersion: '0.6.4',
        lensZoom: 0.5,
      );
      final otherVersion = CaptureCalibrationCache.buildKey(
        model: 'Xiaomi 2107113SG',
        appVersion: '0.6.5',
        lensZoom: 1.0,
      );
      final otherDevice = CaptureCalibrationCache.buildKey(
        model: 'Samsung M12',
        appVersion: '0.6.4',
        lensZoom: 1.0,
      );
      expect(a, isNot(otherLens));
      expect(a, isNot(otherVersion));
      expect(a, isNot(otherDevice));
    });
  });

  group('load/save', () {
    test('round-trips a measured size', () async {
      SharedPreferences.setMockInitialValues({});
      final key = CaptureCalibrationCache.buildKey(
        model: 'm',
        appVersion: '1.0.0',
        lensZoom: 1.0,
      );
      expect(await CaptureCalibrationCache.load(key), isNull);
      await CaptureCalibrationCache.save(key, 4000, 3000);
      expect(await CaptureCalibrationCache.load(key), (4000, 3000));
    });

    test('rejects malformed or non-positive stored values', () async {
      final key = CaptureCalibrationCache.buildKey(
        model: 'm',
        appVersion: '1.0.0',
        lensZoom: 1.0,
      );
      for (final bad in ['garbage', '4000x', 'x3000', '0x3000', '-1x100']) {
        SharedPreferences.setMockInitialValues({key: bad});
        expect(
          await CaptureCalibrationCache.load(key),
          isNull,
          reason: 'stored "$bad" must not load',
        );
      }
    });

    test('save drops other stems but keeps sibling lenses', () async {
      String k(String model, String version, double zoom) =>
          CaptureCalibrationCache.buildKey(
            model: model,
            appVersion: version,
            lensZoom: zoom,
          );
      SharedPreferences.setMockInitialValues({
        k('m', '0.9.0', 1.0): '1000x800', // old app version → dropped
        k('other', '1.0.0', 1.0): '2000x1500', // other device → dropped
        k('m', '1.0.0', 0.5): '3000x2200', // sibling lens, same stem → kept
        'faunapulse_session_config': '{}', // unrelated prefs untouched
      });
      await CaptureCalibrationCache.save(k('m', '1.0.0', 1.0), 4000, 3000);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(k('m', '0.9.0', 1.0)), isNull);
      expect(prefs.getString(k('other', '1.0.0', 1.0)), isNull);
      expect(await CaptureCalibrationCache.load(k('m', '1.0.0', 0.5)), (
        3000,
        2200,
      ));
      expect(await CaptureCalibrationCache.load(k('m', '1.0.0', 1.0)), (
        4000,
        3000,
      ));
      expect(prefs.getString('faunapulse_session_config'), '{}');
    });
  });
}
