// Tests for the download-model URL helper (round 119): only http(s) links that
// point at a supported model file yield a file name; everything else is
// rejected so the dialog's Download button stays disabled. Round 150 widened
// "supported" to .tflite OR *_qnn.onnx (Snapdragon NPU exports) — plain .onnx
// stays rejected because the native layer cannot run it.

import 'package:flutter_test/flutter_test.dart';
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

    test('rejects unsupported links, non-http schemes and garbage', () {
      expect(modelFileNameFromUrl('https://host/model.zip'), isNull);
      expect(modelFileNameFromUrl('https://github.com/user/repo'), isNull);
      expect(modelFileNameFromUrl('ftp://host/m.tflite'), isNull);
      expect(modelFileNameFromUrl('file:///sdcard/m.tflite'), isNull);
      expect(modelFileNameFromUrl('not a url'), isNull);
      expect(modelFileNameFromUrl(''), isNull);
      // A plain ONNX export is NOT runnable by the native layer.
      expect(modelFileNameFromUrl('https://host/m.onnx'), isNull);
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
      expect(r.toBundledDefault, isFalse);
    });

    test('initial-load failure falls back to bundled MDV6 INT8', () {
      final r = modelLoadRecovery(
        failedPath: qnn,
        currentConfigPath: qnn,
        loadedModelPath: '',
      );
      expect(r, isNotNull);
      expect(
        r!.revertToPath,
        'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
      );
      expect(r.toBundledDefault, isTrue);
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

  test('release exposes only the two tester MDV6 assets', () {
    final visible = visibleBundledCustomAssets(const [
      'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
      'assets/models/custom/MDV6-yolov10-c_float16_256.tflite',
      'assets/models/custom/MDV6-yolov10-c_int8_640.tflite',
      'assets/models/custom/arthropod_yolov11_int8.tflite',
      'assets/models/yolo26n_int8.tflite',
    ], releaseMode: true);
    expect(visible, [
      'assets/models/custom/MDV6-yolov10-c_float16_256.tflite',
      'assets/models/custom/MDV6-yolov10-c_int8_256.tflite',
    ]);
  });

  test('debug exposes every supported custom test asset', () {
    final visible = visibleBundledCustomAssets(const [
      'assets/models/custom/z.tflite',
      'assets/models/custom/a_qnn.onnx',
      'assets/models/custom/readme.txt',
      'assets/models/top-level.tflite',
    ], releaseMode: false);
    expect(visible, [
      'assets/models/custom/a_qnn.onnx',
      'assets/models/custom/z.tflite',
    ]);
  });
}
