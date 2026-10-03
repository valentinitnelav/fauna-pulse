// FaunaPulse (round 279): on-device check of deleting models on Download &
// import models: "Delete all detection models…" (opened, then cancelled),
// pressing and holding to select several detection models and deleting them
// together, and an identification model deleted with its class list.
//
// It deletes only files the check's runner copied there beforehand: the
// phone's model folders must hold exactly the four files below (copied with
// adb into the app's own folders), and the check stops before deleting
// anything when it finds any other file. Afterwards the folders are empty
// again. Before deleting, the home screen is shown with these files on the
// phone: its step 1 reads the phone's saved choices back ("Set up for: …"
// when they name these files).
// Run:  flutter test integration_test/models_delete_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in models_screen_check_test.dart.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

const _detectors = {'flatbug-n_640_fp16.tflite', 'insectdct-v8-s_640_fp16.tflite'};
const _idModel = 'insectdct-cls-v7_eff2s_fp16.tflite';
const _classList = 'insectdct-cls-v7_eff2s_fp16.fpack';

Future<Set<String>> _names(Future<Directory> dir) async =>
    {for (final f in (await dir).listSync().whereType<File>()) f.path.split('/').last};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deleting several models on the phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    // Only the check's own files: nothing of the owner's can be deleted.
    expect(await _names(ModelCatalog.modelsDir()), _detectors);
    expect(await _names(IdentificationAssets.modelsDir()), {_idModel});
    expect(await _names(IdentificationAssets.packsDir()), {_classList});

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 4));
    }

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> waitFor(Finder f) async {
      for (var i = 0; i < 150 && f.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(f, findsWidgets);
    }

    Future<void> confirm() async {
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
      await settle();
      await tester.pump(const Duration(seconds: 2)); // the list is read again
      await settle();
    }

    // Home step 1 with these files on the phone.
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: const HomeScreen()));
    final step1 = find.textContaining(RegExp(r'^(On this phone|FaunaPulse needs|Set up for|Chosen AI models)'));
    await waitFor(step1);
    await settle();
    _log('HOME STEP 1 ${tester.widget<Text>(step1).data}');
    await shot('home_with_files');
    await tester.pumpWidget(const SizedBox());
    await settle();

    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: const ModelsScreen()));
    await waitFor(find.text('flatbug-n_640_fp16.tflite'));
    await settle();
    await shot('del_start');

    // "Delete all detection models…": the question, then Cancel.
    await tester.dragUntilVisible(find.text('Delete all detection models…'), find.byType(ListView), const Offset(0, -150));
    await settle();
    await shot('del_all_button');
    await tester.tap(find.text('Delete all detection models…'));
    await settle();
    await shot('del_all_dialog');
    await tester.tap(find.text('Cancel'));
    await settle();
    expect(await _names(ModelCatalog.modelsDir()), _detectors, reason: 'Cancel keeps them');

    // Press and hold one, tap the other, delete both (back at the top first).
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await settle();
    await tester.longPress(find.text('flatbug-n_640_fp16.tflite'));
    await settle();
    await tester.tap(find.text('insectdct-v8-s_640_fp16.tflite'));
    await settle();
    expect(find.text('2 selected'), findsOneWidget);
    await shot('del_selecting');
    await tester.tap(find.byTooltip('Delete the selected files'));
    await settle();
    await shot('del_selected_dialog');
    await confirm();
    final left = await _names(ModelCatalog.modelsDir());
    _log('DETECTORS LEFT ${left.isEmpty ? 'none' : left.join(', ')}');
    expect(left, isEmpty);
    await shot('del_after_detectors');

    // The classifier: its class list goes with it.
    await tester.dragUntilVisible(find.text(_idModel), find.byType(ListView), const Offset(0, -150));
    await settle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: find.text(_idModel), matching: find.byType(ListTile)),
        matching: find.byTooltip('Delete'),
      ),
    );
    await settle();
    expect(find.textContaining('Its class list $_classList is deleted with it.'), findsOneWidget);
    await shot('del_classifier_dialog');
    await confirm();
    final idLeft = {...await _names(IdentificationAssets.modelsDir()), ...await _names(IdentificationAssets.packsDir())};
    _log('IDENTIFICATION LEFT ${idLeft.isEmpty ? 'none' : idLeft.join(', ')}');
    expect(idLeft, isEmpty);
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await settle();
    await shot('del_after_all');
  });
}
