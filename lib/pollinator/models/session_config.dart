// Pollinator Monitor — session configuration.
//
// Everything the user can set before/while recording, with sensible defaults
// from CLAUDE.md. Persisted as a single JSON string in SharedPreferences so the
// last-used settings reappear next time the app opens.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';

import '../tracking/byte_track.dart';

/// SharedPreferences key for the one-time "setup tips" reminder dialog. When the
/// stored bool is true the dialog is suppressed; clearing it (Settings → Camera →
/// "Show setup tips") makes the reminder appear again next time the screen opens.
const String kHideSessionInfoPrefKey = 'pollinator_hide_session_info';

class SessionConfig {
  /// Model identifier or path (e.g. a bundled "yolo26n" id, or a path to a
  /// user-placed .tflite file).
  final String modelPath;

  /// Detector task. Insect detection uses bounding boxes ([YOLOTask.detect]).
  final YOLOTask task;

  /// Minimum detection confidence (0..1). Plugin default 0.25.
  final double confidenceThreshold;

  /// Non-Max-Suppression overlap threshold (0..1). Plugin default 0.7. ("IoU"
  /// here removes duplicate boxes for the same object.)
  final double iouThreshold;

  /// Seconds between saved ROI photos while a visit is active.
  final double stepSeconds;

  /// Total seconds to keep photographing one track from its first detection.
  /// Must be a positive whole multiple of [stepSeconds].
  final double durationSeconds;

  /// Maximum session length in minutes; recording auto-stops after this.
  final int sessionMinutes;

  /// Folder name for this session's output (often the target flower species).
  final String folderName;

  /// Whether to overlay the live frames-per-second number.
  final bool showFps;

  /// Draw our own bounding boxes + track-id labels over the live preview. These
  /// repaint every time the tracks change (potentially every frame), so turning
  /// them off removes that per-frame UI repaint for users who want the lightest
  /// possible preview. Detection/tracking still run — only the drawing stops.
  final bool showBoxes;

  /// Show the top-left status strip (FPS, model, engine, stream, ROI size,
  /// temperature, current track count). Off = nothing on screen but the ROI box
  /// (and the REC indicator / controls), removing those periodic UI rebuilds.
  final bool showOverlayInfo;

  /// Briefly flash the ROI border a contrasting colour the instant a photo is
  /// saved, as a visual cue that capture is happening. Purely a UI border colour
  /// change at the photo cadence (≈ once per step), so it can't affect the
  /// detection frame rate.
  final bool flashOnCapture;

  /// Use the GPU when available (the plugin falls back to CPU automatically).
  final bool useGpu;

  /// Cap on how many times per second the detector runs ("inference").
  /// **0 means uncapped** — run as fast as the device can (the default), which
  /// gives the highest frame rate. A positive value throttles inference to that
  /// rate to cut heat and battery (the model is the hot part); the camera preview
  /// stays smooth regardless. For timing insect visits (which last seconds) even
  /// ~10/s is plenty, so capping is a fine trade if the phone runs hot.
  final int inferenceFps;

  /// When true (default), the app **automatically** adjusts the inference rate
  /// during a session to keep the CPU cool enough to hold a steady frame rate,
  /// instead of running flat-out and overheating into a ~3 fps collapse. When
  /// on, [inferenceFps] acts as the *maximum* rate (the ceiling); when off,
  /// [inferenceFps] is a fixed manual cap (0 = uncapped) as before.
  final bool autoThrottle;

  /// Lowest inference rate the auto-throttle will fall to (fps). Keeps a session
  /// usable even when the phone is hot. Only used when [autoThrottle] is true.
  final int minInferenceFps;

  /// Target CPU busy fraction for inference (0..1) used by the auto-throttle.
  /// Lower = cooler and steadier but fewer fps; higher = more fps but more heat.
  /// Only used when [autoThrottle] is true.
  final double throttleDutyTarget;

  /// Requested camera analysis-stream resolution (4:3). The device delivers the
  /// nearest it supports; its short side caps how large a fast (no-stall) ROI
  /// crop can be. Higher = bigger crops but can cost FPS on weaker phones.
  final int streamWidth;
  final int streamHeight;

  /// ROI photo source. When false (default), photos are cropped from the live
  /// analysis frame — fast, no camera stall, at analysis resolution. When true,
  /// each photo is a full-resolution still (`capturePhoto`) — higher quality but
  /// it briefly stalls the camera, dropping the frame rate during each save.
  final bool fullResPhotos;

