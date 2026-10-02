// FaunaPulse (round 268): one HTTPS download routine for every model file
// (detection models, identification models, name lists). Moved out of
// ModelCatalog.downloadModel so the AI models screen's catalogue downloads
// use the same checks as the "Download…" link dialog.

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../logging/app_error_hooks.dart';
import 'model_file_security.dart';

/// Streams [url] into [target] through a temporary `<target>.part` file and
/// renames only on success, so a dropped connection never leaves half a file
/// where the app looks for models. [validate] checks the finished `.part`
/// file (structure); [expectedSha256], when given, must match. Reports
/// progress via [onProgress] (total is null when the server doesn't say);
/// [isCancelled] is checked between chunks. Throws with a plain-language
/// message on any failure.
Future<File> downloadToFile(
  Uri url,
  File target, {
  required int maxBytes,
  required String tooLargeMessage,
  required Future<void> Function(File part) validate,
  String? expectedSha256,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
  bool Function()? isCancelled,
}) async {
  if (expectedSha256 != null && !isValidSha256(expectedSha256)) {
    throw Exception('The expected SHA-256 value must contain 64 hex digits.');
  }
  final partFile = File('${target.path}.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    // GitHub asset links redirect to the real file host; HttpClient follows
    // redirects on GET by default.
    final request = await client.getUrl(url);
    final response = await request.close();
    if (!redirectChainStaysHttps(url, response.redirects)) {
      throw Exception('The link redirected to an insecure non-HTTPS address.');
    }
    // Round 278: in plain words, as the app's own list can name files that
    // are not uploaded yet.
    if (response.statusCode == HttpStatus.notFound) {
      throw Exception('Nothing was found at this link (HTTP 404). The file may not be online yet: please try again later.');
    }
    if (response.statusCode != HttpStatus.ok) {
      throw Exception('Download failed (HTTP ${response.statusCode}).');
    }
    final total = response.contentLength > 0 ? response.contentLength : null;
    if (total != null && total > maxBytes) throw Exception(tooLargeMessage);
    if (total != null) await ensureModelStorageAvailable(target.parent.path, total);
    var received = 0;
    final sink = partFile.openWrite();
    try {
      // The timeout is BETWEEN chunks: a dead connection errors out (and a
      // stalled stream would otherwise also never reach the cancel check).
      final data = response.timeout(
        const Duration(seconds: 30),
        onTimeout: (s) => s.addError(Exception('Connection stalled — try again.')),
      );
      await for (final chunk in data) {
        if (isCancelled?.call() ?? false) throw Exception('Download cancelled.');
        final nextReceived = received + chunk.length;
        if (nextReceived > maxBytes) throw Exception(tooLargeMessage);
        sink.add(chunk);
        received = nextReceived;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received == 0) throw Exception('The server returned an empty file.');
    await validate(partFile);
    if (expectedSha256 != null) {
      final actual = (await sha256.bind(partFile.openRead()).first).toString();
      if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
        throw Exception('The downloaded file did not match its SHA-256 hash.');
      }
    }
    if (await target.exists()) await target.delete();
    return await partFile.rename(target.path);
  } catch (e) {
    try {
      if (await partFile.exists()) await partFile.delete();
    } catch (e2) {
      logSwallowed('model_download_cleanup', e2);
    }
    rethrow;
  } finally {
    client.close();
  }
}
