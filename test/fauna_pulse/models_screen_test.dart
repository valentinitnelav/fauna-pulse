// Tests for the Download & import models screen (rounds 267-271): what it
// lists for each kind of model, catalogue titles for files on the phone, what
// is offered for download (a name list brings its model along only when it
// is missing), name lists grouped under their model with a warning when a
// model has none (round 271), the class list deleted with its classifier,
// what deleting the last detector or name list warns about, and the 360-px
// layout with a bottom system bar.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

const _dir = '/data/app/files/identification';
final _cls = File('$_dir/models/insectdct-cls-v7_eff2s_fp16.tflite');
final _classList = File('$_dir/packs/insectdct-cls-v7_eff2s_fp16.fpack');

final _downloads = ModelDownloads.parse('''
{"base_url": "https://example.org/r/",
 "detectors": [
   {"id": "md", "title": "MegaDetector V6", "purpose": "Common animals.",
    "licence": "AGPL-3.0", "file": {"name": "MDV6-yolov10-c_int8_256.tflite", "bytes": 2548785}},
   {"id": "fb", "title": "flat-bug (small)", "purpose": "Insects and other arthropods.",
    "licence": "MIT", "file": {"name": "flatbug-n_640_fp16.tflite", "bytes": 5659266}}
 ],
 "identification": [
   {"id": "cls", "title": "insectDCT classifier", "purpose": "Flower visitors.",
    "file": {"name": "insectdct-cls-v7_eff2s_fp16.tflite", "bytes": 43853456},
    "lists": [{"title": "Its 104 classes", "file": {"name": "insectdct-cls-v7_eff2s_fp16.fpack", "bytes": 13737}}]},
   {"id": "b2", "title": "BioCLIP 2", "purpose": "Any organism.",
    "file": {"name": "bioclip-2_image_fp16_4d.tflite", "bytes": 609466720},
    "lists": [{"title": "Europe", "file": {"name": "bioclip2_pollinator_orders_europe_v1.fpack", "bytes": 57479207}},
              {"title": "32 families", "file": {"name": "bioclip2_flower_visitors_32fam_v1.fpack", "bytes": 62754369}}]}
 ]}''');

ModelsInventory _inventory() => ModelsInventory(
  detectors: const [
    ModelEntry(
      id: '/data/app/files/models/MDV6-yolov10-c_int8_256.tflite',
      name: 'MDV6-yolov10-c_int8_256.tflite',
      source: ModelSource.imported,
      precision: 'int8',
      inputSize: 256,
      task: 'detect',
    ),
    ModelEntry(
      id: '/data/app/files/models/my_bees_640.tflite',
      name: 'my_bees_640.tflite',
      source: ModelSource.imported,
      inputSize: 640,
      task: 'detect',
      labels: ['bee', 'hoverfly'],
    ),
  ],
  idModels: [_cls],
  nameLists: [_classList],
  headers: {
    _classList.path: {'kind': 'classes', 'model_id': 'insectdct-cls-v7_eff2s_fp16', 'rows': 104, 'sink_rows': 1},
  },
  sizes: {'/data/app/files/models/my_bees_640.tflite': 6 * 1024 * 1024, _cls.path: 42 * 1024 * 1024},
  storage: 'Storage free: 12.4 GB',
  downloads: _downloads,
);

final _downloaded = <String>[];
var _scans = 0;

