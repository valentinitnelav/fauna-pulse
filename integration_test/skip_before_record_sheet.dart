// FaunaPulse (round 298): device checks tap REC and expect the recording to start at once;
// the "Before you record" sheet would wait for its Start button. Call this at the start of a
// check: it switches the sheet off and puts the phone's own choice back afterwards.

import 'package:fauna_pulse/fauna_pulse/widgets/before_record_sheet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> skipBeforeRecordSheet() async {
  final prefs = await SharedPreferences.getInstance();
  final before = prefs.getBool(kBeforeRecordSheetKey);
  await prefs.setBool(kBeforeRecordSheetKey, false);
  addTearDown(() async {
    if (before == null) {
      await prefs.remove(kBeforeRecordSheetKey);
    } else {
      await prefs.setBool(kBeforeRecordSheetKey, before);
    }
  });
}
