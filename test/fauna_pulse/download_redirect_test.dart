// Round 329: a download that is redirected to a plain http:// address must be refused BEFORE
// the app sends that request (dart:io's HttpClient follows redirects itself, so the app used
// to see the http:// hop only after it was sent in clear text). Two local servers: a secure
// one that redirects, and a plain one that counts what reaches it. The certificate is made by
// openssl for this test only and trusted only inside it.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/file_download.dart';
import 'package:flutter_test/flutter_test.dart';

class _TrustTestCertificate extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..badCertificateCallback = (_, _, _) => true;
}

void main() {
  late Directory tmp;
  late HttpServer plain;
  late HttpServer secure;
  final plainHits = <Uri>[];
  late String nextLocation;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('redirect');
    final made = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
      '-keyout', '${tmp.path}/k.pem', '-out', '${tmp.path}/c.pem',
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    plain.listen((r) {
      plainHits.add(r.uri);
      r.response
        ..statusCode = 200
        ..write('TFL3')
        ..close();
    });
    final ctx = SecurityContext()
      ..useCertificateChain('${tmp.path}/c.pem')
      ..usePrivateKey('${tmp.path}/k.pem');
    secure = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    secure.listen((r) {
      if (r.uri.path == '/trickle') {
        // A redirect whose body never ends: 3 bytes of the 1 MB it announces.
        r.response
          ..statusCode = 302
          ..headers.set('location', '/file')
          ..contentLength = 1 << 20
          ..add([1, 2, 3]);
      } else if (r.uri.path == '/hop') {
        r.response
          ..statusCode = 302
          ..headers.set('location', nextLocation)
          ..close();
      } else {
        r.response
          ..statusCode = 200
          ..headers.contentType = ContentType.binary
          ..add(List.filled(64, 1))
          ..close();
      }
    });
  });

  tearDownAll(() async {
    await plain.close(force: true);
    await secure.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  setUp(plainHits.clear);

  Future<File> download(String path) => HttpOverrides.runZoned(
    () => downloadToFile(
      Uri.parse('https://localhost:${secure.port}$path'),
      File('${tmp.path}/m.tflite'),
      validate: (_) async {},
    ),
    createHttpClient: _TrustTestCertificate().createHttpClient,
  );

  test('a redirect to http:// is refused before that request is sent', () async {
    nextLocation = 'http://127.0.0.1:${plain.port}/m.tflite?x=1';
    await expectLater(
      download('/hop'),
      throwsA(isA<Exception>().having((e) => '$e', 'message', contains('not https'))),
    );
    expect(plainHits, isEmpty);
    expect(File('${tmp.path}/m.tflite').existsSync(), isFalse);
  });

  test('a redirect whose body never ends does not hold the download', () async {
    final f = await download('/trickle').timeout(const Duration(seconds: 10));
    expect(f.lengthSync(), 64);
  });

  test('a redirect that stays on https is followed', () async {
    nextLocation = '/file';
    final f = await download('/hop');
    expect(f.lengthSync(), 64);
  });
}
