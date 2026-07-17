// Tests for round 126: the one-fix-per-session stability tracker, the
// SessionLocation JSON round-trip, and the EXIF stamping on exported crops
// (encode→decode round-trip proves the tags really land in the JPEG).

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:fauna_pulse/fauna_pulse/capture/crop_export.dart';
import 'package:fauna_pulse/fauna_pulse/session/location_fix.dart';

void main() {
  group('LocationFixTracker', () {
    test('keeps the most accurate fix and stops when stable', () {
      final t = LocationFixTracker(startMs: 0);
      expect(t.addFix(47.1, 8.5, 80, 1000), isFalse);
      expect(t.addFix(47.2, 8.6, 40, 2000), isFalse);
      expect(t.best!.accuracyM, 40);
      // A worse fix never replaces the best one.
      expect(t.addFix(47.3, 8.7, 90, 3000), isFalse);
      expect(t.best!.accuracyM, 40);
      // Stable once accuracy reaches the threshold.
      expect(t.addFix(47.25, 8.65, 12, 4000), isTrue);
      expect(t.best!.latitude, 47.25);
      expect(t.best!.source, 'gps');
    });

    test('gives up waiting after maxWaitMs with any fix at all', () {
      final t = LocationFixTracker(startMs: 0, maxWaitMs: 10000);
      expect(t.addFix(47.1, 8.5, 50, 1000), isFalse);
      expect(t.isDone(9999), isFalse);
      expect(t.isDone(10000), isTrue);
      // But never "done" without a single fix.
      final empty = LocationFixTracker(startMs: 0, maxWaitMs: 10000);
      expect(empty.isDone(99999), isFalse);
    });

    test('a fix with unknown accuracy loses to any measured one', () {
      final t = LocationFixTracker(startMs: 0);
      t.addFix(47.1, 8.5, null, 1000);
      t.addFix(47.2, 8.6, 500, 2000);
      expect(t.best!.accuracyM, 500);
    });
  });

  group('SessionLocation JSON', () {
    test('round-trips', () {
      const loc = SessionLocation(
        latitude: 47.12345,
        longitude: 8.54321,
        accuracyM: 8.5,
        fixTimeMs: 1234567,
        source: 'gps',
      );
      final back = SessionLocation.fromJson(loc.toJson());
      expect(back!.latitude, loc.latitude);
      expect(back.longitude, loc.longitude);
      expect(back.accuracyM, loc.accuracyM);
      expect(back.fixTimeMs, loc.fixTimeMs);
      expect(back.source, 'gps');
    });

    test('rejects incomplete maps, accepts manual without accuracy', () {
      expect(SessionLocation.fromJson(null), isNull);
      expect(SessionLocation.fromJson({'lat': 1.0}), isNull);
      final manual = SessionLocation.fromJson({
        'lat': -12.5,
        'lon': -70.25,
        'fix_time_ms': 5,
        'source': 'manual',
      });
      expect(manual!.accuracyM, isNull);
      expect(manual.source, 'manual');
      expect(manual.label, contains('-12.50000, -70.25000'));
      expect(manual.label, isNot(contains('±')));
    });
  });

  group('crop EXIF stamping', () {
    // A real (tiny) JPEG so decode→crop→encode runs the full path.
    List<int> makeJpeg(int side) =>
        img.encodeJpg(img.Image(width: side, height: side));

    test('GPS + DateTimeOriginal survive the encode→decode round trip', () {
      final src = Uint8List.fromList(makeJpeg(64));
      // 2026-07-17 15:04:05 local.
      final at = DateTime(2026, 7, 17, 15, 4, 5).millisecondsSinceEpoch;
      final out = cropJpegRectSync(
        src,
        const Rect.fromLTRB(0, 0, 1, 1),
        exif: CropExifInfo(capturedAtMs: at, latitude: 47.5, longitude: -8.25),
      );
      expect(out, isNotNull);
      final back = img.decodeJpg(out!.jpeg)!;
      expect(
        back.exif.exifIfd['DateTimeOriginal'].toString(),
        '2026:07:17 15:04:05',
      );
      expect(back.exif.gpsIfd['GPSLatitudeRef'].toString(), 'N');
      expect(back.exif.gpsIfd['GPSLongitudeRef'].toString(), 'W');
      // Round 127 hardening: version + datum for strict mobile parsers.
      expect(back.exif.gpsIfd['GPSVersionID'], isNotNull);
      expect(back.exif.gpsIfd['GPSMapDatum'].toString(), 'WGS-84');
      // 47.5° = 47° 30' 0"; -8.25° = 8° 15' 0" W.
      expect(back.exif.gpsIfd['GPSLatitude'].toString(), contains('47'));
      expect(back.exif.gpsIfd['GPSLongitude'].toString(), contains('15'));
    });

    test('no EXIF block is written when info is empty', () {
      final src = Uint8List.fromList(makeJpeg(64));
      final out = cropJpegRectSync(src, const Rect.fromLTRB(0, 0, 1, 1));
      final back = img.decodeJpg(out!.jpeg)!;
      expect(back.exif.gpsIfd['GPSLatitude'], isNull);
      expect(back.exif.exifIfd['DateTimeOriginal'], isNull);
    });

    test('DMS conversion is exact for whole minutes', () {
      final v = exifDmsRational(47.5); // 47° 30' 0"
      expect(v.toString(), contains('47'));
      expect(v.toString(), contains('30'));
      expect(
        exifDateTime(DateTime(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch),
        '2026:01:02 03:04:05',
      );
    });
  });
}
