// Tests for the download helpers that need no server (round 314): the
// plain-words reason for an answer the app cannot use, and the Hugging Face
// file page link turned into the file's own link.

import 'dart:async' show TimeoutException;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/file_download.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_security.dart' show plainModelError;

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

    test('a pasted link: check the link, as waiting does not help (r317)', () {
      expect(
        downloadStatusMessage(404, pastedLink: true),
        'Nothing was found at this link (HTTP 404). Check that the link is complete and correct.',
      );
      for (final code in [401, 403]) {
        final m = downloadStatusMessage(code, pastedLink: true)!;
        expect(m, startsWith('This link is wrong or needs a login (HTTP $code).'));
        expect(m, contains('"Import model files…"'));
        expect(m, isNot(contains('try again later')));
      }
    });

    test('other answers keep their code', () {
      expect(downloadStatusMessage(500), startsWith('Download failed (HTTP 500). Try again later'));
      expect(downloadStatusMessage(500), contains('"Import model files…"'));
    });

    test('a web page instead of the file is refused', () {
      expect(downloadStatusMessage(200, mimeType: 'text/html'), contains('opens a web page'));
    });
  });

  group('plainModelError (r317)', () {
    test("the app's own message loses only its leading \"Exception: \"", () {
      expect(plainModelError(Exception('Download cancelled.')), 'Download cancelled.');
    });

    test('no internet, a lost connection and a full phone say what to do', () {
      expect(
        plainModelError(const SocketException("Failed host lookup: 'huggingface.co'")),
        startsWith('Could not reach the server. Check that the phone is connected to the internet'),
      );
      expect(plainModelError(const HandshakeException('bad certificate')), startsWith('Could not reach the server.'));
      expect(plainModelError(TimeoutException('slow')), startsWith('Could not reach the server.'));
      expect(
        plainModelError(const HttpException('Connection closed while receiving data')),
        'The connection was lost during the download. Please try again.',
      );
      expect(
        plainModelError(const FileSystemException('No space left on device')),
        startsWith('Could not save the file on this phone.'),
      );
    });

    test('any other error: no technical text', () {
      expect(plainModelError(const FormatException('Label pack header is truncated')), 'The download failed. Please try again.');
      expect(plainModelError(StateError('x'), importing: true), 'The file could not be imported. Please try again.');
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
