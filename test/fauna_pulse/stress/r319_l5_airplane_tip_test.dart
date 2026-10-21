// Round 319 (L5f, report item 19): with airplane mode already on, the radios
// tip no longer asks to turn airplane mode on; it names the radio still on.

import 'package:fauna_pulse/fauna_pulse/models/phone_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('airplane mode on with Wi-Fi on: turn Wi-Fi off', () {
    const s = PhoneState(airplaneMode: true, wifiOn: true, bluetoothOn: false);
    expect(s.tips.single.text, 'Airplane mode is on, but Wi-Fi is still on. Turn Wi-Fi off to save battery, unless you need it.');
    expect(s.tips.single.page, 'airplane');
  });

  test('airplane mode on with Bluetooth on: turn Bluetooth off', () {
    const s = PhoneState(airplaneMode: true, wifiOn: false, bluetoothOn: true);
    expect(
      s.tips.single.text,
      'Airplane mode is on, but Bluetooth is still on. Turn Bluetooth off to save battery, unless you need it.',
    );
  });

  test('airplane mode on with both on: one tip names both', () {
    const s = PhoneState(airplaneMode: true, wifiOn: true, bluetoothOn: true);
    expect(
      s.tips.single.text,
      'Airplane mode is on, but Wi-Fi and Bluetooth are still on. Turn them off to save battery, unless you need them.',
    );
  });

  test('airplane mode off or unknown: the old advice stays', () {
    expect(
      const PhoneState(airplaneMode: false, wifiOn: true).tips.single.text,
      'On: mobile network, Wi-Fi. Radios use energy: for the field, turn on airplane mode '
      '(flight mode) and keep Wi-Fi and Bluetooth off.',
    );
    expect(const PhoneState(wifiOn: true).tips.single.text, startsWith('On: Wi-Fi. Radios use energy'));
  });
}
