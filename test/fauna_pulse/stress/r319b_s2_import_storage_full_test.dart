// Round 319 part 2 (S2a): "Import model files…" while the phone's storage
// fills up. The copy into `<target>.part` used an IOSink (openWrite, add,
// flush), the same pattern that made a model download hang (round 319 L1a):
// the write error stayed unseen and flush() waited for ever, so the import
// never ended and the screen's buttons stayed grey.
//
// The full storage is real: `<target>.part` is opened on Linux's /dev/full,
// where every write fails with errno 28 ("No space left on device"). Only
// that one file is redirected; the rest is the app's own code. Skipped when
// /dev/full is missing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_security.dart';

/// The import's `<target>.part` file on a full storage: it is written on
/// /dev/full, and a delete is recorded (/dev/full itself cannot be deleted).
class _FullPartFile implements File {
  _FullPartFile(this.path, this._devFull);

  @override
  final String path;
  final File _devFull;
  bool opened = false;
  bool deleted = false;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    opened = true;
    return _devFull.open(mode: mode);
  }

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    opened = true;
    return _devFull.openWrite(mode: mode, encoding: encoding);
  }

  @override
  Future<bool> exists() async => opened && !deleted;

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    deleted = true;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const thermalChannel = MethodChannel('faunapulse/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const mb = 1024 * 1024;
  late Directory tmp;
  late File source;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319b_s2_import_full');
    // A small .tflite file (TFL3 at bytes 4-7), larger than one read chunk.
    final bytes = Uint8List(512 * 1024);
    bytes.setRange(4, 8, ascii.encode('TFL3'));
    source = File('${tmp.path}/source.tflite')..writeAsBytesSync(bytes);
    // Enough room at the check before the copy.
    messenger.setMockMethodCallHandler(thermalChannel, (call) async {
      if (call.method != 'getFreeStorage') return null;
      return {'freeBytes': 100 * mb, 'totalBytes': 64 * 1024 * mb};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(thermalChannel, null);
    tmp.deleteSync(recursive: true);
  });

  group('r319b S2a: storage full during "Import model files…"', () {
    test('the import stops at once with a plain message and the half file is deleted', () async {
      if (!File('/dev/full').existsSync()) return markTestSkipped('/dev/full missing');
      final target = File('${tmp.path}/models/my_model.tflite')..parent.createSync();
      final parts = <_FullPartFile>[];
      Object? error;
      await IOOverrides.runZoned(
        () async {
          try {
            await copyAndValidateModel(source, target, 'my_model.tflite').timeout(const Duration(seconds: 10));
          } catch (e) {
            error = e;
          }
        },
        createFile: (path) {
          if (!path.endsWith('.part')) return Zone.root.run(() => File(path));
          final f = _FullPartFile(path, File('/dev/full'));
          parts.add(f);
          return f;
        },
      );
      expect(error, isNot(isA<TimeoutException>()), reason: 'the import hung after the storage was full');
      expect(error, isNotNull);
      expect(
        plainModelError(error!, importing: true),
        'Not enough free storage: the import stopped. Delete some files (for example old sessions), then try '
        'again.',
      );
      expect(parts.where((p) => p.opened), isNotEmpty);
      expect(parts.every((p) => !p.opened || p.deleted), isTrue, reason: 'the half file is deleted');
      expect(target.existsSync(), isFalse);
    });

    test('an import with enough room arrives whole (reference)', () async {
      final target = File('${tmp.path}/models/ok.tflite')..parent.createSync();
      await copyAndValidateModel(source, target, 'ok.tflite');
      expect(target.readAsBytesSync(), source.readAsBytesSync());
      expect(File('${target.path}.part').existsSync(), isFalse);
    });
  });
}
