// Pollinator Monitor — the live recording screen.
//
// Ties everything together: the YOLO camera preview, the ROI box, the tracker,
// the time-lapse photo capture, and the append-only log. The detector and the
// YUV->RGB conversion all run inside the plugin; we only consume its per-frame
// results here and never touch raw camera pixels on the hot path.

import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../capture/roi_capture.dart';
import '../logging/device_thermal.dart';
import '../logging/diagnostics.dart';
import '../logging/error_reporter.dart';
import '../logging/session_logger.dart';
import '../models/model_catalog.dart';
import '../models/roi.dart';
import '../models/session_config.dart';
import '../services/recording_keepalive.dart';
import '../models/track.dart';
import '../perf/adaptive_inference_throttle.dart';
import '../tracking/byte_track.dart';
import '../widgets/preview_transform.dart';
import '../widgets/roi_mask.dart';
import '../widgets/roi_overlay.dart';
import '../widgets/track_box_painter.dart';
import 'problem_description_screen.dart';
import 'settings_sheet.dart';
import 'session_summary_screen.dart';

class CameraSessionScreen extends StatefulWidget {
  final SessionConfig initialConfig;

  const CameraSessionScreen({super.key, required this.initialConfig});

  @override
  State<CameraSessionScreen> createState() => _CameraSessionScreenState();
}

