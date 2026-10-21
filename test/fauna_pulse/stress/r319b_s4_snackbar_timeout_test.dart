// Round 319 part 2 (S4a, phone test PA1 c): in this Flutter version a SnackBar
// with an action stays until it is tapped or swiped away (SnackBar.persist is
// `action != null` when not given), so its duration did nothing. The camera
// permission bar on Home ("Open settings", 8 s) stayed 30 s and more; the
// camera screen's "Settings closed without Apply" bar ("Apply", 8 s) too.
// Both now pass persist: false and go away after their 8 s.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/models_on_phone.dart';
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _permissions = MethodChannel('flutter.baseflow.com/permissions/methods');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Home: the camera permission bar goes away by itself after 8 s', (tester) async {
    // Camera (1) refused (0) when New session asks for it.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_permissions, (call) async {
      if (call.method == 'requestPermissions') return {1: 0};
      if (call.method == 'checkPermissionStatus') return 0;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_permissions, null));
    final downloads = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          scan: () async => const [],
          countModels: () async => const ModelsOnPhone(),
          loadDownloads: () async => downloads,
          modelFiles: () async => const ModelFilesOnPhone(),
          modelChoice: (_) async => (detector: null, idModel: null, nameList: null),
          saveChoice: ({detector, idModel, nameList}) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Open settings'), findsOneWidget, reason: 'the bar shows, with its button');
    expect(find.byType(SnackBar), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(SnackBar), findsOneWidget, reason: 'still there before 8 s');

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing, reason: 'gone after its 8 s, without a tap');
    expect(tester.takeException(), isNull);
  });

  // The camera screen cannot be built in a widget test (camera plugin), so
  // this checks the code: every SnackBar in the app that has an action says
  // whether it stays (persist:), as the default would keep it forever.
  test('every SnackBar with an action in lib/ sets persist', () {
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in RegExp(r'SnackBarAction\(').allMatches(src)) {
        // The SnackBar( call that holds this action: the last one before it.
        final start = src.lastIndexOf('SnackBar(', m.start);
        final body = start < 0 ? '' : _call(src, start);
        if (!body.contains('SnackBarAction(') || !body.contains('persist:')) {
          missing.add('${f.path}:${'\n'.allMatches(src.substring(0, m.start)).length + 1}');
        }
      }
    }
    expect(missing, isEmpty, reason: 'a SnackBar with an action stays until tapped unless persist: false');
  });
}

/// The text of the call that starts at [start] (up to its closing bracket).
String _call(String src, int start) {
  var depth = 0;
  for (var i = src.indexOf('(', start); i < src.length; i++) {
    if (src[i] == '(') depth++;
    if (src[i] == ')' && --depth == 0) return src.substring(start, i + 1);
  }
  return src.substring(start);
}
