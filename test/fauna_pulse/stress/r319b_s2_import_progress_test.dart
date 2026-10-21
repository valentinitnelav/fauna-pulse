// Round 319 part 2 (S2b): "Import model files…" of a 1.2 GB model took 26 s
// on the phone (PA3 step d) and showed no progress and no result where the
// user was: the line "Copying into the app…" was at the top of the screen,
// far above the button, and the result was a snack bar that vanished after a
// few seconds. Now the import reports how far it is ("Importing {name}…",
// a bar, copied of total), under the button, and the result line stays.

import 'dart:async';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/model_file_security.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_import.dart';
import 'package:fauna_pulse/fauna_pulse/screens/models_screen.dart';
import 'package:file_picker/file_picker.dart' show FilePickerStatus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../model_file_kind_test.dart' show fakeTflite;

const _mb = 1024 * 1024;
const _name = 'bioclip-2_224_fp32.tflite';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('r319b S2b: the import reports its progress', () {
    late Directory tmp;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('r319b_s2_import_progress');
      messenger.setMockMethodCallHandler(pathChannel, (call) async => '${tmp.path}/app');
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(pathChannel, null);
      tmp.deleteSync(recursive: true);
    });

    test('copyAndValidateModel: from 0 to the file size', () async {
      final source = File('${tmp.path}/a.tflite')..writeAsBytesSync(fakeTflite([[1, 640, 640, 3]], [[1, 5, 8400]]));
      // Larger than one read chunk, so there are several steps.
      source.writeAsBytesSync(List.filled(300 * 1024, 0), mode: FileMode.append);
      final target = File('${tmp.path}/out/a.tflite')..parent.createSync();
      final steps = <int>[];
      await copyAndValidateModel(source, target, 'a.tflite', onProgress: (copied, total) {
        expect(total, source.lengthSync());
        steps.add(copied);
      });
      expect(steps.first, 0);
      expect(steps.last, source.lengthSync());
      expect(steps.length, greaterThan(2));
      expect(target.lengthSync(), source.lengthSync());
    });

    test('importFiles: which file of how many, and its bytes', () async {
      final detector = fakeTflite([[1, 640, 640, 3]], [[1, 5, 8400]]);
      final classifier = fakeTflite([[1, 3, 224, 224]], [[1, 164]]);
      final picked = Directory('${tmp.path}/picked')..createSync();
      File('${picked.path}/my_bees_640.tflite').writeAsBytesSync(detector);
      File('${picked.path}/insectdct-cls-v7_eff2s_fp16.tflite').writeAsBytesSync(classifier);
      final seen = <ModelImportProgress>[];
      final r = await ModelImport.importFiles(
        [
          ('my_bees_640.tflite', '${picked.path}/my_bees_640.tflite'),
          ('insectdct-cls-v7_eff2s_fp16.tflite', '${picked.path}/insectdct-cls-v7_eff2s_fp16.tflite'),
        ],
        replace: (_, _, _) async => true,
        onProgress: seen.add,
      );
      expect(r.imported, hasLength(2));
      expect(seen.first, (name: 'my_bees_640.tflite', index: 0, count: 2, copiedBytes: 0, totalBytes: detector.length));
      expect(seen.last, (
        name: 'insectdct-cls-v7_eff2s_fp16.tflite',
        index: 1,
        count: 2,
        copiedBytes: classifier.length,
        totalBytes: classifier.length,
      ));
    });
  });

  group('r319b S2b: Download & import models shows the import', () {
    Future<void> pump(WidgetTester tester, ModelFilesImporter importFiles) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: ModelsScreen(scan: () async => const ModelsInventory(), importFiles: importFiles),
        ),
      );
      await tester.pumpAndSettle();
      final import = find.text('Import model files…');
      await tester.dragUntilVisible(import, find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
    }

    /// [f] is on the screen, below the "Import model files…" button.
    void expectUnderButton(WidgetTester tester, Finder f) {
      expect(f, findsOneWidget);
      final button = tester.getRect(find.text('Import model files…'));
      final r = tester.getRect(f);
      expect(r.top, greaterThan(button.bottom), reason: 'next to the button the user pressed');
      expect(r.bottom, lessThan(800), reason: 'on the screen');
    }

    testWidgets('one large file: the copy and the result, under the button', (tester) async {
      final done = Completer<void>();
      await pump(tester, ({required replace, onFileLoading, onProgress}) async {
        onFileLoading?.call(FilePickerStatus.picking);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        onProgress?.call((name: _name, index: 0, count: 1, copiedBytes: 0, totalBytes: 1160 * _mb));
        onProgress?.call((name: _name, index: 0, count: 1, copiedBytes: 290 * _mb, totalBytes: 1160 * _mb));
        await done.future;
        return const ModelImportReport(imported: [(_name, ModelFileKind.identification)]);
      });
      await tester.tap(find.text('Import model files…'));
      await tester.pump();
      expectUnderButton(tester, find.text('Copying into the app…'));
      await tester.pump(const Duration(milliseconds: 20));
      expectUnderButton(tester, find.text('Copying $_name into the app…'));
      expectUnderButton(tester, find.text('0.3 GB of 1.1 GB'));
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(0.25, 0.001));
      done.complete();
      await tester.pumpAndSettle();
      // Long after a snack bar would be gone.
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expectUnderButton(
        tester,
        find.text('Imported $_name: an identification model, listed under Identification models.'),
      );
      expect(find.textContaining('Importing'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('several files: which one is copied', (tester) async {
      final done = Completer<void>();
      await pump(tester, ({required replace, onFileLoading, onProgress}) async {
        onProgress?.call((name: 'b.tflite', index: 1, count: 3, copiedBytes: 13737, totalBytes: 41 * _mb));
        await done.future;
        return const ModelImportReport();
      });
      await tester.tap(find.text('Import model files…'));
      await tester.pump();
      expectUnderButton(tester, find.text('Copying b.tflite into the app (file 2 of 3)…'));
      expectUnderButton(tester, find.text('0.0 MB of 41.0 MB'));
      done.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Importing'), findsNothing);
    });

    testWidgets('a failed import: the plain reason in the window, the screen is usable again', (tester) async {
      await pump(tester, ({required replace, onFileLoading, onProgress}) async {
        onProgress?.call((name: _name, index: 0, count: 1, copiedBytes: 0, totalBytes: 1160 * _mb));
        return const ModelImportReport(
          rejected: [
            '$_name: Not enough free storage: the import stopped. Delete some files (for example old sessions), '
                'then try again.',
          ],
        );
      });
      await tester.tap(find.text('Import model files…'));
      await tester.pumpAndSettle();
      expect(find.text('Not imported'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.ancestor(of: find.text('Import model files…'), matching: find.byWidgetPredicate((w) => w is FilledButton)),
      );
      expect(button.onPressed, isNotNull);
      expect(find.textContaining('Importing'), findsNothing);
    });
  });
}
