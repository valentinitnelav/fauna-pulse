import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_storage.dart';

void main() {
  group('StorageReading', () {
    test('label is GB with one decimal and no unit switching', () {
      const gb = 1024 * 1024 * 1024;
      expect(
        const StorageReading(freeBytes: 12 * gb + gb ~/ 2).label,
        'Storage free: 12.5 GB',
      );
      // Small values stay in GB (one scale) instead of flipping to MB.
      expect(
        const StorageReading(freeBytes: 200 * 1024 * 1024).label,
        '⚠ Storage free: 0.2 GB',
      );
    });

    test('low-storage marker appears only below the threshold', () {
      const gb = 1024 * 1024 * 1024;
      expect(const StorageReading(freeBytes: 2 * gb).isLow, isFalse);
      expect(const StorageReading(freeBytes: gb ~/ 2).isLow, isTrue);
      // Unknown reading: hidden, never flagged.
      expect(const StorageReading().isLow, isFalse);
      expect(const StorageReading().label, isEmpty);
    });

    test('toJson carries the raw byte counts for the session log', () {
      expect(const StorageReading(freeBytes: 10, totalBytes: 20).toJson(), {
        'free_storage_bytes': 10,
        'total_storage_bytes': 20,
      });
    });
  });
}
