// FaunaPulse (round 298): phone settings that matter in the field, and the tips shown for them.
//
// Idea and record keys from the sister app FaunaLapse (card 4, "Phone for the field"): a phone
// left on a flower for hours saves energy with its radios off, and must not be stopped by
// battery limits or kept awake by "Stay awake". Apps may only read these settings, so each tip
// comes with the settings page where the user can change it. Pure, so it is unit tested; the
// native side reads the values (MainActivity.readPhoneState).

/// One tip: what to change, and which settings page opens for it.
class PhoneTip {
  final String text;

  /// `airplane`, `location`, `developer`, `battery` or `app` (see MainActivity.openPhoneSettings).
  final String page;
  const PhoneTip(this.text, this.page);
}

class PhoneState {
  const PhoneState({
    this.airplaneMode,
    this.wifiOn,
    this.bluetoothOn,
    this.locationOn,
    this.stayAwake,
    this.batteryLimited,
    this.backgroundRestricted,
    this.batterySaver,
  });

  final bool? airplaneMode;
  final bool? wifiOn;
  final bool? bluetoothOn;
  final bool? locationOn;
  final bool? stayAwake;
  final bool? batteryLimited;
  final bool? backgroundRestricted;
  final bool? batterySaver;

  static PhoneState fromMap(Map<dynamic, dynamic>? m) => PhoneState(
    airplaneMode: m?['airplane_mode'] as bool?,
    wifiOn: m?['wifi_on'] as bool?,
    bluetoothOn: m?['bluetooth_on'] as bool?,
    locationOn: m?['location_on'] as bool?,
    stayAwake: m?['stay_awake_while_charging'] as bool?,
    batteryLimited: m?['battery_optimisation_on'] as bool?,
    backgroundRestricted: m?['background_restricted'] as bool?,
    batterySaver: m?['battery_saver_on'] as bool?,
  );

  /// The start record's `phone_state` block (FaunaLapse's keys, null when unknown).
  Map<String, dynamic> toJson() => {
    'airplane_mode': airplaneMode,
    'wifi_on': wifiOn,
    'bluetooth_on': bluetoothOn,
    'location_on': locationOn,
    'stay_awake_while_charging': stayAwake,
    'battery_optimisation_on': batteryLimited,
    'background_restricted': backgroundRestricted,
    'battery_saver_on': batterySaver,
  };

  /// What to change before a field session; empty when the phone is ready. Battery saver is
  /// recorded but not a tip (it slows the phone, but saves energy).
  List<PhoneTip> get tips {
    final radios = [
      if (airplaneMode == false) 'mobile network',
      if (wifiOn == true) 'Wi-Fi',
      if (bluetoothOn == true) 'Bluetooth',
    ];
    return [
      if (radios.isNotEmpty)
        PhoneTip(
          'On: ${radios.join(', ')}. Radios use energy: for the field, turn on airplane mode '
          '(flight mode) and keep Wi-Fi and Bluetooth off.',
          'airplane',
        ),
      if (locationOn == true)
        const PhoneTip(
          'Location is on, so other apps may use the GPS. Turn it off once the session '
          'position is set.',
          'location',
        ),
      if (stayAwake == true)
        const PhoneTip(
          'Stay awake is on (in Developer options): while the phone charges, also from a '
          'power bank, its screen never switches off by itself. Turn it off for the field.',
          'developer',
        ),
      if (batteryLimited == true)
        const PhoneTip(
          'Battery limits apply to FaunaPulse: some phones then stop long sessions. Allow '
          'it to run without limits.',
          'battery',
        ),
      if (backgroundRestricted == true)
        const PhoneTip(
          'FaunaPulse is restricted in the background: the phone may stop a session.',
          'app',
        ),
    ];
  }

  /// The line shown when nothing needs changing.
  static const readyText =
      'Airplane mode on; Wi-Fi, Bluetooth, location and Stay awake off; no battery '
      'limits for FaunaPulse: ready for the field.';
}
