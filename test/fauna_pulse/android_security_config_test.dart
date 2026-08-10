import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('Android manifest makes backup and network policy explicit', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('android:allowBackup="true"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    expect(manifest, contains('android:usesCleartextTraffic="false"'));
    expect(
      manifest,
      isNot(
        contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'),
      ),
    );
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
    );
    expect(manifest, contains('tools:node="remove"'));
  });

  test('backup includes settings only, not sessions/models/diagnostics', () {
    final legacy = read('android/app/src/main/res/xml/backup_rules.xml');
    final modern = read(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    );
    for (final rules in [legacy, modern]) {
      expect(rules, contains('domain="sharedpref"'));
      expect(rules, isNot(contains('domain="external"')));
      expect(rules, isNot(contains('domain="file"')));
    }
  });

  test('FileProvider exposes only internal and legacy report folders', () {
    final paths = read('android/app/src/main/res/xml/report_file_paths.xml');
    expect(paths, contains('<files-path name="internal_error_reports"'));
    expect(paths, contains('path="error_reports/"'));
    expect(paths, isNot(contains('path="sessions/"')));
    expect(paths, isNot(contains('path="models/"')));
  });

  test(
    'release lint is enabled and API-29 style stays out of base resources',
    () {
      final gradle = read('android/app/build.gradle');
      expect(gradle, contains('checkReleaseBuilds true'));
      expect(gradle, contains('abortOnError true'));
      expect(gradle, isNot(contains('checkReleaseBuilds false')));

      final base = read('android/app/src/main/res/values/styles.xml');
      final baseNight = read(
        'android/app/src/main/res/values-night/styles.xml',
      );
      final api29 = read('android/app/src/main/res/values-v29/styles.xml');
      expect(base, isNot(contains('forceDarkAllowed')));
      expect(baseNight, isNot(contains('forceDarkAllowed')));
      expect(api29, contains('forceDarkAllowed'));
    },
  );

  test(
    'recording wake lock has a renewable fail-safe and no orphan restart',
    () {
      final service = read(
        'android/app/src/main/kotlin/com/ultralytics/yolo/RecordingService.kt',
      );
      expect(service, contains('return START_NOT_STICKY'));
      expect(service, isNot(contains('return START_STICKY')));
      expect(service, contains('lock.acquire(WAKELOCK_TIMEOUT_MS)'));
      expect(
        service,
        contains('postDelayed(renewWakeLock, WAKELOCK_RENEW_MS)'),
      );
      expect(service, contains('WAKELOCK_TIMEOUT_MS = 30L * 60L * 1000L'));
      expect(service, contains('WAKELOCK_RENEW_MS = 25L * 60L * 1000L'));
    },
  );
}
