// Tests for the Download & import models screen (rounds 267-275): what it
// lists for each kind of model, file names with the details in a card behind
// the ⓘ (round 275), what is offered for download, alphabetically (a name
// list brings its model along only when it is missing), name lists grouped
// under their model with a warning when a model has none (round 271), the
// class list deleted with its classifier, what deleting the last detector or
// name list warns about, the one import and link download for every kind
// with the question before replacing a file (round 275), and the 360-px
// layout with a bottom system bar.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_import.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/external_link.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

const _dir = '/data/app/files/identification';
final _cls = File('$_dir/models/insectdct-cls-v7_eff2s_fp16.tflite');
final _classList = File('$_dir/packs/insectdct-cls-v7_eff2s_fp16.fpack');

final _downloads = ModelDownloads.parse('''
{"base_url": "https://example.org/r/",
 "models": [
   {"id": "md", "kind": "detection_model", "title": "MegaDetector V6", "purpose": "Common animals.",
    "licence": "AGPL-3.0", "source": "https://github.com/microsoft/MegaDetector",
    "file": {"name": "MDV6-yolov10-c_int8_256.tflite", "bytes": 2548785}},
   {"id": "fb", "kind": "detection_model", "title": "flat-bug (small)", "purpose": "Insects and other arthropods.",
    "licence": "MIT", "file": {"name": "flatbug-n_640_fp16.tflite", "bytes": 5659266}},
   {"id": "flatbug-s", "kind": "detection_model", "title": "flat-bug s (larger)", "purpose": "Insects, a larger network.",
    "licence": "MIT", "source": "https://github.com/darsa-group/flat-bug"},
   {"id": "cls", "kind": "identification_model", "title": "insectDCT classifier", "purpose": "Flower visitors.",
    "file": {"name": "insectdct-cls-v7_eff2s_fp16.tflite", "bytes": 43853456},
    "name_lists": [{"kind": "class_list", "title": "Its 104 classes", "file": {"name": "insectdct-cls-v7_eff2s_fp16.fpack", "bytes": 13737}}]},
   {"id": "b2", "kind": "identification_model", "title": "BioCLIP 2", "purpose": "Any organism.",
    "file": {"name": "bioclip-2_image_fp16_4d.tflite", "bytes": 609466720},
    "name_lists": [{"kind": "label_pack", "title": "Europe", "file": {"name": "bioclip2_pollinator_orders_europe_v1.fpack", "bytes": 57479207}},
              {"kind": "label_pack", "title": "32 families", "file": {"name": "bioclip2_flower_visitors_32fam_v1.fpack", "bytes": 62754369}}]}
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
    // Known (round 276), by its first part, though not offered.
    ModelEntry(
      id: '/data/app/files/models/flatbug-s_1024_fp16.tflite',
      name: 'flatbug-s_1024_fp16.tflite',
      source: ModelSource.imported,
      inputSize: 1024,
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
final _linked = <String>[];

Future<void> _pump(
  WidgetTester tester, {
  ModelsInventory Function()? inventory,
  ModelFilesImporter? importFiles,
  List<ModelFileKind> onPhone = const [],
}) async {
  _downloaded.clear();
  _linked.clear();
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
        importFiles: importFiles ?? ({required replace, onFileLoading}) async => const ModelImportReport(),
        linkDownload: (url, {onProgress, isCancelled}) async {
          _linked.add(url);
          final name = ModelImport.linkFileName(url)!;
          return (name, name.endsWith('.fpack') ? ModelFileKind.nameList : ModelFileKind.detection);
        },
        onPhoneAs: (name) async => onPhone,
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

/// Opens the card of the file or download [title] (its ⓘ).
Future<void> _card(WidgetTester tester, String title, {String tooltip = 'About this file'}) async {
  await _show(tester, find.text(title));
  await tester.tap(find.descendant(of: _tile(title), matching: find.byTooltip(tooltip)));
  await tester.pumpAndSettle();
}

Finder _inCard(String text) => find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.text('Close'));
  await tester.pumpAndSettle();
}

const _mdv6 = 'MDV6-yolov10-c_int8_256.tflite';
const _clsName = 'insectdct-cls-v7_eff2s_fp16.tflite';
const _europeName = 'bioclip2_pollinator_orders_europe_v1.fpack';

void main() {
  testWidgets('every file is listed by its name; its details are in the card behind the ⓘ', (tester) async {
    await _pump(tester);
    expect(find.text('Download & import models'), findsOneWidget);
    expect(find.text('Storage free: 12.4 GB'), findsOneWidget);
    // Round 277 (owner): who made the models, and to cite the originals.
    expect(find.textContaining('made by other research teams'), findsOneWidget);
    expect(find.textContaining("keeps its creators' licence"), findsOneWidget);
    expect(find.text(_mdv6), findsOneWidget);
    expect(find.text('MegaDetector V6'), findsNothing, reason: 'no catalogue title for a file on the phone');
    expect(find.text('my_bees_640.tflite'), findsOneWidget);
    expect(find.textContaining('Finds:'), findsNothing, reason: 'details only in the card');
    await _card(tester, _mdv6);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('MegaDetector V6'), findsOneWidget);
    expect(find.text('Common animals.'), findsOneWidget);
    expect(find.text('256 px (each picture is resized to this for the model)'), findsOneWidget);
    expect(find.text('int8'), findsOneWidget);
    expect(find.text('AGPL-3.0'), findsOneWidget);
    // The source is a link: its authors say there how to cite the model (round 277).
    expect(find.widgetWithText(ExternalLinkText, 'https://github.com/microsoft/MegaDetector'), findsOneWidget);
    await _close(tester);
    await _card(tester, 'my_bees_640.tflite');
    expect(find.text('bee, hoverfly'), findsOneWidget);
    expect(find.text('On this phone, 6.0 MB'), findsOneWidget);
    expect(find.text('Model'), findsNothing, reason: 'the user\'s own file');
    expect(find.text("Not known: this file is not in the app's model list. Ask whoever made it."), findsOneWidget);
    await _close(tester);
    // A variant that is not offered finds its model by its first part (round 276).
    expect(find.text('flat-bug s (larger)'), findsNothing, reason: 'not offered for download');
    await _card(tester, 'flatbug-s_1024_fp16.tflite');
    expect(_inCard('flat-bug s (larger)'), findsOneWidget);
    expect(_inCard('MIT'), findsOneWidget);
    await _close(tester);
    await _card(tester, _clsName);
    expect(_inCard('insectdct-cls-v7_eff2s_fp16.fpack'), findsOneWidget, reason: 'its name lists');
    expect(find.text('On this phone, 42.0 MB'), findsOneWidget);
    await _close(tester);
    await _card(tester, 'insectdct-cls-v7_eff2s_fp16.fpack');
    expect(find.text('Class list of insectdct-cls-v7_eff2s_fp16: 104 classes'), findsOneWidget);
    expect(find.text('insectDCT classifier: Its 104 classes'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('only what is missing is offered, alphabetically; a name list brings its model along', (tester) async {
    await _pump(tester);
    // MegaDetector is on the phone, flat-bug is not; insectDCT is complete.
    expect(find.descendant(of: _tile(_mdv6), matching: find.text('Download')), findsNothing);
    await _show(tester, find.text('flat-bug (small)'));
    expect(find.descendant(of: _tile('flat-bug (small)'), matching: find.text('Download')), findsOneWidget);
    expect(find.descendant(of: _tile('flat-bug (small)'), matching: find.text('5.4 MB')), findsOneWidget);
    await _card(tester, 'flat-bug (small)', tooltip: 'About this model');
    expect(find.text('Insects and other arthropods.'), findsOneWidget);
    expect(find.text('flatbug-n_640_fp16.tflite, 5.4 MB'), findsOneWidget);
    await _close(tester);
    await _show(tester, find.text('Europe'));
    expect(find.text('54.8 MB plus the model'), findsOneWidget);
    await tester.tap(find.descendant(of: _tile('Europe'), matching: find.text('Download')));
    await tester.pumpAndSettle();
    expect(find.text('Download BioCLIP 2'), findsOneWidget);
    expect(find.textContaining('The model and the name list "Europe". In total 636.0 MB.'), findsOneWidget);
    expect(find.text('A large download: use Wi-Fi if you can.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Download').last);
    await tester.pumpAndSettle();
    expect(_downloaded, ['bioclip-2_image_fp16_4d.tflite', _europeName]);
    expect(find.text('Downloaded bioclip-2_image_fp16_4d.tflite and $_europeName.'), findsOneWidget);
    expect(_scans, 2);
  });

  testWidgets('download offers are in alphabetical order', (tester) async {
    await _pump(tester, inventory: () => ModelsInventory(downloads: _downloads));
    // The catalogue lists MegaDetector first.
    final flatbug = tester.getTopLeft(find.text('flat-bug (small)')).dy;
    expect(flatbug, lessThan(tester.getTopLeft(find.text('MegaDetector V6')).dy));
    await _show(tester, find.text('insectDCT classifier'));
    expect(
      tester.getTopLeft(find.text('BioCLIP 2')).dy,
      lessThan(tester.getTopLeft(find.text('insectDCT classifier')).dy),
    );
  });

  test('files are sorted by name, upper and lower case alike', () {
    final names = ['MDV6-yolov10-c_int8_256.tflite', 'insectdct-v8-s_640_fp16.tflite', 'arthropod_yolov11_float16.tflite'];
    expect(
      (names..sort((a, b) => fileNameOrder('/m/$a', '/m/$b'))),
      ['arthropod_yolov11_float16.tflite', 'insectdct-v8-s_640_fp16.tflite', 'MDV6-yolov10-c_int8_256.tflite'],
    );
  });

  testWidgets('with the BioCLIP model on the phone, a second list comes alone', (tester) async {
    final model = File('$_dir/models/bioclip-2_image_fp16_4d.tflite');
    final europe = File('$_dir/packs/$_europeName');
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
    await _card(tester, _europeName);
    expect(find.text('Label pack for bioclip-2: 35,264 names'), findsOneWidget);
    expect(find.text('BioCLIP 2: Europe'), findsOneWidget);
    await _close(tester);
    await _show(tester, find.text('32 families'));
    expect(find.textContaining("Model on this phone; name lists below"), findsOneWidget);
    await tester.tap(find.descendant(of: _tile('32 families'), matching: find.text('Download')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The name list "32 families". In total 59.8 MB.'), findsOneWidget);
  });

  testWidgets('deleting a classifier says its class list goes with it; Cancel keeps both', (tester) async {
    await _pump(tester);
    await _show(tester, find.text(_clsName));
    await tester.tap(find.descendant(of: _tile(_clsName), matching: find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete $_clsName?'), findsOneWidget);
    expect(find.textContaining('Its class list insectdct-cls-v7_eff2s_fp16.fpack is deleted with it.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text(_clsName), findsOneWidget);
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
    await _show(tester, find.text('bioclip-2_image_fp16_4d.tflite'));
    expect(find.text('⚠ No name list: this model cannot identify. Download or import one.'), findsOneWidget);
    await _show(tester, find.text('Name lists without their model'));
    expect(find.text('Their model is not on this phone, so they cannot be used yet.'), findsOneWidget);
    expect(find.text('bioclip25_pollinator_orders_europe_v1.fpack'), findsOneWidget);
  });

  testWidgets('deleting the only detection model, or a model\'s last name list, says what stops working (r271)', (tester) async {
    final europe = File('$_dir/packs/$_europeName');
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
    await tester.tap(find.descendant(of: _tile(_mdv6), matching: find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    expect(find.textContaining('It is the only detection model here.'), findsOneWidget);
    expect(find.textContaining('Time-lapse and motion capture still work.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _show(tester, find.text(_europeName));
    await tester.tap(find.descendant(of: _tile(_europeName), matching: find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('It is the only name list of bioclip-2_image_fp16_4d.tflite, which then cannot identify'),
      findsOneWidget,
    );
  });

  testWidgets('one import for every kind: asks before replacing a file, groups what came in (r275)', (tester) async {
    final answers = <bool>[];
    await _pump(
      tester,
      importFiles: ({required replace, onFileLoading}) async {
        answers.add(await replace('my_bees_640.tflite', ModelFileKind.detection, 0));
        return ModelImportReport(
          imported: const [
            ('insectdct-cls-v7_res_fp16.tflite', ModelFileKind.identification),
            ('flatbug-s_640_fp16.tflite', ModelFileKind.detection),
            ('insectdct-cls-v7_res_fp16.fpack', ModelFileKind.nameList),
            ('flatbug-s_1024_fp16.tflite', ModelFileKind.detection),
          ],
          kept: const ['my_bees_640.tflite'],
          rejected: const ['notes.tflite: not a model for pictures (its input is not a colour picture).'],
        );
      },
    );
    final import = find.text('Import model files…');
    await _show(tester, import);
    expect(find.textContaining('press and hold one file in the file chooser, then choose "Select all"'), findsOneWidget);
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(find.text('Already on this phone'), findsOneWidget);
    expect(
      find.text('my_bees_640.tflite is already on this phone (detection model). Replace it with the chosen file?'),
      findsOneWidget,
    );
    expect(find.byType(CheckboxListTile), findsNothing, reason: 'the last chosen file');
    await tester.tap(find.text('Keep the one on the phone'));
    await tester.pumpAndSettle();
    expect(answers, [false]);
    expect(find.text('Some files were not imported'), findsOneWidget);
    expect(find.text('2 detection models, listed under Detection models:'), findsOneWidget);
    expect(_inCard('flatbug-s_640_fp16.tflite'), findsOneWidget);
    expect(find.text('1 identification model, listed under Identification models:'), findsOneWidget);
    expect(find.text('1 name list, listed under their identification model:'), findsOneWidget);
    expect(find.text('Already on this phone, kept:'), findsOneWidget);
    expect(_inCard('my_bees_640.tflite'), findsOneWidget);
    expect(find.text('notes.tflite: not a model for pictures (its input is not a colour picture).'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(_scans, 2, reason: 'the list is read again');
  });

  testWidgets('one file: a message says what it is and where it is listed; one answer for many files (r275)', (tester) async {
    final answers = <bool>[];
    await _pump(
      tester,
      importFiles: ({required replace, onFileLoading}) async {
        // Three files already on the phone: the first answer covers the others.
        for (final (i, name) in ['a.tflite', 'b.tflite', 'c.tflite'].indexed) {
          answers.add(await replace(name, ModelFileKind.detection, 2 - i));
        }
        return const ModelImportReport(imported: [('bioclip-2_image_fp16_4d.tflite', ModelFileKind.identification)]);
      },
    );
    final import = find.text('Import model files…');
    await _show(tester, import);
    await tester.tap(import);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Same answer for the other chosen files already on the phone'));
    await tester.pump();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(answers, [true, true, true]);
    expect(find.text('Already on this phone'), findsNothing, reason: 'asked once');
    expect(
      find.text('Imported bioclip-2_image_fp16_4d.tflite: a identification model, listed under Identification models.'),
      findsNothing,
    );
    expect(
      find.text('Imported bioclip-2_image_fp16_4d.tflite: an identification model, listed under Identification models.'),
      findsOneWidget,
    );
  });

  testWidgets('a link to a name list; a file already on the phone is replaced only when asked to (r275)', (tester) async {
    await _pump(tester, onPhone: const [ModelFileKind.nameList]);
    final link = find.text('Download from a link…');
    await _show(tester, link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('Download from a link'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'https://example.org/r/$_europeName');
    await tester.pump();
    final download = find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Download'));
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(
      find.text('$_europeName is already on this phone (name list). Download it again and replace the one on the phone?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Keep the one on the phone'));
    await tester.pumpAndSettle();
    expect(_linked, isEmpty, reason: 'nothing downloaded');
    await tester.tap(download);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(_linked, ['https://example.org/r/$_europeName']);
    expect(find.text('Downloaded $_europeName (name list).'), findsOneWidget);
  });

  testWidgets('a file kept with the wrong kind is flagged (r275)', (tester) async {
    await _pump(
      tester,
      inventory: () {
        final base = _inventory();
        return ModelsInventory(
          detectors: base.detectors,
          idModels: base.idModels,
          nameLists: base.nameLists,
          headers: base.headers,
          downloads: _downloads,
          wrongKind: {base.detectors.last.id: ModelFileKind.identification},
        );
      },
    );
    expect(
      find.text(
        '⚠ This is an identification model, not a detection model. Delete it here and import it again: it '
        'then goes to its place.',
      ),
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

  test('round 276: a label pack belongs to every model file with the same first part', () {
    bool belongs(String list, Map<String, dynamic>? header, String model) =>
        IdentificationAssets.listBelongsTo(File('/p/$list'), header, File('/m/$model'));
    const b2 = {'model_id': 'bioclip-2'};
    const b25 = {'model_id': 'bioclip-2.5'};
    expect(belongs('bioclip-2_flower-visitors-32fam_v1.fpack', b2, 'bioclip-2_224_fp16.tflite'), isTrue);
    expect(belongs('bioclip-2_flower-visitors-32fam_v1.fpack', b2, 'bioclip-2_224_fp32.tflite'), isTrue);
    expect(belongs('bioclip-2.5_pollinator-orders-europe_v1.fpack', b25, 'bioclip-2.5_224_fp16.tflite'), isTrue);
    expect(belongs('bioclip-2.5_pollinator-orders-europe_v1.fpack', b25, 'bioclip-2_224_fp16.tflite'), isFalse);
    // A renamed pack still finds its model through its header.
    expect(belongs('my_list.fpack', b25, 'bioclip-2.5_224_fp16.tflite'), isTrue);
    expect(belongs('bioclip-2_x_v1.fpack', null, 'bioclip-2_224_fp16.tflite'), isFalse, reason: 'unreadable');
    // A class list goes with its classifier's exact name only.
    final cls = {'kind': 'classes', 'model_id': 'insectdct-cls-v7-eff2s_224_fp16'};
    expect(belongs('insectdct-cls-v7-eff2s_224_fp16.fpack', cls, 'insectdct-cls-v7-eff2s_224_fp16.tflite'), isTrue);
    expect(belongs('insectdct-cls-v7-eff2s_224_fp16.fpack', cls, 'insectdct-cls-v7-eff2s_224_fp32.tflite'), isFalse);
  });

  testWidgets('fits a 360-px screen and the last row stays above the system bar', (tester) async {
    simulateBottomSystemBar(tester);
    await _pump(tester);
    final last = find.text('Download from a link…');
    await _show(tester, last);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectAboveBottomInset(tester, last, label: 'last button');
    // The card of a long file name fits too (round 275).
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pumpAndSettle();
    await _card(tester, 'insectdct-cls-v7_eff2s_fp16.fpack');
    expect(tester.takeException(), isNull);
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
