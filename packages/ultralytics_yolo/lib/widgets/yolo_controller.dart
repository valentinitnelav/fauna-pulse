// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/core/yolo_model_resolver.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';
import 'package:ultralytics_yolo/utils/logger.dart';
import 'package:ultralytics_yolo/yolo_streaming_config.dart';

/// Describes a discoverable camera lens (e.g. ultra-wide, wide, telephoto).
class LensInfo {
  const LensInfo({required this.zoomFactor, required this.label});

  /// Zoom factor used to engage this lens (e.g. `0.5`, `1.0`, `2.0`).
  final double zoomFactor;

  /// Human-readable label such as `Ultra wide camera` or `Telephoto camera`.
  final String label;

  /// Builds a [LensInfo] from the native method-channel response map.
  factory LensInfo.fromMap(Map<dynamic, dynamic> map) {
    final factor = (map['zoomFactor'] as num?)?.toDouble() ?? 1.0;
    final label = (map['label'] as String?) ?? '';
    return LensInfo(zoomFactor: factor, label: label);
  }

  @override
  String toString() => 'LensInfo(zoomFactor: $zoomFactor, label: $label)';
}

/// Controls a [YOLOView] imperatively: thresholds, camera, zoom, streaming.
class YOLOViewController {
  MethodChannel? _methodChannel;
  int? _viewId;
  double _confidenceThreshold = 0.25;
  double _iouThreshold = 0.7;
  int _numItemsThreshold = 30;
  bool _torchEnabled = false;
  bool _showOverlays = true;

  final StreamController<double> _zoomController =
      StreamController<double>.broadcast();
  final StreamController<String> _lensController =
      StreamController<String>.broadcast();
  final StreamController<Offset> _focusController =
      StreamController<Offset>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  double get confidenceThreshold => _confidenceThreshold;
  double get iouThreshold => _iouThreshold;
  int get numItemsThreshold => _numItemsThreshold;
  bool get isInitialized => _methodChannel != null && _viewId != null;

  /// Whether the torch (flashlight) is currently enabled, per the last [setTorchMode]/[toggleTorch] call.
  bool get isTorchEnabled => _torchEnabled;

  /// Whether native prediction overlays are shown, per the last [setShowOverlays] call.
  bool get showOverlays => _showOverlays;

  /// Emits the native zoom factor whenever it changes (e.g. via pinch).
  Stream<double> get zoomEvents => _zoomController.stream;

  /// Emits the label of the currently selected lens whenever it changes.
  Stream<String> get lensEvents => _lensController.stream;

  /// Emits the normalized (0..1) view-relative tap-to-focus point.
  Stream<Offset> get focusEvents => _focusController.stream;

  /// Emits an inference error message (e.g. an incompatible model that fails on
  /// every frame), throttled natively so it surfaces about once every few seconds.
  Stream<String> get errorEvents => _errorController.stream;

  YOLOViewController();