  /// Occlusion tolerance, in **seconds** — how long a track survives while the
  /// insect is hidden (e.g. behind a petal) before its id is dropped. Exposed in
  /// seconds for the user; the tracker actually counts *frames*, so this is
  /// converted to a frame count at runtime against the live detector FPS (see
  /// [occlusionFramesFor]) because the frame rate varies during a session.
  final double occlusionSeconds;

  /// Minimum visit length, in **seconds** — how long an insect must stay
  /// continuously detected before it is *confirmed* as a real visit (and given
  /// a counted track id). Anything briefer is treated as a noise blip and
  /// dropped. Exposed in seconds for the user; the tracker actually counts
  /// *frames* ("min hits to confirm"), so this is converted to a frame count at
  /// runtime against the live detector FPS (see [minHitsFramesFor]). Lower =
  /// brief touchdowns are counted (but more false blips); higher = only clear,
  /// sustained landings count. Default 0.2 s (≈ 3 frames at 15 FPS, the old
  /// hardcoded value). Directly affects the visitation rate for short visits.
  final double minHitsSeconds;

  /// How often (seconds) the frame-rate is sampled into the log for the
  /// end-of-session FPS graph. The FPS value is already maintained every frame,
  /// so each sample is just a cheap log line — but a small interval keeps the log
  /// tidy and off the hot path. Default 5 s.
  final int fpsSampleSeconds;

  /// How often (seconds) the phone temperature is sampled into the log for the
  /// end-of-session temperature graph. Each sample is a platform call, so this is
  /// kept coarser than FPS; heat changes slowly. Default 10 s.
  final int thermalSampleSeconds;

  /// How often (seconds) the battery power (current × voltage) and remaining
  /// charge are sampled into the log for the end-of-session energy graphs. Each
  /// sample is a platform call, so it is kept coarse; power changes slowly.
  /// Default 10 s.
  final int powerSampleSeconds;

  /// Whether the end-of-session summary computes its graphs (visit timeline,
  /// temperature, FPS, power) automatically when it opens. When false the user
  /// taps a "Generate graphs" button instead — useful for very long sessions
  /// where the full-log parse takes a moment. Applies both at the end of a
  /// session and when re-opening any past session. Default true.
  final bool autoComputeGraphs;

  /// Which rear camera lens to use, expressed as the lens's effective zoom
  /// factor (1.0 = main "wide" lens, 0.5 = ultra-wide, 2.0/3.0 = telephoto). The
  /// app snaps to the available lens whose factor is closest to this value at
  /// session start; on a single-lens phone it simply stays on the only lens.
  /// Default 1.0 (the main wide lens, as before). See the lens-switch button on
  /// the camera screen and the camera-diagnostics dialog for what each phone
  /// actually exposes.
  final double selectedLensZoom;

  /// Tracker tuning (AI Pipeline tab).
  final ByteTrackParams trackerParams;

  const SessionConfig({
    this.modelPath = 'yolo26n',
    this.task = YOLOTask.detect,
    this.confidenceThreshold = 0.25,
    this.iouThreshold = 0.7,
    this.stepSeconds = 1.0,
    this.durationSeconds = 10.0,
    this.sessionMinutes = 60,
    this.folderName = 'session',
    this.showFps = true,
    this.showBoxes = true,
    this.showOverlayInfo = true,
    this.flashOnCapture = true,
    this.useGpu = true,
    this.inferenceFps =
        0, // 0 = uncapped (max FPS, matches the upstream example);
    // raise it in settings only to cap heat/battery on long sessions.
    // Low default stream (≈ model input) so inference runs at full speed like the
    // original; the stream-resolution setting can raise it for bigger fast crops.
    this.autoThrottle = true,
    this.minInferenceFps = 3,
    this.throttleDutyTarget = 0.5,
    this.streamWidth = 640,
    this.streamHeight = 480,
    this.fullResPhotos = false, // false = fast crops from the live frame
    this.occlusionSeconds = 3.0,
    this.minHitsSeconds = 0.2,
    this.fpsSampleSeconds = 5,
    this.thermalSampleSeconds = 10,
    this.powerSampleSeconds = 10,
    this.autoComputeGraphs = true,
    this.selectedLensZoom = 1.0,
    this.trackerParams = const ByteTrackParams(),
  });

