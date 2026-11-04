// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';
import 'package:ultralytics_yolo/models/yolo_exceptions.dart';
import 'package:ultralytics_yolo/utils/error_handler.dart';
import 'package:ultralytics_yolo/utils/map_converter.dart';

/// Inference functionality for YOLO models
class YOLOInference {
  final MethodChannel _channel;
  final String _instanceId;
  final YOLOTask _task;

  YOLOInference({
    required MethodChannel channel,
    required String instanceId,
    required YOLOTask task,
  }) : _channel = channel,
       _instanceId = instanceId,
       _task = task;

  Future<Map<String, dynamic>> predict(
    Uint8List imageBytes, {
    double? confidenceThreshold,
    double? iouThreshold,
    bool includeAnnotatedImage = true,
  }) async {
    if (imageBytes.isEmpty) {
      throw InvalidInputException('Image data is empty');
    }

    if (confidenceThreshold != null &&
        (confidenceThreshold < 0.0 || confidenceThreshold > 1.0)) {
      throw InvalidInputException(
        'Confidence threshold must be between 0.0 and 1.0',
      );
    }
    if (iouThreshold != null && (iouThreshold < 0.0 || iouThreshold > 1.0)) {
      throw InvalidInputException('IoU threshold must be between 0.0 and 1.0');
    }

    try {
      final Map<String, dynamic> arguments = {'image': imageBytes};

      if (confidenceThreshold != null) {
        arguments['confidenceThreshold'] = confidenceThreshold;
      }
      if (iouThreshold != null) {
        arguments['iouThreshold'] = iouThreshold;
      }
      if (!includeAnnotatedImage) {
        // FaunaPulse (round 156, perf review D3): callers that only read the
        // box list (batch/SAHI photo analysis) skip the native annotated-image
        // render + JPEG encode. The key is sent ONLY when false; the native
        // default stays true so existing callers keep their image.
        arguments['includeAnnotatedImage'] = false;
      }

      if (_instanceId != 'default') {
        arguments['instanceId'] = _instanceId;
      }

      final result = await _channel.invokeMethod(
        'predictSingleImage',
        arguments,
      );

      if (result is Map) {
        return _processInferenceResult(result);
      }

      throw InferenceException('Invalid result format returned from inference');
    } catch (e) {
      throw YOLOErrorHandler.handleError(e, 'Error during image prediction');
    }
  }

  /// FaunaPulse (round 177, perf review E6): tiled inference for the batch/
  /// SAHI analysis path. ONE channel call: the native side decodes
  /// [imageBytes] once, crops every [tiles] rectangle
  /// (`[left, top, width, height]` in source pixels), runs the detector
  /// sequentially per tile and, when [fullPass] is set, on the whole photo
  /// too. Returns:
  ///  - 'imageWidth' / 'imageHeight': the decoded source dimensions (callers
  ///    verify them against the dimensions they planned the grid for),
  ///  - 'tiles': one detection list per input rectangle, same element shape
  ///    as [predict]'s 'detections' but normalized to the TILE,
  ///  - 'fullPass': the whole-photo detection list (when requested).
  /// Detect task only; never returns an annotated image.
  Future<Map<String, dynamic>> predictTiled(
    Uint8List imageBytes, {
    required List<List<int>> tiles,
    bool fullPass = false,
    double? confidenceThreshold,
    double? iouThreshold,
  }) async {
    if (imageBytes.isEmpty) {
      throw InvalidInputException('Image data is empty');
    }
    if (_task != YOLOTask.detect) {
      throw InvalidInputException('predictTiled supports the detect task only');
    }
    try {
      final arguments = <String, dynamic>{
        'image': imageBytes,
        'tiles': tiles,
        'fullPass': fullPass,
        'confidenceThreshold': ?confidenceThreshold,
        'iouThreshold': ?iouThreshold,
        if (_instanceId != 'default') 'instanceId': _instanceId,
      };
      final result = await _channel.invokeMethod(
        'predictTiledImage',
        arguments,
      );
      if (result is! Map) {
        throw InferenceException(
          'Invalid result format returned from tiled inference',
        );
      }
      final map = MapConverter.convertToTypedMap(result);
      List<Map<String, dynamic>> detectionsOf(dynamic rawBoxes) =>
          _processDetectResults(
            MapConverter.convertBoxesList((rawBoxes as List?) ?? const []),
          );
      return {
        'imageWidth': (map['imageWidth'] as num?)?.toInt() ?? 0,
        'imageHeight': (map['imageHeight'] as num?)?.toInt() ?? 0,
        'tiles': [
          for (final t in (map['tiles'] as List? ?? const [])) detectionsOf(t),
        ],
        if (map['fullBoxes'] != null) 'fullPass': detectionsOf(map['fullBoxes']),
      };
    } catch (e) {
      throw YOLOErrorHandler.handleError(e, 'Error during tiled prediction');
    }
  }

  Map<String, dynamic> _processInferenceResult(Map<dynamic, dynamic> result) {
    final Map<String, dynamic> resultMap = MapConverter.convertToTypedMap(
      result,
    );

    final List<Map<String, dynamic>> boxes = [];
    if (resultMap.containsKey('boxes') && resultMap['boxes'] is List) {
      boxes.addAll(MapConverter.convertBoxesList(resultMap['boxes'] as List));
      resultMap['boxes'] = boxes;
    }

    final List<Map<String, dynamic>> detections = [];

    // FaunaPulse fork: detection only (see FAUNAPULSE_FORK.md).
    detections.addAll(_processDetectResults(boxes));

    resultMap['detections'] = detections;

    return resultMap;
  }

  List<Map<String, dynamic>> _processDetectResults(
    List<Map<String, dynamic>> boxes,
  ) {
    final List<Map<String, dynamic>> detections = [];

    for (final box in boxes) {
      detections.add(_createDetectionMap(box));
    }

    return detections;
  }

  Map<String, dynamic> _createDetectionMap(Map<String, dynamic> box) {
    return {
      'classIndex': 0,
      'className': MapConverter.safeGetString(box, 'class'),
      'confidence': MapConverter.safeGetDouble(box, 'confidence'),
      'boundingBox': {
        'left': MapConverter.safeGetDouble(box, 'x1'),
        'top': MapConverter.safeGetDouble(box, 'y1'),
        'right': MapConverter.safeGetDouble(box, 'x2'),
        'bottom': MapConverter.safeGetDouble(box, 'y2'),
      },
      'normalizedBox': {
        'left': MapConverter.safeGetDouble(box, 'x1_norm'),
        'top': MapConverter.safeGetDouble(box, 'y1_norm'),
        'right': MapConverter.safeGetDouble(box, 'x2_norm'),
        'bottom': MapConverter.safeGetDouble(box, 'y2_norm'),
      },
    };
  }
}