  void init(MethodChannel methodChannel, int viewId) {
    _methodChannel = methodChannel;
    _viewId = viewId;
    _invoke('setThresholds', {
      'confidenceThreshold': _confidenceThreshold,
      'iouThreshold': _iouThreshold,
      'numItemsThreshold': _numItemsThreshold,
    });
    // Re-apply state set before the platform view attached, which would otherwise be silently dropped.
    if (!_showOverlays) {
      _invoke('setShowOverlays', {'visible': false});
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    final channel = _methodChannel;
    if (channel == null) return null;
    try {
      return await channel.invokeMethod<T>(method, args);
    } catch (e) {
      logInfo('YOLOViewController.$method failed: $e');
      return null;
    }
  }

  Future<void> setConfidenceThreshold(double threshold) async {
    _confidenceThreshold = threshold.clamp(0.0, 1.0);
    await _invoke('setConfidenceThreshold', {
      'threshold': _confidenceThreshold,
    });
  }

  Future<void> setIoUThreshold(double threshold) async {
    _iouThreshold = threshold.clamp(0.0, 1.0);
    await _invoke('setIoUThreshold', {'threshold': _iouThreshold});
  }

  Future<void> setNumItemsThreshold(int numItems) async {
    _numItemsThreshold = numItems.clamp(1, 100);
    await _invoke('setNumItemsThreshold', {'numItems': _numItemsThreshold});
  }

  Future<void> setThresholds({
    double? confidenceThreshold,
    double? iouThreshold,
    int? numItemsThreshold,
  }) async {
    if (confidenceThreshold != null) {
      _confidenceThreshold = confidenceThreshold.clamp(0.0, 1.0);
    }
    if (iouThreshold != null) {
      _iouThreshold = iouThreshold.clamp(0.0, 1.0);
    }
    if (numItemsThreshold != null) {
      _numItemsThreshold = numItemsThreshold.clamp(1, 100);
    }
    await _invoke('setThresholds', {
      'confidenceThreshold': _confidenceThreshold,
      'iouThreshold': _iouThreshold,
      'numItemsThreshold': _numItemsThreshold,
    });
  }

  Future<void> switchCamera() => _invoke('switchCamera');

  /// Turns the active camera's torch (flashlight) on or off. The platform returns the actual resulting torch state,
  /// which is cached in [isTorchEnabled] — so the cache stays correct even when the call fails or the active camera
  /// has no torch (e.g. most front cameras). On a swallowed platform error the cached state is left unchanged.
  Future<void> setTorchMode(bool enabled) async {
    final result = await _invoke<bool>('setTorchMode', {'enabled': enabled});
    if (result != null) _torchEnabled = result;
  }

  /// Toggles the torch (flashlight) between on and off. See [setTorchMode] and [isTorchEnabled].
  Future<void> toggleTorch() => setTorchMode(!_torchEnabled);

  /// Resets the cached torch state to off without a platform call. Use after an operation where the platform drops
  /// the torch on its own (e.g. switching the camera input), so [isTorchEnabled] stays in sync.
  void resetTorchState() => _torchEnabled = false;

  Future<void> zoomIn() => _invoke('zoomIn');

  Future<void> zoomOut() => _invoke('zoomOut');

  Future<void> setZoomLevel(double zoomLevel) =>
      _invoke('setZoomLevel', {'zoomLevel': zoomLevel});

  /// Returns the lenses the active device exposes (back camera lens cluster).
  Future<List<LensInfo>> getAvailableLenses() async {
    final result = await _invoke<List<dynamic>>('getAvailableLenses');
    if (result == null) return const <LensInfo>[];
    return result
        .whereType<Map>()
        .map(LensInfo.fromMap)
        .toList(growable: false);
  }

  /// Snaps the active camera to the lens whose native zoom factor is [zoomFactor].
  Future<void> setLens(double zoomFactor) =>
      _invoke('setLens', {'zoomFactor': zoomFactor});

  /// Detailed per-camera diagnostics for every physical/logical rear (and front)
  /// camera the device reports, for a "which lenses can this app actually use?"
  /// dialog. Each map describes one camera/lens with keys such as `cameraId`,
  /// `lensFacing`, `focalLengthsMm`, `equiv35mm`, `lensType`, `isLogical`,
  /// `isPhysicalOnly`, `usableForInference`, `reason`, and `analysisSizes`. The
  /// exact keys are produced natively (see `YOLOView.cameraDiagnostics`). Empty
  /// where unavailable. Android only.
  Future<List<Map<String, dynamic>>> getCameraDiagnostics() async {
    final r = await _invoke<List<dynamic>>('getCameraDiagnostics');
    if (r == null) return const <Map<String, dynamic>>[];
    return r
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList(growable: false);
  }

  /// Requests focus + exposure at the view-relative point ([x], [y] in 0..1).
  Future<void> tapToFocus(double x, double y) =>
      _invoke('tapToFocus', {'x': x, 'y': y});

  /// Manual focus (Pollinator Monitor). [value] is 0..1, where 0 = focus at
  /// infinity (far) and 1 = the closest the lens can focus (near). Turns
  /// autofocus off and pins the lens, so the user can lock focus on the flower
  /// inside the ROI. No effect on a fixed-focus camera. Android only.
  Future<void> setManualFocus(double value) =>
      _invoke<void>('setManualFocus', {'value': value});

  /// Returns focus control to continuous autofocus, undoing [setManualFocus].
  Future<void> setAutoFocus() => _invoke<void>('setAutoFocus');

  /// Largest focus distance the lens accepts, in dioptres (1/metres). Returns 0
  /// on a fixed-focus camera (so a manual-focus slider can be hidden). Android only.
  Future<double> getMinFocusDistance() async =>
      (await _invoke<double>('getMinFocusDistance')) ?? 0.0;

  /// Shows or hides native prediction overlays without changing inference callbacks.
  ///
  /// Safe to call before the view attaches: the value is remembered and applied on initialization.
  Future<void> setShowOverlays(bool visible) {
    _showOverlays = visible;
    return _invoke('setShowOverlays', {'visible': visible});
  }

  /// Captures a still photo from the live preview.
  ///
  /// When [withOverlays] is `true`, the returned JPEG includes the rendered bounding-box overlays composited over the
  /// camera frame.
  Future<Uint8List?> capturePhoto({bool withOverlays = true}) =>
      _invoke<Uint8List>('capturePhoto', {'withOverlays': withOverlays});

  /// Captures a still photo exactly as the camera delivers it (Pollinator
  /// Monitor): the JPEG is NOT rotated upright. Returns (bytes, the clockwise
  /// rotation 0/90/180/270 that would make it upright, isFrontCamera), or null
  /// on failure. Rotating a whole multi-megapixel still costs ~1.5 s of CPU
  /// per photo; callers that only need a small crop should map the crop into
  /// raw coordinates and rotate just that square (see the app's cropRoiJpeg).
  /// Android only.
  Future<(Uint8List, int, bool)?> capturePhotoRaw() async {
    final r = await _invoke<Map<dynamic, dynamic>>('capturePhotoRaw');
    final bytes = r?['bytes'];
    if (bytes is! Uint8List) return null;
    return (
      bytes,
      (r?['rotationDegrees'] as num?)?.toInt() ?? 0,
      r?['isFront'] as bool? ?? false,
    );
  }

  /// The analysis-stream resolutions the active camera actually supports, as
  /// "WxH" strings (largest first), from the camera HAL — so the UI can offer
  /// only realistic options. Empty where unavailable. Android only.
  Future<List<String>> getStreamResolutions() async {
    final r = await _invoke<List<dynamic>>('getStreamResolutions');
    return r?.whereType<String>().toList(growable: false) ?? const <String>[];
  }

  /// The realistic ceiling for the live analysis stream on the active camera —
  /// what CameraX `ImageAnalysis` can actually deliver, which is usually smaller
  /// than [getStreamResolutions] (those are still/preview sizes). Keys:
  /// `hardwareLevel` (legacy/limited/full/level3/external/unknown), `recommendedMax`
  /// ("WxH" or ""), `previewBoundW`/`previewBoundH`, `displayW`/`displayH`. It is an
  /// estimate; the delivered size streamed each frame is the ground truth. Empty
  /// where unavailable. Android only. (See `YOLOView.analysisStreamCeiling`.)
  Future<Map<String, dynamic>> getAnalysisStreamCeiling() async {
    final r = await _invoke<Map<dynamic, dynamic>>('getAnalysisStreamCeiling');
    return r?.cast<String, dynamic>() ?? const <String, dynamic>{};
  }

  /// Crops the given ROI directly from the live analysis frame and returns it as
  /// a JPEG (Pollinator Monitor). Unlike [capturePhoto] this does NOT trigger a
  /// full-resolution still capture, so it doesn't stall the camera pipeline —
  /// ideal for time-lapse ROI photos. Resolution is the analysis frame's. Returns
  /// null if no frame is available yet. Android only.
  Future<Uint8List?> captureRoiFromFrame({
    required double cx,
    required double cy,
    required double side,
    int quality = 90,
    // Max saved side (px); larger crops are downscaled (never enlarged)
    // before encoding. 0 = no cap.
    int maxPx = 0,
  }) => _invoke<Uint8List>('captureRoiFromFrame', {
    'cx': cx,
    'cy': cy,
    'side': side,
    'quality': quality,
    'maxPx': maxPx,
  });

  /// Restricts inference to a square region of interest (Pollinator Monitor).
  ///
  /// Coordinates are normalized (0..1) in the upright frame: ([cx],[cy]) is the
  /// centre and [side] is the square's side as a fraction of frame width. The
  /// model then runs only on that crop (upscaled to its input), so small objects
  /// inside the ROI get full model resolution and detections returned are
  /// normalized to the ROI. Pass [side] <= 0 to clear and detect on the whole
  /// frame again. Android only; a no-op where unimplemented.
  Future<void> setInferenceRoi({
    required double cx,
    required double cy,
    required double side,
  }) => _invoke<void>('setInferenceRoi', {'cx': cx, 'cy': cy, 'side': side});

  /// Enables/disables the native motion gate (Pollinator Monitor).
  ///
  /// While enabled, the detector runs only when something moves inside the ROI
  /// (or moved/was detected within the last [wakeSeconds]); otherwise inference
  /// is skipped so the phone stays cool during empty-flower periods. A pixel
  /// counts as "changed" when its brightness (0..255) differs from the learned
  /// background by more than [pixelDelta]; a frame counts as motion when at
  /// least [areaFraction] (0..1) of the ROI pixels changed. The comparison runs
  /// on a [gridSize]×[gridSize] thumbnail of the ROI — finer grids let smaller
  /// insects register (each cell covers ROI-side/gridSize of the scene). While
  /// idle the native side emits ~1 Hz heartbeat maps with `gateIdle: true`
  /// through the streaming callback. Android only; a no-op where unimplemented.
  Future<void> setMotionGate({
    required bool enabled,
    int pixelDelta = 25,
    double areaFraction = 0.005,
    double wakeSeconds = 3.0,
    int gridSize = 48,
    // Frames per second the motion check inspects while the gate is idle;
    // all other idle frames are dropped before conversion (heat saver).
    int idleFps = 5,
  }) => _invoke<void>('setMotionGate', {
    'enabled': enabled,
    'pixelDelta': pixelDelta,
    'areaFraction': areaFraction,
    'wakeSeconds': wakeSeconds,
    'gridSize': gridSize,
    'idleFps': idleFps,
  });

  Future<void> switchModel(String modelPath, [YOLOTask? task]) async {
    final channel = _methodChannel;
    if (channel == null || _viewId == null) return;
    final resolvedModel = await YOLOModelResolver.resolve(
      modelPath: modelPath,
      task: task,
    );
    // Call the channel directly (not _invoke) so a native setModel failure propagates: the in-place-switch path in
    // YOLOView relies on this throwing to revert the target and route to onModelError, instead of silently
    // committing the new model and firing onModelLoad as if it succeeded.
    try {
      await channel.invokeMethod<void>('setModel', {
        'modelPath': resolvedModel.modelPath,
        'task': resolvedModel.task.name,
      });
    } catch (e) {
      logInfo('YOLOViewController.setModel failed: $e');
      rethrow;
    }
  }

  Future<void> setStreamingConfig(YOLOStreamingConfig config) =>
      _invoke('setStreamingConfig', {
        'includeDetections': config.includeDetections,
        'includeClassifications': config.includeClassifications,
        'includeProcessingTimeMs': config.includeProcessingTimeMs,
        'includeFps': config.includeFps,
        'includeMasks': config.includeMasks,
        'includePoses': config.includePoses,
        'includeOBB': config.includeOBB,
        'includeOriginalImage': config.includeOriginalImage,
        'maxFPS': config.maxFPS,
        'throttleIntervalMs': config.throttleInterval?.inMilliseconds,
        'inferenceFrequency': config.inferenceFrequency,
        'skipFrames': config.skipFrames,
        'analysisWidth': config.analysisResolution?.width.round(),
        'analysisHeight': config.analysisResolution?.height.round(),
      });

  Future<void> stop() => _invoke('stop');

  Future<void> restartCamera() => _invoke('restartCamera');

  /// Pause the preview. On iOS this snapshots the next frame into the native share-image cache before stopping the
  /// session (so [capturePhoto] after pause returns the frozen frame); on Android it unbinds the camera use-cases
  /// while keeping the predictor alive.
  Future<void> pause() => _invoke('pause');

  /// Resume after [pause]. iOS clears the cached share frame and restarts the session; Android aliases to
  /// `restartCamera()`.
  Future<void> resume() => _invoke('resume');

  Future<Uint8List?> captureFrame() => _invoke<Uint8List>('captureFrame');

  /// Routes a typed native event (`zoom`/`lens`/`focus`) to the matching stream.
  ///
  /// Called by `YOLOView` from its event-channel listener; safe to invoke from other native bridges that surface the
  /// same typed events.
  void onNativeEvent(Map<dynamic, dynamic> event) {
    final type = event['type'];
    if (type is! String) return;
    switch (type) {
      case 'zoom':
        final value = (event['value'] as num?)?.toDouble();
        if (value != null && !_zoomController.isClosed) {
          _zoomController.add(value);
        }
        break;
      case 'lens':
        final label = event['label'];
        if (label is String && !_lensController.isClosed) {
          _lensController.add(label);
        }
        break;
      case 'focus':
        final x = (event['x'] as num?)?.toDouble();
        final y = (event['y'] as num?)?.toDouble();
        if (x != null && y != null && !_focusController.isClosed) {
          _focusController.add(Offset(x, y));
        }
        break;
      case 'error':
        final message = event['message'];
        if (message is String && !_errorController.isClosed) {
          _errorController.add(message);
        }
        break;
    }
  }

  /// Releases the broadcast stream controllers owned by this controller.
  void dispose() {
    _zoomController.close();
    _lensController.close();
    _focusController.close();
    _errorController.close();
  }
}