  /// True when [durationSeconds] is a positive whole multiple of [stepSeconds].
  /// The UI warns when this is false (per CLAUDE.md).
  bool get isTimeLapseValid {
    if (stepSeconds <= 0 || durationSeconds <= 0) return false;
    final ratio = durationSeconds / stepSeconds;
    return (ratio - ratio.round()).abs() < 1e-6 && ratio.round() >= 1;
  }

  /// Converts the user-facing [occlusionSeconds] into the whole number of frames
  /// the tracker buffers a temporarily-lost track. [detectorFps] should be the
  /// *smoothed* detector frame rate (the EMA), not a raw per-frame value, so the
  /// buffer doesn't jitter as the rate fluctuates. Clamped to a sane range so a
  /// momentary FPS spike or stall can't produce an absurd buffer. Falls back to
  /// 15 FPS before the first real measurement arrives.
  int occlusionFramesFor(double detectorFps) {
    if (occlusionSeconds <= 0) return 1;
    final fps = (detectorFps.isFinite && detectorFps > 0) ? detectorFps : 15.0;
    return (occlusionSeconds * fps).round().clamp(1, 600);
  }

  /// Converts the user-facing [minHitsSeconds] into the whole number of frames a
  /// track must be matched before it is confirmed as a visit. Mirrors
  /// [occlusionFramesFor]: uses the *smoothed* detector FPS, falls back to 15
  /// FPS before the first measurement, and is **clamped to at least 1** (a track
  /// must confirm in one frame minimum — 0 would confirm every blip instantly).
  int minHitsFramesFor(double detectorFps) {
    final fps = (detectorFps.isFinite && detectorFps > 0) ? detectorFps : 15.0;
    return (minHitsSeconds * fps).round().clamp(1, 600);
  }

  SessionConfig copyWith({
    String? modelPath,
    YOLOTask? task,
    double? confidenceThreshold,
    double? iouThreshold,
    double? stepSeconds,
    double? durationSeconds,
    int? sessionMinutes,
    String? folderName,
    bool? showFps,
    bool? showBoxes,
    bool? showOverlayInfo,
    bool? flashOnCapture,
    bool? useGpu,
    int? inferenceFps,
    bool? autoThrottle,
    int? minInferenceFps,
    double? throttleDutyTarget,
    int? streamWidth,
    int? streamHeight,
    bool? fullResPhotos,
    double? occlusionSeconds,
    double? minHitsSeconds,
    int? fpsSampleSeconds,
    int? thermalSampleSeconds,
    int? powerSampleSeconds,
    bool? autoComputeGraphs,
    double? selectedLensZoom,
    ByteTrackParams? trackerParams,
  }) => SessionConfig(
    modelPath: modelPath ?? this.modelPath,
    task: task ?? this.task,
    confidenceThreshold: confidenceThreshold ?? this.confidenceThreshold,
    iouThreshold: iouThreshold ?? this.iouThreshold,
    stepSeconds: stepSeconds ?? this.stepSeconds,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    sessionMinutes: sessionMinutes ?? this.sessionMinutes,
    folderName: folderName ?? this.folderName,
    showFps: showFps ?? this.showFps,
    showBoxes: showBoxes ?? this.showBoxes,
    showOverlayInfo: showOverlayInfo ?? this.showOverlayInfo,
    flashOnCapture: flashOnCapture ?? this.flashOnCapture,
    useGpu: useGpu ?? this.useGpu,
    inferenceFps: inferenceFps ?? this.inferenceFps,
    autoThrottle: autoThrottle ?? this.autoThrottle,
    minInferenceFps: minInferenceFps ?? this.minInferenceFps,
    throttleDutyTarget: throttleDutyTarget ?? this.throttleDutyTarget,
    streamWidth: streamWidth ?? this.streamWidth,
    streamHeight: streamHeight ?? this.streamHeight,
    fullResPhotos: fullResPhotos ?? this.fullResPhotos,
    occlusionSeconds: occlusionSeconds ?? this.occlusionSeconds,
    minHitsSeconds: minHitsSeconds ?? this.minHitsSeconds,
    fpsSampleSeconds: fpsSampleSeconds ?? this.fpsSampleSeconds,
    thermalSampleSeconds: thermalSampleSeconds ?? this.thermalSampleSeconds,
    powerSampleSeconds: powerSampleSeconds ?? this.powerSampleSeconds,
    autoComputeGraphs: autoComputeGraphs ?? this.autoComputeGraphs,
    selectedLensZoom: selectedLensZoom ?? this.selectedLensZoom,
    trackerParams: trackerParams ?? this.trackerParams,
  );

