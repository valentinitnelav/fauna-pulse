// FaunaPulse (round 268): one HTTPS download routine for every model file
// (detection models, identification models, name lists). Moved out of
// ModelCatalog.downloadModel so the AI models screen's catalogue downloads
// use the same checks as the "Download…" link dialog.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import 'model_file_security.dart';

// isNoSpaceLeft moved to model_file_security.dart (round 319: the import uses it too).
export 'model_file_security.dart' show isNoSpaceLeft;

/// Why a download answer cannot be used, in plain words, or null when it
/// can (HTTP 200 and not a web page). Separate from [downloadToFile] so it
/// can be tested without a server. [pastedLink]: the user typed or pasted
/// the link ("Download from a link"), so they can correct it.
String? downloadStatusMessage(int statusCode, {String? mimeType, bool pastedLink = false}) {
  // Round 278: in plain words, as the app's own list can name files that
  // are not uploaded yet. Round 317: for a pasted link a 404 is almost
  // always a wrong link, and waiting does not help.
  if (statusCode == HttpStatus.notFound) {
    return pastedLink
        ? 'Nothing was found at this link (HTTP 404). Check that the link is complete and correct.'
        : 'Nothing was found at this link (HTTP 404). The file may not be online yet: please try again later.';
  }
  // Round 314: Hugging Face answers 401, not 404, for a repository that is
  // private or does not exist (the app's list names files whose repository
  // may not be public yet). Round 317: a pasted link can be wrong or need a
  // login, which the app cannot give.
  if (statusCode == HttpStatus.unauthorized || statusCode == HttpStatus.forbidden) {
    return pastedLink
        ? 'This link is wrong or needs a login (HTTP $statusCode). The app can only download public files: '
              'check the link, or download the file on a computer, copy it to the phone and use '
              '"Import model files…".'
        : 'This link is not public (HTTP $statusCode). The file may not be online yet: please try again later.';
  }
  if (statusCode != HttpStatus.ok) {
    return 'Download failed (HTTP $statusCode). Try again later; if it keeps failing, download the file on a '
        'computer, copy it to the phone and use "Import model files…".';
  }
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

/// Absolute paths of the files [downloadToFile] is writing right now. Two
/// downloads of one file would share `<target>.part` (one truncates or
/// deletes it under the other, so one or both fail), which happens when the
/// download dialog is left with Back and the same file is downloaded again.
/// The single `.part` name is kept on purpose: a `.part` left behind by an
/// app kill is overwritten by the next download instead of piling up.
final Set<String> _activeDownloadTargets = {};

/// Deletes the `.part` files in [dirs]: a download or import that the app
/// kill (force-stop, swipe from Recents, low memory, reboot) cut off never
/// reaches its own cleanup, and the half file (up to 1.2 GB for BioCLIP 2.5)
/// stays hidden: the model lists and the storage line count only finished
/// files. Must run only while no download or import is writing, so it is
/// called once at start ([deleteLeftoverModelPartFiles]). Returns the count.
int deleteLeftoverPartFiles(List<Directory> dirs) {
  var deleted = 0;
  for (final dir in dirs) {
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(followLinks: false).whereType<File>()) {
      if (!f.path.endsWith('.part')) continue;
      try {
        f.deleteSync();
        deleted++;
      } catch (e) {
        logSwallowed('model_part_cleanup', e);
      }
    }
  }
  return deleted;
}

/// Run once at start, before any screen can start a download. The folders
/// are the ones ModelCatalog.modelsDir and IdentificationAssets use (keep in
/// sync, as in renameFormerModelFiles).
Future<void> deleteLeftoverModelPartFiles() async {
  try {
    final base = (await getApplicationSupportDirectory()).path;
    deleteLeftoverPartFiles([
      Directory('$base/models'),
      Directory('$base/identification/models'),
      Directory('$base/identification/packs'),
    ]);
  } catch (e) {
    logSwallowed('model_part_cleanup', e);
  }
}

