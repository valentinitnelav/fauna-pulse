// Stress test (2026-10-20, races): the download dialog of the AI models
// screen. The phone's Back button (barrierDismissible only blocks a tap
// outside the dialog) must stop the download in progress, as it
// does for Cancel and the X, or it keeps using mobile data with no progress
// shown, and a second Download of the same file shares its `.part` file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/download_files_dialog.dart';

final _url = Uri.parse('https://example.org/r/a.tflite');

/// A download in 10 chunks; each chunk waits for [step] to be completed,
/// so the test decides when the "network" sends data.
class _SlowDownload {
  final chunksSent = <String>[];
  final cancelChecks = <bool>[];
  Completer<void> step = Completer<void>();
  bool finished = false;
  bool stoppedByCancel = false;

  Future<void> call(DownloadFile f, void Function(int, int?) onProgress, bool Function() isCancelled) async {
    for (var i = 0; i < 10; i++) {
      await step.future;
      step = Completer<void>();
      final c = isCancelled();
      cancelChecks.add(c);
      if (c) {
        stoppedByCancel = true;
        throw Exception('Download cancelled.');
      }
      chunksSent.add('${f.name}#$i');
      onProgress((i + 1) * f.bytes ~/ 10, f.bytes);
    }
    finished = true;
  }

  void sendChunk() => step.complete();
}

Future<void> _openDialog(WidgetTester tester, _SlowDownload dl, void Function(bool?) onResult) async {
  final f = DownloadFile(name: 'a.tflite', url: _url, bytes: 10 * 1024 * 1024);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => onResult(
            await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => DownloadFilesDialog(title: 'test model', description: 'The model.', files: [f], download: dl.call),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Download'));
  await tester.pump();
}

void main() {
  group('stress: download dialog races', () {
    testWidgets('Cancel stops the download at the next chunk (reference)', (tester) async {
      final dl = _SlowDownload();
      bool? result = true;
      await _openDialog(tester, dl, (r) => result = r);
      dl.sendChunk();
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      dl.sendChunk();
      await tester.pumpAndSettle();
      expect(dl.stoppedByCancel, isTrue);
      expect(result, isFalse);
      expect(find.text('Download test model'), findsNothing);
    });

    testWidgets(
      'the Back button during a download stops the download too',
      (tester) async {
        final dl = _SlowDownload();
        bool? result = true;
        await _openDialog(tester, dl, (r) => result = r);
        dl.sendChunk();
        await tester.pump();
        expect(dl.chunksSent, ['a.tflite#0']);
        // The phone's Back button (system back gesture) acts like Cancel: the
        // dialog stays until the download has stopped, then pops false.
        await tester.binding.handlePopRoute();
        await tester.pump();
        // The "network" keeps sending: the download must notice it was cancelled.
        for (var i = 0; i < 9 && !dl.stoppedByCancel && !dl.finished; i++) {
          dl.sendChunk();
          await tester.pump();
        }
        expect(dl.stoppedByCancel, isTrue,
            reason: 'chunks downloaded after Back: ${dl.chunksSent.length}, finished: ${dl.finished}');
        expect(dl.chunksSent, ['a.tflite#0'], reason: 'no chunk after Back');
        await tester.pumpAndSettle();
        expect(find.text('Download test model'), findsNothing, reason: 'the dialog closed');
        expect(result, isFalse, reason: 'the caller sees "not downloaded", as for Cancel');
      },
    );
  });
}
