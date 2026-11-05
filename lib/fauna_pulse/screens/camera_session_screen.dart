// FaunaPulse — the live recording screen.
//
// Ties everything together: the YOLO camera preview, the ROI box, the tracker,
// the time-lapse photo capture, and the append-only log. The detector and the
// YUV->RGB conversion all run inside the plugin; we only consume its per-frame
// results here and never touch raw camera pixels on the hot path.
//
// The screen's State class is large, so its methods live in `part` files under
// `camera_session/`, one per part of the screen (the `part` lines below are the
// table of contents). Each part file is an extension on the State class: it sees
// every private field, but it cannot declare fields or override lifecycle
// methods, so those stay here, with the getters. Constants that a part uses are
// file-level (`const` at the top level, after the class), because an extension
// cannot reach a class static without the class name.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/gestures.dart' show GestureBinding;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../capture/roi_capture.dart';
import '../capture/roi_video.dart';
import '../capture/time_lapse_plan.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../logging/device_thermal.dart';
import '../logging/error_reporter.dart';
import '../logging/roi_update_debouncer.dart';
import '../logging/session_logger.dart';
import '../models/model_catalog.dart';
import '../models/model_file_kind.dart';
import '../models/roi.dart';
import '../models/schedule_window.dart';
import '../models/session_config.dart';
import '../services/recording_keepalive.dart';
import '../models/track.dart';
import '../perf/adaptive_inference_throttle.dart';
import '../perf/slow_phone_hint.dart';
import '../session/camera_diagnostics_controller.dart';
import '../session/frame_processor.dart';
import '../session/location_fix.dart';
import '../session/schedule_plan.dart';
import '../session/screen_idle.dart';
import '../session/site_photos.dart';
import '../session/plan_sentence.dart';
import '../services/phone_settings.dart';
import '../widgets/before_record_sheet.dart';
import 'field_notes_screen.dart';
import '../models/field_notes.dart';
import '../session/session_guards.dart';
import '../session/session_recorder.dart';
import '../session/time_lapse_camera_coordinator.dart';
import '../tracking/tracker.dart';
import '../widgets/calibrating_banner.dart';
import '../widgets/closable_snack_bar.dart';
import '../widgets/location_dialog.dart';
import '../widgets/preview_transform.dart';
import '../widgets/roi_mask.dart';
import '../widgets/roi_overlay.dart';
import '../widgets/roi_size_sheet.dart';
import '../widgets/session_info_dialog.dart';
import '../widgets/track_box_painter.dart';
import '../widgets/dialog_title.dart';
import '../widgets/not_enough_storage_dialog.dart';
import '../widgets/record_button.dart';
import 'models_screen.dart';
import 'problem_description_screen.dart';
import 'settings_sheet.dart';
import 'session_summary_screen.dart';

part 'camera_session/model_choice.dart';
part 'camera_session/readings.dart';
part 'camera_session/frames.dart';
part 'camera_session/camera_controls.dart';
part 'camera_session/recording.dart';
part 'camera_session/schedule.dart';
part 'camera_session/time_lapse.dart';
part 'camera_session/screen_off.dart';
part 'camera_session/settings_and_notes.dart';
part 'camera_session/layout.dart';

/// The hint on the screen-off cover. Round 317: the moon button also works in
/// Preview, so the hint must not claim a recording runs when none does (a
/// user could leave the phone in the field and get no data).
@visibleForTesting
String blackoutHintText({required bool recording}) => recording
    ? 'Screen off to save power\nRecording continues (tap anywhere to wake)'
    : 'Screen off to save power\nNot recording (tap anywhere to wake)';