class _CameraSessionScreenState extends State<CameraSessionScreen>
    with WidgetsBindingObserver {
  final YOLOViewController _controller = YOLOViewController();

  late SessionConfig _config;
  late ByteTracker _tracker;

  // Auto thermal-aware inference throttle. When active, it adjusts [_appliedCapFps]
  // each second from the measured inference time so the CPU keeps a cooling margin
  // (see AdaptiveInferenceThrottle). [_appliedCapFps] is the rate cap currently fed
  // to the native detector (null = uncapped); it also drives the YOLOView config.
  AdaptiveInferenceThrottle? _throttle;
  int? _appliedCapFps;

  Roi _roi = Roi.defaultRoi;
  int _imageWidth = 0;
  int _imageHeight = 0;
  // Full-resolution still dimensions (the photo actually saved), learned once by
  // probing capturePhoto(). The analysis frame above is much smaller, so the ROI
  // resolution shown to the user is based on these capture dimensions.
  int _captureWidth = 0;
  int _captureHeight = 0;
  bool _captureProbeStarted = false;
  // Which processor actually runs inference ("GPU"/"CPU"/"NPU"), reported by the
  // native side. Note: GPU can't run int8-quantized models and falls back to CPU.
  String _accelerator = '';
  // Camera-supported analysis stream resolutions ("WxH"), for the settings menu.
  List<String> _streamResolutions = const [];
  // Estimated ceiling for what CameraX ImageAnalysis can actually stream on this
  // phone (the still/preview sizes above advertise more than the analysis pipeline
  // can deliver). Keys: hardwareLevel, recommendedMax ("WxH"), previewBoundW/H,
  // displayW/H. Probed once and handed to the settings sheet. See round 56.
  Map<String, dynamic> _analysisCeiling = const {};
  // The model actually loaded (from onModelLoad). Lets the user see when a model
  // switch didn't take effect (e.g. a size that isn't bundled on the device).
  String _loadedModel = '';

  // The model's square input resolution in pixels (e.g. 640 → "640×640 px"),
  // read once from the model metadata via ModelCatalog.inputSizeOf. Tri-state so
  // the overlay can distinguish "still reading" from "read, but the metadata
  // didn't carry it": [_modelInputProbed] is false until the probe returns, then
  // [_modelInputSize] is the value or null when the metadata lacks it.
  int? _modelInputSize;
  bool _modelInputProbed = false;

  // Per-frame values that change ~30x/second. They live in ValueNotifiers, NOT
  // in setState: updating a notifier repaints ONLY the small widget that listens
  // to it (the boxes and the FPS/track chips), instead of rebuilding the whole
  // screen — crucially leaving the native camera preview untouched every frame.
  // Rebuilding the platform view at 30fps was the source of the preview lag.
  final ValueNotifier<List<Track>> _tracksVN = ValueNotifier(const []);
  final ValueNotifier<double> _fpsVN = ValueNotifier(0);
  // Per-frame timing breakdown [pre, inference, post] in ms, from the native
  // detector — to diagnose where the time goes (preprocess vs model vs NMS).
  final ValueNotifier<List<double>> _perfVN = ValueNotifier(const [0, 0, 0]);
  // Three distinct frame rates [camera, detector, pipeline]:
  //  * camera    = analysis frames/sec the sensor delivers to the app;
  //  * detector  = model loop/sec (preprocess + inference + NMS);
  //  * pipeline  = frames/sec the app fully handles (tracking + overlay), Dart-
  //                side. Photo saving runs in the background and doesn't gate it.
  final ValueNotifier<List<double>> _fpsTrioVN = ValueNotifier(const [0, 0, 0]);
  double _pipelineFpsEma = 0;
  int _lastCallbackMs = 0;
  int _lastPerfLogMs = 0;

  // Most recent Dart-side tracker cost (ms) for the once-a-second PERF log, so
  // we can confirm empirically that tracking is a tiny fraction of inference and
  // does not warrant its own thread/isolate.
  double _lastTrackMs = 0;

  // Phone temperature, sampled every few seconds (heat builds up over a long
  // real-time session). Shown on screen and logged while recording.
  final ValueNotifier<ThermalReading> _thermalVN = ValueNotifier(
    const ThermalReading(),
  );
  Timer? _thermalTimer;
  // Frame-rate is logged on its own timer (the value is already maintained every
  // frame, so this just writes a periodic sample) at its own configurable rate.
  Timer? _fpsLogTimer;
  // Battery power (watts) + remaining charge, logged on its own timer for the
  // end-of-session energy graphs.
  Timer? _powerTimer;

  // Manual focus. The lens's largest focus distance (in dioptres, 1/metres) is
  // read once from the camera; > 0 means the lens supports manual focus, so we
  // show a focus slider. _focusValue is 0..1 (0 = far/infinity, 1 = near).
  double _minFocusDistance = 0;
  bool _focusManual = false;
  double _focusValue = 0;
  bool _showFocusSlider = false;

  // Rear-camera lens selection. The device's available lenses (main wide,
  // ultra-wide, telephoto, …) are read once from the camera. Each lens has an
  // effective zoom factor (1.0 = main wide). The lens-switch button cycles
  // through them *before* recording; the chosen lens is fixed for the session
  // and logged in the start metadata. Empty / single-entry on phones that
  // expose only one usable lens — see the camera-diagnostics dialog for why.
  List<LensInfo> _lenses = const [];
  int _lensIndex = 0;
  String _lensLabel = '';

  // Per-camera diagnostics (id, facing, focal lengths, logical/physical, whether
  // usable for inference + why). Read once while the camera is live and passed to
  // the settings sheet for display under Settings → Camera; never shown on the
  // live recording screen.
  List<Map<String, dynamic>> _cameraDiagnostics = const [];

  // Inference-error reporting. Set when the detector reports an error (e.g. an
  // incompatible model) or appears stalled (camera delivering, detector at 0 FPS).
  // Drives a dismissible warning banner with a "Create report" action.
  String? _inferenceError;
  bool _errorBannerDismissed = false;
  StreamSubscription<String>? _errorSub;
  // Watchdog state: have we ever seen the detector produce a frame, and since when
  // has the camera been delivering frames without it?
  bool _detectorEverRan = false;
  int _camDeliverStartMs = 0;

  // Motion-gate state mirrored from the native side. While the gate is idle the
  // detector is deliberately asleep (no results), so the UI must show "idle"
  // instead of a scary 0-FPS state, and the watchdog must stay quiet.
  bool _gateIdle = false;
  int _gateIdleSinceMs = 0;
  // Live changed-pixel fraction (0..1) from the gate, for tuning the trigger.
  final ValueNotifier<double> _motionScoreVN = ValueNotifier(0);

  bool _recording = false;
  // True while the camera/detector is paused (e.g. on the session summary) so we
  // don't keep running inference and heating the phone when it isn't needed.
  bool _paused = false;
  // Blackout power-save mode: when true the whole UI is covered by opaque black
  // and the screen brightness is dropped to minimum, while the camera, detector,
  // tracker and photo capture all keep running underneath (only the display is
  // parked). A tap anywhere wakes it. [_blackoutHint] shows a brief "tap to wake"
  // message that then fades so the steady state is pure black (≈ no screen power
  // on OLED). See [_enterBlackout] / [_exitBlackout].
  bool _blackout = false;
  bool _blackoutHint = false;
  Timer? _blackoutHintTimer;
  SessionLogger? _logger;
  RoiCaptureScheduler? _capture;
  String _sessionId = '';
  Timer? _sessionTimer;
  int _lastFlushMs = 0;

  // Recording elapsed-time clock (shown in the REC banner). Updated by a 1s
  // ticker so the rest of the screen doesn't rebuild.
  final ValueNotifier<int> _recordElapsedVN = ValueNotifier(0);
  Timer? _recordTicker;
  DateTime? _recordStart;

  // Photo-capture flash: briefly true the moment a photo is saved, so the ROI
  // border can blink a contrasting colour as a visual cue. Only this border
  // rebuilds (via a ValueListenableBuilder), at the photo cadence — not per
  // frame — so it has no effect on the detection rate.
  final ValueNotifier<bool> _captureFlashVN = ValueNotifier(false);
  Timer? _flashTimer;

  double get _frameAspect => (_imageWidth <= 0 || _imageHeight <= 0)
      ? 4 / 3
      : _imageWidth / _imageHeight;

  /// The photo source the CURRENT ROI would use for its next saved photo. In
  /// auto mode this flips as the user resizes the box (a small box needs the
  /// full still to meet the minimum saved size; a big one is fine from the live
  /// frame); fast/still modes are constant. All WYSIWYG readouts, grid snapping
  /// and ROI logging derive from it so the box on screen always describes the
  /// file that will actually be written.
  CapturePath get _activePath => chooseCapturePath(
    mode: _config.captureMode,
    targetPx: _config.targetRoiSavedPx,
    roiSideFraction: _roi.sideFraction,
    streamW: _imageWidth,
    streamH: _imageHeight,
    stillW: _captureWidth,
    stillH: _captureHeight,
  );

  /// Width (px) of the grid the ROI BOX is measured and snapped in: ALWAYS the
  /// live analysis frame. Round 62: the geometry used to switch to the still's
  /// grid whenever the still path was active, so the same physical box jumped
  /// scales mid-drag (e.g. "992 px" → "2464 px") and the resize slider ran to
  /// the still's short side — field-tested as thoroughly confusing, and it led
  /// the owner to shrink the box far below the intended size. The box now
  /// lives in ONE scale (the stream the user is looking at, monotonic while
  /// dragging); what the chosen source turns that box into is shown separately
  /// as "saves N×N" ([_savedSideNow]).
  int get _roiSourceWidth => _imageWidth;

  int get _roiSourceHeight => _imageHeight;

  /// Side (px) of the file the CURRENT box would save right now: the crop math
  /// of the active path's source ([savedSidePx] mirrors the native snapping
  /// exactly), then the user's max-side cap. On the still path this is usually
  /// LARGER than the box's stream-pixel size — that is the whole point of
  /// taking a still for a small box.
  int get _savedSideNow {
    final (w, h) = _activePath == CapturePath.still
        ? (_captureWidth, _captureHeight)
        : (_imageWidth, _imageHeight);
    return capSavedSidePx(
      savedSidePx(_roi.sideFraction, w, h),
      _config.targetRoiSavedPx,
    );
  }

  /// Largest ROI side (px, multiple of 32) the crop source can actually provide:
  /// the biggest 32-multiple that fits the source's short side. Caps the readout
  /// so it never claims a size the frame can't deliver (display == saved).
  int get _maxRoiPx {
    final short = _roiSourceWidth < _roiSourceHeight
        ? _roiSourceWidth
        : _roiSourceHeight;
    return (short ~/ 32) * 32;
  }

  /// Dimensions the ROI is logged against — kept consistent with the saved crop
  /// source so the logged pixel size matches the files.
  (int, int) get _roiLogDims => _activePath == CapturePath.still
      ? (_captureWidth, _captureHeight)
      : (_imageWidth, _imageHeight);

  @override
  void initState() {
    super.initState();
    // Observe app lifecycle so we can re-assert the screen-on wakelock when the
    // app returns to the foreground mid-session (belt-and-suspenders for long runs).
    WidgetsBinding.instance.addObserver(this);
    _config = widget.initialConfig;
    // Read the model's input resolution for the status overlay (async; updates
    // the chip from "reading…" once the metadata probe returns).
    _refreshModelInputSize();
    // The occlusion tolerance is stored in seconds; convert it to the tracker's
    // frame-based buffer using a sensible starting FPS (refined live below).
    _tracker = ByteTracker(params: _trackerParamsForFps(_fpsVN.value));
    _rebuildThrottle();
    // Sample temperature now, then on its configured interval. While recording,
    // each sample is also written to the log so heat can be reviewed afterwards.
    _sampleThermal();
    _thermalTimer = Timer.periodic(
      Duration(seconds: _config.thermalSampleSeconds.clamp(1, 600)),
      (_) => _sampleThermal(),
    );
    // Separate, usually faster timer that logs the frame rate for the FPS graph.
    _fpsLogTimer = Timer.periodic(
      Duration(seconds: _config.fpsSampleSeconds.clamp(1, 600)),
      (_) => _sampleFps(),
    );
    // Separate timer that logs battery power (watts) + remaining charge for the
    // end-of-session energy graphs. Its own cadence (default 10 s).
    _powerTimer = Timer.periodic(
      Duration(seconds: _config.powerSampleSeconds.clamp(1, 600)),
      (_) => _samplePower(),
    );
    // Surface native inference errors (e.g. an incompatible model failing on every
    // frame) as a dismissible banner the user can turn into an error report.
    _errorSub = _controller.errorEvents.listen((message) {
      if (!mounted) return;
      // Persist every surfaced error: banners can flash by faster than a
      // field user can read them (round 65).
      _logger?.logAppError({'source': 'detector', 'message': message});
      setState(() {
        _inferenceError = 'Detector error: $message';
        _errorBannerDismissed = false;
      });
    });
    // Show the one-time setup reminder (fix the flower, centre the ROI, lock
    // focus before recording) once the first frame is laid out, unless the user
    // has previously ticked "Don't show again".
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowSessionInfo(),
    );
  }

  /// Shows the setup reminder dialog unless the user has dismissed it for good.
  /// Persists the choice so a returning user goes straight to the preview.
  Future<void> _maybeShowSessionInfo() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kHideSessionInfoPrefKey) ?? false) return;
    if (!mounted) return;
    final dontShowAgain = await showDialog<bool>(
      context: context,
      builder: (_) => const _SessionInfoDialog(),
    );
    if (dontShowAgain == true) {
      await prefs.setBool(kHideSessionInfoPrefKey, true);
    }
  }

  /// The focus state recorded in the session log: 'manual' (locked, recommended),
  /// 'auto' (continuous autofocus), or 'fixed' (fixed-focus lens — no choice).
  String _focusModeForLog() {
    if (_minFocusDistance <= 0) return 'fixed';
    return _focusManual ? 'manual' : 'auto';
  }

  Future<void> _sampleThermal() async {
    final reading = await DeviceThermal.read();
    if (!mounted) return;
    _thermalVN.value = reading;
    // While recording, log the temperature so heat can be reviewed afterwards.
    if (_recording) _logger?.logThermal(reading.toJson());
  }

  /// Logs the current (already-computed) detector FPS. Runs on its own timer and
  /// only writes while recording; the value itself is maintained every frame, so
  /// this adds no work to the inference pipeline.
  void _sampleFps() {
    if (!_recording) return;
    // Full per-second perf fingerprint, so an *uncoupled* run still captures the
    // throttle signature (inference time climbing while temperature stays flat).
    // All values are already maintained every frame, so this adds no pipeline
    // work. `fps` (= detector fps) is kept for the existing FPS graph and for
    // sessions recorded before the extra fields existed.
    final trio = _fpsTrioVN.value; // [cameraFps, detectorFps, pipelineFps]
    final perf = _perfVN.value; // [preMs, infMs, postMs]
    double at(List<double> l, int i) => i < l.length ? l[i] : 0.0;
    _logger?.logFps({
      'fps': _fpsVN.value,
      'camera_fps': at(trio, 0),
      'detector_fps': at(trio, 1),
      'pipeline_fps': at(trio, 2),
      'pre_ms': at(perf, 0),
      'inf_ms': at(perf, 1),
      'post_ms': at(perf, 2),
      'track_ms': _lastTrackMs,
      'engine': _accelerator,
      'analysis_w': _imageWidth,
      'analysis_h': _imageHeight,
      // Auto-throttle state: the applied inference-rate cap (0 = uncapped) and
      // the smoothed inference time it is acting on, so the controller's
      // behaviour is visible in the log and the throttle graph.
      'applied_cap_fps': _appliedCapFps ?? 0,
      if (_throttle != null) 'throttle_inf_ms_ema': _throttle!.infMsEma,
    });
  }

  /// Reads battery power (current × voltage) and remaining charge, and — while
  /// recording — logs a `power` record for the end-of-session energy graphs.
  /// `power_w` is the instantaneous draw; `charge_counter_uah` lets the summary
  /// cross-check the total energy against how much the battery actually drained.
  Future<void> _samplePower() async {
    if (!_recording) return;
    final reading = await DeviceThermal.read();
    if (!_recording) return;
    _logger?.logPower({
      'power_w': reading.powerW,
      'battery_current_ua': reading.batteryCurrentUa,
      'battery_voltage_mv': reading.batteryVoltageMv,
      'charge_counter_uah': reading.chargeCounterUah,
      'is_charging': reading.isCharging,
    });
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    _thermalTimer?.cancel();
    _fpsLogTimer?.cancel();
    _powerTimer?.cancel();
    _recordTicker?.cancel();
    _errorSub?.cancel();
    _blackoutHintTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Make sure we never leave the screen stuck dark or the system bars hidden if
    // disposed while blacked out.
    if (_blackout) {
      ScreenBrightness().resetApplicationScreenBrightness().catchError((_) {});
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (_recording) _stopRecording(normal: false);
    WakelockPlus.disable();
    _controller.dispose();
    _tracksVN.dispose();
    _fpsVN.dispose();
    _perfVN.dispose();
    _fpsTrioVN.dispose();
    _motionScoreVN.dispose();
    _thermalVN.dispose();
    _recordElapsedVN.dispose();
    _flashTimer?.cancel();
    _captureFlashVN.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground mid-session: re-assert the screen-on wakelock in
    // case it was cleared while away, so a long unattended recording keeps the
    // screen on (and the app foreground) reliably.
    if (state == AppLifecycleState.resumed && _recording) {
      WakelockPlus.enable();
    }
  }

  // --- Per-frame pipeline -------------------------------------------------

  void _onStreamingData(Map<String, dynamic> data) {
    // Motion-gate idle heartbeat: while the gate keeps the detector asleep the
    // native side sends ~1 Hz maps with only gate state + camera FPS (no
    // detections). Update the gate indicator and bail out — no tracking, no
    // watchdog (0 detector FPS is *intentional* here).
    if (data['gateIdle'] == true) {
      final hbCamFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
      _motionScoreVN.value = (data['motionScore'] as num?)?.toDouble() ?? 0;
      _fpsTrioVN.value = [hbCamFps, 0, _pipelineFpsEma];
      _setGateIdle(true);
      return;
    }
    if (data.containsKey('gateIdle')) _setGateIdle(false);
    if (data.containsKey('motionScore')) {
      _motionScoreVN.value = (data['motionScore'] as num?)?.toDouble() ?? 0;
    }

    final w = (data['imageWidth'] as num?)?.toInt() ?? _imageWidth;
    final h = (data['imageHeight'] as num?)?.toInt() ?? _imageHeight;
    final fps = (data['fps'] as num?)?.toDouble() ?? _fpsVN.value;
    final accel = (data['accelerator'] as String?) ?? _accelerator;
    final preMs = (data['preMs'] as num?)?.toDouble() ?? 0;
    final inferMs = (data['inferenceMs'] as num?)?.toDouble() ?? 0;
    final postMs = (data['postMs'] as num?)?.toDouble() ?? 0;
    final cameraFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
    _perfVN.value = [preMs, inferMs, postMs];

    // Pipeline FPS: rate at which the app fully handles inferred frames (this
    // callback runs the ROI mapping + tracking + overlay update). Smoothed.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastCallbackMs > 0) {
      final dt = nowMs - _lastCallbackMs;
      if (dt > 0) {
        final inst = 1000.0 / dt;
        _pipelineFpsEma = _pipelineFpsEma == 0
            ? inst
            : 0.1 * inst + 0.9 * _pipelineFpsEma;
      }
    }
    _lastCallbackMs = nowMs;
    _fpsTrioVN.value = [cameraFps, fps, _pipelineFpsEma];

    // Inference watchdog: if the camera is delivering frames but the detector
    // never produces any (0 FPS) for a while, the model is likely failing
    // silently. Raise the same error banner so the user can report it. If the
    // detector recovers, clear the warning.
    if (fps > 0.01) {
      _detectorEverRan = true;
      if (_inferenceError != null) {
        setState(() => _inferenceError = null);
      }
    } else if (cameraFps > 1) {
      if (_camDeliverStartMs == 0) _camDeliverStartMs = nowMs;
      if (!_detectorEverRan &&
          _inferenceError == null &&
          nowMs - _camDeliverStartMs > 8000) {
        _logger?.logAppError({
          'source': 'watchdog',
          'message': 'Detector produced no results for 8 s while the camera '
              'was delivering frames.',
        });
        setState(() {
          _inferenceError =
              'The detector is not producing any results (0 FPS) although the '
              'camera is running. The selected AI model may be incompatible.';
          _errorBannerDismissed = false;
        });
      }
    }

    // Log the timing breakdown ~once a second so it can be read from `flutter
    // run` / logcat to diagnose the frame rate.
    if (nowMs - _lastPerfLogMs >= 1000) {
      _lastPerfLogMs = nowMs;
      // Re-derive the tracker's frame-based buffers (occlusion tolerance and
      // min-hits-to-confirm) from the current (smoothed) detector FPS once a
      // second, so the user's seconds-based settings stay correct as the frame
      // rate drifts during the session.
      final wantedBuffer = _config.occlusionFramesFor(fps);
      final wantedHits = _config.minHitsFramesFor(fps);
      if (wantedBuffer != _tracker.params.trackBuffer ||
          wantedHits != _tracker.params.minHitsToConfirm) {
        _tracker.params = _tracker.params.copyWith(
          trackBuffer: wantedBuffer,
          minHitsToConfirm: wantedHits,
        );
      }
      // Auto thermal-aware throttle: feed the latest inference time and apply the
      // resulting rate cap. A change re-sends the streaming config (declaratively,
      // via the YOLOView prop) which updates the native frame-skip interval with
      // no camera rebind (analysis resolution is unchanged).
      final thr = _throttle;
      if (thr != null && inferMs > 0) {
        final cap = thr.update(inferMs);
        if (cap != _appliedCapFps && mounted) {
          setState(() => _appliedCapFps = cap);
        }
      }
      debugPrint(
        'PERF camera=${cameraFps.toStringAsFixed(1)} '
        'detector=${fps.toStringAsFixed(1)} '
        'pipeline=${_pipelineFpsEma.toStringAsFixed(1)} engine=$accel '
        'pre=${preMs.toStringAsFixed(1)} inf=${inferMs.toStringAsFixed(1)} '
        'post=${postMs.toStringAsFixed(1)} '
        'track=${_lastTrackMs.toStringAsFixed(2)} '
        'cap=${_appliedCapFps ?? 0} analysis=${w}x$h',
      );
    }
    final ts =
        (data['timestamp'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;

    // The native side now crops inference to the ROI, so detection boxes arrive
    // normalized to the ROI (0..1 inside it). We map them back onto the full
    // frame here so the tracker and overlay line up with the live preview. (If
    // the ROI crop isn't active — e.g. older native — we fall back to filtering
    // full-frame detections by ROI centre.)
    final aspect = (w <= 0 || h <= 0) ? _frameAspect : w / h;
    final roiRect = _roi.normalizedRect(aspect);
    final roiActive = data['roiActive'] == true;
    Rect roiToFrame(Rect b) => Rect.fromLTRB(
      roiRect.left + b.left * roiRect.width,
      roiRect.top + b.top * roiRect.height,
      roiRect.left + b.right * roiRect.width,
      roiRect.top + b.bottom * roiRect.height,
    );
    // Strictly confine a frame-space box to the ROI rectangle. Detection runs on
    // the ROI crop, so boxes should already be inside it, but native edge
    // overruns (sub-percent over/under 0..1) — or a stray full-frame box in the
    // fallback path — can poke past the boundary. Clamping guarantees nothing is
    // tracked, drawn, or logged outside the ROI the user defined.
    Rect clampToRoi(Rect b) => Rect.fromLTRB(
      b.left.clamp(roiRect.left, roiRect.right),
      b.top.clamp(roiRect.top, roiRect.bottom),
      b.right.clamp(roiRect.left, roiRect.right),
      b.bottom.clamp(roiRect.top, roiRect.bottom),
    );

    final dets = <Detection>[];
    final rawList = data['detections'];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final result = YOLOResult.fromMap(raw);
        Rect frameBox;
        if (roiActive) {
          frameBox = roiToFrame(result.normalizedBox);
        } else {
          if (!_roi.containsBoxCenter(result.normalizedBox, aspect)) continue;
          frameBox = result.normalizedBox;
        }
        frameBox = clampToRoi(frameBox);
        // Drop anything that clamped to a zero-area sliver (i.e. it was entirely
        // outside the ROI), so a degenerate box never becomes a track.
        if (frameBox.width <= 0 || frameBox.height <= 0) continue;
        dets.add(
          Detection(
            box: frameBox,
            confidence: result.confidence,
            classIndex: result.classIndex,
            className: result.className,
          ),
        );
      }
    }

    final trackSw = Stopwatch()..start();
    final tracks = _tracker.update(dets, ts);
    trackSw.stop();
    _lastTrackMs = trackSw.elapsedMicroseconds / 1000.0;

    if (_recording) {
      _recordFrame(tracks, roiRect, ts);
    }

    // High-frequency updates go through notifiers (no full rebuild).
    _tracksVN.value = tracks;
    _fpsVN.value = fps;

    // The frame size and accelerator change only when the camera/model first
    // start, so a real setState here is rare and cheap. It refreshes the ROI
    // overlay's aspect ratio and the status readouts.
    if (mounted &&
        (w != _imageWidth || h != _imageHeight || accel != _accelerator)) {
      setState(() {
        _imageWidth = w;
        _imageHeight = h;
        _accelerator = accel;
        // A crop source is now known: align a loaded box to the ÷32 grid
        // (no-op if the active path's source size is still unknown).
        _snapRoiToSourceGrid();
      });
    }

    // Once the camera is delivering frames, probe the full-resolution still size
    // a single time so the ROI resolution readout reflects the saved photo, and
    // (re)assert the inference ROI now the native pipeline is certainly live.
    if (!_captureProbeStarted && w > 0 && h > 0) {
      _captureProbeStarted = true;
      _pushInferenceRoi();
      _pushMotionGate();
      _probeCaptureResolution();
      _probeFocusSupport();
      _fetchStreamResolutions();
      _fetchAnalysisCeiling();
      _fetchAvailableLenses();
      _fetchCameraDiagnostics();
    }
  }

  /// Applies a motion-gate state change reported by the native side: updates
  /// the on-screen indicator, logs the transition to the session JSONL (so
  /// gated periods are auditable when validating recall), and — crucially —
  /// expires stale "lost" tracks after a long sleep. While the gate is idle no
  /// frames reach the tracker, so lost tracks cannot age out; without this, an
  /// insect arriving after a long empty period could wrongly inherit the track
  /// id of one that left before the gate closed (inflating visit durations).
  void _setGateIdle(bool idle) {
    if (idle == _gateIdle) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    double idleS = 0;
    if (idle) {
      _gateIdleSinceMs = nowMs;
    } else if (_gateIdleSinceMs > 0) {
      idleS = (nowMs - _gateIdleSinceMs) / 1000.0;
      if (idleS > _config.occlusionSeconds) {
        // Asleep longer than the tracker's re-appearance buffer: whatever was
        // "lost" back then must not be revivable now.
        _tracker.expireLostTracks();
      }
    }
    if (mounted) setState(() => _gateIdle = idle);
    if (_recording) {
      _logger?.logMotionGate({
        'state': idle ? 'idle' : 'awake',
        'motion_score': _motionScoreVN.value,
        if (!idle && idleS > 0) 'idle_s': double.parse(idleS.toStringAsFixed(1)),
      });
    }
  }

  /// Asks the camera which analysis-stream resolutions it supports, so the
  /// settings dropdown can offer only realistic options for this phone.
  Future<void> _fetchStreamResolutions() async {
    try {
      final list = await _controller.getStreamResolutions();
      if (mounted && list.isNotEmpty) {
        setState(() => _streamResolutions = list);
      }
    } catch (_) {
      // Leave empty; settings falls back to a standard preset list.
    }
  }

  /// Asks the camera for the realistic analysis-stream ceiling (what CameraX can
  /// actually deliver, usually smaller than the still/preview sizes above), so
  /// the settings sheet can flag sizes the phone will silently shrink. See round 56.
  Future<void> _fetchAnalysisCeiling() async {
    try {
      final c = await _controller.getAnalysisStreamCeiling();
      if (mounted && c.isNotEmpty) {
        setState(() => _analysisCeiling = c);
      }
    } catch (_) {
      // Leave empty; the dropdown simply won't annotate a ceiling.
    }
  }

  /// Grabs one full-resolution still, reads its pixel size, and stores it so the
  /// UI can show the true ROI resolution. Retries a few times because the very
  /// first capture right after the camera starts often fails (the still-capture
  /// use-case isn't bound yet). If it never succeeds (e.g. a model that stalls
  /// the pipeline), it falls back to the analysis-frame size and marks the
  /// reading approximate, so the "Calibrating…" banner never hangs forever.
  Future<void> _probeCaptureResolution() async {
    for (
      var attempt = 0;
      attempt < 6 && mounted && _captureWidth == 0;
      attempt++
    ) {
      try {
        final raw = await _controller.capturePhotoRaw().timeout(
          const Duration(seconds: 4),
        );
        if (raw != null) {
          final size = await probeJpegSize(raw.$1);
          if (size != null && mounted) {
            // Store UPRIGHT dimensions so all downstream math keeps one frame
            // of reference. uprightStillDims (round 64) handles the decoder
            // having possibly applied the EXIF rotation already — a blind
            // swap here double-rotated in session_97.
            final up = uprightStillDims(raw.$2, size.$1, size.$2);
            setState(() {
              _captureWidth = up.$1;
              _captureHeight = up.$2;
              // The box's grid is the stream (round 62), so no re-snap here —
              // the still size only feeds the "saves N×N" readout and crops.
            });
            return;
          }
        }
      } catch (_) {
        // Try again after a short pause.
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    // Gave up on a real still: fall back to the analysis frame so the UI stops
    // showing "Calibrating…".
    if (mounted && _captureWidth == 0 && _imageWidth > 0) {
      setState(() {
        _captureWidth = _imageWidth;
        _captureHeight = _imageHeight;
      });
    }
  }

  /// Asks the camera whether it can focus manually. If so we expose a focus
  /// slider; fixed-focus lenses report 0 and the focus control stays hidden.
  Future<void> _probeFocusSupport() async {
    try {
      final d = await _controller.getMinFocusDistance();
      if (mounted) setState(() => _minFocusDistance = d);
    } catch (_) {
      // Leave at 0 (manual focus unsupported / unavailable).
    }
  }

  /// Reads the rear-camera lenses the device exposes and snaps to the one the
  /// user picked last time (persisted in [SessionConfig.selectedLensZoom]). On a
  /// single-lens phone this leaves the only lens active. Called once the camera
  /// is delivering frames; failures leave the list empty so the switch button
  /// stays disabled and the app keeps using the default lens.
  Future<void> _fetchAvailableLenses() async {
    try {
      final lenses = await _controller.getAvailableLenses();
      if (!mounted || lenses.isEmpty) return;
      // Find the lens closest to the persisted choice.
      var index = 0;
      var best = double.infinity;
      for (var i = 0; i < lenses.length; i++) {
        final d = (lenses[i].zoomFactor - _config.selectedLensZoom).abs();
        if (d < best) {
          best = d;
          index = i;
        }
      }
      setState(() {
        _lenses = lenses;
        _lensIndex = index;
        _lensLabel = _lensLabelFor(lenses[index]);
      });
      // Apply the persisted lens (no-op if it's already the active one).
      if (lenses[index].zoomFactor != 1.0) {
        await _controller.setLens(lenses[index].zoomFactor);
      }
    } catch (_) {
      // Leave empty: the switch button stays disabled, default lens in use.
    }
  }

  /// Short label for the lens button, e.g. "1×", "0.5×", "2×". Falls back to the
  /// native label (Wide / Ultra wide / Telephoto camera) if the factor is odd.
  String _lensLabelFor(LensInfo lens) {
    final z = lens.zoomFactor;
    if (z <= 0) return lens.label;
    return z < 1
        ? '${z.toStringAsFixed(1)}×'
        : '${z.toStringAsFixed(z == z.roundToDouble() ? 0 : 1)}×';
  }

  /// Advances to the next available rear lens (cycles round). Only reachable
  /// before recording (the button is disabled while recording, because a lens
  /// change rebinds the camera and shifts the field of view). Persists the new
  /// choice so the next session reopens on the same lens.
  Future<void> _cycleLens() async {
    if (_lenses.length < 2) return;
    final next = (_lensIndex + 1) % _lenses.length;
    final lens = _lenses[next];
    setState(() {
      _lensIndex = next;
      _lensLabel = _lensLabelFor(lens);
    });
    await _controller.setLens(lens.zoomFactor);
    final updated = _config.copyWith(selectedLensZoom: lens.zoomFactor);
    setState(() => _config = updated);
    await updated.save();
  }

  /// Reads the per-camera diagnostics (every camera/lens the device reports, with
  /// focal lengths, physical-vs-logical, and whether each is usable by the
  /// inference pipeline). Fetched once while the camera is live and handed to the
  /// settings sheet, which shows it under Settings → Camera ("Camera & lens
  /// info") — it is intentionally *not* shown on the live recording screen.
  Future<void> _fetchCameraDiagnostics() async {
    try {
      final cams = await _controller.getCameraDiagnostics();
      if (mounted && cams.isNotEmpty) {
        setState(() => _cameraDiagnostics = cams);
      }
    } catch (_) {
      // Leave empty; the settings section shows a "not available" note.
    }
  }

  void _setManualFocus(double v) {
    _controller.setManualFocus(v);
    setState(() {
      _focusManual = true;
      _focusValue = v;
    });
  }

  void _resetAutoFocus() {
    _controller.setAutoFocus();
    setState(() => _focusManual = false);
  }

  /// Logs every confirmed track this frame and triggers a shared ROI photo when
  /// one is due. The photo filename is written into the same detection records
  /// so post-processing can join them directly.
  void _recordFrame(List<Track> tracks, Rect roiRect, int ts) {
    final pending = _capture?.evaluate(tracks, ts);
    for (final t in tracks) {
      final jpeg = (pending != null && pending.trackIds.contains(t.id))
          ? pending.fileName
          : null;
      _logger?.logDetection({
        'track_id': t.id,
        'class_index': t.classIndex,
        'class_name': t.className,
        'confidence': t.confidence,
        'box_in_roi': _boxInRoi(t.box, roiRect),
        'jpeg': jpeg,
      });
    }
    // Force buffered lines to disk at most ~twice a second rather than every
    // frame. Each line is already written (so an app crash loses nothing); this
    // periodic fsync bounds what a sudden power/battery loss could drop to ~0.5s
    // while avoiding a costly disk sync on the main thread at 30fps.
    if (tracks.isNotEmpty && ts - _lastFlushMs >= 500) {
      _logger?.flushNow();
      _lastFlushMs = ts;
    }
    if (pending != null) {
      // Fire-and-forget; the scheduler serializes its own work.
      _capture?.capture(pending);
      _flashCaptureCue();
    }
  }

  /// Blinks the ROI border (via [_captureFlashVN]) for a split second so the
  /// user can see when a photo is taken. Off when the user disables it. Only the
  /// ROI border rebuilds, at the photo cadence, so it never touches the FPS.
  void _flashCaptureCue() {
    if (!_config.flashOnCapture) return;
    _captureFlashVN.value = true;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 180), () {
      _captureFlashVN.value = false;
    });
  }

  /// Expresses a normalized frame box as coordinates inside the ROI (0..1),
  /// per CLAUDE.md (boxes are stored relative to the ROI they were found in).
  Map<String, double> _boxInRoi(Rect box, Rect roi) {
    final rw = roi.width == 0 ? 1.0 : roi.width;
    final rh = roi.height == 0 ? 1.0 : roi.height;
    return {
      'left': (box.left - roi.left) / rw,
      'top': (box.top - roi.top) / rh,
      'right': (box.right - roi.left) / rw,
      'bottom': (box.bottom - roi.top) / rh,
    };
  }

  // --- Recording lifecycle ------------------------------------------------

  Future<void> _toggleRecording() async {
    // Don't allow recording to start until calibration (the one-time full-res
    // probe that establishes the true ROI resolution) has finished. Before that
    // the ROI pixel size — logged at session start — isn't known yet.
    if (!_recording && _captureWidth <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Still calibrating — please wait a moment.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (_recording) {
      final logFile = _logger?.file;
      await _stopRecording(normal: true);
      if (!mounted || logFile == null) return;
      // Pause the camera + detector while reviewing the summary so the phone
      // stops heating — inference is the hot part and isn't needed here. Resume
      // it when the user returns to the live preview.
      await _controller.pause();
      _paused = true;
      if (!mounted) return;
      // The summary shows the headline numbers immediately (read cheaply from
      // the first/last log lines); the heavier graphs are computed only when the
      // user taps a button there.
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SessionSummaryScreen(logFile: logFile),
        ),
      );
      if (mounted && _paused) {
        _paused = false;
        await _controller.resume();
      }
    } else {
      // One-time nudge to exempt the app from battery optimization, so a long
      // unattended session isn't killed by the OS / an OEM battery manager.
      await _ensureUnrestricted();
      if (!mounted) return;
      // Recording starts in a single tap; the focus state (manual/auto/fixed) is
      // whatever the user set via the focus button, and is logged for the record.
      await _startRecording(focusMode: _focusModeForLog());
    }
  }

  /// SharedPreferences key remembering that we've already shown the
  /// battery-optimization explanation, so it isn't shown before every session.
  static const String _batteryOptPromptedKey = 'pollinator_batteryopt_prompted';

  /// If the app isn't already exempt from battery optimization, explain once (per
  /// install) why that matters for long unattended field sessions and offer to open
  /// the system dialog. Never blocks recording: whatever the user chooses, the
  /// session still starts. Skipped entirely on devices already exempt.
  Future<void> _ensureUnrestricted() async {
    if (await RecordingKeepAlive.isUnrestricted()) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_batteryOptPromptedKey) == true) return;
    if (!mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keep recording alive?'),
        content: const Text(
          'For long or unattended sessions (hours/days), Android — and especially '
          'some phone makers’ "battery managers" — can stop the app in the '
          'background and end your recording.\n\n'
          'To prevent that, allow this app to run without battery restrictions on '
          'the next screen. On some phones you may also need to enable "Autostart" '
          'for this app in the system settings.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Allow',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    // Remember we've asked, so we don't nag before every session.
    await prefs.setBool(_batteryOptPromptedKey, true);
    if (allow == true) {
      await RecordingKeepAlive.requestUnrestricted();
    }
  }

  Future<void> _startRecording({required String focusMode}) async {
    _tracker.reset();
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    final dir = await _resolveSessionDir(_config.folderName);
    final framesDir = Directory('${dir.path}/roi_frames');
    framesDir.createSync(recursive: true);

    final logger = SessionLogger(File('${dir.path}/session.jsonl'))..open();

    final battery = await _safeBatteryLevel();
    final device = await _safeDeviceDescriptor();
    // Fresh battery/power reading so the start `thermal` block carries an accurate
    // baseline charge counter + voltage (the start↔end charge-counter drop is the
    // ground-truth for the session-total energy estimate).
    final startReading = await DeviceThermal.read();
    if (mounted) _thermalVN.value = startReading;
    logger.logStart({
      'session_id': _sessionId,
      'device': device,
      'battery_percent': battery,
      'model_path': _config.modelPath,
      'task': _config.task.name,
      'use_gpu': _config.useGpu,
      // What was actually used (vs the request above). int8 models run on CPU.
      'accelerator': _accelerator,
      'camera_full_width_px': _captureWidth,
      'camera_full_height_px': _captureHeight,
      // Which rear lens was in use for this session. zoom factor 1.0 = the main
      // wide lens; 0.5 = ultra-wide; 2.0/3.0 = telephoto. The label is the
      // human-readable lens name shown on the switch button.
      'selected_lens_zoom': _lenses.isNotEmpty
          ? _lenses[_lensIndex].zoomFactor
          : _config.selectedLensZoom,
      if (_lensLabel.isNotEmpty) 'selected_lens_label': _lensLabel,
      // Focus mode chosen for this session: 'manual' (locked, recommended),
      // 'auto' (continuous autofocus), or 'fixed' (fixed-focus lens). For a
      // locked focus we also log the 0..1 distance (0 = far/infinity, 1 = near).
      'focus_mode': focusMode,
      if (focusMode == 'manual') 'focus_value': _focusValue,
      'confidence_threshold': _config.confidenceThreshold,
      'iou_threshold': _config.iouThreshold,
      'step_seconds': _config.stepSeconds,
      'duration_seconds': _config.durationSeconds,
      'session_minutes': _config.sessionMinutes,
      // Effective (live) tracker params: trackBuffer and minHitsToConfirm here
      // are the *frame counts* derived from the user's occlusion/min-hit seconds
      // at the current FPS — not the static defaults. The seconds the user
      // actually set are in the `config` block (occlusionSeconds, minHitsSeconds).
      'tracker_params': _tracker.params.toJson(),
      // ROI sizes are expressed against the full-resolution still that is
      // actually saved (capture dims); the smaller analysis frame fed to the
      // detector is logged separately for context.
      'roi': _roi.toLogJson(_roiLogDims.$1, _roiLogDims.$2),
      // Which source the ROI dims above refer to ('fast' = analysis frame,
      // 'still' = full-res still) — in auto mode it depends on the box size.
      'roi_source': _activePath.name,
      // Exact side of the file this box would save (crop snap + max-side cap),
      // so post-processing never has to re-derive it from the fraction.
      'saves_px': _savedSideNow,
      'analysis_frame_width_px': _imageWidth,
      'analysis_frame_height_px': _imageHeight,
      'inference_fps': _config.inferenceFps,
      'fps_sample_seconds': _config.fpsSampleSeconds,
      'thermal_sample_seconds': _config.thermalSampleSeconds,
      'power_sample_seconds': _config.powerSampleSeconds,
      // Full user configuration as one self-describing block, so the end-of-session
      // summary can list *every* setting the user chose (and any setting added in
      // future automatically appears) without each one needing its own top-level
      // key here. The individual keys above are kept for existing readers and for
      // sessions recorded before this block existed.
      'config': _config.toJson(),
      'thermal': startReading.toJson(),
    });

    _capture = RoiCaptureScheduler(
      framesDir: framesDir,
      sessionId: _sessionId,
      stepMs: (_config.stepSeconds * 1000).round(),
      durationMs: (_config.durationSeconds * 1000).round(),
      // The scheduler picks the source PER PHOTO (chooseCapturePath): the fast
      // live-frame crop when it meets the minimum saved size, otherwise a
      // full-resolution still (briefly stalls the camera).
      mode: _config.captureMode,
      targetPx: _config.targetRoiSavedPx,
      streamDims: () => (_imageWidth, _imageHeight),
      stillDims: () => (_captureWidth, _captureHeight),
      fastCaptureFn: () => _controller.captureRoiFromFrame(
        cx: _roi.centerX,
        cy: _roi.centerY,
        side: _roi.sideFraction,
        maxPx: _config.targetRoiSavedPx,
      ),
      stillCaptureFn: () async {
        // Raw (unrotated) still + rotation info — the round-63 lag fix: the
        // full 12 MP frame is never rotated; only the ROI crop is.
        final raw = await _controller.capturePhotoRaw();
        if (raw != null) {
          return RawStill(bytes: raw.$1, rotationDegrees: raw.$2, isFront: raw.$3);
        }
        // Degraded fallback: preview-snapshot bytes are already upright.
        final frame = await _controller.captureFrame();
        return frame == null
            ? null
            : RawStill(bytes: frame, rotationDegrees: 0, isFront: false);
      },
      roiProvider: () => _roi,
      onStat: (s) {
        if (!_recording) return;
        _logger?.logCapture({
          'file': s.fileName,
          'track_ids': s.trackIds,
          'total_ms': s.totalMs,
          'bytes': s.bytes,
          'full_res': s.fullRes,
          // Per-photo source + saved square side, so post-processing knows the
          // real resolution of every file (in auto mode it varies with the ROI).
          'path': s.path.name,
          'saved_px': s.savedPx,
        });
      },
    );

    await WakelockPlus.enable();
    // Keep the OS from sleeping/killing this long session: a foreground service
    // (with an ongoing notification) protects the process. Ask for the
    // notification permission first (Android 13+) so the notification can show;
    // the service still runs either way.
    await Permission.notification.request();
    await RecordingKeepAlive.start();
    _sessionTimer = Timer(
      Duration(minutes: _config.sessionMinutes),
      () => _toggleRecording(),
    );

    // Start the elapsed-time clock for the REC banner.
    _recordStart = DateTime.now();
    _recordElapsedVN.value = 0;
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = _recordStart;
      if (start != null) {
        _recordElapsedVN.value = DateTime.now().difference(start).inSeconds;
      }
    });

    setState(() {
      _logger = logger;
      _recording = true;
    });

    // Snapshot the engine-selection logs (still in the ring buffer at this point)
    // into the session folder for later offline diagnosis.
    await _saveLogcat('logcat_start.txt', maxLines: 2000);
  }

  /// Saves the app's own recent logcat to a file in the session folder, so an
  /// *uncoupled* run (no `flutter run`) still preserves the native engine
  /// decision (e.g. "GPU… falling back to CPU: Failed to compile model") and the
  /// per-second PERF lines. Best-effort; silently skips if the platform refuses
  /// (e.g. iOS) or no logger/dir is available.
  Future<void> _saveLogcat(String fileName, {int maxLines = 5000}) async {
    final dir = _logger?.file.parent;
    if (dir == null) return;
    final text = await Diagnostics.captureLogcat(maxLines: maxLines);
    if (text == null || text.isEmpty) return;
    try {
      await File('${dir.path}/$fileName').writeAsString(text, flush: true);
    } catch (_) {
      // Diagnostics are best-effort; never let them break a recording.
    }
  }

  Future<void> _stopRecording({required bool normal}) async {
    _sessionTimer?.cancel();
    _recordTicker?.cancel();
    _recordTicker = null;
    final battery = await _safeBatteryLevel();
    // Fresh closing reading so the end `thermal` block carries the final charge
    // counter — the start↔end drop is the battery-drain energy estimate.
    final endReading = await DeviceThermal.read();
    _logger?.logEnd({
      'ended_normally': normal,
      'battery_percent': battery,
      'unique_track_count': _tracker.totalConfirmed,
      'thermal': endReading.toJson(),
    });
    // Capture the recent logcat (throttle-era native logs + persisted PERF lines)
    // before closing the log, so an uncoupled run keeps a full record.
    await _saveLogcat('logcat_end.txt');
    _logger?.close();
    await WakelockPlus.disable();
    // Tear down the keep-alive foreground service + its notification.
    await RecordingKeepAlive.stop();
    if (mounted) {
      setState(() => _recording = false);
    } else {
      _recording = false;
    }
  }

  /// Creates `…/Android/data/<pkg>/files/sessions/<folder>/` (USB-visible).
  /// A numeric suffix is added if the folder already exists.
  Future<Directory> _resolveSessionDir(String folderName) async {
    final base =
        (await getExternalStorageDirectory()) ??
        await getApplicationDocumentsDirectory();
    final safe = folderName.trim().isEmpty
        ? 'session'
        : folderName.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '_');
    var dir = Directory('${base.path}/sessions/$safe');
    var i = 2;
    while (dir.existsSync()) {
      dir = Directory('${base.path}/sessions/${safe}_$i');
      i++;
    }
    dir.createSync(recursive: true);
    return dir;
  }

  Future<int?> _safeBatteryLevel() async {
    try {
      return await Battery().batteryLevel;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _safeDeviceDescriptor() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return {
          'platform': 'android',
          'model': a.model,
          'manufacturer': a.manufacturer,
          'id': a.id,
          'android_sdk': a.version.sdkInt,
        };
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        return {
          'platform': 'ios',
          'model': i.utsname.machine,
          'name': i.name,
          'id': i.identifierForVendor,
        };
      }
    } catch (_) {}
    return {'platform': Platform.operatingSystem};
  }

  // --- Settings -----------------------------------------------------------

  /// The tracker params with the frame-based occlusion buffer derived from the
  /// user's occlusion-tolerance *seconds* and the given (smoothed) detector FPS.
  /// Centralised so the init, the settings-apply, and the per-second live
  /// refresh all compute the buffer the same way.
  ByteTrackParams _trackerParamsForFps(double detectorFps) =>
      _config.trackerParams.copyWith(
        trackBuffer: _config.occlusionFramesFor(detectorFps),
        minHitsToConfirm: _config.minHitsFramesFor(detectorFps),
      );

  /// The inference-rate ceiling (fps): the user's manual cap, or a sane 15 fps
  /// when they left it uncapped (0) — used as the auto-throttle's upper bound.
  int get _inferenceCeilFps => _config.inferenceFps > 0 ? _config.inferenceFps : 15;

  /// (Re)builds the auto-throttle from the current config and seeds the applied
  /// cap. Called at init and whenever settings change. When auto-throttle is off
  /// the cap is the plain manual value (null = uncapped), preserving old behaviour.
  void _rebuildThrottle() {
    if (_config.autoThrottle) {
      _throttle = AdaptiveInferenceThrottle(
        minFps: _config.minInferenceFps,
        ceilFps: _inferenceCeilFps,
        dutyTarget: _config.throttleDutyTarget,
      );
      // Start at the ceiling; the per-second loop pulls it down within a few
      // seconds once the first inference-time measurements arrive.
      _appliedCapFps = _inferenceCeilFps;
    } else {
      _throttle = null;
      _appliedCapFps = _config.inferenceFps > 0 ? _config.inferenceFps : null;
    }
  }

  /// Reads the configured model's square input resolution from its metadata (via
  /// the shared [ModelCatalog.inputSizeOf]) and updates the overlay. Marks the
  /// value as "probed" either way, so the chip can show a clear "cannot read"
  /// when the metadata doesn't carry it instead of leaving the line blank.
  Future<void> _refreshModelInputSize() async {
    final size = await ModelCatalog.inputSizeOf(_config.modelPath);
    if (!mounted) return;
    if (size != _modelInputSize || !_modelInputProbed) {
      setState(() {
        _modelInputSize = size;
        _modelInputProbed = true;
      });
    }
  }

  /// How long the "tap to wake" hint takes to fade out after entering blackout.
  /// The screen is held at its normal brightness for this whole window so the
  /// message is comfortably readable; only once it has faded is the brightness
  /// dropped to minimum for the steady-state power saving. Kept in one place so
  /// the fade animation and the brightness-drop timer stay in sync.
  static const Duration _blackoutFade = Duration(seconds: 6);

  /// Enters blackout power-save mode: covers the whole UI with opaque black while
  /// the camera, detector, tracker and photo capture keep running underneath. A
  /// wakelock keeps the screen technically on (so the OS can't sleep it and pause
  /// the camera) even when not recording. The "tap to wake" hint fades out over
  /// [_blackoutFade] at normal brightness (so it can be read), and only then is
  /// the brightness dropped to minimum — so the screen dims down gently rather
  /// than snapping to black. Waking (tap anywhere) is handled by the cover layer.
  Future<void> _enterBlackout() async {
    if (_blackout) return;
    setState(() {
      _blackout = true;
      _blackoutHint = true; // starts fully visible…
    });
    // Hide Android's status bar (clock/battery) and navigation bar (the 3 buttons)
    // so the whole screen is truly black. A swipe from an edge briefly reveals them
    // then they auto-hide; tapping to wake restores them in [_exitBlackout].
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await WakelockPlus.enable();
    // …then fades out over [_blackoutFade]: flip the flag on the next frame so
    // the AnimatedOpacity animates 1 → 0 from the start.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _blackout) setState(() => _blackoutHint = false);
    });
    // Once the hint has faded, drop the brightness to minimum (its big saving on
    // LCD panels; OLED already draws ≈ nothing on the black cover).
    _blackoutHintTimer?.cancel();
    _blackoutHintTimer = Timer(_blackoutFade, () async {
      if (!_blackout) return;
      try {
        await ScreenBrightness().setApplicationScreenBrightness(0.0);
      } catch (_) {
        // Some devices reject 0.0 or lack the API; the opaque black cover alone
        // still hides the screen.
      }
    });
  }

  /// Leaves blackout: restores the previous screen brightness and the normal UI
  /// (which is rebuilt honouring the user's on-screen display settings — boxes,
  /// info panel, capture flash). Drops the wakelock again only if a session is
  /// not recording (an active recording keeps its own wakelock).
  Future<void> _exitBlackout() async {
    if (!_blackout) return;
    _blackoutHintTimer?.cancel();
    setState(() {
      _blackout = false;
      _blackoutHint = false;
    });
    // Bring back the status/navigation bars (edge-to-edge matches the Activity's
    // default) and the screen brightness.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (_) {}
    if (!_recording) await WakelockPlus.disable();
  }

  Future<void> _openSettings() async {
    // Pause the camera + detector while the settings sheet is open so the phone
    // isn't heating from inference the user can't even see behind the sheet.
    await _controller.pause();
    _paused = true;
    if (!mounted) return;
    final updated = await showModalBottomSheet<SessionConfig>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      builder: (_) => SettingsSheet(
        config: _config,
        streamResolutions: _streamResolutions,
        analysisCeiling: _analysisCeiling,
        sensorWidth: _captureWidth,
        sensorHeight: _captureHeight,
        cameraDiagnostics: _cameraDiagnostics,
      ),
    );
    if (mounted && _paused) {
      _paused = false;
      await _controller.resume();
    }
    if (updated == null) return;
    await updated.save();
    final modelChanged = updated.modelPath != _config.modelPath;
    setState(() {
      _config = updated;
      _tracker.params = _trackerParamsForFps(_fpsVN.value);
      _rebuildThrottle();
      // Show "reading…" again while we re-probe the new model's input size.
      if (modelChanged) {
        _modelInputSize = null;
        _modelInputProbed = false;
      }
    });
    if (modelChanged) _refreshModelInputSize();
    await _controller.setThresholds(
      confidenceThreshold: updated.confidenceThreshold,
      iouThreshold: updated.iouThreshold,
    );
    _pushMotionGate();
  }

  void _onRoiChanged(Roi roi) {
    // Keep the box inside the visible preview (covers the size-slider path; the
    // drag/pinch overlay also clamps with its exact constraints).
    var clamped = roi.clampToVisible(_currentVisibleRect(), _frameAspect);
    // Snap the box geometry to the same multiple-of-32 grid the readout and the
    // saved crop use, so the box you see equals the square written to disk
    // ("what you see is what you save"). Only possible once the crop source size
    // is known; until then the box stays continuous and the readout shows
    // "measuring…". Snapping only shrinks the side, so moves are unaffected.
    if (_roiSourceWidth > 0) {
      clamped = clamped.snapSideToGrid(
        sourceWidth: _roiSourceWidth,
        maxSidePx: _maxRoiPx,
        frameAspect: _frameAspect,
      );
    }
    setState(() => _roi = clamped);
    _pushInferenceRoi();
    if (_recording) {
      _logger?.logRoiUpdate({
        'roi': _roi.toLogJson(_roiLogDims.$1, _roiLogDims.$2),
      // Which source the ROI dims above refer to ('fast' = analysis frame,
      // 'still' = full-res still) — in auto mode it depends on the box size.
      'roi_source': _activePath.name,
      // Exact side of the file this box would save (crop snap + max-side cap),
      // so post-processing never has to re-derive it from the fraction.
      'saves_px': _savedSideNow,
      });
    }
  }

  /// Re-snaps the current ROI to the saved-crop multiple-of-32 grid once the crop
  /// source size first becomes known (the first analysis frame, or the full-res
  /// still probe). A box loaded from a persisted session is stored as a raw
  /// fraction, so this lands it on the same grid the readout and crop use, making
  /// it WYSIWYG without the user having to touch it. Call from inside a setState.
  void _snapRoiToSourceGrid() {
    if (_roiSourceWidth <= 0) return;
    _roi = _roi.snapSideToGrid(
      sourceWidth: _roiSourceWidth,
      maxSidePx: _maxRoiPx,
      frameAspect: _frameAspect,
    );
  }

  /// The frame-normalized rectangle currently visible on the preview (the rest
  /// is cropped off by the camera's cover fit), used to clamp the ROI.
  Rect _currentVisibleRect() {
    final size = MediaQuery.of(context).size;
    return PreviewTransform(
      widget: size,
      frameAspect: _frameAspect,
    ).visibleNormalizedRect();
  }

  /// Lets the user set an exact ROI side in pixels (of the saved full-res crop)
  /// with a live slider OR by typing a number, so they don't have to pinch
  /// precisely. Values snap to the nearest multiple of 32 (what the crop uses).
  Future<void> _editRoiSize() async {
    // Use the width the ROI crop is actually saved from, so the px values here
    // match the saved files and the on-screen readout.
    final srcW = _roiSourceWidth;
    if (srcW <= 0) return;
    final visible = _currentVisibleRect();
    // Cap by both the visible width and the source's short side (the real max).
    final maxPx = snapToMultipleOf32(visible.width * srcW).clamp(96, _maxRoiPx);
    const minPx = 96;
    final controller = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      // Let the sheet grow with its content and sit above the keyboard so the
      // helper text below the slider is never clipped off the bottom.
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheet) {
          final curPx = snapToMultipleOf32(
            _roi.sideFraction * srcW,
          ).clamp(minPx, maxPx);
          // Keep the text field showing the current value unless it's focused.
          if (controller.text != curPx.toString() &&
              !FocusScope.of(context).hasFocus) {
            controller.text = curPx.toString();
          }

          void applyPx(int px) {
            final clamped = px.clamp(minPx, maxPx);
            _onRoiChanged(
              Roi(
                centerX: _roi.centerX,
                centerY: _roi.centerY,
                sideFraction: clamped / srcW,
              ),
            );
            setSheet(() {});
          }

          return SafeArea(
            // Scrollable so the sheet can never overflow while the keyboard
            // animates in for the px text field — in a debug build that
            // overflow flashes the striped "BOTTOM OVERFLOWED" banner, which
            // reads like an app error (round 65, owner report session_99).
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                20 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ROI size: $curPx × $curPx px  (max $maxPx)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: curPx.toDouble().clamp(
                            minPx.toDouble(),
                            maxPx.toDouble(),
                          ),
                          min: minPx.toDouble(),
                          max: maxPx.toDouble(),
                          divisions: ((maxPx - minPx) ~/ 32).clamp(1, 1000),
                          label: '$curPx px',
                          onChanged: (v) => applyPx(snapToMultipleOf32(v)),
                        ),
                      ),
                      SizedBox(
                        width: 88,
                        child: TextField(
                          controller: controller,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            suffixText: 'px',
                            suffixStyle: TextStyle(color: Colors.white54),
                            isDense: true,
                          ),
                          onSubmitted: (s) {
                            final v = int.tryParse(s.trim());
                            if (v != null) {
                              applyPx(snapToMultipleOf32(v.toDouble()));
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Slide or type the exact ROI resolution (it snaps to the '
                    'nearest multiple of 32). Then drag or pinch on the preview '
                    'to position it. The maximum equals the full sensor width.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    controller.dispose();
  }

  /// Sends the current ROI to the native side so inference runs only on that
  /// square crop (better small-object recall; nothing outside the ROI detected).
  void _pushInferenceRoi() {
    _controller.setInferenceRoi(
      cx: _roi.centerX,
      cy: _roi.centerY,
      side: _roi.sideFraction,
    );
  }

  /// Sends the motion-gate settings to the native pipeline. When enabled the
  /// detector sleeps while nothing moves inside the ROI (heat/battery saver);
  /// the native side always starts the gate awake so the user sees it working.
  void _pushMotionGate() {
    _controller.setMotionGate(
      enabled: _config.motionGateEnabled,
      pixelDelta: _config.motionGatePixelDelta,
      areaFraction: _config.motionGateAreaFraction,
      wakeSeconds: _config.motionGateWakeSeconds,
      gridSize: _config.motionGateGridSize,
      idleFps: _config.motionGateIdleFps,
    );
    if (!_config.motionGateEnabled && _gateIdle) {
      // Gate switched off while idle: clear the idle indicator immediately.
      setState(() => _gateIdle = false);
    }
  }

  // --- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Show the ROI side at the resolution of the saved photo, snapped to the
    // multiple of 32 the crop actually uses. The full-resolution still size is
    // learned by a one-time probe right after the camera starts; until it
    // returns we show "measuring…" rather than flashing a placeholder number.
    // Two separate numbers, deliberately (round 62): the BOX size in stream
    // pixels (one scale, goes down monotonically as the user shrinks it) and
    // the FILE size the active source would save from it ("saves N×N"). On the
    // still path the file is usually larger than the box's stream-pixel size —
    // that's the point of taking a still for a small box.
    final bool haveRoiDim = _roiSourceWidth > 0;
    final int roiSidePx = haveRoiDim
        ? snapToMultipleOf32(
            _roi.sideFraction * _roiSourceWidth,
          ).clamp(32, _maxRoiPx)
        : 0;
    final int savedPxNow = haveRoiDim ? _savedSideNow : 0;
    // Warn when even the chosen source can't reach the minimum saved size —
    // no software can add those pixels; the fixes are physical (move the
    // phone closer, or switch to a telephoto lens).
    final String warnTag = (haveRoiDim && savedPxNow < _config.targetRoiSavedPx)
        ? '  ⚠ below ${_config.targetRoiSavedPx} px'
        : '';
    final String roiLabel = !haveRoiDim
        ? 'ROI: measuring…'
        : (savedPxNow != roiSidePx
              ? 'ROI: $roiSidePx×$roiSidePx px → saves $savedPxNow×$savedPxNow (${_activePath.name})$warnTag'
              : 'ROI: $roiSidePx×$roiSidePx px (${_activePath.name})$warnTag');
    // Live analysis-stream size (its short side caps the fast ROI crop). Shows a
    // "measuring…" placeholder until the first frame arrives (like ROI), so the
    // line is always present rather than appearing late. If the phone delivered a
    // smaller frame than was requested (it can't stream the asked-for size — see
    // round 56), show both so the cap is never silent.
    final String streamLabel;
    if (_imageWidth <= 0) {
      streamLabel = 'Stream: measuring…';
    } else {
      final int reqArea = _config.streamWidth * _config.streamHeight;
      final int gotArea = _imageWidth * _imageHeight;
      // >~5% smaller by area = a genuine cap, not just a rotation swap.
      final bool capped = reqArea > 0 && gotArea < reqArea * 0.95;
      final int reqLo = _config.streamWidth < _config.streamHeight
          ? _config.streamWidth
          : _config.streamHeight;
      final int reqHi = _config.streamWidth < _config.streamHeight
          ? _config.streamHeight
          : _config.streamWidth;
      streamLabel = capped
          ? 'Stream: $_imageWidth×$_imageHeight px (asked $reqLo×$reqHi — device max)'
          : 'Stream: $_imageWidth×$_imageHeight px';
    }
    // Calibration = the one-time full-res probe; recording waits for it.
    final bool haveCaptureDims = _captureWidth > 0;
    // (Full-sensor still size is shown in Settings, next to "Full-resolution ROI
    // photos", rather than cluttering the live preview.)
    // Engine/Model/Input are always shown, with a clear waiting/unknown state
    // instead of a blank line, so the overlay layout doesn't shift as they load.
    final String engineLabel = _accelerator.isEmpty
        ? 'Engine: detecting…'
        : 'Engine: $_accelerator';
    // The model's input resolution, shown in brackets right after the model name:
    // "reading…" until probed, then the value, or a clear "cannot read" when the
    // model's metadata doesn't carry it.
    final String inputSuffix = !_modelInputProbed
        ? '(input: reading…)'
        : _modelInputSize == null
        ? '(input: cannot read)'
        : '($_modelInputSize×$_modelInputSize px)';
    // A very long model name (e.g. a custom .tflite filename with no spaces) is
    // made wrap-friendly so it flows onto multiple lines in its chip instead of
    // overflowing — see [_wrappable]. The bracketed input size follows the name.
    final String modelLabel = _loadedModel.isEmpty
        ? 'Model: loading… $inputSuffix'
        : 'Model: ${_wrappable(_loadedModel)} $inputSuffix';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          YOLOView(
            // Recreate the camera view when the stream resolution changes so the
            // new analysis resolution is bound immediately (the in-place update
            // path is unreliable for resolution). Keyed ONLY on stream size, so
            // ROI/threshold/model changes don't trigger a rebuild.
            key: ValueKey(
              'stream_${_config.streamWidth}x${_config.streamHeight}',
            ),
            modelPath: _config.modelPath,
            task: _config.task,
            controller: _controller,
            useGpu: _config.useGpu,
            confidenceThreshold: _config.confidenceThreshold,
            iouThreshold: _config.iouThreshold,
            // Cap how often the model runs (camera preview is unaffected). This
            // is the main lever for heat and battery on a long field session.
            streamingConfig: YOLOStreamingConfig.custom(
              // Rate cap fed to the native detector. With auto-throttle on this
              // is managed live by the AdaptiveInferenceThrottle; with it off it
              // is the manual cap (null = uncapped). Changing it re-sends the
              // config (no camera rebind — analysis resolution is unchanged).
              inferenceFrequency: _appliedCapFps,
              includeOriginalImage: false,
              // Requested analysis-stream resolution (user-configurable). The
              // live-frame ROI crops are taken from this stream; inference still
              // downscales to the model input, so the extra cost is only the
              // per-frame copy. The device delivers the nearest it supports — the
              // actual size shows in the on-screen "Stream" readout.
              analysisResolution: Size(
                _config.streamWidth.toDouble(),
                _config.streamHeight.toDouble(),
              ),
            ),
            onStreamingData: _onStreamingData,
            onModelLoad: (modelPath, _) {
              _controller.setShowOverlays(false);
              // Tell the native side to run inference only on the ROI crop.
              _pushInferenceRoi();
              // Record which model actually loaded. If a requested switch fails
              // (e.g. a size that isn't bundled), this callback isn't called for
              // it, so the displayed model stays the one really running.
              final loaded = modelPath.split('/').last;
              if (mounted && loaded != _loadedModel) {
                setState(() => _loadedModel = loaded);
              }
            },
          ),
          // Darken everything outside the ROI: the model only looks inside it.
          // (All these overlays are skipped while blacked out — nothing is drawn
          // and no per-frame painting happens — the camera/pipeline run on
          // underneath, hidden by the opaque blackout layer added at the end.)
          if (!_blackout)
            RoiMask(
              roi: _roi,
              frameAspect: _frameAspect,
              opacity: _recording ? 0.78 : 0.7,
            ),
          // Our own track-id boxes. Wrapped in a RepaintBoundary so that, when
          // the tracks notifier fires each frame, only this layer repaints — the
          // camera preview and everything else are left alone. Skipped entirely
          // when the user turns boxes off (no per-frame repaint at all).
          if (!_blackout && _config.showBoxes)
            IgnorePointer(
              child: RepaintBoundary(
                child: ValueListenableBuilder<List<Track>>(
                  valueListenable: _tracksVN,
                  builder: (_, tracks, _) => CustomPaint(
                    painter: TrackBoxPainter(tracks, frameAspect: _frameAspect),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          // Draggable ROI square (border turns red while recording, and blinks
          // bright green for a split second each time a photo is saved). Only
          // this border rebuilds on the flash, at the photo cadence.
          if (!_blackout)
            ValueListenableBuilder<bool>(
              valueListenable: _captureFlashVN,
              builder: (_, flashing, _) => RoiOverlay(
                roi: _roi,
                frameAspect: _frameAspect,
                interactive: true,
                onChanged: _onRoiChanged,
                borderColor: flashing
                    ? const Color(0xFF00FF6A) // capture flash
                    // Gate idle: detector deliberately asleep — grey the ROI so
                    // the state reads at a glance from arm's length in the field.
                    : (_config.motionGateEnabled && _gateIdle)
                    ? const Color(0x99B0BEC5)
                    : (_recording ? Colors.red : const Color(0xFFFFEB3B)),
                borderWidth: flashing ? 4.0 : 2.5,
              ),
            ),
          // Top-left status strip: one chip per line, top to bottom. It may sit
          // over the ROI if the ROI is large — that's fine. Hidden entirely when
          // the user turns the on-screen info panel off (removes those periodic
          // chip rebuilds, leaving only the ROI box and controls).
          if (!_blackout && _config.showOverlayInfo)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Detector state at a glance (motion gate only): green =
                      // detector running, grey = deliberately asleep because
                      // nothing is moving in the ROI. Bigger and color-coded so
                      // it reads from arm's length in the field.
                      if (_config.motionGateEnabled) _gateStateChip(),
                      if (_config.showFps)
                        ValueListenableBuilder<List<double>>(
                          valueListenable: _fpsTrioVN,
                          builder: (_, f, _) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _statLine(
                                'Camera: ${f[0].toStringAsFixed(0)} fps (sensor→app)',
                              ),
                              _statLine(
                                'Detector: ${f[1].toStringAsFixed(1)} fps '
                                '(pre+inf+NMS)',
                              ),
                              _statLine(
                                'Pipeline: ${f[2].toStringAsFixed(1)} fps '
                                '(+track/overlay)',
                              ),
                            ],
                          ),
                        ),
                      if (_config.showFps)
                        ValueListenableBuilder<List<double>>(
                          valueListenable: _perfVN,
                          builder: (_, p, _) => _statLine(
                            'pre ${p[0].toStringAsFixed(0)} · '
                            'inf ${p[1].toStringAsFixed(0)} · '
                            'post ${p[2].toStringAsFixed(0)} ms',
                          ),
                        ),
                      // Motion gate status: "idle" means the detector is
                      // deliberately asleep (nothing moving in the ROI) — the
                      // 0-fps Detector line above is expected, not a fault. The
                      // live motion % helps tune the trigger-area setting.
                      if (_config.motionGateEnabled)
                        ValueListenableBuilder<double>(
                          valueListenable: _motionScoreVN,
                          builder: (_, score, _) => _statLine(
                            _gateIdle
                                ? 'Gate: idle (detector asleep) · '
                                      'motion ${(score * 100).toStringAsFixed(2)}%'
                                : 'Gate: awake · '
                                      'motion ${(score * 100).toStringAsFixed(2)}%',
                          ),
                        ),
                      // Engine first (just under the perf line), then the Model
                      // line, which carries the input resolution in brackets.
                      _statLine(engineLabel),
                      _statLine(modelLabel),
                      _statLine(streamLabel),
                      // Tappable: opens the exact-size slider when we know the
                      // capture resolution.
                      GestureDetector(
                        onTap: haveRoiDim ? _editRoiSize : null,
                        child: _statLine(
                          haveRoiDim ? '$roiLabel  ✎' : roiLabel,
                        ),
                      ),
                      ValueListenableBuilder<ThermalReading>(
                        valueListenable: _thermalVN,
                        builder: (_, thermal, _) {
                          final label = thermal.shortLabel;
                          if (label.isEmpty) return const SizedBox.shrink();
                          // Label it as the battery sensor only when it really is
                          // a temperature; a bare thermal-status string is left
                          // unprefixed.
                          return _statLine(
                            thermal.batteryTempC != null
                                ? 'Battery temp.: $label'
                                : label,
                          );
                        },
                      ),
                      // Live count of insects currently on the flower, plus the
                      // running total of unique insects confirmed so far this
                      // session (same figure as the summary's "Unique insects").
                      // Both sit in one per-frame builder, so the total stays live
                      // without a separate notifier.
                      ValueListenableBuilder<List<Track>>(
                        valueListenable: _tracksVN,
                        builder: (_, tracks, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _statLine('Current tracks: ${tracks.length}'),
                            _statLine(
                              'Total tracks: ${_tracker.totalConfirmed}',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // REC banner makes it unmistakable that a session is live.
          if (_recording) ...[
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 52),
                  child: ValueListenableBuilder<int>(
                    valueListenable: _recordElapsedVN,
                    builder: (_, secs, _) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.fiber_manual_record,
                            color: Colors.white,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'REC  ${_formatElapsed(secs)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          // Big "Calibrating…" banner until the ROI resolution is known.
          if (!haveRoiDim)
            const IgnorePointer(child: Center(child: _CalibratingBanner())),
          // Inference-error banner (incompatible model / detector stalled).
          if (_inferenceError != null && !_errorBannerDismissed)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: _errorBanner(_inferenceError!),
              ),
            ),
          // Bottom controls.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Manual focus slider (only when the lens supports it and the
                    // user has tapped the focus button). Sits above the controls so
                    // the preview inside the ROI stays visible while adjusting.
                    if (_showFocusSlider && _minFocusDistance > 0)
                      _focusSliderBar(),
                    // FittedBox(scaleDown) guarantees the control strip can never
                    // overflow the screen width (it shrinks to fit on narrow
                    // phones / large text scales) instead of showing Flutter's
                    // yellow/black overflow stripes. The camera & lens diagnostic
                    // lives in Settings → Camera now, not on this live screen.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            icon: const Icon(Icons.settings),
                            onPressed: _recording ? null : _openSettings,
                          ),
                          const SizedBox(width: 16),
                          IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            icon: const Icon(Icons.dark_mode),
                            tooltip:
                                'Screen off (save power) — tap screen to wake',
                            onPressed: _enterBlackout,
                          ),
                          const SizedBox(width: 16),
                          _recordButton(),
                          const SizedBox(width: 16),
                          // Lens switch — immediately right of the record button.
                          // Cycles the rear lenses; disabled while recording.
                          _lensSwitchButton(),
                          const SizedBox(width: 16),
                          IconButton(
                            iconSize: 32,
                            color: _minFocusDistance > 0
                                ? (_showFocusSlider
                                      ? Colors.amber
                                      : Colors.white)
                                : Colors.white24,
                            icon: Icon(
                              _focusManual
                                  ? Icons.center_focus_strong
                                  : Icons.center_focus_weak,
                            ),
                            tooltip: 'Manual focus',
                            onPressed: _minFocusDistance > 0
                                ? () => setState(
                                    () => _showFocusSlider = !_showFocusSlider,
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _recording
                            ? 'Recording — tap to stop'
                            : haveCaptureDims
                            ? 'Preview — tap ● to start recording'
                            : 'Calibrating — please wait…',
                        style: TextStyle(
                          color: _recording
                              ? Colors.redAccent
                              : haveCaptureDims
                              ? Colors.white
                              : Colors.white54,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Blackout power-save cover: opaque black over the whole screen, on top
          // of everything (so it also swallows control taps). The camera + AI
          // pipeline keep running underneath; brightness was dropped to minimum in
          // [_enterBlackout]. A tap anywhere wakes the display. A brief hint fades
          // out so the steady state is pure black (≈ no screen power on OLED).
          if (_blackout)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _exitBlackout,
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: AnimatedOpacity(
                    opacity: _blackoutHint ? 1.0 : 0.0,
                    // Slow fade (held at normal brightness) so the message is easy
                    // to read; easeIn keeps it bright most of the window, then
                    // fades near the end. Kept in sync with the brightness-drop
                    // timer via [_blackoutFade].
                    duration: _blackoutFade,
                    curve: Curves.easeIn,
                    child: const Text(
                      'Screen off to save power\n'
                      'Recording continues — tap anywhere to wake',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Formats the elapsed recording time, adding coarser units only once they
  /// become relevant so short sessions stay compact:
  ///   • under 1 hour  → mm:ss
  ///   • 1–24 hours    → hh:mm:ss
  ///   • 24 hours+     → dd:hh:mm:ss
  /// Called once per second from the REC banner (not in the detection path), so
  /// it has no effect on the frame rate.
  String _formatElapsed(int totalSeconds) {
    final d = totalSeconds ~/ 86400;
    final h = (totalSeconds % 86400) ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (d > 0) return '${two(d)}:${two(h)}:${two(m)}:${two(s)}';
    if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  /// Inserts zero-width spaces (invisible) after common filename separators so a
  /// very long, space-less model name can wrap onto several lines inside its
  /// status chip instead of overflowing/clipping the line. Flutter only breaks
  /// lines at allowed points, and a token like `a_b_c_d.tflite` has none — the
  /// zero-width spaces add break opportunities without changing the visible text.
  String _wrappable(String s) =>
      s.replaceAllMapped(RegExp(r'[_\-./]'), (m) => '${m[0]}\u200B');

  /// A status chip with a little gap beneath, for the vertical left-side stack.
  Widget _statLine(String text) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: _chip(text));

  /// Prominent detector on/off chip, shown only while the motion gate is
  /// enabled: green "DETECTOR ON" while inference runs, grey "SLEEPING" while
  /// the gate keeps it idle (nothing moving in the ROI — expected on a mounted
  /// phone over an empty flower, and NOT a fault).
  Widget _gateStateChip() {
    const awakeColor = Color(0xFF00E676); // vivid green
    const idleColor = Color(0xFFB0BEC5); // blue-grey
    final color = _gateIdle ? idleColor : awakeColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 12, color: color),
            const SizedBox(width: 8),
            Text(
              _gateIdle ? 'SLEEPING' : 'DETECTOR ON',
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 13),
    ),
  );

  /// Horizontal manual-focus slider with an "Auto" reset. 0 = far (infinity),
  /// 1 = near (closest the lens can focus).
  Widget _focusSliderBar() => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Far',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        SizedBox(
          width: 200,
          child: Slider(
            value: _focusValue.clamp(0.0, 1.0),
            onChanged: _setManualFocus,
          ),
        ),
        const Text(
          'Near',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _focusManual ? _resetAutoFocus : null,
          child: Text(
            'Auto',
            style: TextStyle(
              color: _focusManual ? Colors.amber : Colors.white38,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );

  /// Top warning banner shown when the detector errors or stalls. Offers a quick
  /// way to open the error/report dialog, and a dismiss button.
  Widget _errorBanner(String message) => Container(
    margin: const EdgeInsets.all(10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.red.shade900.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: Colors.white, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        TextButton(
          onPressed: () => _showErrorReportDialog(message),
          child: const Text(
            'Report',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
        InkWell(
          onTap: () => setState(() => _errorBannerDismissed = true),
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.close, color: Colors.white70, size: 18),
          ),
        ),
      ],
    ),
  );

  /// Shows the error with the full message (selectable/copyable) and lets the user
  /// create a diagnostic report (saved locally, optionally sent to the developer).
  Future<void> _showErrorReportDialog(String message) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Problem detected'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Selectable so the user can copy the text directly.
              SelectableText(message, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              const Text(
                'You can save a diagnostic report (settings, session log and the '
                "app's recent technical log) to this phone and send it to the "
                'developer. It is stored as a .txt file you can also copy off the '
                'phone over USB.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              // Ask the user to describe the problem first (required).
              final description = await showProblemDescriptionEditor(context);
              if (description == null || !mounted) return;
              await _createReport(message, description);
            },
            child: const Text(
              'Create report',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds and saves the report, then shows its size and offers to send it.
  Future<void> _createReport(String message, String description) async {
    // Brief progress indicator — capturing logcat spawns a process.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    ErrorReport? report;
    try {
      report = await ErrorReporter.build(
        trigger: message,
        userDescription: description,
        config: _config,
        sessionLog: _logger?.file,
      );
    } catch (e) {
      report = null;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss the spinner
    if (report == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the report.')),
      );
      return;
    }
    final saved = report;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report saved'),
        content: Text(
          'Saved a ${saved.humanSize} report to:\n\n${saved.file.path}\n\n'
          'You can send it now, or find it later over USB.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ErrorReporter.share(saved);
            },
            child: const Text(
              'Send…',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recordButton() {
    // Greyed out until calibration completes (recording is blocked before then).
    final bool ready = _recording || _captureWidth > 0;
    return GestureDetector(
      onTap: _toggleRecording,
      child: Opacity(
        opacity: ready ? 1.0 : 0.4,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: _recording ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: _recording ? BorderRadius.circular(8) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Lens-switch button shown immediately right of the record button. Tapping it
  /// cycles through the device's available rear lenses (main wide → ultra-wide →
  /// telephoto → …) and shows the current lens's short label (e.g. "1×", "0.5×",
  /// "2×"). Disabled while recording (a lens change rebinds the camera and shifts
  /// the field of view) and on phones that expose only one usable lens.
  Widget _lensSwitchButton() {
    final bool enabled = !_recording && _lenses.length >= 2;
    final Color tint = enabled ? Colors.white : Colors.white24;
    return Tooltip(
      message: _lenses.length < 2
          ? 'Only one usable lens on this phone'
          : (_recording
                ? 'Stop recording to switch lens'
                : 'Switch camera lens'),
      child: InkWell(
        onTap: enabled ? _cycleLens : null,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cameraswitch, size: 30, color: tint),
              const SizedBox(height: 2),
              Text(
                _lensLabel.isEmpty ? '1×' : _lensLabel,
                style: TextStyle(
                  color: tint,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A prominent centred banner shown while the ROI resolution is being measured
/// from the first full-resolution still, so the user knows the app is busy.
class _CalibratingBanner extends StatelessWidget {
  const _CalibratingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 14),
          Text(
            'Calibrating…',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Measuring ROI resolution',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// One-time setup reminder shown when the camera screen opens. It explains how
/// to frame the shot (fix the flower, centre the ROI) and — importantly — points
/// the user at the focus button beside the record button so they lock focus
/// *before* recording. It does not block recording; the user dismisses it with
/// "Got it" and can tick "Don't show again" to never see it again.
///
/// Pops `true` if the user asked to hide it permanently, otherwise `false`.
class _SessionInfoDialog extends StatefulWidget {
  const _SessionInfoDialog();

  @override
  State<_SessionInfoDialog> createState() => _SessionInfoDialogState();
}

class _SessionInfoDialogState extends State<_SessionInfoDialog> {
  bool _dontShowAgain = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Setting up a session'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bullet(
              Icons.park,
              'Fix the target flower in place — e.g. tie it to a pole — so it '
              'does not sway in the wind.',
            ),
            const SizedBox(height: 12),
            _bullet(
              Icons.crop_square,
              'Centre the yellow ROI box on the target flower(s) or '
              'inflorescence(s).',
            ),
            const SizedBox(height: 12),
            _bullet(
              Icons.center_focus_strong,
              'Before recording, tap the focus button (just right of the record '
              'button) and lock focus on the flower. Focus then stays fixed for '
              'the whole session. This is recommended: autofocus can drift onto '
              'the background if the flower moves.',
            ),
          ],
        ),
      ),
      actions: [
        // Checkbox + button share the actions row; keep them readable on small
        // screens by letting the row wrap.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: InkWell(
                onTap: () => setState(() => _dontShowAgain = !_dontShowAgain),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _dontShowAgain,
                      onChanged: (v) =>
                          setState(() => _dontShowAgain = v ?? false),
                    ),
                    const Flexible(child: Text("Don't show again")),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(_dontShowAgain),
              child: const Text('Got it'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bullet(IconData icon, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ],
  );
}
