// FaunaPulse (round 242): on-device check of BioCLIP on the GPU.
//
// 1. Loads every identification model the phone has (⋮ → AI models → Import
//    model…; files/identification/models/) once with the GPU asked for and
//    once on the CPU, and for each prints which engine it really ran on, why
//    the GPU was not used (if so), the GPU/CPU agreement of the GPU check, the
//    load time and the time per crop over a few synthetic crops (the time does
//    not depend on the picture).
// 2. With the first model that runs on the GPU: "Identify organisms" on the
//    session photo_visits_check_test.dart made (run that first), once on the
//    GPU and once on the CPU, comparing every crop's embedding (cosine) and each
//    visit's answer. That session's identification files are rewritten.
// 3. Round 250, is the speed on the Identify screen real? Every timed crop is measured by
//    three clocks: the app's (a Stopwatch around each call, what the screen shows), the
//    plugin's (System.nanoTime around the model, the "ms" of each reply) and the phone's wall
//    clock (the TIMING start/end lines; a test's print() goes to the PC, not to logcat). On
//    the Xiaomi (round 250) they agreed to 0.01 s per crop. The identification in step 2
//    also reports how much of its time the model took.
// 4. Round 264 (BioCLIP 2.5): --dart-define=MODEL=<part of a file name> tests only the matching
//    models; --dart-define=SESSION=<session folder name> identifies that session from the app's
//    sessions folder in step 2 instead of the photo_visits_check one (only new files named after
//    the model and the pack are written); the pack is the first one built for the model's
//    embedding size (BioCLIP 2 packs have 768 numbers per name, BioCLIP 2.5 packs 1024) whose file
//    name contains --dart-define=PACK=<part of a file name> (default: any).
// 5. Round 266 (fixed-class classifiers, e.g. insectDCT): a model whose class list (the .fpack
//    with the model's file name, kind "classes") is on the phone loads with raw scores
//    (normalize: false), and step 2 uses that class list; cosines are computed with the
//    vectors' lengths, since raw scores are not unit vectors.
// Run:  flutter test integration_test/bioclip_gpu_check_test.dart -d <serial> --no-uninstall
//       e.g. --dart-define=MODEL=bioclip-25 --dart-define=SESSION=bumblebee-2 --dart-define=BIOCLIP_GPU=false
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Keep the phone on the charger; the check keeps the screen on.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _crops = 6;

