// Round 326: the "Download from a link" dialog's helper text says to paste only links from
// people or websites you trust, so it must not be cut off on a narrow phone with large
// system text. Measured with Roboto (Android's font, from the Flutter SDK): the test font
// draws every letter as a full square, about twice as wide.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/widgets/download_model_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('helper text fits at 360 dp width and 1.3x text', (tester) async {
    // flutter_tester runs from <flutter>/bin/cache/artifacts/engine/<platform>/.
    final root = Platform.environment['FLUTTER_ROOT'] ??
        File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
    final roboto = File('$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
    if (!roboto.existsSync()) {
      markTestSkipped('Roboto not found in the Flutter SDK');
      return;
    }
    final bytes = roboto.readAsBytesSync();
    await tester.runAsync(() => (FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(bytes)))).load());
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const DownloadModelDialog()),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final helper = find.textContaining('people or websites you trust');
    expect(helper, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: helper, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });
}
