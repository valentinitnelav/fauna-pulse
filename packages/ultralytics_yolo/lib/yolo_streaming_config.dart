// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import 'dart:ui' show Size;

/// Configuration class for customizing YOLO streaming behavior.
///
/// This class allows fine-grained control over what data is included in
/// real-time YOLO detection streams. It provides options to balance
/// performance with data richness based on application needs.
///
/// Example usage:
/// ```dart
/// // Lightweight configuration for high FPS
/// final lightConfig = YOLOStreamingConfig.lightweight();
///
/// // Detailed configuration with all data
/// final detailedConfig = YOLOStreamingConfig.detailed();
///
/// // Custom configuration
/// final customConfig = YOLOStreamingConfig.custom(
///   includeOriginalImage: true,
///   maxFPS: 20,
///   includeMasks: false,
/// );
/// ```
class YOLOStreamingConfig {
  /// Whether to include basic detection results (bounding boxes, confidence, class).
  ///
  /// This is the core YOLO output and is typically always enabled.
  /// Disabling this will result in no detection data being sent.
  final bool includeDetections;

  /// Whether to include classification results.
  ///
  /// Relevant for classify tasks. When enabled, classification scores
  /// are included in the streaming results.
  final bool includeClassifications;

  /// Whether to include processing time metrics in milliseconds.
  ///
  /// This provides timing information for performance monitoring.
  /// Default is true to maintain compatibility with existing apps.
  final bool includeProcessingTimeMs;

  /// Whether to include frames per second (FPS) metrics.
  ///
  /// This provides real-time FPS information for performance monitoring.
  /// Default is true to maintain compatibility with existing apps.
  final bool includeFps;

  /// Whether to include instance and semantic segmentation masks in the results.
  ///
  /// Only relevant for segmentation tasks. Masks can be memory-intensive
  /// and may impact performance on lower-end devices.
  final bool includeMasks;

  /// Whether to include pose estimation keypoints.
  ///
  /// Only relevant for pose estimation tasks. Includes keypoint coordinates
  /// and confidence scores for detected poses.
  final bool includePoses;

  /// Whether to include oriented bounding box (OBB) data.
  ///
  /// Only relevant for OBB detection tasks. Includes rotated bounding box
  /// coordinates and angles.
  final bool includeOBB;

  /// Whether to include original camera frames without annotations.
  ///
  /// Original images are useful for custom post-processing or debugging.
  /// This significantly increases memory usage and should be used carefully.
  final bool includeOriginalImage;

  /// Maximum frames per second for streaming output.
  ///
  /// This controls how often results are sent to Flutter, not inference frequency.
  /// When set, limits the rate at which results are sent to improve
  /// performance. Null means no limit (device-dependent maximum).
  final int? maxFPS;

  /// Minimum interval between result transmissions.
  ///
  /// When set, ensures a minimum time gap between consecutive results.
  /// Useful for throttling high-frequency updates.
  final Duration? throttleInterval;

  /// Target inference frequency in frames per second.
  ///
  /// This controls how often YOLO inference is actually performed on camera frames.
  /// Lower values reduce CPU/GPU usage and heat generation but may miss fast objects.
  /// Higher values provide smoother tracking but consume more resources.
  ///
  /// Examples:
  /// - `30`: High frequency - smooth tracking, high resource usage
  /// - `15`: Balanced - good tracking with moderate resource usage
  /// - `10`: Low frequency - basic detection, low resource usage
  /// - `5`: Very low - minimal detection, battery saving
  /// - `null`: Maximum frequency (device-dependent, usually 30-60 FPS)
  final int? inferenceFrequency;

  /// Skip frames between inferences for power saving.
  ///
  /// This is an alternative way to control inference frequency by specifying
  /// how many camera frames to skip between inferences.
  ///
  /// Examples:
  /// - `0`: Process every frame (maximum frequency)
  /// - `1`: Process every 2nd frame (half frequency)
  /// - `2`: Process every 3rd frame (1/3 frequency)
  /// - `4`: Process every 5th frame (1/5 frequency)
  ///
  /// Note: If both `inferenceFrequency` and `skipFrames` are set,
  /// `skipFrames` takes precedence.
  final int? skipFrames;

  /// Requested camera analysis resolution (Android only).
  ///
  /// By default CameraX delivers analysis frames at its default size
  /// (typically 640x480), which caps the detail available to models with
  /// larger inputs - small objects can be lost to the upscale. Set this to
  /// request a higher analysis resolution, e.g. `Size(1280, 960)` for an
  /// 800px model. The camera falls back to the nearest supported size, and
  /// detection coordinates are normalized so overlays are unaffected.
  ///
  /// Higher resolutions increase the per-frame copy and downscale cost, so
  /// leave this null (the default) unless small-object detail matters more
  /// than peak FPS. iOS analysis frames already track the capture session
  /// resolution and ignore this setting.
  final Size? analysisResolution;

  /// Creates a YOLOStreamingConfig with custom settings.
  ///
  /// This constructor allows full customization of streaming behavior.
  /// Defaults are optimized for high-speed operation with minimal data.
  const YOLOStreamingConfig({
    this.includeDetections = true,
    this.includeClassifications = true,
    this.includeProcessingTimeMs = true,
    this.includeFps = true,
    this.includeMasks = false, // Changed to false for performance
    this.includePoses = false, // Changed to false for performance
    this.includeOBB = false, // Changed to false for performance
    this.includeOriginalImage = false,
    this.maxFPS,
    this.throttleInterval,
    this.inferenceFrequency,
    this.skipFrames,
    this.analysisResolution,
  });

  /// Creates a custom configuration with specified parameters.
  ///
  /// Any unspecified parameters default to false (except detections,
  /// classifications, and performance metrics which default to true).
  /// FaunaPulse fork: the only constructor the app uses; upstream's presets
  /// (minimal, withMasks, withPoses, full, debug, throttled, powerSaving,
  /// highPerformance) are gone with the non-detect tasks.
  const YOLOStreamingConfig.custom({
    bool? includeDetections,
    bool? includeClassifications,
    bool? includeProcessingTimeMs,
    bool? includeFps,
    bool? includeMasks,
    bool? includePoses,
    bool? includeOBB,
    bool? includeOriginalImage,
    this.maxFPS,
    this.throttleInterval,
    this.inferenceFrequency,
    this.skipFrames,
    this.analysisResolution,
  }) : includeDetections = includeDetections ?? true,
       includeClassifications = includeClassifications ?? true,
       includeProcessingTimeMs = includeProcessingTimeMs ?? true,
       includeFps = includeFps ?? true,
       includeMasks = includeMasks ?? false,
       includePoses = includePoses ?? false,
       includeOBB = includeOBB ?? false,
       includeOriginalImage = includeOriginalImage ?? false;

  @override
  String toString() {
    return 'YOLOStreamingConfig('
        'detections: $includeDetections, '
        'classifications: $includeClassifications, '
        'processingTime: $includeProcessingTimeMs, '
        'fps: $includeFps, '
        'masks: $includeMasks, '
        'poses: $includePoses, '
        'obb: $includeOBB, '
        'originalImage: $includeOriginalImage, '
        'maxFPS: $maxFPS, '
        'throttleInterval: ${throttleInterval?.inMilliseconds}ms, '
        'inferenceFrequency: $inferenceFrequency, '
        'skipFrames: $skipFrames, '
        'analysisResolution: $analysisResolution)';
  }
}
