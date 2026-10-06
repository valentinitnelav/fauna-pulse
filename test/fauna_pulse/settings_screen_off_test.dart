// Round 293: the Power tab's "Screen off by itself after" field at phone width (360 px):
// shown at the top, its explanation opens without overflow, and a typed value is kept.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/settings_sheet.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/numeric_setting_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('faunapulse_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => tmp.path,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    tmp.deleteSync(recursive: true);
  });

  Future<SessionConfig?> open(WidgetTester tester, SessionConfig config) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SessionConfig? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<SessionConfig>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SizedBox(height: 760, child: SettingsSheet(config: config)),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Power tab: screen off by itself after', (tester) async {
    await open(tester, const SessionConfig().copyWith(screenOffAfterMin: 3));
    await tester.tap(find.text('Power'));
    await tester.pumpAndSettle();
    expect(find.text('Screen off by itself after'), findsOneWidget);
    expect(find.text('3'), findsWidgets);
    // Open its explanation (the (i) next to the label) and check nothing overflows.
    final field = find.ancestor(
      of: find.text('Screen off by itself after'),
      matching: find.byType(NumericSettingField),
    );
    await tester.tap(find.descendant(of: field, matching: find.byIcon(Icons.info_outline)));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 = never (the default)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
