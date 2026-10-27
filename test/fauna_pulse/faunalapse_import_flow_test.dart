// Round 330: "Don't show again" in the window before the FaunaLapse zip picker.

import 'package:fauna_pulse/fauna_pulse/screens/faunalapse_import_flow.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Returns no files, as when the user backs out of the picker.
class _CancelledPicker extends FilePicker {
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    return null;
  }
}

void main() {
  testWidgets("the import window stays away after Don't show again", (tester) async {
    SharedPreferences.setMockInitialValues({});
    final picker = _CancelledPicker();
    FilePicker.platform = picker;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );

    // First time: the window explains, the tick is saved even with Cancel.
    final first = pickAndImportFaunaLapse(context);
    await tester.pumpAndSettle();
    expect(find.text('Import a FaunaLapse session'), findsOneWidget);
    await tester.tap(find.text("Don't show again"));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await first, isNull);
    expect(picker.calls, 0);
    expect((await SharedPreferences.getInstance()).getBool(kHideFaunaLapseImportInfoPrefKey), isTrue);

    // Next time: straight to the picker.
    final second = pickAndImportFaunaLapse(context);
    await tester.pumpAndSettle();
    expect(find.text('Import a FaunaLapse session'), findsNothing);
    expect(await second, isNull);
    expect(picker.calls, 1);
  });
}
