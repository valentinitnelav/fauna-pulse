// Tests for the download helpers that need no server (round 314): the
// plain-words reason for an answer the app cannot use, and the Hugging Face
// file page link turned into the file's own link.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/file_download.dart';

void main() {
  group('downloadStatusMessage', () {
    test('a file answer is used', () {
      expect(downloadStatusMessage(200), isNull);
      expect(downloadStatusMessage(200, mimeType: 'application/octet-stream'), isNull);
    });

    test('a file not online yet is explained in plain words (r278)', () {
      expect(
        downloadStatusMessage(404),
        'Nothing was found at this link (HTTP 404). The file may not be online yet: please try again later.',
      );
    });

    test('a private or missing Hugging Face repository (401, 403) too (r314)', () {
      for (final code in [401, 403]) {
        expect(
          downloadStatusMessage(code),
          'This link is not public (HTTP $code). The file may not be online yet: please try again later.',
        );
      }
    });

    test('other answers keep their code', () {
      expect(downloadStatusMessage(500), 'Download failed (HTTP 500).');
    });

    test('a web page instead of the file is refused', () {
      expect(downloadStatusMessage(200, mimeType: 'text/html'), contains('opens a web page'));
    });
  });

  group('directFileUri', () {
    test('a Hugging Face file page link becomes the file link', () {
      expect(
        directFileUri(Uri.parse('https://huggingface.co/owner/repo/blob/main/m_640_fp16.tflite')).toString(),
        'https://huggingface.co/owner/repo/resolve/main/m_640_fp16.tflite',
      );
    });

    test('the query is kept', () {
      expect(
        directFileUri(Uri.parse('https://huggingface.co/owner/repo/blob/main/m.tflite?download=true')).toString(),
        'https://huggingface.co/owner/repo/resolve/main/m.tflite?download=true',
      );
    });

    test('a file link and other hosts are unchanged', () {
      for (final link in [
        'https://huggingface.co/owner/repo/resolve/0123abcd/m.tflite',
        'https://github.com/owner/repo/blob/main/m.tflite',
        'https://example.org/owner/repo/blob/main/m.tflite',
      ]) {
        expect(directFileUri(Uri.parse(link)).toString(), link);
      }
    });
  });
}
