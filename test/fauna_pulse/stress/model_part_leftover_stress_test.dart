// Stress test (2026-10-20, resource leak): a model download cut off by an
// app kill (force-stop, swipe from Recents, reboot) never reaches the cleanup
// in downloadToFile, so `<model>.part` (up to 1.2 GB) stayed hidden in the
// model folders. Fixed 2026-10-20: the app deletes such files at start.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/file_download.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePaths extends PathProviderPlatform {
  final String path;
  _FakePaths(this.path);

  @override
  Future<String?> getApplicationSupportPath() async => '$path/support';

  @override
  Future<String?> getTemporaryPath() async => '$path/cache';
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('part_leftover'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('deletes only .part files, keeps finished models and class lists', () {
    final models = Directory('${tmp.path}/models')..createSync();
    final packs = Directory('${tmp.path}/packs')..createSync();
    File('${models.path}/bioclip-2.5_224_fp16.tflite.part').writeAsBytesSync(List.filled(1000, 1));
    File('${models.path}/insectdct-v8s_640_fp16.tflite').writeAsStringSync('model');
    File('${packs.path}/bioclip-2_pollinator-orders-europe_v1.fpack').writeAsStringSync('pack');
    File('${packs.path}/bioclip-2_flower-visitors-32fam_v1.fpack.part').writeAsStringSync('half');
    // A folder named like a part file is not touched (only files).
    Directory('${models.path}/odd.part').createSync();

    final missing = Directory('${tmp.path}/does_not_exist');
    expect(deleteLeftoverPartFiles([models, packs, missing]), 2);

    final left = [
      for (final d in [models, packs]) ...d.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last),
    ]..sort();
    expect(left, [
      'bioclip-2_pollinator-orders-europe_v1.fpack',
      'insectdct-v8s_640_fp16.tflite',
      'odd.part',
    ]);
  });

  // Round 327: a pasted-link download is staged in the cache, so closing the app there leaves
  // the whole file (finished or not, up to 2 GB) where no screen counts or removes it.
  test('the start-up clean-up also empties the link download folder', () async {
    PathProviderPlatform.instance = _FakePaths(tmp.path);
    final staging = Directory('${tmp.path}/cache/link_download')..createSync(recursive: true);
    File('${staging.path}/my_model.tflite').writeAsStringSync('finished, not moved yet');
    File('${staging.path}/other.tflite.part').writeAsStringSync('half');
    final kept = File('${tmp.path}/cache/keep.txt')..writeAsStringSync('other cache file');
    await deleteLeftoverModelPartFiles();
    expect(staging.existsSync(), isFalse);
    expect(kept.existsSync(), isTrue);
  });
}
