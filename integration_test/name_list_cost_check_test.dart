// FaunaPulse (round 379): on-device cost of one name list: the time and the memory peak of
// reading its header (as every listing does), of loading it whole, and of scoring sessions with
// it ("Update results", the whole list, the phone's own identification settings). Made to
// compare a large list with a smaller one (North America with 56,446 names against Europe),
// one list per app start: the memory peak of a process does not go back down, so a second list
// in the same run would hide its own peak.
//
// Needs on the phone: the name list PACK in the app's identification/packs folder, and the
// sessions SESSIONS (folders under sessions/, separated by "+") with stored crops of MODEL. The
// results of PACK in those sessions are written as a normal run writes them.
// HEADER_ONLY=true decodes the header without the size limit of the app and stops there: the
// cost of a header the app refuses today (a world list), nothing else is run.
// Memory: ProcessInfo.currentRss (the app's resident memory, Dart and native together) sampled
// every 100 ms; "peak" = the highest sample during the step, "before" = the sample at its start.
// Run it as an installed build (no uninstall risk):
//   flutter build apk --debug --target-platform android-arm64 -t integration_test/name_list_cost_check_test.dart \
//     --dart-define=PACK=<file>.fpack --dart-define=SESSIONS=<folder>+<folder>
//   adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk   (stop if not "Success")
//   adb -s <device-id> shell am start -n com.faunapulse.app/com.ultralytics.yolo.MainActivity
//   adb -s <device-id> logcat -s flutter:I     (lines COST, then "All tests passed!")
// Afterwards rebuild and reinstall the normal app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _packName = String.fromEnvironment('PACK');
const _sessions = String.fromEnvironment('SESSIONS');
const _modelName = String.fromEnvironment('MODEL', defaultValue: 'bioclip-2_224_fp16.tflite');
const _headerOnly = bool.fromEnvironment('HEADER_ONLY');

// ignore: avoid_print
void _log(String s) => print('COST $s');

int _mb(int bytes) => bytes ~/ (1 << 20);

int? _memAvailable() {
  for (final line in File('/proc/meminfo').readAsLinesSync()) {
    if (line.startsWith('MemAvailable:')) return int.parse(line.split(RegExp(r'\s+'))[1]) * 1024;
  }
  return null;
}

/// Runs [step], sampling the resident memory every 100 ms; logs its time and memory.
Future<T> _measured<T>(String label, Future<T> Function() step) async {
  final before = ProcessInfo.currentRss, availBefore = _memAvailable() ?? 0;
  var peak = before, minAvail = availBefore;
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > peak) peak = rss;
    final a = _memAvailable();
    if (a != null && a < minAvail) minAvail = a;
  });
  final sw = Stopwatch()..start();
  try {
    return await step();
  } finally {
    timer.cancel();
    _log(
      '$label: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, memory before ${_mb(before)} MB, '
      'peak ${_mb(peak)} MB (+${_mb(peak - before)} MB), phone free at least ${_mb(minAvail)} MB of ${_mb(availBefore)} MB',
    );
  }
}

/// The header of [pack] decoded as the app decodes it, without the app's size limit.
Map<String, dynamic> _decodeRawHeader(File pack) {
  final raf = pack.openSync();
  try {
    raf.readSync(4);
    final len = ByteData.sublistView(raf.readSync(4)).getUint32(0, Endian.little);
    return jsonDecode(utf8.decode(raf.readSync(len))) as Map<String, dynamic>;
  } finally {
    raf.closeSync();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the cost of one name list on this phone', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final pack = File('${(await IdentificationAssets.packsDir()).path}/$_packName');
    expect(pack.existsSync(), isTrue, reason: 'no name list $_packName in identification/packs');
    await tester.runAsync(() async {
      _log('$_packName: ${_mb(pack.lengthSync())} MB, ${Platform.numberOfProcessors} cores, '
          'phone memory ${_mb(IdentificationJob.totalMemoryBytes() ?? 0)} MB');
      if (_headerOnly) {
        final h = await _measured('raw header decode', () => Isolate.run(() => _decodeRawHeader(File(pack.path)).length));
        _log('header keys $h');
        return;
      }
      for (var i = 0; i < 2; i++) {
        await _measured('header ${i + 1}', () => LabelPack.readHeader(pack));
      }
      final rows = await _measured('whole load', () async => (await LabelPack.load(pack)).rows);
      _log('rows $rows');
      final prefs = await IdentifyPrefs.load();
      final root = '${(await getExternalStorageDirectory())!.path}/sessions';
      for (final name in _sessions.split('+').where((s) => s.isNotEmpty)) {
        final session = Directory('$root/$name');
        expect(session.existsSync(), isTrue, reason: 'no session $name');
        final summary = await _measured(
          'score $name',
          () => IdentificationJob.scoreSession(
            session,
            modelName: _modelName,
            modelId: stemOf(_modelName),
            packFile: pack,
            settings: {...prefs.toJson(), 'model': _modelName, 'pack': _packName, 'name_list_scope': 'all'},
          ),
        );
        _log(
          '$name: tracks ${summary['tracks_total']}, by rank ${summary['by_identified_rank']}, '
          'no organism ${summary['no_organism']}, workers ${IdentificationJob.scoringWorkers(1 << 20)} at most',
        );
      }
    });
  }, timeout: const Timeout(Duration(minutes: 40)));
}
