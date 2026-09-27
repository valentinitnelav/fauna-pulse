// FaunaPulse (round 242): on-device check of BioCLIP on the GPU.
//
// 1. Loads every identification model the phone has (Identify organisms →
//    Import…; files/identification/models/) once with the GPU asked for and
//    once on the CPU, and for each prints which engine it really ran on, why
//    the GPU was not used (if so), the GPU/CPU agreement of the GPU check, the
//    load time and the time per crop over a few synthetic crops (the time does
//    not depend on the picture).
// 2. With the first model that runs on the GPU: "Identify organisms" on the
//    session photo_visits_check_test.dart made (run that first), once on the
//    GPU and once on the CPU, comparing every crop's embedding (cosine) and each
//    visit's answer. That session's identification files are rewritten.
// Run:  flutter test integration_test/bioclip_gpu_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Keep the phone on the charger; the check keeps the screen on.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _crops = 6;

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BioCLIP on the GPU and on the CPU on this phone', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final models = await IdentificationAssets.listModels();
    expect(models, isNotEmpty, reason: 'import a BioCLIP model on the Identify screen first');
    final rng = Random(7);
    File? gpuModel;
    for (final m in models) {
      for (final gpu in [true, false]) {
        final t0 = await DeviceThermal.read();
        final info = await ImageEmbedder.load(m.path, useGpu: gpu);
        final side = info.inputWidth * info.inputHeight * 3;
        final images = [
          for (var i = 0; i < _crops; i++) Uint8List.fromList(List.generate(side, (_) => rng.nextInt(256))),
        ];
        await ImageEmbedder.embed([images.first]); // warm-up
        final sw = Stopwatch()..start();
        for (final img in images) {
          await ImageEmbedder.embed([img]);
        }
        final perCrop = sw.elapsedMilliseconds / _crops / 1000;
        await ImageEmbedder.close();
        if (gpu && info.accelerator == 'GPU') gpuModel ??= m;
        final t1 = await DeviceThermal.read();
        _log('EMBED ${m.path.split('/').last} asked ${gpu ? 'GPU' : 'CPU'}: ran on ${info.accelerator}'
            '${info.cpuThreads == null ? '' : ' (${info.cpuThreads} threads)'}, load ${(info.loadMs / 1000).toStringAsFixed(1)} s, '
            '${perCrop.toStringAsFixed(2)} s per crop, battery ${t0.batteryTempC} -> ${t1.batteryTempC} °C'
            '${info.gpuAgreement == null ? '' : ', GPU check agreement ${info.gpuAgreement!.toStringAsFixed(6)}'}'
            '${info.accelerationNote == null ? '' : '; GPU not used: ${info.accelerationNote}'}');
      }
    }

    // 2. Identification of a session on the GPU and on the CPU.
    final m = gpuModel;
    final packs = await IdentificationAssets.listPacks();
    final dir = Directory('${(await getExternalStorageDirectory())!.path}/photo_visits_check/sessions/photo check');
    if (m == null || packs.isEmpty || !dir.existsSync()) {
      _log('IDENTIFY skipped: ${m == null ? 'no model ran on the GPU' : packs.isEmpty ? 'no label pack' : 'no photo_visits_check session'}');
      return;
    }
    final pack = packs.first;
    final name = m.path.split('/').last;
    Future<(List<Float32List>, Map, IdentifyResult)> identify(bool gpu) async {
      final info = await ImageEmbedder.load(m.path, useGpu: gpu);
      expect(info.accelerator, gpu ? 'GPU' : 'CPU');
      final vectors = <Float32List>[];
      final job = IdentificationJob(
        embed: (List<Uint8List> rgb) async {
          final b = await ImageEmbedder.embed(rgb);
          final out = [for (var i = 0; i < b.count; i++) Float32List.fromList(b.vector(i))];
          vectors.addAll(out);
          return out;
        },
      );
      final res = await job.run(
        dir,
        settings: IdentifyRunSettings(
          modelName: name,
          modelId: stemOf(name),
          packName: pack.path.split('/').last,
          inputSize: info.inputWidth,
          dim: info.dim,
          accelerator: info.accelerator,
        ),
        packFile: pack,
        restart: true,
      );
      await ImageEmbedder.close();
      expect(res.error, isNull);
      final summary = jsonDecode(
        IdentificationPaths(dir).summaryJson(stemOf(pack.path.split('/').last)).readAsStringSync(),
      ) as Map;
      _log('IDENTIFY ${info.accelerator}: ${res.embedded} crops in ${res.elapsed.inMilliseconds / 1000} s, '
          '${summary['tracks_total']} track ids');
      return (vectors, summary, res);
    }

    final (gv, gs, _) = await identify(true);
    final (cv, cs, _) = await identify(false);
    expect(gv.length, cv.length);
    final cos = [
      for (var i = 0; i < gv.length; i++)
        [for (var k = 0; k < gv[i].length; k++) gv[i][k] * cv[i][k]].reduce((a, b) => a + b),
    ];
    _log('CROPS ${cos.length}: GPU vs CPU cosine min ${cos.reduce(min).toStringAsFixed(5)}, '
        'mean ${(cos.reduce((a, b) => a + b) / cos.length).toStringAsFixed(5)}');
    final gt = {for (final t in gs['tracks'] as List) t['track_id']: t};
    for (final t in cs['tracks'] as List) {
      final g = gt[t['track_id']];
      _log('  #${t['track_id']} CPU ${t['headline']} (${t['identified_rank']}) p=${t['p']} | '
          'GPU ${g?['headline']} (${g?['identified_rank']}) p=${g?['p']}');
      expect(g?['headline'], t['headline']);
    }
    expect(cos.reduce(min), greaterThan(0.99));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
