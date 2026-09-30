// IdentifyPrefs persistence (round 262: the "Square crops" switch).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';

void main() {
  test('square crops default on, survive save and load, and reach the run record', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await IdentifyPrefs.load();
    expect(p.squareCrops, isTrue);
    expect(p.toJson()['square_crops'], isTrue);
    p
      ..squareCrops = false
      ..margin = 0.1;
    await p.save();
    final back = await IdentifyPrefs.load();
    expect(back.squareCrops, isFalse);
    expect(back.margin, closeTo(0.1, 1e-9));
    expect(back.toJson()['square_crops'], isFalse);
  });
}
