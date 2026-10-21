// Round 319 part 2 (S2d): a model download with airplane mode on. Phone
// test PA3 (a-iii): with airplane mode on and Wi-Fi off, the download dialog
// said "Could not reach the server. Check that the phone is connected to the
// internet (Wi-Fi or mobile data), then try again." and did not say that
// airplane mode was the reason. The dialogs now read the phone's state
// (PhoneSettings.read, the same reading as the "Before you record" tips)
// after a network error. With Wi-Fi turned on again inside airplane mode
// (PA3 a-iv), airplane mode is not the reason, so the general text stays.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_kind.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_security.dart' show plainModelError;
import 'package:fauna_pulse/fauna_pulse/models/phone_state.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/download_files_dialog.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/download_model_dialog.dart';

const _airplaneText =
    'Could not reach the server: airplane mode is on. Turn off airplane mode or turn on Wi-Fi, then try again.';
const _generalText =
    'Could not reach the server. Check that the phone is connected to the internet (Wi-Fi or mobile data), '
    'then try again.';
const _lookup = SocketException("Failed host lookup: 'huggingface.co'");

class _FakePaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => '/data/user/0/app/files';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('r319b S2d: the network error names airplane mode', () {
    test('plain words for each phone state', () {
      const airplane = PhoneState(airplaneMode: true, wifiOn: false);
      expect(plainModelError(_lookup, phone: airplane), _airplaneText);
      expect(plainModelError(const HandshakeException('x'), phone: airplane), _airplaneText);
      // Wi-Fi on again inside airplane mode (PA3 a-iv): not the reason.
      expect(plainModelError(_lookup, phone: const PhoneState(airplaneMode: true, wifiOn: true)), _generalText);
      expect(plainModelError(_lookup, phone: const PhoneState(airplaneMode: false, wifiOn: false)), _generalText);
      // Unknown (not Android, or the reading failed).
      expect(plainModelError(_lookup, phone: const PhoneState()), _generalText);
      expect(plainModelError(_lookup), _generalText);
      // Not a network error: the phone state does not change the words.
      expect(plainModelError(Exception('Download cancelled.'), phone: airplane), 'Download cancelled.');
    });

    testWidgets('download dialog (Download buttons of the list)', (tester) async {
      PathProviderPlatform.instance = _FakePaths();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const thermal = MethodChannel('faunapulse/thermal');
      messenger.setMockMethodCallHandler(thermal, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(thermal, null));
      var phoneReads = 0;
      final f = DownloadFile(name: 'flatbug-n_640_fp16.tflite', url: Uri.parse('https://example.org/f'), bytes: 5659266);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => DownloadFilesDialog(
                  title: 'flat-bug (small)',
                  description: 'The detection model.',
                  files: [f],
                  download: (f, onProgress, isCancelled) async => throw _lookup,
                  readPhoneState: () async {
                    phoneReads++;
                    return const PhoneState(airplaneMode: true, wifiOn: false);
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(phoneReads, 0, reason: 'read only after a network error');
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.text('⚠ $_airplaneText'), findsOneWidget);
      expect(phoneReads, 1);
    });

    testWidgets('"Download from a link" dialog', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DownloadModelDialog(
                  download: (url, {onProgress, isCancelled}) async => throw _lookup,
                  onPhoneAs: (name) async => const <ModelFileKind>[],
                  readPhoneState: () async => const PhoneState(airplaneMode: true, wifiOn: false),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'https://example.org/r/flatbug-n_640_fp16.tflite');
      await tester.pump();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Download')));
      await tester.pumpAndSettle();
      expect(find.textContaining(_airplaneText), findsOneWidget);
    });
  });
}
