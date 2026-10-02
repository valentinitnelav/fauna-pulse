// Round 278: the page behind an answer to "What do you want to watch?": the
// suggested models from the list file (`uses`), which are on the phone, the
// size to download, one download for the chosen files, and "Use them from now
// on" (the choice is saved only when ticked).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_storage.dart' show formatBytes;
import 'package:fauna_pulse/fauna_pulse/models/model_choice_keys.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/models_on_phone.dart';
import 'package:fauna_pulse/fauna_pulse/screens/watch_plan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _downloads = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
WatchUse _use(String id) => _downloads.uses.firstWhere((u) => u.id == id);

class _Calls {
  final downloaded = <(String, bool)>[];
  final saved = <(String?, String?, String?)>[];
  Object? failWith;
}

Future<bool?> _pump(WidgetTester tester, WatchUse use, Set<String> onPhone, _Calls calls) async {
  tester.view.physicalSize = const Size(360, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  bool? popped;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => WatchPlanScreen(
                      use: use,
                      onPhone: () async => onPhone,
                      download: (f, identification, onProgress, isCancelled) async {
                        if (calls.failWith != null) throw calls.failWith!;
                        calls.downloaded.add((f.name, identification));
                      },
                      saveChoice: ({detector, idModel, nameList}) async =>
                          calls.saved.add((detector, idModel, nameList)),
                    ),
                  ),
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
  return popped;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the shipped list has the three answers, each with offered models', () {
    expect(_downloads.uses.map((u) => u.id), ['pollinators', 'flat_surface', 'mammals_birds']);
    expect(_use('pollinators').find.map((d) => d.id), ['insectdct-v8s', 'flatbug-n']);
    expect(_use('pollinators').name.map((n) => n.$1.id), ['insectdct-cls-v7-eff2s', 'bioclip-2', 'bioclip-2']);
    expect(_use('flat_surface').find.first.id, 'flatbug-n');
    final (model, list) = _use('mammals_birds').name.single;
    expect(model.id, 'bioclip-2');
    expect(list.file.name, 'bioclip-2_mammals-birds-world_v1.fpack');
    expect(list.file.bytes, greaterThan(0));
    expect(list.file.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    for (final u in _downloads.uses) {
      expect(u.setup, isNotEmpty, reason: u.id);
    }
  });

  testWidgets('pollinators: what is on the phone, the size, one download, the choice saved', (tester) async {
    final calls = _Calls();
    await _pump(tester, _use('pollinators'), {'insectdct-v8-s_640_fp16.tflite'}, calls);
    expect(find.text('To find the animals'), findsOneWidget);
    expect(find.text('insectDCT detector'), findsOneWidget);
    expect(find.text('flat-bug n (small)'), findsOneWidget);
    expect(find.text('On this phone'), findsOneWidget, reason: 'only the insectDCT detector');
    expect(find.text('To name them'), findsOneWidget);
    expect(find.text('insectDCT classifier'), findsOneWidget);
    expect(find.textContaining('Name list: Flies, bees and wasps'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'nothing overflows at 360 px');
    // Preselected: the first of each; only the classifier and its class list
    // are missing.
    final cls = _use('pollinators').name.first;
    final bytes = cls.$1.file!.bytes + cls.$2.file.bytes;
    await tester.ensureVisible(find.text('Download (${formatBytes(bytes)})'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download (${formatBytes(bytes)})'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The detection model insectDCT detector and the identification model insectDCT classifier with its class list'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Download')));
    await tester.pumpAndSettle();
    expect(calls.downloaded, [('insectdct-cls-v7_eff2s_fp16.tflite', true), ('insectdct-cls-v7_eff2s_fp16.fpack', true)]);
    expect(calls.saved, [('insectdct-v8-s_640_fp16.tflite', 'insectdct-cls-v7_eff2s_fp16.tflite', 'insectdct-cls-v7_eff2s_fp16.fpack')]);
    expect(find.byType(WatchPlanScreen), findsNothing, reason: 'back on the home screen');
  });

  testWidgets('another detector, no naming, not used: downloads only, saves nothing', (tester) async {
    final calls = _Calls();
    await _pump(tester, _use('pollinators'), const {}, calls);
    await tester.tap(find.text('flat-bug n (small)'));
    await tester.tap(find.text('Not now'));
    await tester.ensureVisible(find.text('Use them from now on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use them from now on'));
    await tester.pumpAndSettle();
    final flatbug = _use('pollinators').find[1].file!;
    await tester.ensureVisible(find.text('Download (${formatBytes(flatbug.bytes)})'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download (${formatBytes(flatbug.bytes)})'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Download')));
    await tester.pumpAndSettle();
    expect(calls.downloaded, [(flatbug.name, false)]);
    expect(calls.saved, isEmpty);
  });

  testWidgets('everything on the phone: "Use them", which needs the tick', (tester) async {
    final calls = _Calls();
    final use = _use('mammals_birds');
    final (model, list) = use.name.single;
    await _pump(tester, use, {use.find.single.file!.name, model.file!.name, list.file.name}, calls);
    expect(find.text('On this phone'), findsNWidgets(2));
    await tester.tap(find.text('Use them from now on'));
    await tester.pumpAndSettle();
    final button = find.widgetWithText(FilledButton, 'Use them');
    expect(tester.widget<FilledButton>(button).onPressed, isNull, reason: 'nothing to do');
    await tester.tap(find.text('Use them from now on'));
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(calls.downloaded, isEmpty);
    expect(calls.saved, [(use.find.single.file!.name, model.file!.name, list.file.name)]);
  });

  testWidgets('mammals and birds: the new name list and a large download', (tester) async {
    await _pump(tester, _use('mammals_birds'), const {}, _Calls());
    expect(find.text('MegaDetector V6'), findsOneWidget);
    expect(find.textContaining('Name list: Mammals and birds of the world'), findsOneWidget);
    expect(find.textContaining('use Wi-Fi'), findsOneWidget, reason: 'BioCLIP 2 is over 600 MB');
  });

  testWidgets('a file not online yet: the plain message, nothing saved', (tester) async {
    final calls = _Calls()..failWith = Exception('Nothing was found at this link (HTTP 404). The file may not be online yet: please try again later.');
    await _pump(tester, _use('mammals_birds'), const {}, calls);
    await tester.tap(find.textContaining('Download ('));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Download')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The file may not be online yet'), findsOneWidget);
    expect(calls.saved, isEmpty);
  });

  test('useModels: the Identify choice is saved under the keys Identify reads', () async {
    await useModels(idModel: 'bioclip-2_image_fp16_4d.tflite', nameList: 'bioclip-2_mammals-birds-world_v1.fpack');
    final p = await SharedPreferences.getInstance();
    expect(p.getString(kIdentifyModelPref), 'bioclip-2_image_fp16_4d.tflite');
    expect(p.getString(kIdentifyPackPref), 'bioclip-2_mammals-birds-world_v1.fpack');
    expect(p.getString(kAnalysisModelPref), isNull, reason: 'no detection model given');
  });
}
