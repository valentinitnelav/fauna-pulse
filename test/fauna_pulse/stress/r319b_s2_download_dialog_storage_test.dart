// Round 319 part 2 (S2c, S2e): the download dialog after the storage was
// full. Phone test PB1 (L1a): the download stopped on a full storage, the
// user freed space in another app and came back: the dialog still said
// "About 1.1 GB more is needed", an amount that was no longer true. S2e: the
// "too little room" line used two units in one sentence ("needs 1.2 GB, but
// only 765.2 MB is free").
//
// The phone's answers (app folder, free storage) come from test fakes of
// the same channels the app reads (as in r319_l1_download_dialog_storage_test).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/download_files_dialog.dart';

const _mb = 1024 * 1024;
final _url = Uri.parse('https://example.org/r/a.tflite');

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

  setUp(() {
    PathProviderPlatform.instance = _FakePaths();
    messenger.setMockMethodCallHandler(thermalChannel, (call) async {
      if (call.method != 'getFreeStorage') return null;
      return free == null ? null : {'freeBytes': free, 'totalBytes': 64 * 1024 * _mb};
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(thermalChannel, null));

  Future<void> open(WidgetTester tester, CatalogueDownloader download) async {
    final f = DownloadFile(name: 'bioclip.tflite', url: _url, bytes: 1200 * _mb);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => DownloadFilesDialog(
                title: 'BioCLIP 2.5',
                description: 'The model.',
                files: [f],
                download: download,
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

  void backToFront(WidgetTester tester) {
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  TextButton button(WidgetTester tester, String label) =>
      tester.widget<TextButton>(find.ancestor(of: find.text(label), matching: find.byType(TextButton)));

  /// What downloadToFile throws when the storage fills up during the
  /// download (r319_l1_download_storage_full_test.dart); the storage is
  /// then nearly full (58.2 MB free, as in PB1).
  Future<void> fillsUp(DownloadFile f, void Function(int, int?) onProgress, bool Function() isCancelled) async {
    onProgress(60 * _mb, f.bytes);
    free = (58.2 * _mb).round();
    throw Exception(
      'Not enough free storage: the download stopped. About 1.1 GB more is needed. Delete some files (for '
      'example old sessions), then try again.',
    );
  }

  group('r319b S2c: no outdated amount after space was freed', () {
    testWidgets('back in the app with enough room: the old amount is gone and the download can start', (tester) async {
      free = 2000 * _mb;
      await open(tester, fillsUp);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      // Still full: the line with the amounts read now.
      expect(find.textContaining('the download needs 1.2 GB, but only 0.1 GB is free'), findsOneWidget);
      // The user deletes files in another app and comes back.
      free = 3000 * _mb;
      backToFront(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('more is needed'), findsNothing, reason: 'the amount is no longer true');
      expect(find.textContaining('Not enough free storage'), findsNothing);
      final start = find.text('Download').evaluate().isEmpty ? 'Try again' : 'Download';
      expect(button(tester, start).onPressed, isNotNull);
    });

    testWidgets('back in the app, still too little room: the amounts are read again', (tester) async {
      free = 2000 * _mb;
      await open(tester, fillsUp);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      free = 600 * _mb;
      backToFront(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('the download needs 1.2 GB, but only 0.6 GB is free'), findsOneWidget);
      expect(find.textContaining('more is needed'), findsNothing);
      expect(button(tester, 'Try again').onPressed, isNull);
    });

    testWidgets('right after the failure the reason stays, also when the half file freed enough room', (
      tester,
    ) async {
      free = 2000 * _mb;
      await open(tester, (f, onProgress, isCancelled) async {
        // Deleting the half file gave the room back (the filler was small).
        free = 1300 * _mb;
        throw Exception('Not enough free storage: the download stopped. Delete some files (for example old '
            'sessions), then try again.');
      });
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.textContaining('⚠ Not enough free storage: the download stopped.'), findsOneWidget);
      expect(button(tester, 'Try again').onPressed, isNotNull);
    });

    testWidgets('another error stays when the app comes back (only storage amounts go out of date)', (
      tester,
    ) async {
      free = 2000 * _mb;
      await open(tester, (f, onProgress, isCancelled) async {
        throw Exception('The downloaded file is damaged or not the expected version. Please try again.');
      });
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      backToFront(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('⚠ The downloaded file is damaged'), findsOneWidget);
    });
  });

  group('r319b S2e: one unit in the "too little room" line', () {
    testWidgets('PB1: 765.2 MB free for a 1.2 GB download', (tester) async {
      free = (765.2 * _mb).round();
      await open(tester, (f, onProgress, isCancelled) async => fail('Download must not start'));
      expect(
        find.text(
          '⚠ Not enough free storage: the download needs 1.2 GB, but only 0.7 GB is free. '
          'Delete some files (for example old sessions on the Sessions screen), then come back here.',
        ),
        findsOneWidget,
      );
    });
  });
}
