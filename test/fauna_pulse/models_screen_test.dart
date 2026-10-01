// Tests for the AI models screen (round 267): what it lists for each kind of
// model, which files can be deleted, that a classifier's class list goes
// with it, and the 360-px layout with a bottom system bar.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

const _dir = '/data/app/files/identification';
final _cls = File('$_dir/models/insectdct-cls-v7_eff2s_fp16.tflite');
final _clip = File('$_dir/models/bioclip-2_image_fp16.tflite');
final _classList = File('$_dir/packs/insectdct-cls-v7_eff2s_fp16.fpack');
final _labelPack = File('$_dir/packs/bioclip2_pollinator_orders_europe_v1.fpack');

ModelsInventory _inventory() => ModelsInventory(
  detectors: const [
    ModelEntry(
      id: 'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
      name: 'MDV6-yolov10-c_int8_256.tflite',
      source: ModelSource.bundled,
      precision: 'int8',
      inputSize: 256,
      task: 'detect',
      labels: ['animal', 'person', 'vehicle'],
    ),
    ModelEntry(
      id: '/data/app/files/models/flatbug-n_640_fp16.tflite',
      name: 'flatbug-n_640_fp16.tflite',
      source: ModelSource.imported,
      precision: 'fp16',
      inputSize: 640,
      task: 'detect',
      labels: ['arthropod'],
    ),
  ],
  idModels: [_clip, _cls],
  nameLists: [_labelPack, _classList],
  headers: {
    _classList.path: {'kind': 'classes', 'model_id': 'insectdct-cls-v7_eff2s_fp16', 'rows': 104},
    _labelPack.path: {'model_id': 'bioclip-2', 'rows': 512},
  },
  sizes: {
    '/data/app/files/models/flatbug-n_640_fp16.tflite': 6 * 1024 * 1024,
    _cls.path: 42 * 1024 * 1024,
  },
  storage: 'Storage free: 12.4 GB',
);

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: ModelsScreen(scan: () async => _inventory()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists both kinds of model with what each one is', (tester) async {
    await _pump(tester);
    expect(find.text('AI models'), findsOneWidget);
    expect(find.text('Storage free: 12.4 GB'), findsOneWidget);
    expect(find.textContaining('Finds: animal, person, vehicle'), findsOneWidget);
    expect(find.textContaining('Built into the app'), findsOneWidget);
    expect(find.textContaining('Imported, 6.0 MB'), findsOneWidget);

    final list = find.byType(ListView);
    await tester.dragUntilVisible(find.text(_classList.path.split('/').last), list, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(find.text('With its class list, 42.0 MB'), findsOneWidget);
    expect(find.text('Uses a label pack made for this model'), findsOneWidget);
    expect(find.text('Class list of insectdct-cls-v7_eff2s_fp16: 104 classes'), findsOneWidget);
    expect(find.text('Label pack for bioclip-2: 512 names'), findsOneWidget);
  });

  testWidgets('only imported files can be deleted', (tester) async {
    await _pump(tester);
    final list = find.byType(ListView);
    await tester.dragUntilVisible(find.text(_classList.path.split('/').last), list, const Offset(0, -150));
    await tester.pumpAndSettle();
    // The built-in MDV6 has none; flat-bug, 2 identification models and 2
    // name lists have one each (the list may have scrolled flat-bug away).
    await tester.dragUntilVisible(find.text('MDV6-yolov10-c_int8_256.tflite'), list, const Offset(0, 150));
    await tester.pumpAndSettle();
    final mdv6 = find.ancestor(of: find.text('MDV6-yolov10-c_int8_256.tflite'), matching: find.byType(ListTile));
    expect(find.descendant(of: mdv6, matching: find.byTooltip('Delete')), findsNothing);
    final flatbug = find.ancestor(of: find.text('flatbug-n_640_fp16.tflite'), matching: find.byType(ListTile));
    expect(find.descendant(of: flatbug, matching: find.byTooltip('Delete')), findsOneWidget);
  });

  testWidgets('deleting a classifier says its class list goes with it; Cancel keeps both', (tester) async {
    await _pump(tester);
    final list = find.byType(ListView);
    final name = _cls.path.split('/').last;
    await tester.dragUntilVisible(find.text(name), list, const Offset(0, -150));
    await tester.pumpAndSettle();
    final tile = find.ancestor(of: find.text(name), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: tile, matching: find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete $name?'), findsOneWidget);
    expect(find.textContaining('Its class list insectdct-cls-v7_eff2s_fp16.fpack is deleted with it.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete $name?'), findsNothing);
    expect(find.text(name), findsOneWidget);
  });

  testWidgets('fits a 360-px screen and the last row stays above the system bar', (tester) async {
    simulateBottomSystemBar(tester);
    await _pump(tester);
    final last = find.text(_classList.path.split('/').last);
    await tester.dragUntilVisible(last, find.byType(ListView), const Offset(0, -150));
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectAboveBottomInset(tester, last, label: 'last name list');
  });

  test('a classifier is deleted together with its class list only', () async {
    final tmp = Directory.systemTemp.createTempSync('models_screen');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final model = File('${tmp.path}/cls.tflite')..writeAsStringSync('m');
    final own = File('${tmp.path}/cls.fpack')..writeAsStringSync('c');
    final other = File('${tmp.path}/bioclip2_pack.fpack')..writeAsStringSync('p');
    final lists = IdentificationAssets.classListsOf(model, [other, own]);
    expect(lists.map((f) => f.path), [own.path]);
    final deleted = await IdentificationAssets.deleteFiles([model, ...lists]);
    expect(deleted, ['cls.tflite', 'cls.fpack']);
    expect(model.existsSync(), isFalse);
    expect(own.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
  });
}