/// Streams [url] into [target] through a temporary `<target>.part` file and
/// renames only on success, so a dropped connection never leaves half a file
/// where the app looks for models. Files above [kMaxModelFileBytes] are
/// refused, from the size the server declares and while they stream.
/// [validate] checks the finished `.part` file (structure);
/// [expectedSha256], when given, must match. Reports
/// progress via [onProgress] (total is null when the server doesn't say);
/// [isCancelled] is checked between chunks. [pastedLink]: see
/// [downloadStatusMessage]. Throws with a plain-language message for the
/// app's own checks; network errors reach the caller as they are
/// ([plainModelError] words them).
Future<File> downloadToFile(
  Uri url,
  File target, {
  required Future<void> Function(File part) validate,
  String? expectedSha256,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
  bool Function()? isCancelled,
  bool pastedLink = false,
}) async {
  if (expectedSha256 != null && !isValidSha256(expectedSha256)) {
    throw Exception('The expected SHA-256 value must contain 64 hex digits.');
  }
  // Refused before the try below, whose catch would delete the running
  // download's `.part` file.
  final targetKey = target.absolute.path;
  if (!_activeDownloadTargets.add(targetKey)) {
    throw Exception('This file is already being downloaded. Wait for that download to finish, then check the list again.');
  }
  final partFile = File('${target.path}.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  int? total; // the size the server declares, when it does
  try {
    // GitHub release links and Hugging Face file links redirect to a file
    // host; HttpClient follows redirects on GET by default.
    final request = await client.getUrl(url);
    final response = await request.close();
    if (!redirectChainStaysHttps(url, response.redirects)) {
      throw Exception(
        'The link leads on to an unsafe address (not https), so the app does not download it. Use a link '
        'that starts with https, or download the file on a computer, copy it to the phone and use '
        '"Import model files…".',
      );
    }
    final problem = downloadStatusMessage(
      response.statusCode,
      mimeType: response.headers.contentType?.mimeType,
      pastedLink: pastedLink,
    );
    if (problem != null) throw Exception(problem);
    if (response.contentLength > 0) total = response.contentLength;
    if (total != null && total > kMaxModelFileBytes) throw Exception(sizeLimitMessage());
    if (total != null) await ensureModelStorageAvailable(target.parent.path, total);
    var received = 0;
    // Round 319: each chunk is written and waited for before the next one.
    // An IOSink (openWrite) took the chunks without waiting: when the
    // storage filled up, its write error stayed unseen, the download counted
    // on to the end and then waited for ever in flush(), and Cancel did
    // nothing (stress test 2026-10-20). Waiting for each write also stops
    // the network while the storage is slow, instead of buffering in memory.
    final out = await partFile.open(mode: FileMode.write);
    try {
      // The timeout is BETWEEN chunks: a dead connection errors out (and a
      // stalled stream would otherwise also never reach the cancel check).
      final data = response.timeout(
        const Duration(seconds: 30),
        onTimeout: (s) => s.addError(
          Exception('The connection stopped (no data for 30 seconds). Check the internet connection and try again.'),
        ),
      );
      await for (final chunk in data) {
        if (isCancelled?.call() ?? false) throw Exception('Download cancelled.');
        final nextReceived = received + chunk.length;
        if (nextReceived > kMaxModelFileBytes) throw Exception(sizeLimitMessage());
        await out.writeFrom(chunk);
        received = nextReceived;
        onProgress?.call(received, total);
      }
    } finally {
      await out.close();
    }
    if (received == 0) throw Exception('The server returned an empty file.');
    await validate(partFile);
    if (expectedSha256 != null) {
      final actual = (await sha256.bind(partFile.openRead()).first).toString();
      if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
        // The checksum differs: a damaged download, or the file on the
        // server was replaced by a newer export than the app's list knows.
        throw Exception('The downloaded file is damaged or not the expected version. Please try again.');
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
    if (isNoSpaceLeft(e)) {
      // The technical text for a problem report; the user gets plain words
      // with the amount to free (read after the half file was deleted).
      logSwallowed('model_download_no_space', e);
      throw Exception(await _noSpaceMessage(target.parent.path, total));
    }
    rethrow;
  } finally {
    _activeDownloadTargets.remove(targetKey);
    client.close();
  }
}

/// The message for a download stopped by full storage. [total] is the size
/// the server declared (null when it did not say); the amount uses the same
/// margin as the check before the download.
Future<String> _noSpaceMessage(String dirPath, int? total) async {
  final free = (await DeviceStorage.read(path: dirPath)).freeBytes;
  final more = total == null || free == null ? 0 : modelStorageNeededBytes(total) - free;
  return 'Not enough free storage: the download stopped. '
      '${more > 0 ? 'About ${formatBytes(more)} more is needed. ' : ''}'
      'Delete some files (for example old sessions), then try again.';
}
