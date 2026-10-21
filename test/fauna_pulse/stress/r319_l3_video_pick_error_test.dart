// Round 319 (stress test 2026-10-20, report item 6): with too little free
// storage for the photo picker's copies, "Import videos" showed the raw
// "Could not open the videos: PlatformException(missing_valid_video_uri,
// Cannot find at least one of the selected videos., null, null)" and left the
// half-made copies (34 MB) in the app's cache. The Android picker
// (image_picker_android FileUtils.getPathFromUri) copies each video into
// <cache>/<random id>/<name>; a failed copy returns null without deleting the
// half file, and the plugin then reports that error code.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/video_import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePaths extends PathProviderPlatform {
  final String path;
  _FakePaths(this.path);

  @override
  Future<String?> getTemporaryPath() async => path;

  @override
  Future<String?> getExternalStoragePath() async => path;
}

/// Does what the Android picker does when a copy fails: some copies made,
/// one half copy, then the error.
class _FailingPicker extends ImagePickerPlatform {
  final Directory cache;
  final PlatformException error;
  final bool makeCopies;
  _FailingPicker(this.cache, this.error, {this.makeCopies = true});

  @override
  Future<List<XFile>> getMultiVideoWithOptions({MultiVideoPickerOptions options = const MultiVideoPickerOptions()}) async {
    if (makeCopies) {
      final a = Directory('${cache.path}/6dfd8a5c-b57a-4025-b0c0-506bc01e7476')..createSync();
      File('${a.path}/1000095497.mp4').writeAsBytesSync(List.filled(30000, 1));
      final b = Directory('${cache.path}/786c9472-9b0e-4e45-94b5-9ac87c20712a')..createSync();
      File('${b.path}/1000095498.mp4').writeAsBytesSync(List.filled(4000, 1)); // cut off
    }
    throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const thermal = MethodChannel('faunapulse/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp, cache;
  var freeBytes = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319_l3_pick');
    cache = Directory('${tmp.path}/cache')..createSync();
    PathProviderPlatform.instance = _FakePaths(cache.path);
    messenger.setMockMethodCallHandler(thermal, (call) async => {'freeBytes': freeBytes, 'totalBytes': 64 << 30});
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(thermal, null);
    tmp.deleteSync(recursive: true);
  });

  Future<void> pick(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => pickAndImportVideos(context), child: const Text('pick')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  final copyFailed = PlatformException(
    code: 'missing_valid_video_uri',
    message: 'Cannot find at least one of the selected videos.',
  );

  testWidgets('storage full: plain message, and the half copies of this pick are deleted', (tester) async {
    // A copy from an earlier pick (its import screen may still need it) and
    // other cache folders stay.
    final earlier = Directory('${cache.path}/0b7a3c1e-1111-4222-8333-944455556666')..createSync();
    File('${earlier.path}/VID_1.mp4').writeAsStringSync('video');
    Directory('${cache.path}/data').createSync();
    freeBytes = 1 << 20; // what is left once the copies filled the storage
    ImagePickerPlatform.instance = _FailingPicker(cache, copyFailed);

    await pick(tester);

    expect(find.textContaining('PlatformException'), findsNothing);
    expect(
      find.textContaining('The videos could not be copied: not enough free storage', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Free some space and try again.', findRichText: true), findsOneWidget);
    final left = cache.listSync().map((e) => e.path.split('/').last).toList()..sort();
    expect(left, ['0b7a3c1e-1111-4222-8333-944455556666', 'data']);
    expect(find.text('Reading the videos…'), findsNothing); // the wait dialog closed
  });

  testWidgets('plenty of storage: says one video could not be copied, not the raw error', (tester) async {
    freeBytes = 20 << 30;
    ImagePickerPlatform.instance = _FailingPicker(cache, copyFailed);

    await pick(tester);

    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('not enough free storage'), findsNothing);
    expect(find.textContaining('One of the videos could not be copied into the app.'), findsOneWidget);
    expect(cache.listSync(), isEmpty);
  });

  testWidgets('any other picker error is readable too', (tester) async {
    freeBytes = 20 << 30;
    ImagePickerPlatform.instance = _FailingPicker(
      cache,
      PlatformException(code: 'already_active', message: 'Image picker is already active'),
      makeCopies: false,
    );

    await pick(tester);

    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('already active'), findsNothing);
    expect(find.text('The videos could not be opened. Try again.'), findsOneWidget);
  });
}
