// FaunaPulse (round 268): one HTTPS download routine for every model file
// (detection models, identification models, name lists). Moved out of
// ModelCatalog.downloadModel so the AI models screen's catalogue downloads
// use the same checks as the "Download…" link dialog.

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../logging/app_error_hooks.dart';
import 'model_file_security.dart';

/// Why a download answer cannot be used, in plain words, or null when it
/// can (HTTP 200 and not a web page). Separate from [downloadToFile] so it
/// can be tested without a server.
String? downloadStatusMessage(int statusCode, {String? mimeType}) {
  // Round 278: in plain words, as the app's own list can name files that
  // are not uploaded yet.
  if (statusCode == HttpStatus.notFound) {
    return 'Nothing was found at this link (HTTP 404). The file may not be online yet: please try again later.';
  }
  // Round 314: Hugging Face answers 401, not 404, for a repository that is
  // private or does not exist (the app's list names files whose repository
  // may not be public yet).
  if (statusCode == HttpStatus.unauthorized || statusCode == HttpStatus.forbidden) {
    return 'This link is not public (HTTP $statusCode). The file may not be online yet: please try again later.';
  }
  if (statusCode != HttpStatus.ok) return 'Download failed (HTTP $statusCode).';
  // Round 314: a file page (e.g. a Hugging Face or GitHub "blob" link) is a
  // web page, not the file; refused before its body is downloaded.
  if (mimeType == 'text/html') {
    return 'This link opens a web page, not the file itself. Use the download link of the file.';
  }
  return null;
}

/// The link of the file itself for a Hugging Face file page link
/// (`huggingface.co/<owner>/<repo>/blob/<version>/<file>` becomes
/// `.../resolve/...`), as people copy the page's address from the browser.
/// Any other link is returned unchanged.
Uri directFileUri(Uri uri) {
  final s = uri.pathSegments;
  final huggingFace = uri.host == 'huggingface.co' || uri.host == 'hf.co';
  if (!huggingFace || s.length < 5 || s[2] != 'blob') return uri;
  return uri.replace(pathSegments: [...s.take(2), 'resolve', ...s.skip(3)]);
}

/// Streams [url] into [target] through a temporary `<target>.part` file and
/// renames only on success, so a dropped connection never leaves half a file
/// where the app looks for models. Files above [kMaxModelFileBytes] are
/// refused, from the size the server declares and while they stream.
/// [validate] checks the finished `.part` file (structure);
/// [expectedSha256], when given, must match. Reports
/// progress via [onProgress] (total is null when the server doesn't say);
/// [isCancelled] is checked between chunks. Throws with a plain-language
/// message on any failure.
Future<File> downloadToFile(
  Uri url,
  File target, {
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
    // GitHub release links and Hugging Face file links redirect to a file
    // host; HttpClient follows redirects on GET by default.
    final request = await client.getUrl(url);
    final response = await request.close();
    if (!redirectChainStaysHttps(url, response.redirects)) {
      throw Exception('The link redirected to an insecure non-HTTPS address.');
    }
    final problem = downloadStatusMessage(
      response.statusCode,
      mimeType: response.headers.contentType?.mimeType,
    );
    if (problem != null) throw Exception(problem);
    final total = response.contentLength > 0 ? response.contentLength : null;
    if (total != null && total > kMaxModelFileBytes) throw Exception(sizeLimitMessage());
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
        if (nextReceived > kMaxModelFileBytes) throw Exception(sizeLimitMessage());
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
