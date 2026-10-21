// Round 319 part 2 (S2e): one unit for two sizes in one sentence. Phone
// test PB1: "3.8 GB free, but a recording needs at least 5000 MB free" ("Before
// you record" and the "Not enough free storage" window) and "the download
// needs 1.2 GB, but only 765.2 MB is free" (download dialog). Where the
// sentence names a setting in MB, both numbers are in MB; otherwise both are
// in the unit of the larger number.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/logging/device_storage.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_security.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_import_screen.dart' show notEnoughStorageMessage;
import 'package:fauna_pulse/fauna_pulse/widgets/not_enough_storage_dialog.dart';

const _mb = 1024 * 1024;
const _gb = 1024 * _mb;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PB1: 3.8 GB free and a 5000 MB reserve, both in MB', () {
    final text = notEnoughStorageText((3.8 * _gb).round(), 5000);
    expect(
      text,
      '3891 MB free, but a recording needs at least 5000 MB free (Settings, Power tab, Keep free storage). '
      'Free some space first, for example by deleting old sessions or videos.',
    );
  });

  test('the check before a model download or import: one unit', () async {
    const channel = MethodChannel('faunapulse/thermal');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => {'freeBytes': (765.2 * _mb).round(), 'totalBytes': 64 * _gb});
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Object? error;
    try {
      await ensureModelStorageAvailable('/x', 1200 * _mb);
    } catch (e) {
      error = e;
    }
    expect(
      plainModelError(error!),
      'Not enough free storage on this phone: the file needs 1.2 GB, and only 0.7 GB is free. Delete some '
      'files (for example old sessions), then try again.',
    );
  });

  test('videos that do not fit: one unit', () {
    expect(
      notEnoughStorageMessage(neededBytes: (1.2 * _gb).round(), freeBytes: (765.2 * _mb).round()),
      'The videos could not be copied: not enough free storage (1.2 GB needed, 0.7 GB free). Free some space '
      'and try again.',
    );
    // Only one number: its own unit.
    expect(
      notEnoughStorageMessage(freeBytes: (26.8 * _mb).round()),
      'The videos could not be copied: not enough free storage (26.8 MB free). Free some space and try again.',
    );
  });

  test('formatBytes in the unit of another number', () {
    expect(formatBytes(0, unitOf: _gb), '0.0 GB');
    // Whole MB like "Keep free storage", rounded down.
    expect(formatMegabytes((4999.6 * _mb).round()), '4999 MB');
    expect(freeStorageClause(30 * _mb, unitOf: (1.2 * _gb).round()), 'almost no storage is free');
    expect(freeStorageClause((765.2 * _mb).round(), unitOf: (1.2 * _gb).round()), 'only 0.7 GB is free');
    expect(formatBytes((765.2 * _mb).round(), unitOf: (1.2 * _gb).round()), '0.7 GB');
    expect(formatBytes(13737, unitOf: 41 * _mb), '0.0 MB');
    expect(formatBytes(3 * _gb, unitOf: _mb), '3072.0 MB');
    // Without it, as before.
    expect(formatBytes((765.2 * _mb).round()), '765.2 MB');
    expect(formatBytes(13737), '13 KB');
  });
}
