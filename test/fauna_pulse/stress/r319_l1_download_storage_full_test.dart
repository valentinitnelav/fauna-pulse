// Round 319 (stress test 2026-10-20, item 1): a model download while the
// phone's storage fills up. The writes into `<target>.part` fail with "No
// space left on device" (errno 28). Before round 319 the download did not
// see this: it counted on to "1.2 GB of 1.2 GB" and then waited for ever,
// and Cancel did nothing.
//
// The full storage is real: `<target>.part` is opened on Linux's /dev/full,
// where every write fails with errno 28 (only the open and delete of that
// one file are redirected; the rest is the app's own code). A local HTTPS
// server (a
// certificate made for this test with openssl, never stored) sends the file
// in small chunks. Skipped when openssl or /dev/full is missing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/file_download.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_security.dart' show plainModelError;

/// Accepts the test's own certificate.
class _TrustAll extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..badCertificateCallback = (cert, host, port) => host == 'localhost';
}

/// The download's `<target>.part` file on a full storage: it is written on
/// /dev/full, and a delete is recorded (/dev/full itself cannot be deleted).
class _FullPartFile implements File {
  _FullPartFile(this.path, this._devFull);

  @override
  final String path;
  final File _devFull;
  bool deleted = false;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) => _devFull.open(mode: mode);

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      _devFull.openWrite(mode: mode, encoding: encoding);

  @override
  Future<bool> exists() async => !deleted;

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
  late Directory tmp;
  HttpServer? server;
  late Uint8List content;
  const chunk = 4096;
  const mb = 1024 * 1024;

  /// The free storage the phone reports, one value per reading (the last
  /// one repeats).
  var freeReadings = <int>[];

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('r319_storage_full');
    if (!File('/dev/full').existsSync()) return;
    final r = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
      '-keyout', '${tmp.path}/key.pem', '-out', '${tmp.path}/cert.pem',
    ]).catchError((Object _) => ProcessResult(0, 1, '', ''));
    if (r.exitCode != 0) return;
    final ctx = SecurityContext()
      ..useCertificateChain('${tmp.path}/cert.pem')
      ..usePrivateKey('${tmp.path}/key.pem');
    final rng = Random(7);
    content = Uint8List.fromList(List.generate(256 * 1024, (_) => rng.nextInt(256)));
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    server!.listen((req) async {
      req.response.headers.contentType = ContentType.binary;
      // With its size, so the free-storage check before the download runs.
      req.response.contentLength = content.length;
      try {
        for (var i = 0; i < content.length; i += chunk) {
          req.response.add(content.sublist(i, min(i + chunk, content.length)));
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await req.response.close();
      } catch (_) {
        // The app stopped the download and closed the connection.
      }
    });
  });

  setUp(() {
    messenger.setMockMethodCallHandler(thermalChannel, (call) async {
      if (call.method != 'getFreeStorage') return null;
      final free = freeReadings.length > 1 ? freeReadings.removeAt(0) : freeReadings.first;
      return {'freeBytes': free, 'totalBytes': 64 * 1024 * mb};
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(thermalChannel, null));

  tearDownAll(() async {
    await server?.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Uri url() => Uri.parse('https://localhost:${server!.port}/model.tflite');

  /// The `.part` files the downloads opened on the full storage.
  final parts = <_FullPartFile>[];

  /// Runs [body] with real HTTPS to the test server and every `.part` file
  /// on a full storage.
  Future<void> onFullStorage(Future<void> Function() body) {
    final devFull = File('/dev/full');
    return HttpOverrides.runZoned(
      () => IOOverrides.runZoned(
        body,
        createFile: (path) {
          if (!path.endsWith('.part')) return Zone.root.run(() => File(path));
          final f = _FullPartFile(path, devFull);
          parts.add(f);
          return f;
        },
      ),
      createHttpClient: _TrustAll().createHttpClient,
    );
  }

  File newTarget(String name) => File('${tmp.path}/$name/model.tflite')..parent.createSync();

  Future<Object?> download(File target, {bool Function()? isCancelled}) async {
    try {
      await downloadToFile(url(), target, validate: (_) async {}, isCancelled: isCancelled).timeout(
        const Duration(seconds: 10),
      );
      return null;
    } catch (e) {
      return e;
    }
  }

  group('r319 L1a: storage full during a model download', () {
    test('the download stops at once with a plain message and the half file is deleted', () async {
      if (server == null) return markTestSkipped('openssl or /dev/full missing');
      // 100 MB free when it starts, 2 MB after the failure.
      freeReadings = [100 * mb, 2 * mb];
      await onFullStorage(() async {
        final target = newTarget('stops');
        var progressCalls = 0;
        Object? error;
        try {
          await downloadToFile(
            url(),
            target,
            validate: (_) async {},
            onProgress: (_, _) => progressCalls++,
          ).timeout(const Duration(seconds: 10));
        } catch (e) {
          error = e;
        }
        expect(error, isNot(isA<TimeoutException>()), reason: 'the download hung after the storage was full');
        expect(error, isNotNull);
        // 256 KB + the 5 MB margin - 2 MB free = 3.3 MB.
        expect(
          plainModelError(error!),
          'Not enough free storage: the download stopped. About 3.3 MB more is needed. '
          'Delete some files (for example old sessions), then try again.',
        );
        expect(progressCalls, lessThanOrEqualTo(1), reason: 'no progress counted for data that was never saved');
        expect(parts.last.path, '${target.path}.part');
        expect(parts.last.deleted, isTrue, reason: 'the half file is deleted');
        expect(target.existsSync(), isFalse);
      });
    });

    test('without a free-storage reading the message leaves the amount out', () async {
      if (server == null) return markTestSkipped('openssl or /dev/full missing');
      await onFullStorage(() async {
        messenger.setMockMethodCallHandler(thermalChannel, (call) async => null);
        final target = newTarget('unknown');
        final error = await download(target);
        expect(error, isNot(isA<TimeoutException>()), reason: 'the download hung after the storage was full');
        expect(
          plainModelError(error!),
          'Not enough free storage: the download stopped. Delete some files (for example old sessions), then try again.',
        );
      });
    });

    test('Cancel ends the download also when the storage is full', () async {
      if (server == null) return markTestSkipped('openssl or /dev/full missing');
      freeReadings = [100 * mb];
      await onFullStorage(() async {
        final target = newTarget('cancel');
        var cancelled = false;
        // Cancel after the whole file was sent (where the old code waited).
        Timer(const Duration(seconds: 2), () => cancelled = true);
        final error = await download(target, isCancelled: () => cancelled);
        expect(error, isNot(isA<TimeoutException>()), reason: 'Cancel did not end the download');
        expect(parts.last.deleted, isTrue);
      });
    });

    test('a download with enough room still arrives whole (reference)', () async {
      if (server == null) return markTestSkipped('openssl or /dev/full missing');
      freeReadings = [100 * mb];
      await HttpOverrides.runZoned(() async {
        final target = File('${tmp.path}/ok/model.tflite')..parent.createSync();
        var last = 0;
        await downloadToFile(url(), target, validate: (_) async {}, onProgress: (r, _) => last = r);
        expect(target.readAsBytesSync(), content);
        expect(last, content.length);
        expect(File('${target.path}.part').existsSync(), isFalse);
      }, createHttpClient: _TrustAll().createHttpClient);
    });
  });
}
