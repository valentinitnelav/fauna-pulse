// Round 319 (stress test 2026-10-20, report item 6): with too little free
// storage for the photo picker's copies, "Import videos" showed the raw
// "Could not open the videos: PlatformException(missing_valid_video_uri,
// Cannot find at least one of the selected videos., null, null)" and left the
// half-made copies (34 MB) in the app's cache. The Android picker
// (image_picker_android FileUtils.getPathFromUri) copies each video into
// <cache>/<random id>/<name>; a failed copy returns null without deleting the
// half file, and the plugin then reports that error code.
//
// Round 395: the import uses the file chooser plugin (file_picker), which
// copies each file to <cache>/file_picker/<time in ms>/<name> and, when a
// copy fails, leaves the half file and silently hands over the other files
// only (FileUtils.openFileStream returns null, addFile skips it).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/video_import_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Does what the file chooser does when a copy fails: one copy made, one
/// half copy, and only the whole one handed over; or [error] is thrown
/// before any copy.
class _FailingPicker extends FilePicker {
  final Directory cache;
  final PlatformException? error;
  _FailingPicker(this.cache, {this.error});

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    if (error != null) throw error!;
    final a = Directory('${cache.path}/file_picker/1795373273001')..createSync(recursive: true);
    final whole = File('${a.path}/VID_20260924_155954.mp4')..writeAsBytesSync(List.filled(30000, 1));
    final b = Directory('${cache.path}/file_picker/1795373273002')..createSync();
    File('${b.path}/VIDT05B01680_260612120338 - Trim.mp4').writeAsBytesSync(List.filled(4000, 1)); // cut off
    return FilePickerResult([PlatformFile(path: whole.path, name: 'VID_20260924_155954.mp4', size: 30000)]);
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

  testWidgets('storage full: plain message, and the half copies of this pick are deleted', (tester) async {
    // A copy from an earlier pick (its import screen may still need it) and
    // other cache folders stay.
    final earlier = Directory('${cache.path}/file_picker/1795373000000')..createSync(recursive: true);
    File('${earlier.path}/VID_1.mp4').writeAsStringSync('video');
    Directory('${cache.path}/data').createSync();
    freeBytes = 1 << 20; // what is left once the copies filled the storage
    FilePicker.platform = _FailingPicker(cache);

    await pick(tester);

    expect(find.textContaining('PlatformException'), findsNothing);
    expect(
      find.textContaining('The videos could not be copied: not enough free storage', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Free some space and try again.', findRichText: true), findsOneWidget);
    final left = cache.listSync(recursive: true).map((e) => e.path.substring(cache.path.length + 1)).toList()..sort();
    expect(left, ['data', 'file_picker', 'file_picker/1795373000000', 'file_picker/1795373000000/VID_1.mp4']);
    expect(find.text('Reading the videos…'), findsNothing); // the wait dialog closed
    expect(find.text('Import videos'), findsNothing, reason: 'no import screen for a failed pick');
  });

  testWidgets('plenty of storage: says one video could not be copied, not the raw error', (tester) async {
    freeBytes = 20 << 30;
    FilePicker.platform = _FailingPicker(cache);

    await pick(tester);

    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('not enough free storage'), findsNothing);
    expect(find.textContaining('One of the videos could not be copied into the app.'), findsOneWidget);
    expect(Directory('${cache.path}/file_picker').listSync(), isEmpty);
  });

  testWidgets('any other picker error is readable too', (tester) async {
    freeBytes = 20 << 30;
    FilePicker.platform = _FailingPicker(
      cache,
      error: PlatformException(code: 'already_active', message: 'File picker is already active'),
    );

    await pick(tester);

    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('already active'), findsNothing);
    expect(find.text('The videos could not be opened. Try again.'), findsOneWidget);
  });
}
