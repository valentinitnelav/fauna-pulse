// Round 296: when a recording stops by itself (low battery, low storage).

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/session/session_guards.dart';

void main() {
  String? reason({
    int? battery = 50,
    bool? plugged = false,
    bool? charging = false,
    int? free = 10 << 30,
    int low = 15,
    int reserve = 200,
  }) => guardStopReason(
    batteryPercent: battery,
    isPlugged: plugged,
    isCharging: charging,
    freeBytes: free,
    lowBatteryPercent: low,
    storageReserveMb: reserve,
  );

  test('low battery stops only on the phone\'s own battery', () {
    expect(reason(battery: 16), isNull);
    expect(reason(battery: 15), 'low_battery');
    expect(reason(battery: 5, plugged: true), isNull, reason: 'a power bank keeps it going');
    expect(reason(battery: 5, charging: true), isNull);
    expect(reason(battery: 5, low: 0), isNull, reason: '0 = never');
    expect(reason(battery: null), isNull, reason: 'unknown level');
  });

  test('low storage stops below the reserve', () {
    expect(reason(free: 200 * 1024 * 1024), isNull);
    expect(reason(free: 200 * 1024 * 1024 - 1), 'storage_low');
    expect(reason(free: 0, reserve: 0), isNull, reason: '0 = never');
    expect(reason(free: null), isNull);
  });

  test('settings: defaults 15 % and 200 MB, saved, loaded and clamped', () {
    const c = SessionConfig();
    expect(c.lowBatteryStopPercent, 15);
    expect(c.storageReserveMb, 200);
    final j = c.copyWith(lowBatteryStopPercent: 20, storageReserveMb: 500).toJson();
    final back = SessionConfig.fromJson(j);
    expect(back.lowBatteryStopPercent, 20);
    expect(back.storageReserveMb, 500);
    expect(SessionConfig.fromJson({...j, 'lowBatteryStopPercent': 99, 'storageReserveMb': -5}).lowBatteryStopPercent, 50);
    expect(SessionConfig.fromJson({...j, 'storageReserveMb': -5}).storageReserveMb, 0);
    expect(SessionConfig.fromJson(const {}).lowBatteryStopPercent, 15);
    expect(SessionConfig.fromJson(const {}).storageReserveMb, 200);
  });
}
