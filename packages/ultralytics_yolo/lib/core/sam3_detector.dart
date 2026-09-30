// FaunaPulse (round 257, sam3 branch): Dart side of the SAM 3 detector.
//
// SAM 3 finds everything that matches a short text prompt ("insect") in a
// picture, without training, but takes seconds per picture, so it is used
// only for "AI later" runs over videos. [load] reads the model folder and
// encodes the prompt once; video runs then pass `detector: 'sam3'` to
// [VideoFrameSource.open]. All work runs on the native video thread, one call
// at a time. See Sam3Detector.kt for the files and the maths.

import 'package:flutter/services.dart';

import '../config/channel_config.dart';

/// What the native side reports after loading SAM 3.
class Sam3Info {
  /// The prompt's token numbers (start, pieces, end), for checking the tokenizer.
  final List<int> tokenIds;

  /// "GPU" or "CPU" for the picture model (the slow part) and the head.
  final String visionAccelerator;
  final String headAccelerator;

  /// Why the picture model is not on the GPU although asked, or null.
  final String? visionNote;
  final double loadMs;

  const Sam3Info({
    required this.tokenIds,
    required this.visionAccelerator,
    required this.headAccelerator,
    this.visionNote,
    required this.loadMs,
  });
}

/// Boxes found in one picture file, in its pixels: `[left, top, right, bottom,
/// probability, 0]`, plus the model's "prompt is in the picture" score.
class Sam3Result {
  final List<List<double>> boxes;
  final int width;
  final int height;
  final double presence;
  final double visionMs;
  final double headMs;

  const Sam3Result({
    required this.boxes,
    required this.width,
    required this.height,
    required this.presence,
    required this.visionMs,
    required this.headMs,
  });
}

class Sam3Detector {
  static final MethodChannel _channel = ChannelConfig.createSingleImageChannel();

  /// Loads the SAM 3 files in [dir] and encodes [prompt], replacing any SAM 3
  /// loaded before. Takes tens of seconds (the picture model is about 1 GB).
  static Future<Sam3Info> load(
    String dir,
    String prompt, {
    bool useGpu = true,
    bool headOnGpu = false,
  }) async {
    final r = await _channel.invokeMethod<Map>('sam3Load', {
      'dir': dir,
      'prompt': prompt,
      'useGpu': useGpu,
      'headOnGpu': headOnGpu,
    });
    if (r == null) throw StateError('sam3Load returned nothing');
    return Sam3Info(
      tokenIds: [for (final v in r['tokenIds'] as List) (v as num).toInt()],
      visionAccelerator: (r['visionAccelerator'] as String?) ?? '?',
      headAccelerator: (r['headAccelerator'] as String?) ?? '?',
      visionNote: r['visionNote'] as String?,
      loadMs: (r['loadMs'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Runs the loaded detector on the picture file at [path].
  static Future<Sam3Result> detectFile(String path, {double confidence = 0.5, double iou = 0.7}) async {
    final r = await _channel.invokeMethod<Map>('sam3DetectFile', {
      'path': path,
      'confidence': confidence,
      'iou': iou,
    });
    if (r == null) throw StateError('sam3DetectFile returned nothing');
    return Sam3Result(
      boxes: [
        for (final b in r['boxes'] as List) [for (final v in b as List) (v as num).toDouble()],
      ],
      width: (r['width'] as num).toInt(),
      height: (r['height'] as num).toInt(),
      presence: (r['presence'] as num).toDouble(),
      visionMs: (r['visionMs'] as num).toDouble(),
      headMs: (r['headMs'] as num).toDouble(),
    );
  }

  /// Releases the native models (safe to call when none is loaded).
  static Future<void> close() => _channel.invokeMethod<void>('sam3Close');
}
