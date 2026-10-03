// Rounds 278-279: the page behind an answer to "What do you want to watch?":
// a drawing of the setup, the models chosen for the user from the list file
// (`uses`), shown by their file names, with one button that downloads what is
// missing and saves the choice (no tick box since round 279), and the other
// suggestions in a closed fold "Choose other models". Round 280: "Not now"
// says what it means and clears Identify's choice; each answer has the phone
// screen of its drawing alone (home step 2). Round 281: the fold also lists
// the other models on the phone (one's own detector, for example). Round
// 284: the box is "Suggested AI models"; BioCLIP 2 with the European list
// names pollinators; the answer used last opens with the models in use.
// Round 286: the button returns the choice; readyChoice says what a tap on an
// answer switches to; each answer remembers its own models. Round 287: the
// fold's two parts in their own colours, radio buttons beside the file names.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_storage.dart' show formatBytes;
import 'package:fauna_pulse/fauna_pulse/models/model_choice_keys.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/models_on_phone.dart';
import 'package:fauna_pulse/fauna_pulse/screens/watch_plan_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/watch_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _downloads = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
WatchUse _use(String id) => _downloads.uses.firstWhere((u) => u.id == id);

class _Calls {
  final downloaded = <(String, bool)>[];
  final saved = <(String?, String?, String?)>[];
  Object? failWith;

  /// What the page returned.
  ModelChoice? popped;
}

