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

  // Round 346: memory and processor figures ride on the same reading.
  group('memory and cores busy', () {
    Map<String, dynamic> phone({required int cpuMs, required int uptimeMs, int? kernelFree = 1200000000}) =>
        <String, dynamic>{
          'batteryTempC': 31.5,
          'memTotalBytes': 4000000000,
          'memAvailBytes': 1500000000,
          'memAvailableKernelBytes': kernelFree,
          'lowMemoryBytes': 300000000,
          'appRssBytes': 900000000,
          'appCpuMs': cpuMs,
          'uptimeMs': uptimeMs,
          'cpuCount': 8,
        };

    test('free memory is the smaller of the two figures; cores need two readings', () async {
      nativeResponse = () => phone(cpuMs: 10000, uptimeMs: 100000);
      final first = await DeviceThermal.read();
      expect(first.memTotalBytes, 4000000000);
      expect(first.memFreeBytes, 1200000000);
      expect(first.memUsedBytes, 2800000000);
      expect(first.lowMemoryBytes, 300000000);
      expect(first.appMemoryBytes, 900000000);
      expect(first.cpuCount, 8);
      expect(first.appCpuCores, isNull);
      // 20 s of processor time in 10 s of clock = 2 cores busy.
      fakeClock = DeviceThermal.cacheWindow;
      nativeResponse = () => phone(cpuMs: 30000, uptimeMs: 110000);
      final second = await DeviceThermal.read();
      expect(second.appCpuCores, 2.0);
      // A 1 s reading of 4 cores moves the 10 s average a tenth of the way.
      fakeClock = DeviceThermal.cacheWindow * 2;
      nativeResponse = () => phone(cpuMs: 34000, uptimeMs: 111000);
      final third = await DeviceThermal.read();
      expect(third.appCpuCores, closeTo(2.2, 0.011));
      final json = third.toJson();
      expect(json['mem_free_bytes'], 1200000000);
      expect(json['app_cpu_ms'], 34000);
      expect(json['app_cpu_cores'], third.appCpuCores);
      expect(json['cpu_count'], 8);
      // After a long gap (a new run after idle time) the average starts afresh.
      fakeClock = DeviceThermal.cacheWindow * 3;
      nativeResponse = () => phone(cpuMs: 35000, uptimeMs: 111000 + DeviceThermal.cpuRestartGap.inMilliseconds + 1);
      final fourth = await DeviceThermal.read();
      expect(fourth.appCpuCores, isNull);
      fakeClock = DeviceThermal.cacheWindow * 4;
      nativeResponse = () => phone(cpuMs: 45000, uptimeMs: 111000 + DeviceThermal.cpuRestartGap.inMilliseconds + 10001);
      expect((await DeviceThermal.read()).appCpuCores, 1.0);
    });

    test('Android\'s figure alone when the kernel file is unreadable; nothing without the native figures', () async {
      nativeResponse = () => phone(cpuMs: 1, uptimeMs: 1, kernelFree: null);
      expect((await DeviceThermal.read()).memFreeBytes, 1500000000);
      fakeClock = DeviceThermal.cacheWindow;
      nativeResponse = () => <String, dynamic>{'batteryTempC': 31.5};
      final bare = await DeviceThermal.read();
      expect(bare.memFreeBytes, isNull);
      expect(bare.memUsedBytes, isNull);
      expect(bare.appCpuCores, isNull);
      expect(bare.toJson()['mem_total_bytes'], isNull);
    });
  });
}
