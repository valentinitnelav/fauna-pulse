// Round 298: phone-for-the-field tips and the phone_state record block.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/phone_state.dart';

void main() {
  test('a ready phone has no tips', () {
    const ready = PhoneState(
      airplaneMode: true,
      wifiOn: false,
      bluetoothOn: false,
      locationOn: false,
      stayAwake: false,
      batteryLimited: false,
      backgroundRestricted: false,
      batterySaver: true,
    );
    expect(ready.tips, isEmpty);
  });

  test('each setting gives one tip with its settings page', () {
    final s = PhoneState.fromMap({
      'airplane_mode': false,
      'wifi_on': true,
      'bluetooth_on': false,
      'location_on': true,
      'stay_awake_while_charging': true,
      'battery_optimisation_on': true,
      'background_restricted': true,
      'battery_saver_on': false,
    });
    expect(s.tips.map((t) => t.page), ['airplane', 'location', 'developer', 'battery', 'app']);
    expect(s.tips.first.text, startsWith('On: mobile network, Wi-Fi.'));
    expect(s.toJson().keys, [
      'airplane_mode', 'wifi_on', 'bluetooth_on', 'location_on', 'stay_awake_while_charging',
      'battery_optimisation_on', 'background_restricted', 'battery_saver_on',
    ]);
    expect(s.toJson()['stay_awake_while_charging'], true);
  });

  test('unknown values give no tips', () {
    expect(const PhoneState().tips, isEmpty);
    expect(PhoneState.fromMap(null).toJson().values, everyElement(isNull));
  });
}
