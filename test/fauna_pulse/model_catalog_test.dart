// Tests for the download-model URL helper (round 119): only http(s) links that
// point at a .tflite file yield a file name; everything else is rejected so
// the dialog's Download button stays disabled.

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

    test('rejects non-tflite links, non-http schemes and garbage', () {
      expect(modelFileNameFromUrl('https://host/model.zip'), isNull);
      expect(modelFileNameFromUrl('https://github.com/user/repo'), isNull);
      expect(modelFileNameFromUrl('ftp://host/m.tflite'), isNull);
      expect(modelFileNameFromUrl('file:///sdcard/m.tflite'), isNull);
      expect(modelFileNameFromUrl('not a url'), isNull);
      expect(modelFileNameFromUrl(''), isNull);
    });
  });

  test('the dropdown offers no phantom official sizes (r119)', () {
    expect(ModelCatalog.officialModels.keys, ['yolo26n']);
    expect(ModelCatalog.bundledIds, {'yolo26n'});
  });
}
