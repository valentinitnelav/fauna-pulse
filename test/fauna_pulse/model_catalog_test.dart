// Tests for the download-model URL helper: only safe HTTPS links that
// point at a supported model file yield a file name; everything else is
// rejected so the dialog's Download button stays disabled. Round 150 widened
// "supported" to .tflite OR *_qnn.onnx (Snapdragon NPU exports) — plain .onnx
// stays rejected because the native layer cannot run it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/bundled_models.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_catalog.dart';

void main() {
  group('modelFileNameFromUrl', () {
    test('a GitHub release asset link yields the file name', () {
      expect(
        modelFileNameFromUrl(
          'https://github.com/valentinitnelav/fauna-pulse/releases/download/'
          'models-v1/arthropod_yolov11_int8.tflite',
        ),
        'arthropod_yolov11_int8.tflite',
      );
    });

    test('a query string is ignored', () {
      expect(
        modelFileNameFromUrl('https://host/models/m.tflite?token=abc'),
        'm.tflite',
      );
    });

    test('surrounding whitespace (a sloppy paste) is tolerated', () {
      expect(modelFileNameFromUrl('  https://host/m.tflite \n'), 'm.tflite');
    });

    test('case-insensitive extension', () {
      expect(modelFileNameFromUrl('https://host/M.TFLITE'), 'M.TFLITE');
    });

    test('a Snapdragon NPU export (*_qnn.onnx) is accepted (r150)', () {
      expect(
        modelFileNameFromUrl('https://host/models/yolo26n_qnn.onnx'),
        'yolo26n_qnn.onnx',
      );
    });

    test('rejects unsupported links, non-HTTPS schemes and garbage', () {
      expect(modelFileNameFromUrl('https://host/model.zip'), isNull);
      expect(modelFileNameFromUrl('https://github.com/user/repo'), isNull);
      expect(modelFileNameFromUrl('http://host/m.tflite'), isNull);
      expect(modelFileNameFromUrl('ftp://host/m.tflite'), isNull);
      expect(modelFileNameFromUrl('file:///sdcard/m.tflite'), isNull);
      expect(modelFileNameFromUrl('https:///m.tflite'), isNull);
      expect(modelFileNameFromUrl('not a url'), isNull);
      expect(modelFileNameFromUrl(''), isNull);
      // A plain ONNX export is NOT runnable by the native layer.
      expect(modelFileNameFromUrl('https://host/m.onnx'), isNull);
    });

    test('rejects decoded traversal, separators and unsafe names', () {
      expect(
        modelFileNameFromUrl('https://host/%2e%2e%2fsessions%2fevil.tflite'),
        isNull,
      );
      expect(modelFileNameFromUrl('https://host/a%5Cb.tflite'), isNull);
      expect(modelFileNameFromUrl('https://host/model%20one.tflite'), isNull);
      expect(modelFileNameFromUrl('https://host/model..tflite'), isNull);
    });
  });

  group('model file security', () {
    test('safe names and the one size limit are explicit', () {
      expect(isSafeModelBaseName('pollinator_v2-int8.tflite'), isTrue);
      expect(isSafeModelBaseName('detector_qnn.onnx'), isTrue);
      expect(isSafeModelBaseName('../detector.tflite'), isFalse);
      expect(isSafeModelBaseName('folder/detector.tflite'), isFalse);
      // Round 314: one limit for every model file and name list, a ceiling
      // the app sets (see kMaxModelFileBytes for why 2 GiB).
      expect(kMaxModelFileBytes, 2 * 1024 * 1024 * 1024);
      expect(
        sizeLimitMessage(),
        'The file is larger than 2.0 GB, the largest model file or name list the app can use.',
      );
    });

    test('every kind of file passes up to the limit, detectors included (r314)', () async {
      final dir = Directory.systemTemp.createTempSync('model_limit_');
      try {
        // Larger than the old detector (30 MiB) and NPU (256 MiB) limits.
        // Sparse: the file system stores no data for the zeros.
        final big = File('${dir.path}/big')
          ..writeAsBytesSync([0, 0, 0, 0, 0x54, 0x46, 0x4c, 0x33]);
        final raf = big.openSync(mode: FileMode.append);
        raf.truncateSync(300 * 1024 * 1024);
        raf.closeSync();
        for (final name in ['detector.tflite', 'detector_qnn.onnx', 'names.fpack']) {
          await expectLater(validateModelFile(big, name), completes, reason: name);
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('a file above the limit is refused and nothing is left behind', () async {
      final dir = Directory.systemTemp.createTempSync('model_over_limit_');
      try {
        // A small limit stands in for 2 GiB (no test writes such a file).
        final source = File('${dir.path}/source.tflite')
          ..writeAsBytesSync([0, 0, 0, 0, 0x54, 0x46, 0x4c, 0x33, ...List.filled(56, 0)]);
        final target = File('${dir.path}/models/m.tflite')..parent.createSync();
        for (final name in ['m.tflite', 'm_qnn.onnx', 'm.fpack']) {
          await expectLater(
            validateModelFile(source, name, maxBytes: 32),
            throwsA(predicate((e) => '$e'.contains('larger than 32 B'))),
            reason: name,
          );
        }
        await expectLater(
          copyAndValidateModel(source, target, 'm.tflite', maxBytes: 32),
          throwsA(predicate((e) => '$e'.contains('larger than 32 B'))),
        );
        expect(target.parent.listSync(), isEmpty, reason: 'no model file');
        // The same file at its own size passes.
        await copyAndValidateModel(source, target, 'm.tflite', maxBytes: 64);
        expect(target.lengthSync(), 64);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('a file just above the real limit is refused (r314)', () async {
      final dir = Directory.systemTemp.createTempSync('model_real_limit_');
      try {
        // Sparse: the file system stores no data for the zeros.
        final big = File('${dir.path}/big')
          ..writeAsBytesSync([0, 0, 0, 0, 0x54, 0x46, 0x4c, 0x33]);
        final raf = big.openSync(mode: FileMode.append);
        raf.truncateSync(kMaxModelFileBytes + 1);
        raf.closeSync();
        bool tooLarge(Object e) => '$e'.contains('larger than 2.0 GB');
        for (final name in ['d.tflite', 'd_qnn.onnx', 'n.fpack']) {
          await expectLater(validateModelFile(big, name), throwsA(predicate(tooLarge)), reason: name);
        }
        final target = File('${dir.path}/models/d.tflite')..parent.createSync();
        await expectLater(copyAndValidateModel(big, target, 'd.tflite'), throwsA(predicate(tooLarge)));
        expect(target.parent.listSync(), isEmpty, reason: 'no model and no .part file');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('a refused copy leaves no .part file and keeps the model in place', () async {
      final dir = Directory.systemTemp.createTempSync('model_bad_copy_');
      try {
        final good = [0, 0, 0, 0, 0x54, 0x46, 0x4c, 0x33, ...List.filled(56, 1)];
        final target = File('${dir.path}/models/m.tflite')
          ..parent.createSync()
          ..writeAsBytesSync(good);
        // No TFL3 header: refused after the copy into m.tflite.part.
        final source = File('${dir.path}/source.tflite')..writeAsBytesSync(List.filled(64, 0));
        await expectLater(
          copyAndValidateModel(source, target, 'm.tflite'),
          throwsA(predicate((e) => '$e'.contains('not a .tflite model file'))),
        );
        expect(File('${target.path}.part').existsSync(), isFalse);
        expect(target.readAsBytesSync(), good, reason: 'the usable model is not replaced');
        expect(target.parent.listSync(), hasLength(1));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('target containment and SHA-256 syntax are checked', () {
      final dir = Directory.systemTemp.createTempSync('model_security_');
      try {
        expect(
          safeModelTarget(dir, 'safe.tflite').parent.absolute.path,
          dir.absolute.path,
        );
        expect(() => safeModelTarget(dir, '../escape.tflite'), throwsException);
        expect(isValidSha256(List.filled(64, 'a').join()), isTrue);
        expect(isValidSha256('not-a-hash'), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('TFLite header is accepted and malformed input is rejected', () async {
      final dir = Directory.systemTemp.createTempSync('model_header_');
      final valid = File('${dir.path}/valid.tflite')
        ..writeAsBytesSync([0, 0, 0, 0, 0x54, 0x46, 0x4c, 0x33]);
      final invalid = File('${dir.path}/invalid.tflite')
        ..writeAsBytesSync([0, 0, 0, 0, 0, 0, 0, 0]);
      try {
        await expectLater(validateModelFile(valid, valid.path), completes);
        await expectLater(
          validateModelFile(invalid, invalid.path),
          throwsException,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('isSupportedModelFileName (r150)', () {
    test('accepts .tflite and *_qnn.onnx, case-insensitively', () {
      expect(isSupportedModelFileName('m.tflite'), isTrue);
      expect(isSupportedModelFileName('/abs/path/M.TFLITE'), isTrue);
      expect(isSupportedModelFileName('yolo26n_qnn.onnx'), isTrue);
      expect(isSupportedModelFileName('/abs/path/YOLO26N_QNN.ONNX'), isTrue);
    });

    test('rejects plain .onnx and everything else', () {
      expect(isSupportedModelFileName('m.onnx'), isFalse);
      expect(isSupportedModelFileName('m.pt'), isFalse);
      expect(isSupportedModelFileName('m.zip'), isFalse);
    });
  });

  test('isQnnModelPath flags only NPU models', () {
    expect(isQnnModelPath('/models/yolo26n_qnn.onnx'), isTrue);
    expect(isQnnModelPath('/models/m.tflite'), isFalse);
    expect(isQnnModelPath('yolo26n'), isFalse);
  });

  test('the model list label: file name and its details, no "(imported)" (r317)', () {
    const m = ModelEntry(id: '/m/a_640_fp16.tflite', name: 'a_640_fp16.tflite', source: ModelSource.imported, precision: 'fp16', inputSize: 640);
    expect(m.label, 'a_640_fp16.tflite (fp16, 640 px)');
    expect(const ModelEntry(id: '/m/b.tflite', name: 'b.tflite', source: ModelSource.imported).label, 'b.tflite');
  });

  group('modelLoadRecovery (r151)', () {
    const qnn = '/storage/models/yolo26n_v73_qnn.onnx';

    test('switch failure reverts to the still-loaded model', () {
      final r = modelLoadRecovery(
        failedPath: qnn,
        currentConfigPath: qnn,
        loadedModelPath: '/storage/models/arthropod_yolov11_int8.tflite',
      );
      expect(r, isNotNull);
      expect(r!.revertToPath, '/storage/models/arthropod_yolov11_int8.tflite');
    });

    test('initial-load failure goes to no model (r270: none ships with the app)', () {
      final r = modelLoadRecovery(
        failedPath: qnn,
        currentConfigPath: qnn,
        loadedModelPath: '',
      );
      expect(r, isNotNull);
      expect(r!.revertToPath, '');
    });

    test('native reports the RESOLVED path; matching is by file name', () {
      final r = modelLoadRecovery(
        failedPath: '/resolved/elsewhere/yolo26n_v73_qnn.onnx',
        currentConfigPath: qnn,
        loadedModelPath: '',
      );
      expect(r, isNotNull);
    });

    test('stale failure (user already picked another model) is ignored', () {
      final r = modelLoadRecovery(
        failedPath: qnn,
        currentConfigPath: '/storage/models/other_model.tflite',
        loadedModelPath: '',
      );
      expect(r, isNull);
    });

    test('official id matches its resolved bundled asset, not lookalikes', () {
      // "yolo26n" must equal its real asset file...
      expect(
        sameModelFile(
          'yolo26n',
          'flutter_assets/assets/models/yolo26n_int8.tflite',
        ),
        isTrue,
      );
      // ...but NOT another file that merely starts with the id.
      expect(sameModelFile('yolo26n', 'yolo26n_v73_qnn.onnx'), isFalse);
    });
  });

  group('modelLoadHint (r151)', () {
    test('QNN arch mismatch gets a plain-language line', () {
      final hint = modelLoadHint(
        '/m/yolo26n_v73_qnn.onnx',
        'OrtException: Error code - ORT_INVALID_GRAPH ... Error code: 5005',
      );
      expect(hint, contains('Snapdragon NPU'));
    });

    test('the normal build without the NPU runtime names the edition (r299)', () {
      final hint = modelLoadHint(
        '/m/yolo26n_v73_qnn.onnx',
        "IllegalStateException: QNN (*_qnn.onnx) models require the optional "
            "'com.microsoft.onnxruntime:onnxruntime-android-qnn' dependency in your app's build.gradle",
      );
      expect(hint, contains('NPU edition'));
      expect(hint, isNot(contains('different Snapdragon NPU generation')));
    });

    test('other failures get no hint', () {
      expect(modelLoadHint('/m/x.tflite', 'file not found'), isEmpty);
      expect(
        modelLoadHint('/m/yolo26n_v73_qnn.onnx', 'file not found'),
        isEmpty,
      );
    });
  });

  test('debug keeps only the real local YOLO official entry', () {
    expect(ModelCatalog.officialModels.keys, ['yolo26n']);
    expect(ModelCatalog.bundledIds, {'yolo26n'});
  });

  test('bundled-model manifest ignores comments and normalizes paths', () {
    final paths = parseBundledModelsManifest('''
# release tester weights
/fauna-pulse/assets/models/yolo26n_int8.tflite
assets/models/custom/a.tflite
./assets/models/custom/b_qnn.onnx

''');
    expect(paths, {
      'assets/models/yolo26n_int8.tflite',
      'assets/models/custom/a.tflite',
      'assets/models/custom/b_qnn.onnx',
    });
  });

  test('release exposes only assets selected by the text manifest', () {
    final visible = visibleBundledModelAssets(
      const [
        'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
        'assets/models/custom/MDV6-yolov10-c_float16_256.tflite',
        'assets/models/custom/MDV6-yolov10-c_int8_640.tflite',
        'assets/models/custom/arthropod_yolov11_int8.tflite',
        'assets/models/yolo26n_int8.tflite',
      ],
      releaseMode: true,
      releaseBundledModelPaths: const {
        'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
        'assets/models/custom/MDV6-yolov10-c_float16_256.tflite',
        'assets/models/yolo26n_int8.tflite',
      },
    );
    expect(visible, [
      'assets/models/custom/MDV6-yolov10-c_float16_256.tflite',
      'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
      'assets/models/yolo26n_int8.tflite',
    ]);
  });

  test(
    'debug exposes supported local weights except its special YOLO entry',
    () {
      final visible = visibleBundledModelAssets(const [
        'assets/models/custom/z.tflite',
        'assets/models/custom/a_qnn.onnx',
        'assets/models/custom/readme.txt',
        'assets/models/top-level.tflite',
        'assets/models/yolo26n_int8.tflite',
      ], releaseMode: false);
      expect(visible, [
        'assets/models/custom/a_qnn.onnx',
        'assets/models/custom/z.tflite',
        'assets/models/top-level.tflite',
      ]);
    },
  );
}
