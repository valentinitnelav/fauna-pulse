// Round 319 part 3 (A7, phone check P2R S2b): after "Import model files…" the
// screen lists the new file (and, for an identification model, the name lists
// under it) above the button. The list grew by about 390 pixels just as the
// import ended, and pushed the line under the button ("Imported …") off the
// screen. The screen now keeps that line in view when it appears or changes.

import 'dart:async';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_import.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';
import 'package:file_picker/file_picker.dart' show FilePickerStatus;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _mb = 1024 * 1024;
const _name = 'my_bees_640.tflite';

ModelEntry _detector(int i) => ModelEntry(
  id: '/data/app/files/models/bees_$i.tflite',
  name: 'bees_$i.tflite',
  source: ModelSource.imported,
  inputSize: 640,
  task: 'detect',
);

void main() {
  /// The screen scrolled to "Import model files…" at the bottom of a phone screen; [after] is the
  /// list once the import has added its file.
  Future<void> pump(WidgetTester tester, ModelFilesImporter importFiles, ModelsInventory after) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    var scans = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ModelsScreen(
          scan: () async => scans++ == 0 ? ModelsInventory(detectors: [for (var i = 0; i < 3; i++) _detector(i)]) : after,
          importFiles: importFiles,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Download from a link…'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  void expectOnScreen(WidgetTester tester, Finder f) {
    expect(f, findsOneWidget);
    expect(f.hitTestable(), findsOneWidget, reason: 'on the screen');
    final r = tester.getRect(f);
    expect(r.top, greaterThan(0), reason: 'below the top of the screen: $r');
    expect(r.bottom, lessThanOrEqualTo(800), reason: 'above the bottom of the screen: $r');
  }

  testWidgets('the list grows above when the import ends: "Imported …" stays on the screen', (tester) async {
    await pump(
      tester,
      ({required replace, onFileLoading, onProgress}) async => const ModelImportReport(imported: [(_name, ModelFileKind.detection)]),
      // Six identification models more above the button.
      ModelsInventory(
        detectors: [for (var i = 0; i < 3; i++) _detector(i)],
        idModels: [for (var i = 0; i < 6; i++) File('/data/app/files/identification/models/my_model_$i.tflite')],
      ),
    );
    await tester.tap(find.text('Import model files…'));
    await tester.pumpAndSettle();
    expectOnScreen(tester, find.text('Imported $_name: a detection model, listed under Detection models.'));
  });

  testWidgets('the copy line appears below the screen: brought into view', (tester) async {
    final done = Completer<void>();
    await pump(
      tester,
      ({required replace, onFileLoading, onProgress}) async {
        onFileLoading?.call(FilePickerStatus.picking);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        onProgress?.call((name: _name, index: 0, count: 1, copiedBytes: 290 * _mb, totalBytes: 1160 * _mb));
        await done.future;
        return const ModelImportReport();
      },
      const ModelsInventory(),
    );
    // The user looks a little further up while the file chooser copies the file.
    await tester.tap(find.text('Import model files…'));
    await tester.pump();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 250));
    await tester.pumpAndSettle();
    expect(find.text('Copying into the app…').hitTestable(), findsNothing);
    // Our copy starts: its line comes into view once.
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();
    expectOnScreen(tester, find.text('Copying $_name into the app…'));
    expectOnScreen(tester, find.text('0.3 GB of 1.1 GB'));
    done.complete();
    await tester.pumpAndSettle();
  });
}