// --dart-define=BIOCLIP_GPU=false: CPU only (a phone whose GPU run would be
// killed for lack of memory, round 243).
const _tryGpu = bool.fromEnvironment('BIOCLIP_GPU', defaultValue: true);
const _modelFilter = String.fromEnvironment('MODEL');
const _sessionName = String.fromEnvironment('SESSION');
const _packFilter = String.fromEnvironment('PACK');
// --dart-define=THREADS=4: CPU threads of step 1's CPU rows (default 0 = the app's automatic choice).
const _threads = int.fromEnvironment('THREADS');

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BioCLIP on the GPU and on the CPU on this phone', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final models = [
      for (final m in await IdentificationAssets.listModels())
        if (m.path.split('/').last.contains(_modelFilter)) m,
    ];
    expect(models, isNotEmpty, reason: 'import a BioCLIP model on the Identify screen first');
    final rng = Random(7);
    final packs = await IdentificationAssets.listPacks();
    // Round 266: the class list of a classifier carries the model file's name.
    Future<File?> classListOf(File model) async {
      final stem = stemOf(model.path.split('/').last);
      for (final p in packs) {
        if (stemOf(p.path.split('/').last) == stem && (await LabelPack.readHeader(p))['kind'] == 'classes') return p;
      }
      return null;
    }
    File? gpuModel;
    int? gpuModelDim;
    var gpuModelRaw = false;
    for (final m in models) {
      final raw = await classListOf(m) != null;
      for (final gpu in [if (_tryGpu) true, false]) {
        final t0 = await DeviceThermal.read();
        final info = await ImageEmbedder.load(m.path, useGpu: gpu, cpuThreads: _threads, normalize: !raw);
        final side = info.inputWidth * info.inputHeight * 3;
        final images = [
          for (var i = 0; i < _crops; i++) Uint8List.fromList(List.generate(side, (_) => rng.nextInt(256))),
        ];
        await ImageEmbedder.embed([images.first]); // warm-up
        final label = '${m.path.split('/').last} ${gpu ? 'GPU' : 'CPU'}';
        _log('TIMING $label start ${DateTime.now().toIso8601String()}');
        var appMs = 0;
        var nativeMs = 0.0;
        for (final img in images) {
          final sw = Stopwatch()..start();
          final b = await ImageEmbedder.embed([img]);
          appMs += sw.elapsedMilliseconds;
          nativeMs += b.ms;
          // The app's clock wraps the native one (plus the hand-over of the picture).
          expect(b.ms, lessThanOrEqualTo(sw.elapsedMilliseconds + 1));
        }
        _log('TIMING $label end ${DateTime.now().toIso8601String()}');
        final perCrop = appMs / _crops / 1000;
        await ImageEmbedder.close();
        if ((gpu && info.accelerator == 'GPU' || !_tryGpu) && gpuModel == null) {
          gpuModel = m;
          gpuModelDim = info.dim;
          gpuModelRaw = raw;
        }
        final t1 = await DeviceThermal.read();
        _log('EMBED ${m.path.split('/').last} asked ${gpu ? 'GPU' : 'CPU'}: ran on ${info.accelerator}'
            '${info.cpuThreads == null ? '' : ' (${info.cpuThreads} threads)'}, load ${(info.loadMs / 1000).toStringAsFixed(1)} s, '
            '${perCrop.toStringAsFixed(2)} s per crop (native clock ${(nativeMs / _crops / 1000).toStringAsFixed(2)} s), '
            'battery ${t0.batteryTempC} -> ${t1.batteryTempC} °C'
            '${info.gpuAgreement == null ? '' : ', GPU check agreement ${info.gpuAgreement!.toStringAsFixed(6)}'}'
            '${info.accelerationNote == null ? '' : '; GPU not used: ${info.accelerationNote}'}');
      }
    }

    // 2. Identification of a session on the GPU and on the CPU.
    final m = gpuModel;
    final external = (await getExternalStorageDirectory())!.path;
    final dir = Directory(_sessionName.isEmpty
        ? '$external/photo_visits_check/sessions/photo check'
        : '$external/sessions/$_sessionName');
    File? found = m == null || !gpuModelRaw ? null : await classListOf(m);
    for (final p in packs) {
      if (found != null) break;
      final h = await LabelPack.readHeader(p);
      if (p.path.split('/').last.contains(_packFilter) && h['dim'] == gpuModelDim && h['kind'] != 'classes') {
        found = p;
      }
    }
    if (m == null || found == null || !dir.existsSync()) {
      _log('IDENTIFY skipped: ${m == null ? 'no model ran on the GPU' : found == null ? 'no label pack for this model' : 'no session ${dir.path}'}');
      return;
    }
    final pack = found;
    _log('IDENTIFY ${dir.path} with ${m.path.split('/').last} + ${pack.path.split('/').last}');
    final name = m.path.split('/').last;
    Future<(List<Float32List>, Map, IdentifyResult)> identify(bool gpu) async {
      final info = await ImageEmbedder.load(m.path, useGpu: gpu, normalize: !gpuModelRaw);
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
          'the model ${res.modelTime.inMilliseconds / 1000} s of it '
          '(${(res.modelTime.inMilliseconds / max(res.embedded, 1) / 1000).toStringAsFixed(2)} s per crop), '
          '${summary['tracks_total']} track IDs');
      return (vectors, summary, res);
    }

    if (!_tryGpu) {
      final (_, cs, _) = await identify(false);
      for (final t in cs['tracks'] as List) {
        _log('  #${t['track_id']} CPU ${t['headline']} (${t['identified_rank']}) p=${t['p']}');
      }
      _logOwnClasses(dir, pack);
      return;
    }
    final (gv, gs, _) = await identify(true);
    final (cv, cs, _) = await identify(false);
    expect(gv.length, cv.length);
    // Cosine with the vectors' lengths (round 266: a classifier's raw scores are not unit vectors).
    double dot(Float32List a, Float32List b) {
      var ab = 0.0, aa = 0.0, bb = 0.0;
      for (var k = 0; k < a.length; k++) {
        ab += a[k] * b[k];
        aa += a[k] * a[k];
        bb += b[k] * b[k];
      }
      return ab / sqrt(aa * bb);
    }
    final cos = [for (var i = 0; i < gv.length; i++) dot(gv[i], cv[i])];
    _log('CROPS ${cos.length}: GPU vs CPU cosine min ${cos.reduce(min).toStringAsFixed(5)}, '
        'mean ${(cos.reduce((a, b) => a + b) / cos.length).toStringAsFixed(5)}');
    // Round 250: the GPU computes every crop anew (a stale or repeated result would make two
    // crops' vectors identical), and each GPU vector is nearest to its own crop's CPU vector
    // (reported only: two near-identical crops of the same insect may swap).
    var sameGpu = 0.0;
    var ownNearest = 0;
    for (var i = 0; i < gv.length; i++) {
      var nearest = 0;
      for (var j = 0; j < gv.length; j++) {
        if (j != i) sameGpu = max(sameGpu, dot(gv[i], gv[j]));
        if (dot(gv[i], cv[j]) > dot(gv[i], cv[nearest])) nearest = j;
      }
      if (nearest == i) ownNearest++;
    }
    _log('CROPS distinct: closest pair of GPU vectors cosine ${sameGpu.toStringAsFixed(5)}; '
        '$ownNearest of ${gv.length} GPU vectors nearest to their own crop\'s CPU vector');
    expect(sameGpu, lessThan(0.99999));
    final gt = {for (final t in gs['tracks'] as List) t['track_id']: t};
    for (final t in cs['tracks'] as List) {
      final g = gt[t['track_id']];
      _log('  #${t['track_id']} CPU ${t['headline']} (${t['identified_rank']}) p=${t['p']} | '
          'GPU ${g?['headline']} (${g?['identified_rank']}) p=${g?['p']}');
      expect(g?['headline'], t['headline']);
    }
    expect(cos.reduce(min), greaterThan(0.99));
    _logOwnClasses(dir, pack);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

/// Round 266: a classifier's own class per track ID (written by the last identification).
void _logOwnClasses(Directory dir, File pack) {
  final f = IdentificationPaths(dir).tracksJson(stemOf(pack.path.split('/').last));
  for (final t in (jsonDecode(f.readAsStringSync())['tracks'] as List).cast<Map>()) {
    if (t['model_class'] case {'name': final name, 'p': final p}) _log('  #${t['track_id']} own class $name p=$p');
  }
}
