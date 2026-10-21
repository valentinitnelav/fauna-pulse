// Round 319 (stress test 2026-10-20, items 1 and 14): the download dialog
// and the phone's free storage. The dialog warns as soon as it opens when
// the files do not fit (before round 319 only after Download was pressed),
// checks again when the app comes back to the front, and stays usable when
// the storage fills up during a download.
//
// The phone's answers (app folder, free storage) come from test fakes of
// the same channels the app reads.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/download_files_dialog.dart';

const _mb = 1024 * 1024;
final _url = Uri.parse('https://example.org/r/a.tflite');

/// The app's private folder (where the models are saved).
class _FakePaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => '/data/user/0/app/files';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const thermalChannel = MethodChannel('faunapulse/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// The free storage the phone reports (null: the phone does not say).
  int? free;
  final readPaths = <String?>[];

  setUp(() {
    PathProviderPlatform.instance = _FakePaths();
    readPaths.clear();
    messenger.setMockMethodCallHandler(thermalChannel, (call) async {
      if (call.method != 'getFreeStorage') return null;
      readPaths.add((call.arguments as Map?)?['path'] as String?);
      return free == null ? null : {'freeBytes': free, 'totalBytes': 64 * 1024 * _mb};
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(thermalChannel, null));

  Future<void> open(WidgetTester tester, CatalogueDownloader download, void Function(bool?) onResult) async {
    final f = DownloadFile(name: 'bioclip.tflite', url: _url, bytes: 1200 * _mb);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => DownloadFilesDialog(
                  title: 'BioCLIP 2.5',
                  description: 'The model.',
                  files: [f],
                  download: download,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  TextButton button(WidgetTester tester, String label) =>
      tester.widget<TextButton>(find.ancestor(of: find.text(label), matching: find.byType(TextButton)));

  Future<void> noDownload(DownloadFile f, void Function(int, int?) onProgress, bool Function() isCancelled) async =>
      fail('Download must not start');

  group('r319 L1b: free storage in the download dialog', () {
    testWidgets('too little room: the warning shows when the dialog opens and Download is off', (tester) async {
      free = 100 * _mb;
      await open(tester, noDownload, (_) {});
      // 1200 MB + the 5 MB margin.
      expect(
        find.text(
          '⚠ Not enough free storage: the download needs 1.2 GB, but only 0.1 GB is free. '
          'Delete some files (for example old sessions on the Sessions screen), then come back here.',
        ),
        findsOneWidget,
      );
      expect(button(tester, 'Download').onPressed, isNull);
      expect(button(tester, 'Cancel').onPressed, isNotNull);
      expect(readPaths, ['/data/user/0/app/files'], reason: 'the storage of the model folders is read');
    });

    testWidgets('enough room, or the phone does not say: no warning, Download is on', (tester) async {
      for (final f in [2000 * _mb, null]) {
        free = f;
        await open(tester, noDownload, (_) {});
        expect(find.textContaining('Not enough free storage'), findsNothing);
        expect(button(tester, 'Download').onPressed, isNotNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('space freed in another app: checked again when the app comes back', (tester) async {
      free = 100 * _mb;
      await open(tester, noDownload, (_) {});
      expect(find.textContaining('Not enough free storage'), findsOneWidget);
      free = 3000 * _mb;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Not enough free storage'), findsNothing);
      expect(button(tester, 'Download').onPressed, isNotNull);
    });

    testWidgets('storage full during the download: plain message, the dialog stays usable', (tester) async {
      free = 2000 * _mb;
      bool? result = true;
      await open(tester, (f, onProgress, isCancelled) async {
        onProgress(64 * _mb, f.bytes);
        // What downloadToFile throws for a full storage (r319_l1_download_storage_full_test.dart).
        free = 1300 * _mb;
        throw Exception(
          'Not enough free storage: the download stopped. About 0.1 GB more is needed. Delete some files (for example old sessions), then try again.',
        );
      }, (r) => result = r);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.textContaining('⚠ Not enough free storage: the download stopped.'), findsOneWidget);
      expect(button(tester, 'Try again').onPressed, isNotNull, reason: '1.3 GB is free again');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Download BioCLIP 2.5'), findsNothing);
      expect(result, isFalse);
    });

    testWidgets('storage still full after a failed download: Try again stays off until there is room', (
      tester,
    ) async {
      free = 2000 * _mb;
      await open(tester, (f, onProgress, isCancelled) async {
        free = 0;
        throw Exception('Not enough free storage: the download stopped. Free some space and try again.');
      }, (_) {});
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.textContaining('the download needs 1.2 GB, but almost no storage is free'), findsOneWidget);
      expect(button(tester, 'Try again').onPressed, isNull);
    });
  });
}
