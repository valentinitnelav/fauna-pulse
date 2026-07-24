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

  test('the dropdown offers no phantom official sizes (r119)', () {
    expect(ModelCatalog.officialModels.keys, ['yolo26n']);
    expect(ModelCatalog.bundledIds, {'yolo26n'});
  });
}
