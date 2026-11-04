// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/yolo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('YOLO Integration Tests', () {
    test('YOLO instance creation works', () {
      final yolo = YOLO(modelPath: 'test_model.tflite', task: YOLOTask.detect);
      expect(yolo, isNotNull);
      expect(yolo.modelPath, 'test_model.tflite');
      expect(yolo.task, YOLOTask.detect);
    });

    test('different task types work correctly', () {
      final detectYolo = YOLO(
        modelPath: 'detect_model.tflite',
        task: YOLOTask.detect,
      );

      expect(detectYolo.task, YOLOTask.detect);
      expect(YOLOTask.values, [YOLOTask.detect]); // FaunaPulse fork
    });

    test('model path handling works', () {
      final yolo1 = YOLO(
        modelPath: 'assets/models/yolo11n.tflite',
        task: YOLOTask.detect,
      );
      final yolo2 = YOLO(
        modelPath: 'models/special_chars_émojï_🤖.tflite',
        task: YOLOTask.detect,
      );

      expect(yolo1.modelPath, 'assets/models/yolo11n.tflite');
      expect(yolo2.modelPath, 'models/special_chars_émojï_🤖.tflite');
    });

    test('edge cases handled gracefully', () {
      // Test with minimal data
      final yolo = YOLO(modelPath: 'test_model.tflite', task: YOLOTask.detect);
      expect(yolo, isNotNull);

      // Test with different model paths
      final yolo2 = YOLO(
        modelPath: 'models/特殊字符_émojï_🤖_model.tflite',
        task: YOLOTask.detect,
      );
      expect(yolo2, isNotNull);
    });
  });
}