Future<void> _pump(
  WidgetTester tester,
  WatchUse use,
  ModelFilesOnPhone onPhone,
  _Calls calls, {
  ModelChoice? inUse,
}) async {
  tester.view.physicalSize = const Size(360, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => calls.popped = await Navigator.of(context).push<ModelChoice>(
                MaterialPageRoute(
                  builder: (_) => WatchPlanScreen(
                    use: use,
                    onPhone: () async => onPhone,
                    download: (f, identification, onProgress, isCancelled) async {
                      if (calls.failWith != null) throw calls.failWith!;
                      calls.downloaded.add((f.name, identification));
                    },
                    saveChoice: ({detector, idModel, nameList}) async => calls.saved.add((detector, idModel, nameList)),
                    inUse: inUse == null ? null : (_) async => inUse,
                  ),
                ),
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
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder _inDialog(String text) => find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the shipped list has the three answers, each with offered models and a drawing', () {
    expect(_downloads.uses.map((u) => u.id), ['pollinators', 'flat_surface', 'mammals_birds']);
    expect(_use('pollinators').find.map((d) => d.id), ['insectdct-v8s', 'flatbug-n']);
    expect(_use('pollinators').name.map((n) => n.$1.id), ['bioclip-2', 'insectdct-cls-v7-eff2s', 'bioclip-2']);
    expect(_use('pollinators').name.first.$2.file.name, 'bioclip2_pollinator_orders_europe_v1.fpack');
    expect(_use('flat_surface').name.first.$2.file.name, 'bioclip2_pollinator_orders_europe_v1.fpack');
    for (final u in _downloads.uses) {
      expect(u.name.first.$1.id, 'bioclip-2', reason: '${u.id}: BioCLIP 2 is suggested for naming');
    }
    expect(_use('flat_surface').find.first.id, 'flatbug-n');
    final (model, list) = _use('mammals_birds').name.single;
    expect(model.id, 'bioclip-2');
    expect(list.file.name, 'bioclip-2_mammals-birds-world_v1.fpack');
    expect(list.file.bytes, greaterThan(0));
    expect(list.file.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    for (final u in _downloads.uses) {
      expect(u.setup, contains('yellow square'), reason: u.id);
      expect(File('assets/images/setup_${u.icon}.png').existsSync(), isTrue, reason: u.icon);
      expect(File(roiPicture(u.icon)).existsSync(), isTrue, reason: u.icon);
    }
  });

  testWidgets('pollinators: the suggested models by file name, one download, the choice saved', (tester) async {
    final calls = _Calls();
    await _pump(tester, _use('pollinators'), const ModelFilesOnPhone(detectors: {'insectdct-v8-s_640_fp16.tflite'}), calls);
    expect(find.byType(SetupPicture), findsOneWidget);
    expect(find.text('Suggested AI models'), findsOneWidget);
    expect(find.text('Back to the suggested models'), findsNothing);
    expect(find.text('insectdct-v8-s_640_fp16.tflite'), findsOneWidget);
    expect(find.text('bioclip-2_image_fp16_4d.tflite'), findsOneWidget);
    expect(find.text('with bioclip2_pollinator_orders_europe_v1.fpack'), findsOneWidget);
    expect(find.text('flatbug-n_640_fp16.tflite'), findsNothing, reason: 'the other models wait in the fold');
    expect(find.text('Choose other models'), findsOneWidget);
    expect(find.text('Use them from now on'), findsNothing, reason: 'choosing is using');
    expect(tester.takeException(), isNull, reason: 'nothing overflows at 360 px');
    final bioclip = _use('pollinators').name.first;
    final button = 'Download and use (${formatBytes(bioclip.$1.file!.bytes + bioclip.$2.file.bytes)})';
    expect(find.text('The rest is on this phone. A large download: use Wi-Fi.'), findsOneWidget);
    await _tap(tester, find.text(button));
    expect(
      find.textContaining(
        'bioclip-2_image_fp16_4d.tflite, bioclip2_pollinator_orders_europe_v1.fpack (the other chosen files are on this phone).',
      ),
      findsOneWidget,
    );
    await _tap(tester, _inDialog('Download'));
    expect(calls.downloaded, [('bioclip-2_image_fp16_4d.tflite', true), ('bioclip2_pollinator_orders_europe_v1.fpack', true)]);
    expect(calls.saved, [
      ('insectdct-v8-s_640_fp16.tflite', 'bioclip-2_image_fp16_4d.tflite', 'bioclip2_pollinator_orders_europe_v1.fpack'),
    ]);
    expect(find.byType(WatchPlanScreen), findsNothing, reason: 'back on the home screen');
  });

  testWidgets('another detector and no naming, from the fold: "Your choice", downloaded and saved', (tester) async {
    final calls = _Calls();
    await _pump(tester, _use('pollinators'), const ModelFilesOnPhone(), calls);
    await _tap(tester, find.text('Choose other models'));
    expect(find.text('Flies, bees and wasps, beetles, butterflies and moths of Europe (35,264 names)'), findsOneWidget);
    expect(find.text('with bioclip2_pollinator_orders_europe_v1.fpack'), findsNWidgets(2), reason: 'box and fold');
    expect(tester.takeException(), isNull, reason: 'the open fold fits 360 px');
    await _tap(tester, find.text('flatbug-n_640_fp16.tflite'));
    await _tap(tester, find.text('Not now'));
    await tester.drag(find.byType(ListView), const Offset(0, 3000)); // back to the box at the top
    await tester.pumpAndSettle();
    expect(find.text('Your choice'), findsOneWidget);
    expect(find.text('Download and use (${formatBytes(_use('pollinators').find[1].file!.bytes)})').hitTestable(), findsOneWidget,
        reason: 'the button stays in view below the open fold');
    expect(find.text('None (animals are found and counted, not named)'), findsOneWidget, reason: 'in the box');
    expect(find.text('Not now'), findsOneWidget, reason: 'in the fold');
    final flatbug = _use('pollinators').find[1].file!;
    await _tap(tester, find.text('Download and use (${formatBytes(flatbug.bytes)})'));
    await _tap(tester, _inDialog('Download'));
    expect(calls.downloaded, [(flatbug.name, false)]);
    expect(calls.saved, [(flatbug.name, null, null)]);
  });

  testWidgets('everything on the phone: "Use these" saves at once', (tester) async {
    final calls = _Calls();
    final use = _use('mammals_birds');
    final (model, list) = use.name.single;
    await _pump(
      tester,
      use,
      ModelFilesOnPhone(detectors: {use.find.single.file!.name}, idModels: {model.file!.name}, nameLists: {list.file.name}),
      calls,
    );
    expect(find.text('On this phone'), findsOneWidget);
    await _tap(tester, find.text('Use these'));
    expect(calls.downloaded, isEmpty);
    expect(calls.saved, [(use.find.single.file!.name, model.file!.name, list.file.name)]);
    expect(calls.popped, (detector: use.find.single.file!.name, idModel: model.file!.name, nameList: list.file.name));
  });

  testWidgets('mammals and birds: the new name list and a large download', (tester) async {
    await _pump(tester, _use('mammals_birds'), const ModelFilesOnPhone(), _Calls());
    expect(find.text('MDV6-yolov10-c_int8_256.tflite'), findsOneWidget);
    expect(find.text('bioclip-2_image_fp16_4d.tflite'), findsOneWidget);
    expect(find.text('with bioclip-2_mammals-birds-world_v1.fpack'), findsOneWidget);
    expect(find.text('A large download: use Wi-Fi.'), findsOneWidget, reason: 'BioCLIP 2 is over 600 MB');
  });

  testWidgets('a file not online yet: the plain message, nothing saved', (tester) async {
    final calls = _Calls()
      ..failWith = Exception(
        'Nothing was found at this link (HTTP 404). The file may not be online yet: please try again later.',
      );
    await _pump(tester, _use('mammals_birds'), const ModelFilesOnPhone(), calls);
    await _tap(tester, find.textContaining('Download and use ('));
    await _tap(tester, _inDialog('Download'));
    expect(find.textContaining('The file may not be online yet'), findsOneWidget);
    expect(calls.saved, isEmpty);
  });

  testWidgets('models already on the phone can be chosen too, without a download', (tester) async {
    final calls = _Calls();
    await _pump(
      tester,
      _use('pollinators'),
      const ModelFilesOnPhone(
        detectors: {'insectdct-v8-s_640_fp16.tflite', 'my_bees_640_fp16.tflite', 'MDV6-yolov10-c_int8_256.tflite'},
        idModels: {'my_moths_224_fp16.tflite', 'bioclip-2_image_fp16_4d.tflite'},
        nameLists: {'my_moths_224_fp16.fpack', 'bioclip-2_mammals-birds-world_v1.fpack'},
      ),
      calls,
    );
    expect(find.text('my_bees_640_fp16.tflite'), findsNothing, reason: 'in the closed fold');
    await _tap(tester, find.text('Choose other models'));
    expect(find.text('Other models on this phone'), findsNWidgets(2), reason: 'detection and identification');
    expect(find.text('MDV6-yolov10-c_int8_256.tflite'), findsOneWidget, reason: 'suggested for another answer');
    expect(find.text('with bioclip-2_mammals-birds-world_v1.fpack'), findsOneWidget);
    expect(find.text('insectdct-v8-s_640_fp16.tflite'), findsNWidgets(2), reason: 'box and suggestion, not again');
    expect(tester.takeException(), isNull, reason: 'the longer fold fits 360 px');
    await _tap(tester, find.text('my_bees_640_fp16.tflite'));
    await _tap(tester, find.text('my_moths_224_fp16.tflite'));
    await tester.drag(find.byType(ListView), const Offset(0, 3000)); // back to the box at the top
    await tester.pumpAndSettle();
    expect(find.text('Your choice'), findsOneWidget);
    expect(find.text('my_bees_640_fp16.tflite'), findsNWidgets(2), reason: 'in the box and in the fold');
    expect(find.textContaining('with my_moths'), findsNothing, reason: 'a class list has its model\'s name');
    await _tap(tester, find.text('Use these'));
    expect(calls.downloaded, isEmpty);
    expect(calls.saved, [('my_bees_640_fp16.tflite', 'my_moths_224_fp16.tflite', 'my_moths_224_fp16.fpack')]);
  });

  testWidgets('the fold: its two parts in their own colours, each radio button beside its file name', (tester) async {
    await _pump(
      tester,
      _use('flat_surface'),
      const ModelFilesOnPhone(
        detectors: {'insectdct-v8-s_640_fp16.tflite', 'my_bees_640_fp16.tflite'},
        idModels: {'my_moths_224_fp16.tflite'},
        nameLists: {'my_moths_224_fp16.fpack'},
      ),
      _Calls(),
    );
    await _tap(tester, find.text('Choose other models'));
    // .last: the fold comes after the box, which has the same words.
    Color fillOf(String text) =>
        tester.widget<Material>(find.ancestor(of: find.text(text).last, matching: find.byType(Material)).first).color!;
    expect(fillOf('To find the animals'), isNot(fillOf('To name them')));
    expect(fillOf('my_bees_640_fp16.tflite'), fillOf('To find the animals'), reason: 'other models in their part');
    expect(fillOf('my_moths_224_fp16.tflite'), fillOf('To name them'));
    // A model without details (one's own, where the button sat lower), one
    // with three lines under it (the button sat in their middle), "Not now".
    for (final name in ['my_bees_640_fp16.tflite', 'flatbug-n_640_fp16.tflite', 'Not now']) {
      final title = find.text(name).last;
      final radio = find.descendant(
        of: find.ancestor(of: title, matching: find.byType(Row)).first,
        matching: find.byType(Icon),
      );
      expect(tester.getCenter(radio).dy, moreOrLessEquals(tester.getCenter(title).dy, epsilon: 0.5), reason: name);
    }
    expect(tester.takeException(), isNull, reason: 'the panels fit 360 px');
  });

  testWidgets('the answer used last opens with the models in use, and goes back to the suggestions', (tester) async {
    final calls = _Calls();
    await _pump(
      tester,
      _use('pollinators'),
      const ModelFilesOnPhone(
        detectors: {'insectdct-v8-s_640_fp16.tflite', 'my_bees_640_fp16.tflite'},
        idModels: {'insectdct-cls-v7_eff2s_fp16.tflite'},
        nameLists: {'insectdct-cls-v7_eff2s_fp16.fpack'},
      ),
      calls,
      inUse: (
        detector: 'my_bees_640_fp16.tflite',
        idModel: 'insectdct-cls-v7_eff2s_fp16.tflite',
        nameList: 'insectdct-cls-v7_eff2s_fp16.fpack',
      ),
    );
    expect(find.text('Your choice'), findsOneWidget);
    expect(find.text('my_bees_640_fp16.tflite'), findsOneWidget, reason: 'in the box (the fold is closed)');
    expect(find.text('insectdct-cls-v7_eff2s_fp16.tflite'), findsOneWidget);
    expect(find.text('On this phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, find.text('Back to the suggested models'));
    expect(find.text('Suggested AI models'), findsOneWidget);
    expect(find.text('Back to the suggested models'), findsNothing);
    expect(find.text('bioclip-2_image_fp16_4d.tflite'), findsOneWidget);
    expect(calls.saved, isEmpty, reason: 'nothing saved before the button');
  });

  testWidgets('models in use: no detector keeps the suggested one; no naming shows None', (tester) async {
    final calls = _Calls();
    await _pump(
      tester,
      _use('pollinators'),
      const ModelFilesOnPhone(detectors: {'insectdct-v8-s_640_fp16.tflite'}),
      calls,
      inUse: (detector: null, idModel: null, nameList: null),
    );
    expect(find.text('Your choice'), findsOneWidget);
    expect(find.text('insectdct-v8-s_640_fp16.tflite'), findsOneWidget);
    expect(find.text('None (animals are found and counted, not named)'), findsOneWidget);
    await _tap(tester, find.text('Use these'));
    expect(calls.saved, [('insectdct-v8-s_640_fp16.tflite', null, null)]);
  });

  test('readyChoice: the models used last if on the phone, else suggestions that are on the phone', () {
    final use = _use('flat_surface');
    const flatbug = 'flatbug-n_640_fp16.tflite', insectdct = 'insectdct-v8-s_640_fp16.tflite';
    const classifier = ('insectdct-cls-v7_eff2s_fp16.tflite', 'insectdct-cls-v7_eff2s_fp16.fpack');
    const bioclip = ('bioclip-2_image_fp16_4d.tflite', 'bioclip2_pollinator_orders_europe_v1.fpack');
    ModelFilesOnPhone files(Set<String> detectors, List<(String, String)> namings) => ModelFilesOnPhone(
      detectors: detectors,
      idModels: {for (final n in namings) n.$1},
      nameLists: {for (final n in namings) n.$2},
    );
    expect(readyChoice(use, null, files({flatbug, insectdct}, [classifier, bioclip])),
        (detector: flatbug, idModel: bioclip.$1, nameList: bioclip.$2), reason: 'the first suggestions');
    expect(readyChoice(use, null, files({insectdct, 'my_bees_640_fp16.tflite'}, [classifier])),
        (detector: insectdct, idModel: classifier.$1, nameList: classifier.$2), reason: 'the first ones on the phone');
    expect(readyChoice(use, null, files({flatbug}, const [])), isNull, reason: 'no suggested naming on the phone');
    expect(readyChoice(use, null, files({'my_bees_640_fp16.tflite'}, [classifier])), isNull, reason: 'no suggested detector');
    const mine = (detector: 'my_bees_640_fp16.tflite', idModel: null, nameList: null);
    expect(readyChoice(use, mine, files({'my_bees_640_fp16.tflite'}, const [])), mine,
        reason: 'the models used last for this answer, no naming');
    expect(readyChoice(use, mine, files({flatbug}, [bioclip])), isNull,
        reason: 'its own detector was deleted: the page shows what to do, no silent change to the suggestions');
  });

  test('each answer remembers its own models', () async {
    await rememberWatchChoice('pollinators', (detector: 'a.tflite', idModel: 'b.tflite', nameList: 'b.fpack'));
    await rememberWatchChoice('mammals_birds', (detector: 'c.tflite', idModel: null, nameList: null));
    expect(await watchChoices(['pollinators', 'flat_surface', 'mammals_birds']), {
      'pollinators': (detector: 'a.tflite', idModel: 'b.tflite', nameList: 'b.fpack'),
      'mammals_birds': (detector: 'c.tflite', idModel: null, nameList: null),
    });
  });

  test('namingPairs: a class list only with its own model, a label pack with each model of its name', () {
    expect(
      namingPairs(
        ['insectdct-cls-v7_eff2s_fp16.tflite', 'insectdct-cls-v7_eff2m_fp16.tflite', 'bioclip-2_image_fp16_4d.tflite', 'bioclip-2_224_fp16.tflite'],
        ['insectdct-cls-v7_eff2s_fp16.fpack', 'bioclip2_pollinator_orders_europe_v1.fpack'],
      ),
      [
        ('bioclip-2_224_fp16.tflite', 'bioclip2_pollinator_orders_europe_v1.fpack'),
        ('bioclip-2_image_fp16_4d.tflite', 'bioclip2_pollinator_orders_europe_v1.fpack'),
        ('insectdct-cls-v7_eff2s_fp16.tflite', 'insectdct-cls-v7_eff2s_fp16.fpack'),
      ],
    );
  });

  test('useModels: the Identify choice is saved under the keys Identify reads', () async {
    await useModels(idModel: 'bioclip-2_image_fp16_4d.tflite', nameList: 'bioclip-2_mammals-birds-world_v1.fpack');
    final p = await SharedPreferences.getInstance();
    expect(p.getString(kIdentifyModelPref), 'bioclip-2_image_fp16_4d.tflite');
    expect(p.getString(kIdentifyPackPref), 'bioclip-2_mammals-birds-world_v1.fpack');
    expect(p.getString(kAnalysisModelPref), isNull, reason: 'no detection model given');
  });

  test('"Not now" clears Identify\'s choice; a model with its list sets it', () async {
    SharedPreferences.setMockInitialValues({kIdentifyModelPref: 'old.tflite', kIdentifyPackPref: 'old.fpack'});
    await saveNamingChoice(null, null);
    final p = await SharedPreferences.getInstance();
    expect((p.getString(kIdentifyModelPref), p.getString(kIdentifyPackPref)), (null, null));
    await saveNamingChoice('insectdct-cls-v7_eff2s_fp16.tflite', 'insectdct-cls-v7_eff2s_fp16.fpack');
    expect(p.getString(kIdentifyModelPref), 'insectdct-cls-v7_eff2s_fp16.tflite');
  });

  test('currentModelChoice: the saved files, each only while it is on the phone', () async {
    SharedPreferences.setMockInitialValues({
      kIdentifyModelPref: 'bioclip-2_image_fp16_4d.tflite',
      kIdentifyPackPref: 'bioclip-2_mammals-birds-world_v1.fpack',
    });
    var c = await currentModelChoice({'bioclip-2_image_fp16_4d.tflite', 'bioclip-2_mammals-birds-world_v1.fpack'});
    expect(c.detector, isNull, reason: 'no camera model saved');
    expect(c.idModel, 'bioclip-2_image_fp16_4d.tflite');
    expect(c.nameList, 'bioclip-2_mammals-birds-world_v1.fpack');
    c = await currentModelChoice({'bioclip-2_image_fp16_4d.tflite'});
    expect((c.idModel, c.nameList), (null, null), reason: 'the list was deleted');
  });
}