/// The scheduled-sleep cover's status text. A window that has begun but not
/// started recording (free storage below "Keep free storage", or a camera that
/// gave no frames) is tried again on each schedule tick, at most 60 s apart,
/// until the window ends: it is neither "next" nor the end of the run.
@visibleForTesting
String sleepStatusText({
  required SchedulePlan plan,
  required DateTime now,
  required int sessionsDone,
  String? storageSkipNote,
  ScheduleSlot? storageSkipSlot,
}) {
  final skip = storageSkipNote == null ? '' : '$storageSkipNote\n';
  final open = plan.activeSlotAt(now);
  if (open != null) {
    final end = plan.endOf(open);
    final until = ScheduleWindow.hhmm(end.hour * 60 + end.minute);
    return open == storageSkipSlot
        ? '${skip}Free some storage: this window still starts if space is freed before $until.'
        : '${skip}Recording starts soon (this window ends at $until).';
  }
  final next = plan.nextSlotAt(now);
  if (next == null) return '${skip}Scheduled run finishing…';
  final start = plan.startOf(next);
  final startsToday =
      start.year == now.year &&
      start.month == now.month &&
      start.day == now.day;
  final when = ScheduleWindow.hhmm(start.hour * 60 + start.minute);
  return '${skip}Scheduled sleep (day ${next.day + 1} of ${plan.days})\n'
      'Next recording: ${startsToday ? '' : 'tomorrow '}$when\n'
      '$sessionsDone session'
      '${sessionsDone == 1 ? '' : 's'} recorded so far';
}

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

  late InsectTracker _tracker;

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
      if (!mounted) return;
      _fitCameraRateToLens();
      _maybeApplyAutoStreamDefault();
      setState(() {});
    },
    // Round 164 (always-manual focus): fires when the lens's focus range
    // (re)lands — at the first probe and after every lens switch — so the
    // close-up preset is applied against the range of the lens in use.
    onFocusRangeKnown: () {
      if (mounted) _applyFocusPreset();
    },
  );

  // Round 109: settles ROI drags into one roi_update record per adjustment
  // (the overlay fires per tick; the log wants the value the user stopped on).
  final RoiUpdateDebouncer _roiLogDebounce = RoiUpdateDebouncer();

  // Round 132: same for mid-recording focus changes — the slider fires per
  // tick, the log wants one focus_change record with the value the user
  // settled on (the start record only carries the initial focus).
  final SettledUpdateDebouncer<({bool manual, double value})>
  _focusLogDebounce = SettledUpdateDebouncer();

  // Round 109: the auto stream-resolution default is evaluated at most once
  // per screen lifetime (the resulting camera rebind re-fires probe callbacks;
  // without the flag that would loop).
  bool _autoStreamApplied = false;

  // Auto thermal-aware inference throttle. When active, it adjusts [_appliedCapFps]
  // each second from the measured inference time so the CPU keeps a cooling margin
  // (see AdaptiveInferenceThrottle). [_appliedCapFps] is the rate cap currently fed
  // to the native detector (null = uncapped); it also drives the YOLOView config.
  AdaptiveInferenceThrottle? _throttle;

  int? _appliedCapFps;

  Roi _roi = Roi.defaultRoi;

  int _imageWidth = 0;

  int _imageHeight = 0;

  // Full-resolution high-res photo dimensions (the file actually saved), learned once
  // by probing capturePhoto() — see [CameraDiagnosticsController]. The analysis
  // frame above is much smaller, so the ROI resolution shown to the user is
  // based on these capture dimensions.
  int get _captureWidth => _probes.captureWidth;

  int get _captureHeight => _probes.captureHeight;

  bool _captureProbeStarted = false;

  // ONE flag for the whole start-up calibration cycle (round 120): the first
  // analysis frame (ROI/stream "measuring…"), the one-time full-res photo
  // probe (the slow part — it retries), and the analysis-ceiling probe the
  // settings sheet needs to list realistic stream resolutions. Every part
  // terminates (the photo probe falls back to the analysis frame; the ceiling
  // probe flags itself in a finally), so this always clears. The controls row
  // and recording stay disabled while true, so the user can never open
  // half-probed settings (e.g. an incomplete resolution list) mid-calibration.
  bool get _calibrating =>
      _imageWidth <= 0 || _captureWidth <= 0 || !_probes.analysisCeilingProbed;

  bool _statsExpanded = false;

  // Round 278 (owner): a hint when the phone checks fewer than 5 pictures per
  // second in live detection (perf/slow_phone_hint.dart), once per visit of
  // this screen. Hidden until the "Don't show again" choice is read.
  final _slowHint = SlowPhoneHint();

  bool _hideSlowHint = true;

  /// Pictures per second while the hint shows; null otherwise.
  double? _slowPerSecond;

  final ValueNotifier<SessionLocation?> _locationVN = ValueNotifier(null);

  final ValueNotifier<bool> _locSearchingVN = ValueNotifier(false);

  SessionLocator? _locator;

  SessionLocation? _previousLocation;

  bool _locationManuallySet = false;

  // Round 297: the field notes saved with every session (FieldNotesScreen).
  FieldNotes _fieldNotes = const FieldNotes();

  // Which processor actually runs inference ("GPU"/"CPU"/"NPU"), reported by the
  // native side. Note: GPU can't run int8-quantized models and falls back to CPU.
  String _accelerator = '';

  // Camera-supported analysis stream resolutions ("WxH"), for the settings menu.
  List<String> get _streamResolutions => _probes.streamResolutions;

  // Estimated ceiling for what CameraX ImageAnalysis can actually stream on this
  // phone (the photo/preview sizes above advertise more than the analysis pipeline
  // can deliver). Keys: hardwareLevel, recommendedMax ("WxH"), previewBoundW/H,
  // displayW/H. Probed once and handed to the settings sheet. See round 56.
  Map<String, dynamic> get _analysisCeiling => _probes.analysisCeiling;

  // The model actually loaded (from onModelLoad). Lets the user see when a model
  // switch didn't take effect (e.g. a size that isn't bundled on the device).
  String _loadedModel = '';

  // Config-style path + task of that loaded model (round 151), so a failed
  // switch can revert the config to the model that is really still running.
  String _loadedModelPath = '';

  YOLOTask? _loadedModelTask;

  // One model-error dialog at a time; repeated failures while it shows are
  // only logged (each failure has already reverted the config anyway).
  bool _modelErrorDialogOpen = false;

  /// The model the camera loads (round 270): the chosen one when its file is
  /// on this phone, else '' and the camera runs without a model (motion and
  /// time-lapse capture need none). A path inside the app or a retired id
  /// counts as missing: no model ships with the app. Cached per path, as
  /// build() reads it.
  String get _cameraModelPath {
    final path = _config.modelPath;
    if (path != _cameraModelFor) {
      _cameraModelFor = path;
      _cameraModelOnPhone = path.startsWith('/') && File(path).existsSync();
    }
    return _cameraModelOnPhone ? path : '';
  }

  String? _cameraModelFor;

  bool _cameraModelOnPhone = false;

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

  // Battery temperature (with the memory and processor figures of the same
  // reading), sampled every few seconds (heat builds up over a long real-time
  // session). Shown on screen and logged while recording.
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

  // Focus is ALWAYS manual (round 164) — autofocus is not selectable
  // anywhere: on a phone mounted over a flower it drifts onto the background
  // and silently changes what "sharp" means mid-session. As soon as the
  // lens's focus range is probed (largest focus distance in dioptres,
  // 1/metres; > 0 = manual focus supported), [_applyFocusPreset] locks the
  // close-up preset (~13 cm, kFocusPresetDioptres) and the user fine-tunes
  // with the slider. _focusValue is 0..1 (0 = far/infinity, 1 = near).
  // [_focusUserAdjusted] drives the amber "set your focus" badge on the
  // focus button: false until the user drags the slider themselves (the
  // programmatic preset doesn't count), re-armed on every lens switch.
  double get _minFocusDistance => _probes.minFocusDistance;

  bool _focusManual = false;

  double _focusValue = 0;

  bool _showFocusSlider = false;

  bool _focusUserAdjusted = false;

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

  // Round 290: clock-driven photos (time-lapse, reference photos) are cut
  // from the newest camera frame. When the camera stops without being told
  // (power button, another app, camera failure) that frame gets old, so these
  // photos wait until stream events arrive again ([_cameraFramesFresh]).
  static const int _framesFreshMs = 5000;

  bool _timeLapseSkipLogged = false;

  // The app is not on screen (Home, power button). Without the hold
  // ([_cameraHeld], round 292) the camera follows the screen, so it stops at
  // that moment, before the stream goes quiet.
  bool _appHidden = false;

  bool _cameraHeld = false;

  /// Whether a clock-driven photo can be cut now: the app is on screen, the
  /// camera is not paused on purpose and a stream event arrived within
  /// [_framesFreshMs].
  bool _cameraFramesFresh(int nowMs) =>
      (!_appHidden || _cameraHeld) &&
      !_paused &&
      _lastStreamEventMs != 0 &&
      nowMs - _lastStreamEventMs < _framesFreshMs;

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

  /// Drives the reference photos (r107 as "ground-truth frames"; wire names
  /// stay gt_*) while recording with the toggle on. Ticks every second
  /// regardless of the configured interval — the reference scheduler's own
  /// window decides when a photo is really due, so timer jitter (or doze
  /// stretching a tick) can never double-photograph. A plain timer,
  /// deliberately independent of the frame stream: reference photos must
  /// continue while the motion gate holds the detector asleep.
  Timer? _gtFrameTimer;

  TimeLapsePlan? _timeLapsePlan;

  int _timeLapseStartMs = 0;

  int _tlLastCycle = -1;

  bool _tlBurstActive = false;

  // Time-lapse video bursts (round 238): non-null while recording with
  // "Save bursts as: Video". Opens one clip per burst on the tick below.
  TimeLapseVideoClips? _tlVideo;

  // Live AI + ROI video (round 240): 5-minute clips while the AI records,
  // kept in step by a 1 s timer (none while the camera is paused).
  TimeLapseVideoClips? _liveVideo;

  Timer? _liveVideoTimer;

  int _liveVideoStartMs = 0;

  // Camera parking between time-lapse bursts (round 163, perf review E3):
  // non-null only while recording in time-lapse mode with the user's
  // "Turn camera off between bursts" setting on. The coordinator is the pure
  // decision logic (park / wake / nothing per tick); [_tlCameraBusy]
  // serializes the async pause/resume transitions the same way
  // [_scheduleBusy] does for scheduled sleeps — a 60 s-capped tick must not
  // start a second wake while one is mid-flight.
  TimeLapseCameraCoordinator? _tlCamera;

  bool _tlCameraBusy = false;

  // Nocturnal time-lapse torch (round 180): non-null only while recording in
  // time-lapse mode with "Torch during bursts" on. [_tlTorchPlan] is the pure
  // on/off schedule (lead before each burst through burst end);
  // [_tlTorchOn] is the last state the camera CONFIRMED (the platform reply),
  // so a failed or rebind-raced call keeps the mismatch and the next tick
  // retries — that retry-on-mismatch is also how the torch comes back after a
  // camera-parking wake (the unbind physically kills the LED).
  // [_tlTorchBusy] serializes the async platform call; [_tlTorchWarned] and
  // [_tlTorchLoggedFailure] keep the no-torch snackbar and the failure log
  // line one-time per recording.
  TimeLapseTorchPlan? _tlTorchPlan;

  bool _tlTorchOn = false;

  bool _tlTorchBusy = false;

  bool _tlTorchWarned = false;

  bool _tlTorchLoggedFailure = false;

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

  // Round 319: the window not started for low free storage (told once per
  // window), and the line the sleep status shows for it.
  ScheduleSlot? _storageSkipSlot;

  String? _storageSkipNote;

  // Tap-for-status while scheduled-sleeping: shows day/next-window info at
  // readable brightness for a few seconds, then re-dims (never wakes fully).
  bool _sleepStatusVisible = false;

  Timer? _sleepStatusTimer;

  // Recording elapsed-time clock (shown in the REC banner). Updated by a 1s
  // ticker so the rest of the screen doesn't rebuild.
  final ValueNotifier<int> _recordElapsedVN = ValueNotifier(0);

  Timer? _recordTicker;

  DateTime? _recordStart;

  // Planned end of the CURRENT recording, for the REC banner's countdown:
  // a manual session ends after the configured session length, a scheduled
  // window ends at the window's wall-clock end time. The banner shows the
  // remaining time as its own value next to the elapsed time (never blended
  // into one number — the two run on different clocks in a scheduled run).
  DateTime? _recordEndAt;

  // "session k/N" when the current recording is one window of a scheduled
  // run: k is the window's position in the whole planned bundle (same order
  // as the folders' d<day>w<win> suffixes), N the bundle size. Null for a
  // manual session.
  String? _recordSlotLabel;

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
  /// high-res photo to meet the minimum saved size; a big one is fine from the
  /// live frame); fast/high-res modes are constant. All WYSIWYG readouts, grid snapping
  /// and ROI logging derive from it so the box on screen always describes the
  /// file that will actually be written.
  CapturePath get _activePath => chooseCapturePath(
    mode: _config.captureMode,
    targetPx: _config.targetRoiSavedPx,
    roiSideFraction: _roi.sideFraction,
    streamW: _imageWidth,
    streamH: _imageHeight,
    highResW: _captureWidth,
    highResH: _captureHeight,
  );

  /// Width (px) of the grid the ROI BOX is measured and snapped in: ALWAYS the
  /// live analysis frame. Round 62: the geometry used to switch to the
  /// high-res frame's grid whenever that path was active, so the same physical
  /// box jumped scales mid-drag (e.g. "992 px" → "2464 px") and the resize
  /// slider ran to its short side — field-tested as thoroughly confusing, and it led
  /// the owner to shrink the box far below the intended size. The box now
  /// lives in ONE scale (the stream the user is looking at, monotonic while
  /// dragging); what the chosen source turns that box into is shown separately
  /// as "saves N×N" ([_savedSideNow]).
  int get _roiSourceWidth => _imageWidth;

  int get _roiSourceHeight => _imageHeight;

  /// Side (px) of the file the CURRENT box would save right now: the crop math
  /// of the active path's source ([savedSidePx] mirrors the native snapping
  /// exactly), then the user's max-side cap. On the high-res path this is
  /// usually LARGER than the box's stream-pixel size — that is the whole point
  /// of paying for a high-res photo for a small box.
  int get _savedSideNow {
    final (w, h) = _activePath == CapturePath.highRes
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
  int get _maxRoiPx => largestSquareSidePx(_roiSourceWidth, _roiSourceHeight);

  /// Dimensions the ROI is logged against — kept consistent with the saved crop
  /// source so the logged pixel size matches the files.
  (int, int) get _roiLogDims => _activePath == CapturePath.highRes
      ? (_captureWidth, _captureHeight)
      : (_imageWidth, _imageHeight);

  @override
  void initState() {
    super.initState();
    // Observe app lifecycle so we can re-assert the screen-on wakelock when the
    // app returns to the foreground mid-session (belt-and-suspenders for long runs).
    WidgetsBinding.instance.addObserver(this);
    _config = widget.initialConfig.normalizedFpsCaps();
    // Restore the info-panel expansion preference (round 124).
    SharedPreferences.getInstance()
        .then((p) {
          final v = p.getBool(_statsExpandedKey) ?? false;
          _hideSlowHint = p.getBool(kHideSlowPhoneHintPrefKey) ?? false;
          if (mounted && v != _statsExpanded) {
            setState(() => _statsExpanded = v);
          }
        })
        .catchError((Object e) {
          logSwallowed('stats_expanded_load', e);
        });
    // Session location (round 126): silent auto-acquire — only proceeds when
    // the location permission was granted before, so no surprise prompt; the
    // pin button's dialog is the prompting path. Also restore the previous
    // session's location as a one-tap default.
    // Round 297: the saved field notes go into every start record. Round 302:
    // the silent GPS search starts once they are read, with their goal.
    _locator = SessionLocator(onUpdate: _onLocationUpdate);
    FieldNotes.load().then((n) {
      if (!mounted) return;
      _fieldNotes = n;
      _locator?.start(goalM: n.gpsGoalM.toDouble(), maxWaitMs: kGpsMaxWaitMs).catchError((Object e) {
        logSwallowed('gps_autostart', e);
        return false;
      });
    });
    SharedPreferences.getInstance()
        .then((p) {
          final raw = p.getString(_lastLocationKey);
          if (raw == null || !mounted) return;
          _previousLocation = SessionLocation.fromJson(
            (jsonDecode(raw) as Map).cast<String, dynamic>(),
          );
        })
        .catchError((Object e) {
          logSwallowed('location_load', e);
        });
    // Read the model's input resolution for the status overlay (async; updates
    // the chip from "reading…" once the metadata probe returns).
    _refreshModelInputSize();
    // The occlusion tolerance is stored in seconds; convert it to the tracker's
    // frame-based buffer using a sensible starting FPS (refined live below).
    _tracker = _buildTracker(_fpsVN.value);
    _frame = FrameProcessor(tracker: _tracker);
    _rebuildThrottle();
    // Sample temperature now, then start the sampling timers.
    _sampleThermal();
    _rebuildSamplingTimers();
    // Surface native inference errors (e.g. an incompatible model failing on every
    // frame) as a dismissible banner the user can turn into an error report.
    _errorSub = _controller.errorEvents.listen((message) {
      if (!mounted) return;
      // Persist every surfaced error: banners can flash by faster than a
      // field user can read them (round 65).
      _logger?.logAppError({'source': 'detector', 'message': message});
      setState(() {
        _inferenceError =
            'The detection model failed on a camera picture; insects may be '
            'missed. If this keeps coming back, choose another model or tap '
            'Report. Details: $message';
        _errorBannerDismissed = false;
      });
    });
    // Show the one-time setup reminder (fix the flower, centre the ROI, lock
    // focus before recording) once the first frame is laid out, unless the user
    // has previously ticked "Don't show again".
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _maybeShowSessionInfo();
      if (mounted && _config.detectorEnabled && _cameraModelPath.isEmpty) {
        await _askForDetector();
      }
    });
  }

  // Round 296 (idea from FaunaLapse): stop cleanly before the battery or the
  // storage runs out (see guardStopReason).
  bool _guardStopping = false;

  @override
  void dispose() {
    // After this frame: the bar belongs to the app's messenger, which must
    // not rebuild while this screen is being taken down.
    // close() looks again after the frame: the bar may have gone by then.
    if (_unappliedSnack.isShowing) WidgetsBinding.instance.addPostFrameCallback((_) => _unappliedSnack.close());
    _stopScreenIdle();
    _sessionTimer?.cancel();
    _scheduleTimer?.cancel();
    _sleepStatusTimer?.cancel();
    _thermalTimer?.cancel();
    _fpsLogTimer?.cancel();
    _powerTimer?.cancel();
    _recordTicker?.cancel();
    _timeLapseTimer?.cancel();
    _gtFrameTimer?.cancel();
    _errorSub?.cancel();
    _blackoutHintTimer?.cancel();
    _locator?.stop();
    _locationVN.dispose();
    _locSearchingVN.dispose();
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
    // A start still waiting for the phone counts too: the recorder runs this
    // stop when its start ends, so no session is left open behind the screen.
    if (_recording || _recorder.starting) _stopRecording(normal: false);
    // After _stopRecording's synchronous flush — drops any leftover timer.
    _roiLogDebounce.cancel();
    _focusLogDebounce.cancel();
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
    // Round 290: hidden = the camera has stopped (it follows the screen);
    // inactive also comes on the way back, when the camera starts again.
    final wasHidden = _appHidden;
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _appHidden = true;
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.resumed) {
      _appHidden = false;
    }
    if (_recording && _appHidden != wasHidden) {
      _logger?.logScreen({'state': _appHidden ? 'hidden' : 'visible'});
    }
    // Returning to the foreground mid-session: re-assert the screen-on wakelock in
    // case it was cleared while away, so a long unattended recording keeps the
    // screen on (and the app foreground) reliably. A scheduled run needs it even
    // while sleeping between windows (no recording, but the run must survive).
    if (state == AppLifecycleState.resumed &&
        (_recording || _schedule != null)) {
      // Round 293: coming back on screen counts as a touch for the screen-off timer.
      _touchScreenIdle();
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

  // --- Recording lifecycle ------------------------------------------------

  /// True from a REC tap that may start a session until that tap's start path
  /// ends. [_recorder.starting] alone comes too late: before it, the start path
  /// waits for the "Before you record" sheet, the battery pop-up and
  /// PhoneSettings.read, and a second tap there ran a second start (two
  /// session folders, timers armed twice).
  bool _recStartBusy = false;

  /// True from the first line of [_stopRecording] until it ends.
  /// [_recorder.stopping] alone comes too late: before it, the stop awaits the
  /// video clips closing (up to 5 s on a hot phone), and a second Stop tap (or
  /// the session timer) there ran a second stop, which closed the log before
  /// the first stop wrote its clip-end record. Round 319: a notifier, so the
  /// record button shows "Stopping…" meanwhile (never disposed: a stop run
  /// unawaited from dispose() still clears it after the screen is gone).
  final ValueNotifier<bool> _stopInProgressVN = ValueNotifier(false);

  bool get _stopInProgress => _stopInProgressVN.value;

  /// True for the whole of [_stopAndShowSummary] (stop, camera pause, summary
  /// review, resume). Blocks a second summary on top of the first, and a tap
  /// between the stop and the summary push that would open the start path.
  bool _summaryFlowBusy = false;

  /// The inference-rate ceiling (FPS): the user's value, never above the
  /// camera cap (round 313: applied here, the stored value stays as typed).
  int get _inferenceCeilFps => _config.effectiveInferenceFps;

  /// The "Settings closed without Apply" bar, closed when it no longer fits
  /// (Settings opened again, a recording started, the screen left).
  final _unappliedSnack = ClosableSnackBar();

  /// Records a failed fire-and-forget call: console line for `flutter run`
  /// plus an `app_error` JSONL line when a session log is open, so "that
  /// feature silently did nothing all day" stays diagnosable from the field.
  void _logAsyncError(String source, Object error) {
    debugPrint('[$source] $error');
    _logger?.logAppError({'source': source, 'message': '$error'});
  }

  // Round 293: "Screen off by itself after" (idea from FaunaLapse). While the
  // camera is held, the screen is held on only until N minutes after the last
  // touch; then the app lets go and the phone's own timeout (or the power
  // button) switches it off, with the black power-save cover meanwhile.
  ScreenIdle? _screenIdle;

  Timer? _screenIdleTimer;

  @override
  Widget build(BuildContext context) => _buildScreen(context);
}