Future<void> _pump(WidgetTester tester, {ModelsInventory Function()? inventory}) async {
  _downloaded.clear();
  _scans = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: ModelsScreen(
        scan: () async {
          _scans++;
          return (inventory ?? _inventory)();
        },
        download: (f, identification, onProgress, isCancelled) async => _downloaded.add(f.name),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _tile(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListTile));

Future<void> _show(WidgetTester tester, Finder f) async {
  await tester.dragUntilVisible(f, find.byType(ListView), const Offset(0, -150));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('files on the phone show the catalogue title; own files their name and classes', (tester) async {
    await _pump(tester);
    expect(find.text('Download & import models'), findsOneWidget);
    expect(find.text('Storage free: 12.4 GB'), findsOneWidget);
    expect(find.text('MegaDetector V6'), findsOneWidget);
    expect(find.textContaining('Common animals.\nMDV6-yolov10-c_int8_256.tflite'), findsOneWidget);
    expect(find.text('my_bees_640.tflite'), findsOneWidget);
    expect(find.textContaining('Finds: bee, hoverfly\nOn this phone, 6.0 MB'), findsOneWidget);
    await _show(tester, find.text('insectDCT classifier'));
    expect(find.textContaining('On this phone, 42.0 MB'), findsOneWidget);
    await _show(tester, find.text('insectDCT classifier: Its 104 classes'));
    expect(find.textContaining('Class list of insectdct-cls-v7_eff2s_fp16: 104 classes'), findsOneWidget);
  });

  testWidgets('only what is missing is offered; a name list brings its model along', (tester) async {
    await _pump(tester);
    // MegaDetector is on the phone, flat-bug is not; insectDCT is complete.
    expect(find.descendant(of: _tile('MegaDetector V6'), matching: find.text('Download')), findsNothing);
    await _show(tester, find.text('flat-bug (small)'));
    expect(find.descendant(of: _tile('flat-bug (small)'), matching: find.text('Download')), findsOneWidget);
    await _show(tester, find.text('Europe'));
    expect(find.text('54.8 MB plus the model'), findsOneWidget);
    await tester.tap(find.descendant(of: _tile('Europe'), matching: find.text('Download')));
    await tester.pumpAndSettle();
    expect(find.text('Download BioCLIP 2'), findsOneWidget);
    expect(find.textContaining('The model and the name list "Europe". In total 636.0 MB.'), findsOneWidget);
    expect(find.text('A large download: use Wi-Fi if you can.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Download').last);
    await tester.pumpAndSettle();
    expect(_downloaded, ['bioclip-2_image_fp16_4d.tflite', 'bioclip2_pollinator_orders_europe_v1.fpack']);
    expect(find.text('Downloaded BioCLIP 2.'), findsOneWidget);
    expect(_scans, 2);
  });

  testWidgets('with the BioCLIP model on the phone, a second list comes alone', (tester) async {
    final model = File('$_dir/models/bioclip-2_image_fp16_4d.tflite');
    final europe = File('$_dir/packs/bioclip2_pollinator_orders_europe_v1.fpack');
    await _pump(
      tester,
      inventory: () {
        final base = _inventory();
        return ModelsInventory(
          detectors: base.detectors,
          idModels: [...base.idModels, model],
          nameLists: [...base.nameLists, europe],
          headers: {
            ...base.headers,
            europe.path: {'model_id': 'bioclip-2', 'rows': 35270, 'sink_rows': 6},
          },
          downloads: _downloads,
        );
      },
    );
    // The pack's own count leaves out its "none of these" entries, as the title does.
    await _show(tester, find.text('BioCLIP 2: Europe'));
    expect(find.textContaining('Label pack for bioclip-2: 35,264 names'), findsOneWidget);
    await _show(tester, find.text('32 families'));
    expect(find.textContaining("Model on this phone; name lists below"), findsOneWidget);
    await tester.tap(find.descendant(of: _tile('32 families'), matching: find.text('Download')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The name list "32 families". In total 59.8 MB.'), findsOneWidget);
  });

  testWidgets('deleting a classifier says its class list goes with it; Cancel keeps both', (tester) async {
    await _pump(tester);
    await _show(tester, find.text('insectDCT classifier'));
    await tester.tap(find.descendant(of: _tile('insectDCT classifier'), matching: find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete insectdct-cls-v7_eff2s_fp16.tflite?'), findsOneWidget);
    expect(find.textContaining('Its class list insectdct-cls-v7_eff2s_fp16.fpack is deleted with it.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('insectDCT classifier'), findsOneWidget);
  });

  testWidgets('an empty phone says what needs a model', (tester) async {
    await _pump(tester, inventory: () => ModelsInventory(downloads: _downloads));
    expect(find.textContaining('None yet: live detection'), findsOneWidget);
    await _show(tester, find.text('None yet: "Identify organisms" needs one.'));
  });

  testWidgets('a model without a name list is flagged; a list without its model is set apart (r271)', (tester) async {
    final b2 = File('$_dir/models/bioclip-2_image_fp16_4d.tflite');
    final b25List = File('$_dir/packs/bioclip25_pollinator_orders_europe_v1.fpack');
    await _pump(
      tester,
      inventory: () => ModelsInventory(
        idModels: [b2],
        nameLists: [b25List],
        headers: {
          b25List.path: {'model_id': 'bioclip-2.5', 'rows': 34710, 'sink_rows': 6},
        },
        downloads: _downloads,
      ),
    );
    await _show(tester, find.text('BioCLIP 2'));
    expect(find.text('⚠ No name list: this model cannot identify. Download or import one.'), findsOneWidget);
    await _show(tester, find.text('Name lists without their model'));
    expect(find.text('Their model is not on this phone, so they cannot be used yet.'), findsOneWidget);
  });

  testWidgets('deleting the only detection model, or a model\'s last name list, says what stops working (r271)', (tester) async {
    final europe = File('$_dir/packs/bioclip2_pollinator_orders_europe_v1.fpack');
    final b2 = File('$_dir/models/bioclip-2_image_fp16_4d.tflite');
    await _pump(
      tester,
      inventory: () => ModelsInventory(
        detectors: [_inventory().detectors.first],
        idModels: [b2],
        nameLists: [europe],
        headers: {
          europe.path: {'model_id': 'bioclip-2', 'rows': 35270, 'sink_rows': 6},
        },
        downloads: _downloads,
      ),
    );
    await tester.tap(find.descendant(of: _tile('MegaDetector V6'), matching: find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    expect(find.textContaining('It is the only detection model here.'), findsOneWidget);
    expect(find.textContaining('Time-lapse and motion capture still work.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _show(tester, find.text('BioCLIP 2: Europe'));
    await tester.tap(find.descendant(of: _tile('BioCLIP 2: Europe'), matching: find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('It is the only name list of bioclip-2_image_fp16_4d.tflite, which then cannot identify'),
      findsOneWidget,
    );
  });

  test('a name list belongs to its model: same file name, or model_id at the start of the name (r271)', () {
    bool belongs(String list, Map<String, dynamic>? header, String model) =>
        IdentificationAssets.listBelongsTo(File('/p/$list'), header, File('/m/$model'));
    expect(belongs('bioclip2_x_v1.fpack', {'model_id': 'bioclip-2'}, 'bioclip-2_image_fp16_4d.tflite'), isTrue);
    expect(belongs('bioclip2_x_v1.fpack', {'model_id': 'bioclip-2'}, 'bioclip-2_image_fp16.tflite'), isTrue);
    expect(belongs('bioclip25_x_v1.fpack', {'model_id': 'bioclip-2.5'}, 'bioclip-25_image_fp16.tflite'), isTrue);
    expect(belongs('bioclip25_x_v1.fpack', {'model_id': 'bioclip-2.5'}, 'bioclip-2_image_fp16_4d.tflite'), isFalse);
    expect(belongs('bioclip2_x_v1.fpack', {'model_id': 'bioclip-2'}, 'bioclip-25_image_fp16.tflite'), isFalse);
    // A class list goes with the model of the same file name only.
    final cls = {'kind': 'classes', 'model_id': 'insectdct-cls-v7_eff2s_fp16'};
    expect(belongs('insectdct-cls-v7_eff2s_fp16.fpack', cls, 'insectdct-cls-v7_eff2s_fp16.tflite'), isTrue);
    expect(belongs('insectdct-cls-v7_eff2s_fp16.fpack', cls, 'insectdct-cls-v7_res_fp16.tflite'), isFalse);
    expect(belongs('unreadable.fpack', null, 'bioclip-2_image_fp16.tflite'), isFalse);
  });

  testWidgets('fits a 360-px screen and the last row stays above the system bar', (tester) async {
    simulateBottomSystemBar(tester);
    await _pump(tester);
    final last = find.text('Import name list…');
    await _show(tester, last);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectAboveBottomInset(tester, last, label: 'last button');
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
