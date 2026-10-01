// Round 274: the identification model and name list shared by "Identify
// organisms" and the Find screens' "Also identify them" (IdentificationChoice),
// and the automatic start of Identify organisms.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_choice.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_choice_fields.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Two BioCLIP lists, a classifier with its class list, and a model without
  // any list (file names as on the owner's phone).
  final bioclip = File('/x/models/bioclip-2_image_fp16_4d.tflite');
  final dct = File('/x/models/insectdct-eff2s_cls.tflite');
  final lonely = File('/x/models/lonely.tflite');
  final europe = File('/x/packs/europe_insects.fpack');
  final world = File('/x/packs/world_insects.fpack');
  final dctList = File('/x/packs/insectdct-eff2s_cls.fpack');
  final headers = <String, Map<String, dynamic>>{
    europe.path: {'model_id': 'bioclip-2', 'pack_id': 'europe'},
    world.path: {'model_id': 'bioclip-2', 'pack_id': 'world'},
    dctList.path: {'model_id': 'insectdct-eff2s_cls', 'kind': 'classes'},
  };
  IdentificationChoice choice({String? model, String? pack}) => IdentificationChoice.fromFiles(
    [bioclip, dct, lonely],
    [europe, world, dctList],
    headers,
    modelName: model,
    packName: pack,
  );

  test('the remembered model and name list are chosen when on the phone', () {
    final c = choice(model: 'bioclip-2_image_fp16_4d.tflite', pack: 'world_insects.fpack');
    expect(c.model, bioclip);
    expect(c.pack, world);
    expect(c.modelPacks, [europe, world]);
    expect(c.ready, isTrue);
    expect(c.isClassList, isFalse);
    // Not on the phone any more: the first model and its first list.
    final gone = choice(model: 'deleted.tflite', pack: 'deleted.fpack');
    expect(gone.model, bioclip);
    expect(gone.pack, europe);
  });

  test('a classifier takes its class list; a model without a list cannot identify', () {
    final c = choice(model: 'insectdct-eff2s_cls.tflite', pack: 'world_insects.fpack');
    expect(c.pack, dctList);
    expect(c.isClassList, isTrue);
    final none = choice(model: 'lonely.tflite');
    expect(none.modelPacks, isEmpty);
    expect(none.pack, isNull);
    expect(none.ready, isFalse);
    expect(none.anyUsable, isTrue, reason: 'other models have lists');
    expect(IdentificationChoice.fromFiles([lonely], [europe], headers).anyUsable, isFalse);
  });

  test('a model change picks a fitting list and keeps a fitting choice', () {
    final c = choice(model: 'bioclip-2_image_fp16_4d.tflite', pack: 'world_insects.fpack');
    c.selectModel(dct);
    expect(c.pack, dctList);
    c.selectModel(bioclip);
    expect(c.pack, europe, reason: 'the class list does not fit, so the first list');
    c.selectPack(world);
    c.selectModel(bioclip);
    expect(c.pack, world, reason: 'the chosen list still fits');
    c.selectModel(lonely);
    expect(c.pack, isNull);
  });

  test('the choice is remembered for Identify organisms and the switch', () async {
    SharedPreferences.setMockInitialValues({});
    await choice(model: 'insectdct-eff2s_cls.tflite').save();
    final p = await SharedPreferences.getInstance();
    expect(p.getString('identify_model'), 'insectdct-eff2s_cls.tflite');
    expect(p.getString('identify_pack'), 'insectdct-eff2s_cls.fpack');
    // The switch: on the first time when some model has a list, then as left.
    final (_, firstTime) = await AlsoIdentify.load(choice());
    expect(firstTime, isTrue);
    await AlsoIdentify.save(false);
    final (_, later) = await AlsoIdentify.load(choice());
    expect(later, isFalse);
    final (_, nothing) = await AlsoIdentify.load(IdentificationChoice());
    expect(nothing, isFalse, reason: 'saved off stays off');
  });

  group('Identify organisms, automatic start', () {
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('also_identify');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        (call) async => tmp.path,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
      tmp.deleteSync(recursive: true);
    });

    testWidgets('does not start without crops, and says why (360 px)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // A classifier with its class list (same file name), so a run could start.
      final models = Directory('${tmp.path}/identification/models')..createSync(recursive: true);
      final packs = Directory('${tmp.path}/identification/packs')..createSync(recursive: true);
      File('${models.path}/insectdct-eff2s_cls.tflite').writeAsBytesSync([0]);
      File('${packs.path}/insectdct-eff2s_cls.fpack').writeAsBytesSync([0]);
      final session = Directory('${tmp.path}/sessions/empty')..createSync(recursive: true);
      File('${session.path}/session.jsonl').writeAsStringSync(
        '{"type":"start_of_session","time_ms":1000,"config":{"captureTrigger":"timelapse"}}\n',
      );

      await tester.pumpWidget(MaterialApp(home: IdentificationScreen(sessionDir: session, autoStart: true)));
      final why = find.textContaining('No crops to identify');
      for (var i = 0; i < 250 && why.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(why, findsOneWidget);
      expect(find.text('Model (.tflite)'), findsOneWidget, reason: 'the shared fields');
      expect(find.text('Name list (.fpack)'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'not started');
      expect(tester.takeException(), isNull);
    });
  });
}
