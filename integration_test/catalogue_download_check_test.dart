// FaunaPulse (round 314): on-device check of the download list
// (assets/model_downloads.json) against the published files on Hugging Face.
//
// Every offered model file and name list up to MAX_MB megabytes is downloaded
// with the app's own downloadCatalogueFile (HTTPS redirects, SHA-256, the
// intake checks) into the folder its kind lives in. Then each file must be of
// the kind the list says (modelFileKind), each detection model must load and
// run once on a plain grey picture (CPU), each identification model must load
// (CPU) and give as many numbers per picture as its name lists expect, and a
// class list must name its classifier (header model_id = the model's file
// name), as the Identify screen demands. Larger files are skipped and logged.
//
// Best run in the side-by-side copy: a fresh copy has no models (like a new
// user's phone) and the installed app and its data are not touched:
//   ORG_GRADLE_PROJECT_debugIdSuffix=.check flutter build apk --debug \
//     -t integration_test/catalogue_download_check_test.dart --dart-define=MAX_MB=700
//   adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb -s <serial> shell am start -n com.faunapulse.app.check/com.ultralytics.yolo.MainActivity
//   adb -s <serial> logcat -v brief flutter:I '*:S'      (lines start with CATALOGUE)
// Remove the copy afterwards: adb -s <serial> uninstall com.faunapulse.app.check
// (that deletes only the copy's downloads). Use Wi-Fi: MAX_MB=700 fetches about 1 GB
// (BioCLIP 2 included, the 1.3 GB BioCLIP 2.5 model left out).
// On a Xiaomi phone (MIUI) a new app such as the copy needs a person to tap Install
// on "Install this app via USB?". Built without the suffix it installs over the
// app with `adb install -r` (data kept, no question when "Remember my choice" was
// ticked for it); the downloads then stay in the app, and the normal build must be
// installed again afterwards.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart' show stemOf;
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _maxMb = int.fromEnvironment('MAX_MB', defaultValue: 100);

// ignore: avoid_print
void _log(String s) => print('CATALOGUE $s');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every listed file downloads, has its kind and loads', (tester) async {
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final list = await ModelDownloads.load();
    final problems = <String>[];
    var ok = 0, skipped = 0;
    final grey = img.encodeJpg(img.fill(img.Image(width: 640, height: 640), color: img.ColorRgb8(128, 128, 128)));

    Future<File?> fetch(DownloadFile f, {required bool identification, required ModelFileKind kind}) async {
      final mb = f.bytes / 1e6;
      if (mb > _maxMb) {
        skipped++;
        _log('SKIP ${f.name} (${mb.toStringAsFixed(0)} MB > MAX_MB $_maxMb)');
        return null;
      }
      final watch = Stopwatch()..start();
      try {
        final file = await downloadCatalogueFile(f, identification: identification);
        final seconds = watch.elapsedMilliseconds / 1000;
        final got = await modelFileKind(file, f.name);
        if (got != kind) throw Exception('kept as ${got.label}, the list says ${kind.label}');
        _log('DOWNLOADED ${f.name} ${mb.toStringAsFixed(1)} MB in ${seconds.toStringAsFixed(1)} s from ${f.url.host}');
        return file;
      } catch (e) {
        problems.add('${f.name}: $e');
        _log('PROBLEM ${f.name}: $e');
        return null;
      }
    }

    for (final d in list.detectors) {
      final f = d.file;
      if (f == null) continue;
      final file = await fetch(f, identification: false, kind: ModelFileKind.detection);
      if (file == null) continue;
      final yolo = YOLO(modelPath: file.path, task: YOLOTask.detect, useGpu: false);
      try {
        await yolo.loadModel();
        final r = await yolo.predict(grey, includeAnnotatedImage: false);
        _log('RUNS ${f.name}: ${(r['boxes'] as List?)?.length ?? 0} boxes on a grey picture');
        ok++;
      } catch (e) {
        problems.add('${f.name} does not run: $e');
        _log('PROBLEM ${f.name} does not run: $e');
      } finally {
        await yolo.dispose();
      }
    }

    for (final d in list.identification) {
      final f = d.file;
      if (f == null) continue;
      final model = await fetch(f, identification: true, kind: ModelFileKind.identification);
      final headers = <String, Map<String, dynamic>>{};
      for (final l in d.nameLists) {
        final pack = await fetch(l.file, identification: true, kind: ModelFileKind.nameList);
        if (pack == null) continue;
        headers[l.file.name] = await LabelPack.readHeader(pack);
        if (l.classList && headers[l.file.name]!['model_id'] != stemOf(f.name)) {
          final p = '${l.file.name} names the model ${headers[l.file.name]!['model_id']}, not ${stemOf(f.name)}';
          problems.add(p);
          _log('PROBLEM $p');
        } else {
          ok++;
        }
      }
      if (model == null) continue;
      final classList = d.nameLists.any((l) => l.classList);
      try {
        final info = await ImageEmbedder.load(model.path, useGpu: false, normalize: !classList);
        for (final e in headers.entries) {
          final dim = (e.value['dim'] as num?)?.toInt();
          if (dim != null && dim != info.dim) throw Exception('${e.key} expects $dim numbers, the model gives ${info.dim}');
        }
        _log('LOADS ${f.name}: ${info.dim} numbers per picture, ${info.inputWidth} px, ${info.loadMs.toStringAsFixed(0)} ms');
        ok++;
      } catch (e) {
        problems.add('${f.name} does not load: $e');
        _log('PROBLEM ${f.name} does not load: $e');
      } finally {
        await ImageEmbedder.close();
      }
    }

    _log('DONE $ok ok, ${problems.length} problems, $skipped skipped (MAX_MB $_maxMb)');
    expect(problems, isEmpty);
  });
}