  Map<String, dynamic> toJson() => {
    'modelPath': modelPath,
    'task': task.name,
    'confidenceThreshold': confidenceThreshold,
    'iouThreshold': iouThreshold,
    'stepSeconds': stepSeconds,
    'durationSeconds': durationSeconds,
    'sessionMinutes': sessionMinutes,
    'folderName': folderName,
    'showFps': showFps,
    'showBoxes': showBoxes,
    'showOverlayInfo': showOverlayInfo,
    'flashOnCapture': flashOnCapture,
    'useGpu': useGpu,
    'inferenceFps': inferenceFps,
    'autoThrottle': autoThrottle,
    'minInferenceFps': minInferenceFps,
    'throttleDutyTarget': throttleDutyTarget,
    'streamWidth': streamWidth,
    'streamHeight': streamHeight,
    'fullResPhotos': fullResPhotos,
    'occlusionSeconds': occlusionSeconds,
    'minHitsSeconds': minHitsSeconds,
    'fpsSampleSeconds': fpsSampleSeconds,
    'thermalSampleSeconds': thermalSampleSeconds,
    'powerSampleSeconds': powerSampleSeconds,
    'autoComputeGraphs': autoComputeGraphs,
    'selectedLensZoom': selectedLensZoom,
    'trackerParams': trackerParams.toJson(),
  };

  factory SessionConfig.fromJson(Map<String, dynamic> j) => SessionConfig(
    modelPath: j['modelPath'] as String? ?? 'yolo26n',
    task: YOLOTaskParsing.tryParse(j['task'] as String?) ?? YOLOTask.detect,
    confidenceThreshold: (j['confidenceThreshold'] as num?)?.toDouble() ?? 0.25,
    iouThreshold: (j['iouThreshold'] as num?)?.toDouble() ?? 0.7,
    stepSeconds: (j['stepSeconds'] as num?)?.toDouble() ?? 1.0,
    durationSeconds: (j['durationSeconds'] as num?)?.toDouble() ?? 10.0,
    sessionMinutes: (j['sessionMinutes'] as num?)?.toInt() ?? 60,
    folderName: j['folderName'] as String? ?? 'session',
    showFps: j['showFps'] as bool? ?? true,
    showBoxes: j['showBoxes'] as bool? ?? true,
    showOverlayInfo: j['showOverlayInfo'] as bool? ?? true,
    flashOnCapture: j['flashOnCapture'] as bool? ?? true,
    useGpu: j['useGpu'] as bool? ?? true,
    inferenceFps: (j['inferenceFps'] as num?)?.toInt() ?? 0,
    autoThrottle: j['autoThrottle'] as bool? ?? true,
    minInferenceFps: (j['minInferenceFps'] as num?)?.toInt() ?? 3,
    throttleDutyTarget: (j['throttleDutyTarget'] as num?)?.toDouble() ?? 0.5,
    streamWidth: (j['streamWidth'] as num?)?.toInt() ?? 640,
    streamHeight: (j['streamHeight'] as num?)?.toInt() ?? 480,
    fullResPhotos: j['fullResPhotos'] as bool? ?? false,
    occlusionSeconds: (j['occlusionSeconds'] as num?)?.toDouble() ?? 1.0,
    minHitsSeconds: (j['minHitsSeconds'] as num?)?.toDouble() ?? 0.2,
    fpsSampleSeconds: (j['fpsSampleSeconds'] as num?)?.toInt() ?? 5,
    thermalSampleSeconds: (j['thermalSampleSeconds'] as num?)?.toInt() ?? 10,
    powerSampleSeconds: (j['powerSampleSeconds'] as num?)?.toInt() ?? 10,
    autoComputeGraphs: j['autoComputeGraphs'] as bool? ?? true,
    selectedLensZoom: (j['selectedLensZoom'] as num?)?.toDouble() ?? 1.0,
    trackerParams: j['trackerParams'] is Map
        ? ByteTrackParams.fromJson(
            (j['trackerParams'] as Map).cast<String, dynamic>(),
          )
        : const ByteTrackParams(),
  );

  static const String _prefsKey = 'pollinator_session_config';

  /// Loads the last-saved config, or defaults if none/invalid.
  static Future<SessionConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const SessionConfig();
    try {
      return SessionConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const SessionConfig();
    }
  }

  /// Persists this config as the new last-used settings.
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }
}