// On-screen info panel expansion (round 124). Collapsed = one tappable
// "▸ fps · temp" line so the stats never cover the ROI; expanded = the full
// list. Remembered across screens in shared_preferences (a viewing
// preference, not a session parameter — deliberately not in SessionConfig).
const String _statsExpandedKey = 'stats_panel_expanded';

// Session location (round 126): ONE stable GPS read per session — acquired
// silently on screen open when the permission already exists, or via the
// pin button's dialog (which may prompt). Notifiers (not plain fields) so
// the open dialog keeps receiving fixes live. `_locationManuallySet` stops
// a late GPS fix from overwriting a manual/previous/cleared choice.
const String _lastLocationKey = 'last_session_location';

const int _cameraSilentAfterMs = 10000;

const String _cameraSilentError =
    'The camera stopped delivering frames. Another app may have taken it '
    'over, or the camera service failed. Stop and restart the session '
    '(or reopen the app) to resume recording.';

Widget? _detectorSubtitle(ModelEntry m) => m.labels.isEmpty
    ? null
    : Text('Finds: ${m.labels.take(3).join(', ')}${m.labels.length > 3 ? ', …' : ''}');

/// SharedPreferences key remembering that we've already shown the
/// battery-settings explanation, so it isn't shown before every session.
const String _batteryOptPromptedKey = 'faunapulse_batteryopt_prompted';

/// How long the "tap to wake" hint takes to fade out after entering blackout.
/// The screen is held at its normal brightness for this whole window so the
/// message is comfortably readable; only once it has faded is the brightness
/// dropped to minimum for the steady-state power saving. Kept in one place so
/// the fade animation and the brightness-drop timer stay in sync.
const Duration _blackoutFade = Duration(seconds: 6);

/// Round 294: the zero-shutter-lag photo buffer only when high-res photos
/// can be taken (photo source Auto or High-res). With "fast" every photo is
/// cut from the live stream, so the buffer would only keep the camera
/// hardware making full-size frames for nothing.
bool _stillZslFor(SessionConfig c) => c.captureMode != RoiCaptureMode.fast;

// Mode-chip colors: green = photos are happening (or can happen right
// now), grey = waiting. One pair of constants for every chip state.
const Color _chipActiveColor = Color(0xFF00E676); // vivid green

const Color _chipWaitingColor = Color(0xFFB0BEC5); // blue-grey
