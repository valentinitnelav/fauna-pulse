// FaunaPulse (round 298): reads the phone settings that matter in the field and opens their
// settings pages (native side: MainActivity.readPhoneState / openPhoneSettings, on the
// `faunapulse/keepalive` channel). Best-effort: never throws.

import 'dart:io';

import 'package:flutter/services.dart';

import '../logging/app_error_hooks.dart';
import '../models/phone_state.dart';

class PhoneSettings {
  PhoneSettings._();

  static const MethodChannel _channel = MethodChannel('faunapulse/keepalive');

  /// The current phone state; all values unknown when it cannot be read.
  static Future<PhoneState> read() async {
    if (!Platform.isAndroid) return const PhoneState();
    try {
      return PhoneState.fromMap(await _channel.invokeMethod<Map<dynamic, dynamic>>('phoneState'));
    } catch (e) {
      logSwallowed('phone_state', e);
      return const PhoneState();
    }
  }

  /// Opens the settings page of a [PhoneTip.page]. Returns whether one opened.
  static Future<bool> open(String page) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openPhoneSettings', {'page': page}) ?? false;
    } catch (e) {
      logSwallowed('phone_settings_open', e);
      return false;
    }
  }
}
