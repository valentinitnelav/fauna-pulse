// Pollinator Monitor — the live recording screen.
//
// Ties everything together: the YOLO camera preview, the ROI box, the tracker,
// the time-lapse photo capture, and the append-only log. The detector and the
// YUV->RGB conversion all run inside the plugin; we only consume its per-frame
// results here and never touch raw camera pixels on the hot path.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../capture/roi_capture.dart';
import '../capture/time_lapse_plan.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../logging/device_thermal.dart';
import '../logging/error_reporter.dart';
import '../logging/session_logger.dart';
import '../models/model_catalog.dart';
import '../models/roi.dart';
import '../models/schedule_window.dart';
import '../models/session_config.dart';
import '../services/recording_keepalive.dart';
import '../models/track.dart';
import '../perf/adaptive_inference_throttle.dart';
import '../session/camera_diagnostics_controller.dart';
import '../session/frame_processor.dart';
import '../session/schedule_plan.dart';
import '../session/session_recorder.dart';
import '../tracking/byte_track.dart';
import '../widgets/calibrating_banner.dart';
import '../widgets/preview_transform.dart';
import '../widgets/roi_mask.dart';
import '../widgets/roi_overlay.dart';
import '../widgets/roi_size_sheet.dart';
import '../widgets/session_info_dialog.dart';
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

  // Round 73 (review B6): the screen's non-UI responsibilities live in three
  // plain collaborators — [_frame] does the per-frame detection mapping +
  // tracking (unit-testable, see frame_processor.dart), [_recorder] owns the
  // recording session's disk/lifecycle work, and [_probes] runs the one-time
  // camera probes. Thin getters below keep the screen's original field names
  // working so the build method and read sites did not have to change.
  late FrameProcessor _frame;
  final SessionRecorder _recorder = SessionRecorder();
  late final CameraDiagnosticsController _probes = CameraDiagnosticsController(
    controller: _controller,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  // Auto thermal-aware inference throttle. When active, it adjusts [_appliedCapFps]
  // each second from the measured inference time so the CPU keeps a cooling margin
  // (see AdaptiveInferenceThrottle). [_appliedCapFps] is the rate cap currently fed
  // to the native detector (null = uncapped); it also drives the YOLOView config.
  AdaptiveInferenceThrottle? _throttle;
  int? _appliedCapFps;

  Roi _roi = Roi.defaultRoi;
  int _imageWidth = 0;
  int _imageHeight = 0;
  // Full-resolution still dimensions (the photo actually saved), learned once
  // by probing capturePhoto() — see [CameraDiagnosticsController]. The analysis
  // frame above is much smaller, so the ROI resolution shown to the user is
  // based on these capture dimensions.
  int get _captureWidth => _probes.captureWidth;
  int get _captureHeight => _probes.captureHeight;
  bool _captureProbeStarted = false;
  // Which processor actually runs inference ("GPU"/"CPU"/"NPU"), reported by the
  // native side. Note: GPU can't run int8-quantized models and falls back to CPU.
  String _accelerator = '';
  // Camera-supported analysis stream resolutions ("WxH"), for the settings menu.
  List<String> get _streamResolutions => _probes.streamResolutions;
  // Estimated ceiling for what CameraX ImageAnalysis can actually stream on this
  // phone (the still/preview sizes above advertise more than the analysis pipeline
  // can deliver). Keys: hardwareLevel, recommendedMax ("WxH"), previewBoundW/H,
  // displayW/H. Probed once and handed to the settings sheet. See round 56.
  Map<String, dynamic> get _analysisCeiling => _probes.analysisCeiling;
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
  // Free storage on the session volume, sampled together with the temperature
  // (hours of JPEGs can fill a phone). Shown on screen so the user knows when
  // to clean up; logged with each thermal sample while recording.
  final ValueNotifier<StorageReading> _storageVN = ValueNotifier(
    const StorageReading(),
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
  double get _minFocusDistance => _probes.minFocusDistance;
  bool _focusManual = false;
  double _focusValue = 0;
  bool _showFocusSlider = false;

  // Rear-camera lens selection. The device's available lenses (main wide,
  // ultra-wide, telephoto, …) are read once from the camera. Each lens has an
  // effective zoom factor (1.0 = main wide). The lens-switch button cycles
  // through them *before* recording; the chosen lens is fixed for the session
  // and logged in the start metadata. Empty / single-entry on phones that
  // expose only one usable lens — see the camera-diagnostics dialog for why.
  List<LensInfo> get _lenses => _probes.lenses;
  int get _lensIndex => _probes.lensIndex;
  String get _lensLabel => _probes.lensLabel;

  // Per-camera diagnostics (id, facing, focal lengths, logical/physical, whether
  // usable for inference + why). Read once while the camera is live and passed to
  // the settings sheet for display under Settings → Camera; never shown on the
  // live recording screen.
  List<Map<String, dynamic>> get _cameraDiagnostics =>
      _probes.cameraDiagnostics;

  // Inference-error reporting. Set when the detector reports an error (e.g. an
  // incompatible model) or appears stalled (camera delivering, detector at 0 FPS).
  // Drives a dismissible warning banner with a "Create report" action.
  String? _inferenceError;
  bool _errorBannerDismissed = false;
  StreamSubscription<String>? _errorSub;
  // Set when the session log itself can no longer be written (storage full /
  // permission revoked). Kept separate from _inferenceError because the
  // watchdog clears that one as soon as the detector produces frames — this
  // condition must stay visible until dismissed or a new session starts.
  String? _logWriteError;
  // Watchdog state: have we ever seen the detector produce a frame, and since when
  // has the camera been delivering frames without it?
  bool _detectorEverRan = false;
  int _camDeliverStartMs = 0;
  // Camera-delivery watchdog (B4): when the camera *itself* stops delivering
  // (HAL crash, another app grabbing it, OS reclaim) no stream events arrive
  // at all — so this check runs on the 1 s recording ticker, not in the
  // stream callback. Any stream event counts as alive, including the ~1 Hz
  // gate-idle heartbeats (a sleeping detector is intentional; a silent
  // camera is not).
  int _lastStreamEventMs = 0;
  bool _cameraSilent = false;
  static const int _cameraSilentAfterMs = 10000;
  static const String _cameraSilentError =
      'The camera stopped delivering frames. Another app may have taken it '
      'over, or the camera service failed. Stop and restart the session '
      '(or reopen the app) to resume recording.';

  // Motion-gate state mirrored from the native side (held by [_frame]). While
  // the gate is idle the detector is deliberately asleep (no results), so the
  // UI must show "idle" instead of a scary 0-FPS state, and the watchdog must
  // stay quiet.
  bool get _gateIdle => _frame.gateIdle;
  // Live changed-pixel fraction (0..1) from the gate, for tuning the trigger.
  final ValueNotifier<double> _motionScoreVN = ValueNotifier(0);

  // Recording state lives in [_recorder] (round 73, review B6b): `recording`
  // flips false at the START of the stop sequence (so the frame path stops
  // logging instantly) and `stopping` guards against a quick second tap
  // falling into the "start recording" branch while teardown is running.
  bool get _recording => _recorder.recording;
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
  SessionLogger? get _logger => _recorder.logger;
  Timer? _sessionTimer;

  // Time-lapse capture mode (round 97): a self-rescheduling one-shot timer
  // drives clock-triggered photo bursts while recording. [_timeLapsePlan] is
  // the pure burst math (anchored at [_timeLapseStartMs] = recording start);
  // [_tlBurstActive] mirrors the current phase for the chip and for pushing
  // the phase-appropriate native frame-sampling rate; [_tlLastCycle] detects
  // burst starts (re-arm the scheduler's capture window).
  Timer? _timeLapseTimer;
  TimeLapsePlan? _timeLapsePlan;
  int _timeLapseStartMs = 0;
  int _tlLastCycle = -1;
  bool _tlBurstActive = false;

  // Scheduled recording (opt-in via Settings). While [_schedule] is non-null a
  // scheduled run is active: [_scheduleTimer] re-arms itself for the next
  // window boundary (capped at 60 s so doze gaps / clock jumps self-heal) and
  // [_scheduleTick] reconciles the actual state against the plan. Between
  // windows the run "scheduled-sleeps": the session is closed, the camera is
  // FULLY unbound (`_controller.pause()` — the blackout alone only detaches
  // the preview) and the blackout cover is up; the keep-alive service +
  // wakelock stay on for the whole run so the OS can't kill the sleeping app.
  // [_scheduleBusy] serializes the async transitions (a 60 s tick must not
  // start a second wake while one is mid-flight).
  SchedulePlan? _schedule;
  Timer? _scheduleTimer;
  bool _scheduleBusy = false;
  bool _scheduleSleeping = false;
  int _scheduleSessionsDone = 0;
  // Tap-for-status while scheduled-sleeping: shows day/next-window info at
  // readable brightness for a few seconds, then re-dims (never wakes fully).
  bool _sleepStatusVisible = false;
  Timer? _sleepStatusTimer;

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
    _frame = FrameProcessor(tracker: _tracker);
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
      builder: (_) => const SessionInfoDialog(),
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
    // Free storage rides along on the thermal cadence: it changes on the same
    // "slowly, over hours" timescale and needs no timer of its own.
    final storage = await DeviceStorage.read();
    if (!mounted) return;
    _thermalVN.value = reading;
    _storageVN.value = storage;
    // While recording, log the temperature so heat can be reviewed afterwards
    // (plus free storage, so fill rate is visible in the session data).
    if (_recording) {
      _logger?.logThermal({...reading.toJson(), ...storage.toJson()});
    }
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
    // While the motion gate keeps the detector asleep, no inference happens —
    // so the inference-derived fields are OMITTED rather than logged as 0 (or,
    // worse, as their last awake values, which is what flat-lined the FPS and
    // inference-time graphs before round 77). Absent = "gate idle, detector
    // off"; present = the detector really ran at that number. Stats read the
    // gaps as missing data, exactly as the owner wants. `gate_idle` makes the
    // state explicit; camera_fps stays, it is real regardless.
    final gateIdle = _gateIdle;
    // Motion-only and time-lapse capture: the detector never runs at all, so
    // the inference-derived fields are omitted even while frames flow (same
    // rule — absent means "detector off", never a logged 0).
    final detectorOff = gateIdle || !_config.detectorEnabled;
    _logger?.logFps({
      if (gateIdle) 'gate_idle': true,
      if (_config.motionOnlyCapture) 'motion_only': true,
      if (_config.timeLapseCapture) 'time_lapse': true,
      if (!detectorOff) ...{
        'fps': _fpsVN.value,
        'detector_fps': at(trio, 1),
        'pipeline_fps': at(trio, 2),
        'pre_ms': at(perf, 0),
        'inf_ms': at(perf, 1),
        'post_ms': at(perf, 2),
        'track_ms': _lastTrackMs,
      },
      'camera_fps': at(trio, 0),
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
    _scheduleTimer?.cancel();
    _sleepStatusTimer?.cancel();
    _thermalTimer?.cancel();
    _fpsLogTimer?.cancel();
    _powerTimer?.cancel();
    _recordTicker?.cancel();
    _timeLapseTimer?.cancel();
    _errorSub?.cancel();
    _blackoutHintTimer?.cancel();
    // A scheduled run disposed while *sleeping* holds the keep-alive service
    // without a recording (the recording path releases it via _stopRecording
    // below). Best-effort, unawaited — the screen is going away.
    if (_schedule != null && !_recording) {
      RecordingKeepAlive.stop().catchError(
        (Object e) => logSwallowed('schedule_keepalive_stop', e),
      );
    }
    WidgetsBinding.instance.removeObserver(this);
    // Stop late camera-probe results from calling setState on a dead screen.
    _probes.dispose();
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
    _storageVN.dispose();
    _recordElapsedVN.dispose();
    _flashTimer?.cancel();
    _captureFlashVN.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground mid-session: re-assert the screen-on wakelock in
    // case it was cleared while away, so a long unattended recording keeps the
    // screen on (and the app foreground) reliably. A scheduled run needs it even
    // while sleeping between windows (no recording, but the run must survive).
    if (state == AppLifecycleState.resumed &&
        (_recording || _schedule != null)) {
      WakelockPlus.enable();
    }
    // A scheduled run reconciles against the plan immediately on resume: if
    // the OS froze our timers while away, this catches a missed boundary now
    // rather than at the next ≤60 s self-check.
    if (state == AppLifecycleState.resumed && _schedule != null) {
      _scheduleTick();
    }
    // Going to the background (or the engine detaching): force the log queue
    // to disk NOW. Aggressive OEM battery managers — the Xiaomi test device
    // included — can kill a backgrounded app without warning; this shrinks
    // the loss window from ≤0.5 s of detections to ~zero. `hidden` fires
    // just before `paused` on Android; flushing on both is harmless.
    if (_recording &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      _logger?.flushNow();
    }
  }

  // --- Per-frame pipeline -------------------------------------------------

  void _onStreamingData(Map<String, dynamic> data) {
    // Any event from the native side means the camera is alive: feed the
    // camera-delivery watchdog and clear its banner if it had fired.
    _lastStreamEventMs = DateTime.now().millisecondsSinceEpoch;
    if (_cameraSilent) {
      _cameraSilent = false;
      if (_recording) {
        _logger?.logAppError({
          'source': 'watchdog',
          'message': 'Camera frame delivery resumed.',
        });
      }
      if (mounted && _inferenceError == _cameraSilentError) {
        setState(() => _inferenceError = null);
      }
    }
    // Motion-gate idle heartbeat: while the gate keeps the detector asleep the
    // native side sends ~1 Hz maps with only gate state + camera FPS (no
    // detections). Update the gate indicator and bail out — no tracking, no
    // watchdog (0 detector FPS is *intentional* here).
    if (data['gateIdle'] == true) {
      final hbCamFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
      _motionScoreVN.value = (data['motionScore'] as num?)?.toDouble() ?? 0;
      // The detector is asleep: no inference is happening, so every
      // inference-derived number must read 0 now. These used to keep their
      // last awake values ("Pipeline: 11.7 fps", frozen inf_ms flat-lining
      // the end-of-session graphs) — round 77.
      _fpsVN.value = 0;
      _perfVN.value = const [0, 0, 0];
      _lastTrackMs = 0;
      _fpsTrioVN.value = [hbCamFps, 0, 0];
      _setGateIdle(true);
      return;
    }
    if (data.containsKey('gateIdle')) _setGateIdle(false);
    if (data.containsKey('motionScore')) {
      _motionScoreVN.value = (data['motionScore'] as num?)?.toDouble() ?? 0;
    }

    // Motion-only capture mode: the detector never runs, so the native side
    // sends awake gate maps (`motionOnly: true`, no detections) instead of
    // results. Drive the motion time-lapse photos from them and bail out —
    // no tracking, and the 0-FPS detector watchdog below must NEVER see these
    // frames (0 detector FPS is the whole point of the mode, not a failure).
    if (_config.motionOnlyCapture && data['motionOnly'] == true) {
      final w = (data['imageWidth'] as num?)?.toInt() ?? _imageWidth;
      final h = (data['imageHeight'] as num?)?.toInt() ?? _imageHeight;
      final cameraFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
      // No inference is happening: every inference-derived number reads 0
      // (same honesty rule as the gate-idle heartbeat above, round 77).
      _fpsVN.value = 0;
      _perfVN.value = const [0, 0, 0];
      _lastTrackMs = 0;
      _fpsTrioVN.value = [cameraFps, 0, 0];
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_recorder.recordMotionFrame(
        nowMs,
        motionScore: _motionScoreVN.value,
      )) {
        _flashCaptureCue();
      }
      if (mounted && (w != _imageWidth || h != _imageHeight)) {
        setState(() {
          _imageWidth = w;
          _imageHeight = h;
          _snapRoiToSourceGrid();
        });
      }
      // Same one-time bootstrap as the detector path below: these maps carry
      // the analysis dims precisely so the ROI push + still-size probe can
      // run when the app starts straight into motion-only mode.
      if (!_captureProbeStarted && w > 0 && h > 0) {
        _captureProbeStarted = true;
        _pushInferenceRoi();
        _pushMotionGate();
        _pushCameraFpsCap();
        _pushTimeLapse();
        _probes.begin(
          analysisDims: () => (_imageWidth, _imageHeight),
          preferredLensZoom: _config.selectedLensZoom,
        );
      }
      return;
    }

    // Time-lapse capture mode: photos are driven by [_timeLapseTick]'s clock,
    // NOT by these maps — the native side only heartbeats ~1 Hz (with dims)
    // so the bootstrap and the camera watchdog stay fed. Zero the inference
    // numbers and bail out before the 0-FPS detector watchdog, exactly like
    // the motion-only branch above.
    if (_config.timeLapseCapture && data['timeLapse'] == true) {
      final w = (data['imageWidth'] as num?)?.toInt() ?? _imageWidth;
      final h = (data['imageHeight'] as num?)?.toInt() ?? _imageHeight;
      final cameraFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
      _fpsVN.value = 0;
      _perfVN.value = const [0, 0, 0];
      _lastTrackMs = 0;
      _fpsTrioVN.value = [cameraFps, 0, 0];
      if (mounted && (w != _imageWidth || h != _imageHeight)) {
        setState(() {
          _imageWidth = w;
          _imageHeight = h;
          _snapRoiToSourceGrid();
        });
      }
      if (!_captureProbeStarted && w > 0 && h > 0) {
        _captureProbeStarted = true;
        _pushInferenceRoi();
        _pushMotionGate();
        _pushCameraFpsCap();
        _pushTimeLapse();
        _probes.begin(
          analysisDims: () => (_imageWidth, _imageHeight),
          preferredLensZoom: _config.selectedLensZoom,
        );
      }
      return;
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
    // callback runs the ROI mapping + tracking + overlay update). Smoothed,
    // maintained by the frame processor.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _fpsTrioVN.value = [cameraFps, fps, _frame.updatePipelineFps(nowMs)];

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
          'message':
              'Detector produced no results for 8 s while the camera '
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
        'pipeline=${_frame.pipelineFpsEma.toStringAsFixed(1)} engine=$accel '
        'pre=${preMs.toStringAsFixed(1)} inf=${inferMs.toStringAsFixed(1)} '
        'post=${postMs.toStringAsFixed(1)} '
        'track=${_lastTrackMs.toStringAsFixed(2)} '
        'cap=${_appliedCapFps ?? 0} analysis=${w}x$h',
      );
    }
    // Detection mapping + tracking live in [FrameProcessor] (round 73, review
    // B6a) so the core per-frame logic is unit-testable: it maps the
    // ROI-normalized boxes back onto the full frame (or filters full-frame
    // boxes by ROI centre on the fallback path), confines them to the ROI,
    // and advances the tracker.
    final result = _frame.process(
      data: data,
      roi: _roi,
      width: w,
      height: h,
      fallbackAspect: _frameAspect,
    );
    _lastTrackMs = result.trackMs;

    // While recording, log this frame's tracks and trigger a shared ROI photo
    // when one is due; blink the border as the visual cue if it was. Detector
    // mode only: during startup a few detector-style frames can arrive before
    // the first setMotionGate/setTimeLapse lands natively, and they must
    // never write `detections` records into a motion-only/time-lapse log.
    if (_config.detectorEnabled &&
        _recorder.recordFrame(
          result.tracks,
          result.roiRect,
          result.timestampMs,
        )) {
      _flashCaptureCue();
    }

    // High-frequency updates go through notifiers (no full rebuild).
    _tracksVN.value = result.tracks;
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
      _pushCameraFpsCap();
      _pushTimeLapse();
      _probes.begin(
        analysisDims: () => (_imageWidth, _imageHeight),
        preferredLensZoom: _config.selectedLensZoom,
      );
    }
  }

  /// Applies a motion-gate state change reported by the native side: the
  /// frame processor holds the state and — crucially — expires stale "lost"
  /// tracks after a sleep longer than the occlusion tolerance (see
  /// [FrameProcessor.setGateIdle]); this wrapper updates the on-screen
  /// indicator and logs the transition to the session JSONL (so gated periods
  /// are auditable when validating recall).
  void _setGateIdle(bool idle) {
    final change = _frame.setGateIdle(
      idle,
      occlusionSeconds: _config.occlusionSeconds,
    );
    if (change == null) return;
    // Motion-only capture: the gate going to sleep ends the motion event —
    // re-arm the photo burst so the NEXT wake photographs immediately
    // (round 96: without this, a second hand-wave within ~wake+duration
    // seconds of the first burst captured nothing). Transition-only: a
    // repeated idle heartbeat returns null above.
    if (change.idle && _config.motionOnlyCapture) {
      _recorder.onMotionGateIdle();
    }
    if (mounted) setState(() {});
    if (_recording) {
      _logger?.logMotionGate({
        'state': change.idle ? 'idle' : 'awake',
        'motion_score': _motionScoreVN.value,
        if (!change.idle && change.idleSeconds > 0)
          'idle_s': double.parse(change.idleSeconds.toStringAsFixed(1)),
      });
    }
  }

  /// Advances to the next available rear lens (cycles round; the probe
  /// controller updates the label and applies the lens). Only reachable
  /// before recording (the button is disabled while recording, because a lens
  /// change rebinds the camera and shifts the field of view). Persists the new
  /// choice so the next session reopens on the same lens.
  Future<void> _cycleLens() async {
    final lens = await _probes.cycleLens();
    if (lens == null) return;
    final updated = _config.copyWith(selectedLensZoom: lens.zoomFactor);
    setState(() => _config = updated);
    await updated.save();
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

  /// Camera-delivery watchdog (B4), run from the 1 s recording ticker: if no
  /// stream event of any kind (detections, heartbeats) has arrived for
  /// [_cameraSilentAfterMs], the camera itself has stopped — a HAL crash,
  /// another app grabbing it, or OS resource reclaim. An unattended session
  /// would otherwise sit recording nothing for hours. Fires once per outage:
  /// app_error line (flushed, in case this precedes a bigger failure) + the
  /// red banner; both clear automatically if delivery resumes.
  void _checkCameraDelivery() {
    if (!_recording || _cameraSilent || _lastStreamEventMs == 0) return;
    final silentMs = DateTime.now().millisecondsSinceEpoch - _lastStreamEventMs;
    if (silentMs < _cameraSilentAfterMs) return;
    _cameraSilent = true;
    _logger?.logAppError({
      'source': 'watchdog',
      'message':
          'Camera delivered no frames for ${(silentMs / 1000).round()} s '
          '(camera lost: HAL crash, other app, or OS reclaim).',
    });
    _logger?.flushNow();
    if (mounted) {
      setState(() {
        _inferenceError = _cameraSilentError;
        _errorBannerDismissed = false;
      });
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

  // --- Recording lifecycle ------------------------------------------------

  Future<void> _toggleRecording() async {
    // A tap while the previous stop sequence is still tearing down does
    // nothing (it would otherwise start a new session mid-teardown).
    if (_recorder.stopping) return;
    // While a scheduled run is active the record button means "stop the whole
    // run", never "stop this one window" — confirm-guarded, since it ends a
    // possibly multi-day deployment.
    if (_schedule != null) {
      await _confirmAbortSchedule();
      return;
    }
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
      await _stopAndShowSummary();
    } else if (_config.scheduleEnabled) {
      // Scheduled mode: the record button launches the whole windows×days run
      // (after a confirm dialog spelling out what will happen) instead of a
      // single manual session.
      await _confirmStartSchedule();
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

  /// The manual stop path: end the session normally and review its summary.
  /// Shared by the record-button stop, the [_sessionTimer] timed end, and a
  /// schedule abort mid-window (the user is present in all three).
  Future<void> _stopAndShowSummary() async {
    // A timed session end arrives here straight from [_sessionTimer] with the
    // blackout cover still up: the summary would otherwise be pushed on top of
    // it at minimum window brightness, with no cover left to tap (the window
    // brightness override outlives this route — it is per-Activity, and the
    // whole app is one Activity). No-op when not blacked out.
    await _exitBlackout();
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
      MaterialPageRoute(builder: (_) => SessionSummaryScreen(logFile: logFile)),
    );
    if (mounted && _paused) {
      _paused = false;
      await _controller.resume();
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

  /// [scheduleSlot] is set when this session is one window of a scheduled run:
  /// the folder gets a `_d<day>w<window>` suffix so the per-window sessions
  /// sort readably, the start record carries a `schedule` block, and the
  /// [_sessionTimer] auto-end is NOT armed (the window's end time governs —
  /// the default 60-min session length must not truncate a 4-hour window).
  Future<void> _startRecording({
    required String focusMode,
    ScheduleSlot? scheduleSlot,
  }) async {
    _tracker.reset();

    // The session folder, logger, photo scheduler, wakelock and keep-alive
    // service are all set up by [SessionRecorder.start] (round 73, review
    // B6b); this method supplies the screen-state pieces: the start-record
    // metadata, the capture wiring, and the log-write-failure banner.
    _logWriteError = null;
    await _recorder.start(
      folderName: scheduleSlot == null
          ? _config.folderName
          : '${_config.folderName}'
                '_d${scheduleSlot.day + 1}w${scheduleSlot.windowIndex + 1}',
      onLogWriteError: (error) {
        if (!mounted) return;
        setState(() {
          _logWriteError =
              'Cannot write to the session log (storage full or removed?). '
              'The session keeps running, but detections may no longer be '
              'saved. Free up storage or stop the session.';
          _errorBannerDismissed = false;
        });
      },
      onStartReadings: (thermal, storage) {
        if (!mounted) return;
        _thermalVN.value = thermal;
        _storageVN.value = storage;
      },
      startMetadata: () => {
        'model_path': _config.modelPath,
        'task': _config.task.name,
        'use_gpu': _config.useGpu,
        'cpu_threads': _config.cpuThreads,
        // What was actually used (vs the request above). CPU fallback happens
        // per model when the GPU backend can't compile its graph — int8 models
        // CAN run on GPU (verified round 77, session_120).
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
        // Which slot of a scheduled run this session is (1-based for humans);
        // absent for a manual session. The windows themselves are in `config`.
        if (scheduleSlot != null && _schedule != null)
          'schedule': {
            'day': scheduleSlot.day + 1,
            'days_total': _schedule!.days,
            'window': scheduleSlot.windowIndex + 1,
            'windows_per_day': _schedule!.windows.length,
            'window_start':
                _schedule!.windows[scheduleSlot.windowIndex].startLabel,
            'window_end':
                _schedule!.windows[scheduleSlot.windowIndex].endLabel,
          },
        // Full user configuration as one self-describing block, so the end-of-session
        // summary can list *every* setting the user chose (and any setting added in
        // future automatically appears) without each one needing its own top-level
        // key here. The individual keys above are kept for existing readers and for
        // sessions recorded before this block existed.
        'config': _config.toJson(),
      },
      captureBuilder: (framesDir, fileToken) => RoiCaptureScheduler(
        framesDir: framesDir,
        sessionToken: fileToken,
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
            return RawStill(
              bytes: raw.$1,
              rotationDegrees: raw.$2,
              isFront: raw.$3,
            );
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
        onError: (fileName, error) =>
            _logAsyncError('roi_capture', 'Photo $fileName failed: $error'),
      ),
    );

    // The session-length auto-end applies to MANUAL sessions only: in a
    // scheduled run each window's end time governs (via _scheduleTick), and
    // the default 60-min length must not silently truncate a longer window.
    if (scheduleSlot == null) {
      _sessionTimer = Timer(
        Duration(minutes: _config.sessionMinutes),
        () => _toggleRecording(),
      );
    }

    // Start the elapsed-time clock for the REC banner. The same 1 s tick
    // hosts the camera-delivery watchdog: it must run on a timer because a
    // dead camera produces no stream callbacks at all.
    _recordStart = DateTime.now();
    _recordElapsedVN.value = 0;
    _lastStreamEventMs = DateTime.now().millisecondsSinceEpoch;
    _cameraSilent = false;
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = _recordStart;
      if (start != null) {
        _recordElapsedVN.value = DateTime.now().difference(start).inSeconds;
      }
      _checkCameraDelivery();
    });

    // Time-lapse mode: anchor the burst plan at the recording start and kick
    // off the self-rescheduling tick (works the same for manual sessions and
    // scheduled windows — each window is its own recording, so each anchors
    // its own plan).
    if (_config.timeLapseCapture) {
      _timeLapsePlan = TimeLapsePlan(
        stepMs: (_config.stepSeconds * 1000).round(),
        burstMs: (_config.durationSeconds * 1000).round(),
        intervalMs: (_config.timeLapseIntervalSeconds * 1000).round(),
      );
      _timeLapseStartMs = DateTime.now().millisecondsSinceEpoch;
      _tlLastCycle = -1;
      _tlBurstActive = false;
      _timeLapseTimer?.cancel();
      _timeLapseTimer = Timer(Duration.zero, _timeLapseTick);
    }

    // Recording is already live inside the recorder; rebuild the screen so
    // the REC banner and controls reflect it.
    setState(() {});

    // Snapshot the engine-selection logs (still in the ring buffer at this point)
    // into the session folder for later offline diagnosis.
    await _recorder.saveLogcat('logcat_start.txt', maxLines: 2000);
  }

  /// Thin wrapper around [SessionRecorder.stop] (which owns the ordered
  /// teardown — critical records first, best-effort diagnostics after):
  /// cancels the screen's timers, hands over the tracker's visit count for
  /// the end record, then rebuilds. Safe to run unawaited from dispose().
  Future<void> _stopRecording({
    required bool normal,
    bool retainKeepAlive = false,
  }) async {
    if (_recorder.stopping) return;
    _sessionTimer?.cancel();
    _recordTicker?.cancel();
    _recordTicker = null;
    _timeLapseTimer?.cancel();
    _timeLapseTimer = null;
    _timeLapsePlan = null;
    if (_tlBurstActive) {
      _tlBurstActive = false;
      _pushTimeLapse(); // back to the low between-burst sampling rate
    }
    await _recorder.stop(
      normal: normal,
      uniqueTrackCount: _tracker.totalConfirmed,
      retainKeepAlive: retainKeepAlive,
    );
    if (mounted) setState(() {});
  }

  // --- Scheduled recording --------------------------------------------------

  /// Spells out the run before starting it (windows, days, and that the
  /// screen goes dark between windows) — a scheduled run can hold the phone
  /// for days, so a stray tap must not launch one silently.
  Future<void> _confirmStartSchedule() async {
    if (!_config.isScheduleValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The schedule is invalid (check the windows in Settings).',
          ),
        ),
      );
      return;
    }
    final windows = _config.scheduleWindows.map((w) => w.label).join(', ');
    final days = _config.scheduleDays;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start scheduled run?'),
        content: Text(
          'Recording windows: $windows\n'
          'Days: $days\n\n'
          'Each window is saved as its own session. Between windows the '
          'screen goes dark and the camera turns off to save power — the app '
          'must stay open (and on power) the whole time. Tap the dark screen '
          'to see the status; the record button stops the run.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Start',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _startSchedule();
  }

  Future<void> _startSchedule() async {
    final plan = SchedulePlan(
      windows: _config.scheduleWindows,
      days: _config.scheduleDays,
      startedAt: DateTime.now(),
    );
    if (plan.phaseAt(DateTime.now()) == SchedulePhase.finished) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "All of today's windows are already over — nothing to record. "
            'Adjust the windows or the number of days in Settings.',
          ),
        ),
      );
      return;
    }
    // Same one-time battery-optimization nudge as a manual session — even
    // more important here, where the app may sleep unattended overnight.
    await _ensureUnrestricted();
    if (!mounted) return;
    setState(() {
      _schedule = plan;
      _scheduleSessionsDone = 0;
    });
    // Protect the WHOLE run up front (not just each window): the foreground
    // service + wakelock must already be up if the run starts with a sleep
    // phase (e.g. started at 22:00 for a 06:00 window). Both are idempotent,
    // so the per-window SessionRecorder.start() calls are harmless.
    await Permission.notification.request();
    await RecordingKeepAlive.start();
    await WakelockPlus.enable();
    _scheduleTick();
  }

  /// The reconciler: compares what the plan says SHOULD be happening against
  /// what IS happening and transitions if they differ, then re-arms the timer
  /// for the next boundary (capped at 60 s). Everything derives from the wall
  /// clock on each call, so a missed/late tick — OS doze, a clock jump, a
  /// failed wake — is corrected by the next one instead of compounding.
  void _scheduleTick() {
    final plan = _schedule;
    if (plan == null) return;
    if (!_scheduleBusy && !_recorder.stopping) {
      switch (plan.phaseAt(DateTime.now())) {
        case SchedulePhase.recording:
          if (!_recording) {
            final slot = plan.activeSlotAt(DateTime.now());
            if (slot != null) _wakeForWindow(slot);
          }
        case SchedulePhase.sleeping:
          if (_recording) {
            _endWindow();
          } else if (!_scheduleSleeping) {
            // Sleep-first start (or a wake that found its window already
            // over): park the camera and go dark until the next window.
            _enterScheduledSleep();
          }
        case SchedulePhase.finished:
          _finishSchedule();
          return; // run over — don't re-arm
      }
    }
    _armScheduleTimer();
  }

  void _armScheduleTimer() {
    _scheduleTimer?.cancel();
    final plan = _schedule;
    if (plan == null) return;
    final now = DateTime.now();
    // Aim just past the next boundary so the tick lands cleanly inside the
    // new phase; never sleep longer than 60 s so doze gaps, clock changes and
    // failed wakes are retried promptly.
    var delay = const Duration(seconds: 60);
    final next = plan.nextTransitionAt(now);
    if (next != null) {
      final toNext = next.difference(now) + const Duration(milliseconds: 500);
      if (toNext < delay) delay = toNext;
    }
    if (delay <= Duration.zero) delay = const Duration(seconds: 1);
    _scheduleTimer = Timer(delay, _scheduleTick);
  }

  /// A window's end: close this window's session normally (its own folder +
  /// summary data, `ended_normally: true`) WITHOUT the summary screen — the
  /// user is asleep/away — and go into scheduled sleep until the next window.
  Future<void> _endWindow() async {
    _scheduleBusy = true;
    try {
      // Keep the foreground service + wakelock: the run isn't over, and the
      // sleeping app must survive until the next window (MIUI kills easily).
      await _stopRecording(normal: true, retainKeepAlive: true);
      _scheduleSessionsDone++;
      await _enterScheduledSleep();
    } finally {
      _scheduleBusy = false;
    }
  }

  /// Scheduled sleep = the real between-windows power save: the camera is
  /// FULLY unbound (analysis + still capture + preview — `pause()` is the
  /// same call the summary/settings cool-down uses), and the blackout cover
  /// goes up with the sleep-status variant (tap shows status, never wakes).
  Future<void> _enterScheduledSleep() async {
    if (!_paused) {
      try {
        await _controller.pause();
        _paused = true;
      } catch (e) {
        _logAsyncError('schedule_pause', e);
      }
    }
    if (!mounted) return;
    setState(() => _scheduleSleeping = true);
    await _enterBlackout();
    // Show the status once on entry (next window, day X/Y) at readable
    // brightness; it re-dims by itself like a tap would.
    _showSleepStatus();
  }

  /// A window's start: rebind the camera (cover stays up), wait until frames
  /// actually flow, then start this window's session and re-assert the
  /// blackout steady state. On a wake failure the camera is parked again and
  /// the ≤60 s tick retries — a transient camera error at 06:00 must not
  /// silently cost the whole morning window.
  Future<void> _wakeForWindow(ScheduleSlot slot) async {
    _scheduleBusy = true;
    try {
      if (_paused) {
        await _controller.resume();
        _paused = false;
      }
      final gotFrames = await _waitForFrames(const Duration(seconds: 20));
      if (!mounted || _schedule == null) return;
      if (!gotFrames) {
        logSwallowed(
          'schedule_wake',
          'Camera produced no frames within 20 s of the scheduled wake — '
              'parked again, retrying on the next tick.',
        );
        try {
          await _controller.pause();
          _paused = true;
        } catch (e) {
          _logAsyncError('schedule_wake_pause', e);
        }
        return;
      }
      _sleepStatusTimer?.cancel();
      setState(() {
        _scheduleSleeping = false;
        _sleepStatusVisible = false;
      });
      await _startRecording(
        focusMode: _focusModeForLog(),
        scheduleSlot: slot,
      );
      // The cover never came down: put the display + preview back into the
      // measured power-save state now that the camera is running again. (If
      // the cover happens to be down — user was watching — recording proceeds
      // visibly and the moon button re-darkens as usual.)
      if (_blackout) await _applyBlackoutSteadyState();
    } finally {
      _scheduleBusy = false;
    }
  }

  /// Polls [_lastStreamEventMs] (fed by every native stream event, including
  /// gate-idle heartbeats) until a frame newer than the call arrives.
  Future<bool> _waitForFrames(Duration timeout) async {
    final since = DateTime.now().millisecondsSinceEpoch;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || _schedule == null) return false;
      if (_lastStreamEventMs >= since) return true;
    }
    return false;
  }

  /// The run's natural end: close everything, release the keep-alive service
  /// + wakelock, restore the screen and tell the user what was recorded. The
  /// per-window sessions are on the home screen's list — no summary stack.
  Future<void> _finishSchedule() async {
    final plan = _schedule;
    if (plan == null) return;
    _scheduleBusy = true;
    try {
      _scheduleTimer?.cancel();
      _scheduleTimer = null;
      if (_recording) {
        // Final window ran to the end of the run: a plain stop releases the
        // keep-alive service and wakelock as usual.
        await _stopRecording(normal: true);
        _scheduleSessionsDone++;
      } else {
        try {
          await RecordingKeepAlive.stop();
        } catch (e) {
          logSwallowed('schedule_keepalive_stop', e);
        }
      }
      final recorded = _scheduleSessionsDone;
      _scheduleSleeping = false;
      // Clear the run BEFORE exiting blackout so its wakelock guard
      // (`_schedule == null`) really drops the wakelock.
      setState(() => _schedule = null);
      await _exitBlackout();
      if (_paused && mounted) {
        _paused = false;
        await _controller.resume();
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Scheduled run complete'),
          content: Text(
            '$recorded session${recorded == 1 ? '' : 's'} recorded. '
            'Each window is its own session — find them in the list on the '
            'home screen.',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      _scheduleBusy = false;
    }
  }

  /// Confirm-guarded abort of the whole run (record button, or the sleep
  /// overlay's stop button).
  Future<void> _confirmAbortSchedule() async {
    // Freeze the sleep-status auto-dim while the dialog is up — its 8 s timer
    // would otherwise drop the brightness to 0 mid-question.
    _sleepStatusTimer?.cancel();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop the scheduled run?'),
        content: Text(
          _recording
              ? 'The current window will be closed and its summary shown. '
                    'No further windows will be recorded.'
              : 'No further windows will be recorded.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep running'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Stop run',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _abortSchedule();
    } else if (mounted && _scheduleSleeping) {
      // Kept running: restart the status display so it re-dims normally.
      _showSleepStatus();
    }
  }

  /// Ends the run right now. Mid-window the user is present, so this follows
  /// the manual-stop path (summary screen for the aborted window); mid-sleep
  /// it just releases everything and brings the live preview back.
  Future<void> _abortSchedule() async {
    _scheduleBusy = true;
    try {
      _scheduleTimer?.cancel();
      _scheduleTimer = null;
      _sleepStatusTimer?.cancel();
      final wasSleeping = _scheduleSleeping;
      _scheduleSleeping = false;
      setState(() => _schedule = null);
      if (_recording) {
        await _stopAndShowSummary();
      } else if (wasSleeping) {
        try {
          await RecordingKeepAlive.stop();
        } catch (e) {
          logSwallowed('schedule_keepalive_stop', e);
        }
        await _exitBlackout();
        if (_paused && mounted) {
          _paused = false;
          await _controller.resume();
        }
      }
    } finally {
      _scheduleBusy = false;
    }
  }

  /// Tap on the dark cover while scheduled-sleeping: show the status (day,
  /// next window, sessions so far) at readable brightness for a few seconds,
  /// then drop back to dark. Deliberately NOT a full wake — the camera stays
  /// off and the cover stays up; only the stop button leaves the run.
  void _showSleepStatus() {
    _sleepStatusTimer?.cancel();
    if (mounted) setState(() => _sleepStatusVisible = true);
    ScreenBrightness().resetApplicationScreenBrightness().catchError(
      (Object e) => logSwallowed('sleep_status_brightness', e),
    );
    _sleepStatusTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || !_scheduleSleeping) return;
      setState(() => _sleepStatusVisible = false);
      ScreenBrightness().setApplicationScreenBrightness(0.0).catchError(
        (Object e) => logSwallowed('sleep_status_dim', e),
      );
    });
  }

  /// The sleep overlay's status text, recomputed on each build from the plan.
  String _sleepStatusText() {
    final plan = _schedule;
    if (plan == null) return '';
    final now = DateTime.now();
    final next = plan.nextSlotAt(now);
    if (next == null) return 'Scheduled run finishing…';
    final start = plan.startOf(next);
    final startsToday =
        start.year == now.year &&
        start.month == now.month &&
        start.day == now.day;
    final when = ScheduleWindow.hhmm(start.hour * 60 + start.minute);
    return 'Scheduled sleep — day ${next.day + 1}/${plan.days}\n'
        'Next recording: ${startsToday ? '' : 'tomorrow '}$when\n'
        '$_scheduleSessionsDone session'
        '${_scheduleSessionsDone == 1 ? '' : 's'} recorded so far';
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
  int get _inferenceCeilFps =>
      _config.inferenceFps > 0 ? _config.inferenceFps : 15;

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
    _blackoutHintTimer = Timer(_blackoutFade, _applyBlackoutSteadyState);
  }

  /// The blackout's steady-state power savings: preview stream detached at the
  /// camera + brightness at minimum. Split out of [_enterBlackout]'s hint
  /// timer so a scheduled wake — which starts recording underneath a cover
  /// that is ALREADY up — can re-apply it directly (the resumed camera comes
  /// back with the preview attached and compositing frames nobody can see).
  Future<void> _applyBlackoutSteadyState() async {
    if (!_blackout) return;
    // Round 82: dropping brightness alone was measured to save almost
    // nothing — the camera kept producing and compositing preview frames
    // behind the black cover (~1 CPU core). Detach the preview stream at
    // the camera; detection, tracking and photo capture keep running.
    // Skipped while the whole camera is unbound (scheduled sleep): there is
    // no bound preview use-case to detach, only a dead channel call.
    if (!_paused) {
      _controller
          .setPreviewEnabled(false)
          .catchError((Object e) => _logAsyncError('preview_off', e));
    }
    try {
      await ScreenBrightness().setApplicationScreenBrightness(0.0);
    } catch (e) {
      // Some devices reject 0.0 or lack the API; the opaque black cover alone
      // still hides the screen.
      logSwallowed('screen_dim', e);
    }
  }

  /// Leaves blackout: restores the previous screen brightness and the normal UI
  /// (which is rebuilt honouring the user's on-screen display settings — boxes,
  /// info panel, capture flash). Drops the wakelock again only if a session is
  /// not recording (an active recording keeps its own wakelock).
  Future<void> _exitBlackout() async {
    if (!_blackout) return;
    _blackoutHintTimer?.cancel();
    _sleepStatusTimer?.cancel();
    // Reattach the preview stream first (round 82) so the live image is back
    // within ~0.2 s of the wake tap; the native side re-asserts the focus
    // lock and camera fps cap after the reattach. Skipped while the whole
    // camera is unbound (scheduled sleep) — resume() rebinds everything.
    if (!_paused) {
      _controller
          .setPreviewEnabled(true)
          .catchError((Object e) => _logAsyncError('preview_on', e));
    }
    setState(() {
      _blackout = false;
      _blackoutHint = false;
      _sleepStatusVisible = false;
    });
    // Bring back the status/navigation bars (edge-to-edge matches the Activity's
    // default) and the screen brightness.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (e) {
      logSwallowed('screen_brightness_reset', e);
    }
    // An active recording keeps its own wakelock; so does a scheduled run —
    // even between windows the sleeping app must stay alive for days.
    if (!_recording && _schedule == null) await WakelockPlus.disable();
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
    _pushCameraFpsCap();
    _pushTimeLapse();
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
  ///
  /// The sheet is a real widget (RoiSizeSheet, round 71) rather than an
  /// inline StatefulBuilder: the old version disposed its text controller as
  /// soon as the sheet's future completed, but the builder could still run
  /// once more during the closing animation (keyboard inset animating away)
  /// and wrote to the disposed controller — a split-second red error flash
  /// on screen (caught twice by the round-67 error trap in session_107).
  Future<void> _editRoiSize() async {
    // Use the width the ROI crop is actually saved from, so the px values here
    // match the saved files and the on-screen readout.
    final srcW = _roiSourceWidth;
    if (srcW <= 0) return;
    final visible = _currentVisibleRect();
    const minPx = 96;
    // Cap by both the visible width and the source's short side (the real max).
    final maxPx = snapToMultipleOf32(
      visible.width * srcW,
    ).clamp(minPx, _maxRoiPx).toInt();
    final curPx = snapToMultipleOf32(
      _roi.sideFraction * srcW,
    ).clamp(minPx, maxPx).toInt();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      // Let the sheet grow with its content and sit above the keyboard so the
      // helper text below the slider is never clipped off the bottom.
      isScrollControlled: true,
      builder: (_) => RoiSizeSheet(
        minPx: minPx,
        maxPx: maxPx,
        initialPx: curPx,
        onApply: (px) => _onRoiChanged(
          Roi(
            centerX: _roi.centerX,
            centerY: _roi.centerY,
            sideFraction: px / srcW,
          ),
        ),
      ),
    );
  }

  /// Records a failed fire-and-forget call: console line for `flutter run`
  /// plus an `app_error` JSONL line when a session log is open, so "that
  /// feature silently did nothing all day" stays diagnosable from the field.
  void _logAsyncError(String source, Object error) {
    debugPrint('[$source] $error');
    _logger?.logAppError({'source': source, 'message': '$error'});
  }

  /// Sends the current ROI to the native side so inference runs only on that
  /// square crop (better small-object recall; nothing outside the ROI detected).
  void _pushInferenceRoi() {
    _controller
        .setInferenceRoi(
          cx: _roi.centerX,
          cy: _roi.centerY,
          side: _roi.sideFraction,
        )
        .catchError((Object e) => _logAsyncError('set_inference_roi', e));
  }

  /// Sends the camera frame-rate cap to the native side (round 82). This slows
  /// the camera *hardware* (sensor + image processor) — the standing load that
  /// keeps warming the phone even while the motion gate has the detector
  /// asleep. The inference cap above it only skips frames in software.
  void _pushCameraFpsCap() {
    _controller
        .setCameraFpsCap(_config.cameraFpsCap)
        .catchError((Object e) => _logAsyncError('set_camera_fps_cap', e));
  }

  /// Sends the motion-gate settings to the native pipeline. When enabled the
  /// detector sleeps while nothing moves inside the ROI (heat/battery saver);
  /// the native side always starts the gate awake so the user sees it working.
  void _pushMotionGate() {
    // In time-lapse mode the gate is irrelevant (photos are clock-driven):
    // force it off natively even if the detector-mode setting is on.
    final gateOn =
        _config.motionOnlyCapture ||
        (_config.detectorEnabled && _config.motionGateEnabled);
    _controller
        .setMotionGate(
          // Motion-only capture cannot work without the gate (it IS the
          // trigger), so it forces the gate on; the native side guards the
          // same way (belt and braces).
          enabled: gateOn,
          pixelDelta: _config.motionGatePixelDelta,
          areaFraction: _config.motionGateAreaFraction,
          wakeSeconds: _config.motionGateWakeSeconds,
          gridSize: _config.motionGateGridSize,
          idleFps: _config.motionGateIdleFps,
          motionOnly: _config.motionOnlyCapture,
        )
        .catchError((Object e) => _logAsyncError('set_motion_gate', e));
    if (!gateOn && _gateIdle) {
      // Gate switched off while idle: clear the idle indicator immediately.
      setState(_frame.forceGateAwake);
    }
  }

  /// Applies time-lapse mode natively. The frame-sampling rate follows the
  /// burst phase: high during a burst so fast ROI crops stay fresher than
  /// half a photo step, 1 fps between bursts (just frame-cache freshness for
  /// the next burst's first photo + the 1 Hz heartbeat).
  void _pushTimeLapse() {
    final burstFps = (2 / _config.stepSeconds).ceil().clamp(1, 30);
    _controller
        .setTimeLapse(
          enabled: _config.timeLapseCapture,
          sampleFps: _config.timeLapseCapture && _tlBurstActive ? burstFps : 1,
        )
        .catchError((Object e) => _logAsyncError('set_time_lapse', e));
  }

  /// Time-lapse driving tick (self-rescheduling one-shot; capped at 60 s so
  /// clock jumps/doze self-heal): asks the pure [TimeLapsePlan] what phase
  /// we're in, re-arms the capture window at each burst start, triggers the
  /// due photo, and re-pushes the native sampling rate on phase changes.
  void _timeLapseTick() {
    _timeLapseTimer = null;
    final plan = _timeLapsePlan;
    if (!_recording || !_config.timeLapseCapture || plan == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final t = nowMs - _timeLapseStartMs;
    final inBurst = plan.inBurstAt(t);
    if (inBurst) {
      final cycle = plan.cycleIndexAt(t);
      if (cycle != _tlLastCycle) {
        _tlLastCycle = cycle;
        _recorder.beginTimeLapseBurst();
      }
      if (_recorder.recordTimeLapseFrame(nowMs, burstIndex: cycle)) {
        _flashCaptureCue();
      }
    }
    if (inBurst != _tlBurstActive) {
      _tlBurstActive = inBurst;
      _pushTimeLapse();
      if (mounted) setState(() {}); // chip label flips
    }
    final delay = plan.nextTickDelayMs(t).clamp(100, 60000);
    _timeLapseTimer = Timer(Duration(milliseconds: delay), _timeLapseTick);
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
            cpuThreads: _config.cpuThreads,
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
                    : (((_config.motionGateEnabled &&
                                  _config.detectorEnabled) ||
                              _config.motionOnlyCapture) &&
                          _gateIdle)
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
                      // it reads from arm's length in the field. Time-lapse
                      // mode has its own chip (burst state + countdown).
                      if (_config.timeLapseCapture)
                        _timeLapseChip()
                      else if ((_config.motionGateEnabled &&
                              _config.detectorEnabled) ||
                          _config.motionOnlyCapture)
                        _gateStateChip(),
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
                              // Detector/pipeline rates are meaningless while
                              // the detector never runs (motion-only and
                              // time-lapse modes).
                              if (_config.detectorEnabled) ...[
                                _statLine(
                                  'Detector: ${f[1].toStringAsFixed(1)} fps '
                                  '(pre+inf+NMS)',
                                ),
                                _statLine(
                                  'Pipeline: ${f[2].toStringAsFixed(1)} fps '
                                  '(+track/overlay)',
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (_config.showFps && _config.detectorEnabled)
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
                      if ((_config.motionGateEnabled &&
                              _config.detectorEnabled) ||
                          _config.motionOnlyCapture)
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
                      // Detector-off modes replace the Engine line: no engine
                      // is doing any work (the model loaded but never runs).
                      _statLine(
                        _config.motionOnlyCapture
                            ? 'Mode: motion-only capture (detector off)'
                            : _config.timeLapseCapture
                            ? 'Mode: time-lapse (detector off)'
                            : engineLabel,
                      ),
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
                      // Free storage on the session volume — hours of JPEGs can
                      // fill a phone, so the user sees when to clean up before
                      // mounting it. Refreshed on the thermal cadence.
                      ValueListenableBuilder<StorageReading>(
                        valueListenable: _storageVN,
                        builder: (_, storage, _) {
                          final label = storage.label;
                          if (label.isEmpty) return const SizedBox.shrink();
                          return _statLine(label);
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
            const IgnorePointer(child: Center(child: CalibratingBanner())),
          // Error banner: a broken session log (storage full) outranks a
          // detector error — the watchdog auto-clears _inferenceError once
          // frames flow again, but a log-write failure must stay visible.
          if ((_logWriteError ?? _inferenceError) != null &&
              !_errorBannerDismissed)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: _errorBanner((_logWriteError ?? _inferenceError)!),
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
                            // Also locked during a scheduled run's sleep phase:
                            // settings changes mid-run would desync the plan.
                            onPressed: (_recording || _schedule != null)
                                ? null
                                : _openSettings,
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
                        _schedule != null
                            ? (_recording
                                  ? 'Scheduled recording — tap ■ to stop the run'
                                  : 'Scheduled run active')
                            : _recording
                            ? 'Recording — tap to stop'
                            : haveCaptureDims
                            ? (_config.scheduleEnabled
                                  ? 'Tap ● to start scheduled run '
                                        '(${_config.scheduleWindows.length} '
                                        'window'
                                        '${_config.scheduleWindows.length == 1 ? '' : 's'}'
                                        ' × ${_config.scheduleDays} '
                                        'day${_config.scheduleDays == 1 ? '' : 's'})'
                                  : 'Preview — tap ● to start recording')
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
                // While scheduled-sleeping a tap shows the status (then
                // re-dims) instead of waking: the camera is OFF between
                // windows and a full wake would misleadingly show a dead
                // preview. Only the overlay's stop button leaves the run.
                onTap: _scheduleSleeping ? _showSleepStatus : _exitBlackout,
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: _scheduleSleeping
                      ? _sleepStatusOverlay()
                      : AnimatedOpacity(
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
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
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
  /// phone over an empty flower, and NOT a fault). In motion-only capture mode
  /// the same states read "CAPTURING" / "WAITING FOR MOTION" — no detector
  /// exists to be on.
  Widget _gateStateChip() {
    const awakeColor = Color(0xFF00E676); // vivid green
    const idleColor = Color(0xFFB0BEC5); // blue-grey
    final color = _gateIdle ? idleColor : awakeColor;
    final label = _config.motionOnlyCapture
        ? (_gateIdle ? 'WAITING FOR MOTION' : 'CAPTURING')
        : (_gateIdle ? 'SLEEPING' : 'DETECTOR ON');
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
              label,
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

  /// Time-lapse mode chip: green "CAPTURING" during a burst, grey countdown
  /// to the next burst between them (ticks via [_recordElapsedVN], which the
  /// 1 s record ticker already updates), grey "starts with REC" before
  /// recording. Mirrors the gate chip's look so the field glance stays the
  /// same: green = photos happening now.
  Widget _timeLapseChip() {
    const awakeColor = Color(0xFF00E676); // vivid green
    const idleColor = Color(0xFFB0BEC5); // blue-grey
    return ValueListenableBuilder<int>(
      valueListenable: _recordElapsedVN,
      builder: (_, _, _) {
        String label;
        bool active;
        final plan = _timeLapsePlan;
        if (!_recording || plan == null) {
          label = 'TIME-LAPSE (starts with REC)';
          active = false;
        } else {
          final t =
              DateTime.now().millisecondsSinceEpoch - _timeLapseStartMs;
          active = plan.inBurstAt(t);
          if (active) {
            label = 'TIME-LAPSE: CAPTURING';
          } else {
            final waitS = ((plan.nextBurstStartAt(t) - t) / 1000).ceil();
            final mm = (waitS ~/ 60).toString().padLeft(2, '0');
            final ss = (waitS % 60).toString().padLeft(2, '0');
            label = 'NEXT BURST in $mm:$ss';
          }
        }
        final color = active ? awakeColor : idleColor;
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
                  label,
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
      },
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

  /// Content of the blackout cover during scheduled sleep: the run status +
  /// a stop button, shown for a few seconds after a tap (or on sleep entry)
  /// and hidden the rest of the time (pure black). The button only accepts
  /// taps while visible — an invisible tappable stop button under a black
  /// screen would be an accidental-abort trap.
  Widget _sleepStatusOverlay() => IgnorePointer(
    ignoring: !_sleepStatusVisible,
    child: AnimatedOpacity(
      opacity: _sleepStatusVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 400),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bedtime_outlined, color: Colors.white38, size: 36),
          const SizedBox(height: 12),
          Text(
            _sleepStatusText(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 15,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: _confirmAbortSchedule,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
            ),
            child: const Text('Stop scheduled run'),
          ),
        ],
      ),
    ),
  );

  Widget _recordButton() {
    // Greyed out until calibration completes (recording is blocked before then).
    final bool ready = _recording || _captureWidth > 0;
    // While a scheduled run is active (recording or sleeping) the button is a
    // stop-square; when idle with scheduling enabled it carries a clock badge
    // so the different tap behaviour (launches the whole run) is visible.
    final bool runActive = _schedule != null;
    final bool square = _recording || runActive;
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
                shape: square ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: square ? BorderRadius.circular(8) : null,
              ),
              child: (!square && _config.scheduleEnabled)
                  ? const Icon(Icons.schedule, color: Colors.white, size: 30)
                  : null,
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
