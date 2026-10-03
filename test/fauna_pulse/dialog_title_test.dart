// Round 289 (owner): every window closes the same way: Cancel or Close at the
// bottom right, and an X at the top right of the title that does the same
// (a long window can be closed without scrolling).

import 'dart:async';

import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/dialog_title.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/download_files_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens [dialog] from a button and returns what it closed with.
Future<Object?> Function() _open(WidgetTester tester, Widget Function(BuildContext) dialog) {
  Object? result = 'open';
  return () async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => result = await showDialog<Object>(context: context, builder: dialog),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  };
}

final _x = find.descendant(of: find.byType(AlertDialog), matching: find.byTooltip('Close'));

void main() {
  testWidgets('the X sits at the top right, can be pressed, and closes as Cancel does', (tester) async {
    Object? result = 'open';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: DialogTitle(
                    const Text('A long title that takes two lines on a phone'),
                    onClose: () => Navigator.of(ctx).pop(false),
                  ),
                  content: const Text('Text'),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The window's surface (the AlertDialog itself fills the screen).
    final dialog = tester.getRect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first);
    final x = tester.getRect(_x);
    expect(x.top - dialog.top, lessThan(32), reason: 'at the top');
    expect(dialog.right - x.right, lessThan(24), reason: 'at the right');
    expect(_x.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(_x);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result, isFalse, reason: 'as Cancel');
  });

  testWidgets('a download window: the X cancels as its Cancel button does', (tester) async {
    final file = DownloadFile(name: 'flatbug-n_640_fp16.tflite', url: Uri.parse('https://example.org/f'), bytes: 100);
    final result = await _open(
      tester,
      (_) => DownloadFilesDialog(
        title: 'flat-bug n',
        description: 'The detection model.',
        files: [file],
        download: (f, onProgress, isCancelled) => Completer<void>().future,
      ),
    )();
    expect(result, 'open');
    await tester.tap(_x);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing, reason: 'closed before any download');
  });
}
