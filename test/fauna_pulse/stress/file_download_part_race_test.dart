// Stress test (2026-10-20, races): two downloads of the same model file at
// once. downloadToFile writes into `<target>.part` and renames it at the end;
// both downloads use the same `.part` name. This happens in the app when the
// download dialog is closed with Back (the download goes on, see
// download_dialog_race_test.dart) and the same file is downloaded again.
// Fixed 2026-10-20: a second download of a file that is still downloading is
// refused with a plain message, so the first one is never disturbed.
//
// A local HTTPS server (a certificate made for this test with openssl, never
// stored) sends the file in small chunks with pauses. The test is skipped
// when openssl is missing.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/file_download.dart';

/// Accepts the test's own certificate.
class _TrustAll extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..badCertificateCallback = (cert, host, port) => host == 'localhost';
}

void main() {
  late Directory tmp;
  HttpServer? server;
  late Uint8List content;
  late String contentSha;
  const chunkPause = Duration(milliseconds: 4);
  const chunk = 2048;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('part_race');
    final r = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
      '-keyout', '${tmp.path}/key.pem', '-out', '${tmp.path}/cert.pem',
    ]).catchError((Object _) => ProcessResult(0, 1, '', ''));
    if (r.exitCode != 0) return;
    final ctx = SecurityContext()
      ..useCertificateChain('${tmp.path}/cert.pem')
      ..usePrivateKey('${tmp.path}/key.pem');
    final rng = Random(42);
    content = Uint8List.fromList(List.generate(64 * 1024, (_) => rng.nextInt(256)));
    contentSha = sha256.convert(content).toString();
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    server!.listen((req) async {
      req.response.headers.contentType = ContentType.binary;
      // No Content-Length: the free-storage check (a phone channel) is skipped.
      try {
        for (var i = 0; i < content.length; i += chunk) {
          req.response.add(content.sublist(i, min(i + chunk, content.length)));
          await req.response.flush();
          await Future<void>.delayed(chunkPause);
        }
        await req.response.close();
      } catch (_) {
        // The app cancelled and closed the connection.
      }
    });
  });

  tearDownAll(() async {
    await server?.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Uri url() => Uri.parse('https://localhost:${server!.port}/model.tflite');

  Future<Object?> download(File target, {bool Function()? isCancelled, String? sha}) async {
    try {
      await downloadToFile(url(), target, validate: (_) async {}, expectedSha256: sha, isCancelled: isCancelled);
      return null;
    } catch (e) {
      return e;
    }
  }

  group('stress: two downloads of one file', () {
    test('one download arrives whole (reference)', () async {
      if (server == null) return markTestSkipped('openssl missing');
      await HttpOverrides.runZoned(() async {
        final target = File('${tmp.path}/one/model.tflite')..parent.createSync();
        expect(await download(target, sha: contentSha), isNull);
        expect(sha256.convert(target.readAsBytesSync()).toString(), contentSha);
        expect(File('${target.path}.part').existsSync(), isFalse);
      }, createHttpClient: _TrustAll().createHttpClient);
    });

    test('a second download while the first runs is refused; after the first is cancelled, a new one arrives',
        () async {
      if (server == null) return markTestSkipped('openssl missing');
      await HttpOverrides.runZoned(() async {
        final target = File('${tmp.path}/cancel/model.tflite')..parent.createSync();
        var cancelFirst = false;
        final first = download(target, isCancelled: () => cancelFirst, sha: contentSha);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final second = await download(target, sha: contentSha);
        expect('$second', contains('already being downloaded'));
        cancelFirst = true;
        expect('${await first}', contains('cancelled'));
        // The refusal ends with the first download, so trying again works.
        expect(await download(target, sha: contentSha), isNull);
        expect(sha256.convert(target.readAsBytesSync()).toString(), contentSha);
        expect(File('${target.path}.part').existsSync(), isFalse);
      }, createHttpClient: _TrustAll().createHttpClient);
    });

    // The second download starts when the first is a quarter or three
    // quarters done (the file takes about 130 ms here).
    for (final lateMs in [30, 95]) {
      test('two downloads at once (second starts after $lateMs ms): the first arrives whole, the second is refused',
          () async {
        if (server == null) return markTestSkipped('openssl missing');
        await HttpOverrides.runZoned(() async {
          final target = File('${tmp.path}/both_$lateMs/model.tflite')..parent.createSync();
          final first = download(target, sha: contentSha);
          await Future<void>.delayed(Duration(milliseconds: lateMs));
          final second = download(target, sha: contentSha);
          final results = await Future.wait([first, second]);
          // ignore: avoid_print
          print('two downloads at once, second after $lateMs ms: $results');
          expect(results[0], isNull, reason: 'the first download failed: ${results[0]}');
          expect('${results[1]}', contains('already being downloaded'));
          expect(target.existsSync(), isTrue);
          expect(sha256.convert(target.readAsBytesSync()).toString(), contentSha);
        }, createHttpClient: _TrustAll().createHttpClient);
      });
    }
  });
}
