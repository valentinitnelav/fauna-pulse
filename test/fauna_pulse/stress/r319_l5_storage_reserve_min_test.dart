// Round 319 (L5b, stress finding n54): "Keep free storage" = 0 ("never") let a
// full storage leave half-written files and even break the settings file. The
// lowest value is now 50 MB: in the Settings box and for saved values.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/settings_sheet.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/numeric_setting_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saved values are clamped to 50..5000 MB; a saved 0 becomes 50', () {
    expect(SessionConfig.fromJson(const {'storageReserveMb': 0}).storageReserveMb, 50);
    expect(SessionConfig.fromJson(const {'storageReserveMb': -5}).storageReserveMb, 50);
    expect(SessionConfig.fromJson(const {'storageReserveMb': 49}).storageReserveMb, 50);
    expect(SessionConfig.fromJson(const {'storageReserveMb': 50}).storageReserveMb, 50);
    expect(SessionConfig.fromJson(const {'storageReserveMb': 9999}).storageReserveMb, 5000);
    expect(SessionConfig.fromJson(const {}).storageReserveMb, 200);
  });

  group('Settings box', () {
    late Directory tmp;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('faunapulse_r319_reserve');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        (call) async => tmp.path,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
      tmp.deleteSync(recursive: true);
    });

    testWidgets('lowest 50 MB, helper text without "0 = never"', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<SessionConfig>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SizedBox(height: 760, child: SettingsSheet(config: const SessionConfig())),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Power'));
      await tester.pumpAndSettle();
      final field = find.ancestor(of: find.text('Keep free storage'), matching: find.byType(NumericSettingField));
      final w = tester.widget<NumericSettingField>(field);
      expect(w.min, 50);
      expect(w.max, 5000);
      expect(
        w.helperText,
        'The recording stops when the free storage drops below this, with its files closed '
        'properly. Lowest 50 MB, so the phone and the last files still have room. Default 200 MB.',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
