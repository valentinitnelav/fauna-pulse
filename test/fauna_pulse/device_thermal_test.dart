// Tests for the round-170 (perf review E7) DeviceThermal sample coalescing:
// the thermal and power timers tick in the same instant, so their reads must
// share ONE native channel call, and a reading younger than the cache window
// is served without touching the channel at all (Android's getThermalHeadroom
// answers NaN when polled faster than ~1/s).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('faunapulse/thermal');

  var nativeCalls = 0;
  Object? Function()? nativeResponse;
  var fakeClock = Duration.zero;

  setUp(() {
    nativeCalls = 0;
    nativeResponse = () => <String, dynamic>{
      'batteryTempC': 31.5,
      'thermalStatus': 'none',
      'batteryCurrentUa': 250000,
      'batteryVoltageMv': 4000,
      'isCharging': false,
    };
    fakeClock = Duration.zero;
    DeviceThermal.resetForTesting();
    DeviceThermal.now = () => fakeClock;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls++;
          return nativeResponse!();
        });
  });

  tearDown(() {
    DeviceThermal.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('concurrent callers share one in-flight channel call', () async {
    final readings = await Future.wait([
      DeviceThermal.read(),
      DeviceThermal.read(),
    ]);
    expect(nativeCalls, 1);
    expect(readings[0].batteryTempC, 31.5);
    expect(identical(readings[0], readings[1]), isTrue);
  });

  test('a reading inside the cache window is served without a channel call',
      () async {
    await DeviceThermal.read();
    fakeClock = DeviceThermal.cacheWindow - const Duration(milliseconds: 1);
    final second = await DeviceThermal.read();
    expect(nativeCalls, 1);
    expect(second.batteryTempC, 31.5);
  });

  test('past the cache window a fresh sample is fetched', () async {
    await DeviceThermal.read();
    fakeClock = DeviceThermal.cacheWindow;
    nativeResponse = () => <String, dynamic>{'batteryTempC': 40.0};
    final second = await DeviceThermal.read();
    expect(nativeCalls, 2);
    expect(second.batteryTempC, 40.0);
  });

  test('a channel error yields an empty reading and is cached too', () async {
    nativeResponse = () => throw PlatformException(code: 'boom');
    final first = await DeviceThermal.read();
    expect(first.batteryTempC, isNull);
    // Inside the window the failure is not re-hammered.
    final second = await DeviceThermal.read();
    expect(nativeCalls, 1);
    expect(second.batteryTempC, isNull);
    // Past the window the channel is tried again and can recover.
    fakeClock = DeviceThermal.cacheWindow;
    nativeResponse = () => <String, dynamic>{'batteryTempC': 33.0};
    final third = await DeviceThermal.read();
    expect(nativeCalls, 2);
    expect(third.batteryTempC, 33.0);
  });
}
