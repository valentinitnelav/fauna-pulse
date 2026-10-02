// FaunaPulse (round 275): on-device check of the Download & import models
// screen with the phone's own model files.
//
// Nothing is added, replaced or deleted: the check only reads the model
// folders, and its import step answers "Keep the one on the phone".
// Run:  flutter test integration_test/models_screen_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in video_review_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.
//
// Steps:
//  - every model file on the phone is read with modelFileKind (the file's
//    tensor shapes): its kind and the time it took are logged, also for the
//    1.3 GB BioCLIP 2.5 file; a file kept with the wrong kind is reported;
//  - the screen with the real files: names only, alphabetical (SHOT); the
//    card of the first detection model (SHOT) and of the first
//    identification model (SHOT); "Your own models" (SHOT);
//  - the import of a copy of a detection model already on the phone: the
//    question comes, "Keep" leaves the file on the phone unchanged.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_kind.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_import.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the models screen with the phone\'s own files', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    // 1. Every file's kind, read from the file.
    final detectors = (await ModelCatalog.modelsDir()).listSync().whereType<File>().where(
      (f) => isSupportedModelFileName(f.path),
    );
    final idModels = await IdentificationAssets.listModels();
    final packs = await IdentificationAssets.listPacks();
    Future<void> kindOf(File f, String folder) async {
      final name = f.path.split('/').last;
      final watch = Stopwatch()..start();
      String what;
      try {
        what = (await modelFileKind(f, name)).label;
      } catch (e) {
        what = 'REFUSED $e';
      }
      final size = (await f.length()) / (1024 * 1024);
      _log('KIND $folder $name (${size.toStringAsFixed(1)} MB): $what in ${watch.elapsedMilliseconds} ms');
    }

    for (final f in detectors) {
      await kindOf(f, 'detection');
    }
    for (final f in idModels) {
      await kindOf(f, 'identification');
    }
    for (final f in packs) {
      await kindOf(f, 'lists');
    }
    final inv = await ModelsInventory.scan();
    _log('ORDER detection: ${inv.detectors.map((m) => m.name).join(', ')}');
    _log('ORDER identification: ${inv.idModels.map((f) => f.path.split('/').last).join(', ')}');
    _log('WRONG KIND: ${inv.wrongKind.isEmpty ? 'none' : inv.wrongKind}');

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

    // 2. The screen. The import step uses a copy of the first detection
    // model; the answer to the question is "Keep the one on the phone".
    final first = inv.detectors.first;
    final copy = File('${(await getTemporaryDirectory()).path}/${first.name}');
    await File(first.id).copy(copy.path);
    final before = await File(first.id).lastModified();
    ModelImportReport? report;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ModelsScreen(
          importFiles: ({required replace, onFileLoading}) async =>
              report = await ModelImport.importFiles([(first.name, copy.path)], replace: replace),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.text('Detection models').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle();
    await shot('models_top');

    Future<void> card(String name) async {
      final tile = find.ancestor(of: find.text(name), matching: find.byType(ListTile));
      await tester.scrollUntilVisible(find.text(name), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.descendant(of: tile, matching: find.byTooltip('About this file')));
      await settle();
    }

    Future<void> close() async {
      await tester.tap(find.text('Close'));
      await settle();
    }

    await card(first.name);
    await shot('models_card_detection');
    await close();
    if (inv.idModels.isNotEmpty) {
      await card(inv.idModels.first.path.split('/').last);
      await shot('models_card_identification');
      await close();
    }
    final import = find.text('Import model files…');
    await tester.scrollUntilVisible(import, 300, scrollable: find.byType(Scrollable).first);
    await settle();
    await shot('models_own');

    // 3. The import of a file already on the phone: the question, then Keep.
    await tester.tap(import);
    for (var i = 0; i < 50 && find.text('Already on this phone').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Already on this phone'), findsOneWidget);
    await shot('models_replace_question');
    await tester.tap(find.text('Keep the one on the phone'));
    await settle();
    expect(report?.kept, [first.name]);
    expect(await File(first.id).lastModified(), before, reason: 'the file on the phone is unchanged');
    _log('IMPORT kept ${report?.kept}, imported ${report?.imported}, refused ${report?.rejected}');
    await shot('models_after_keep');
    await copy.delete();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
