// FaunaPulse (round 361): which heat sensors can the app itself read on this phone?
//
// The adb shell can read /sys/class/thermal (the chip, skin and battery sensors) on some
// phones, but the app runs under another security domain (untrusted_app) and may not.
// This check lists, from inside the app's own process, every thermal zone it can read
// (name and temperature in thousandths of a degree), the battery sysfs temperature, the
// cpu0 clock files, and what the framework gives (battery temperature, thermal status,
// thermal headroom), so the possibilities of a phone model are known before any feature
// relies on them.
// Run:  flutter test integration_test/thermal_zones_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ignore: avoid_print
void _log(String s) => print(s);

String _read(String path) {
  try {
    return File(path).readAsStringSync().trim();
  } on FileSystemException catch (e) {
    return 'ERR ${e.osError?.message ?? e.message}';
  } catch (e) {
    return 'ERR $e';
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Heat sensors readable by the app process', (tester) async {
    for (final root in ['/sys/class/thermal', '/sys/devices/virtual/thermal']) {
      List<FileSystemEntity> entries;
      try {
        entries = Directory(root).listSync()..sort((a, b) => a.path.compareTo(b.path));
      } catch (e) {
        _log('DIR $root: cannot list ($e)');
        continue;
      }
      var readable = 0, total = 0;
      for (final e in entries) {
        final name = e.path.split('/').last;
        if (!name.startsWith('thermal_zone')) continue;
        total++;
        final type = _read('${e.path}/type');
        final temp = _read('${e.path}/temp');
        if (!temp.startsWith('ERR')) readable++;
        _log('ZONE $root $name $type $temp');
      }
      _log('DIR $root: $readable of $total zones readable');
    }
    for (final p in [
      '/sys/class/power_supply/battery/temp',
      '/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq',
      '/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq',
    ]) {
      _log('FILE $p ${_read(p)}');
    }
    final r = await DeviceThermal.read();
    _log('FRAMEWORK battery=${r.batteryTempC} status=${r.thermalStatus} headroom=${r.thermalHeadroom} '
        'cpus=${r.cpuCount}');
  });
}
