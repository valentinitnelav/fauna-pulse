// FaunaPulse — session configuration.
//
// Everything the user can set before/while recording, with sensible defaults
// from CLAUDE.md. Persisted as a single JSON string in SharedPreferences so the
// last-used settings reappear next time the app opens.

import 'dart:convert';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';

import '../tracking/byte_track.dart';
import '../tracking/c_biou_track.dart';
import '../tracking/tracker.dart';

import '../logging/app_error_hooks.dart';
import 'bundled_models.dart';
import 'schedule_window.dart';

/// SharedPreferences key for the one-time "setup tips" reminder dialog. When the
/// stored bool is true the dialog is suppressed; clearing it (Settings → Camera →
/// "Show setup tips") makes the reminder appear again next time the screen opens.
const String kHideSessionInfoPrefKey = 'faunapulse_hide_session_info';

/// Where each saved ROI photo comes from. Two sources exist, with opposite
/// trade-offs (round 112 renamed "still" → "high-res" everywhere the user
/// sees it — the old name wrongly suggested those photos were the crisp
/// ones, when they are the slower, motion-blur-prone ones):
///
///  * **fast** — crop the live analysis frame (the small video frame the
///    detector already sees, e.g. 640×480). No camera stall, no extra heat,
///    but a small ROI yields a small (low-detail) photo.
///  * **highRes** — take a full-resolution photo (like pressing the shutter
///    in the camera app, e.g. 4000×3000) and cut the ROI out of it. Far more
///    pixels on the flower, but each one briefly stalls the camera stream
///    (the detector misses frames), lands a fraction of a second after the
///    detection that scheduled it (motion blur / a moved insect), and costs
///    more heat and storage.
///  * **auto** — decide per photo: use the fast crop when it already meets the
///    user's minimum saved size ([SessionConfig.minRoiSavedPx]); only when the
///    ROI is too small in the stream does that photo pay for a high-res one.
enum RoiCaptureMode { fast, highRes, auto }

/// The FROZEN wire name each mode saves as. `highRes` still writes `"still"`:
/// that string is in every saved config and session start record ever logged,
/// and external parsers (R/Python, DATA_GUIDE snippets) key on it — renaming
/// the Dart identifier must not change the file format.
String _captureModeWireName(RoiCaptureMode m) =>
    m == RoiCaptureMode.highRes ? 'still' : m.name;

/// Reads the photo-source policy from a saved config, accepting the wire
/// name (`still`), the Dart enum name (`highRes`, defensive) and the legacy
/// `fullResPhotos` boolean the mode string replaced (old sessions saved
/// `fullResPhotos: true` for the always-high-res behaviour).
RoiCaptureMode _captureModeFromJson(Map<String, dynamic> j) {
  final name = j['captureMode'] as String?;
  if (name != null) {
    for (final m in RoiCaptureMode.values) {
      if (m.name == name || _captureModeWireName(m) == name) return m;
    }
  }
  if (j['fullResPhotos'] as bool? ?? false) return RoiCaptureMode.highRes;
  // A legacy config without the new key was fast-only; keep its behaviour
  // rather than silently switching an old setup to auto.
  if (j.containsKey('fullResPhotos')) return RoiCaptureMode.fast;
  // No capture key at all: the constructor default (fast since round 117 —
  // a config that ever saw the settings sheet carries an explicit value).
  return RoiCaptureMode.fast;
}

/// What causes photos (and detections) during a session — the session's
/// fundamental operating mode:
///  * **detector** — the default AI pipeline: detect, track, photograph per
///    track id.
///  * **motion** — motion-triggered photos, the detector never runs (round 95;
///    the motion gate alone decides).
///  * **timelapse** — clock-triggered photo bursts, no AI and no motion check
///    (round 97): a photo every [SessionConfig.stepSeconds] for
///    [SessionConfig.durationSeconds] per burst, then a
///    [SessionConfig.timeLapseGapSeconds] break before the next burst
///    (round 174; 0 = continuous). The cheapest mode — meant for later
///    offline detection/tracking on the saved photos.
enum CaptureTrigger { detector, motion, timelapse }

/// Moves missing and obsolete model selections to the current bundled MDV6
/// default. YOLO26 remains selectable for the project owner's debug builds,
/// but an upgraded release must not try to download that retired default.
String migrateModelPath(String? stored, {bool releaseMode = kReleaseMode}) {
  const legacyPlaceholderIds = {'yolo26s', 'yolo26m', 'yolo26l', 'yolo26x'};
  if (stored == null || legacyPlaceholderIds.contains(stored)) {
    return kDefaultBundledModelPath;
  }
  if (releaseMode &&
      (stored == kLocalYolo26ModelId || stored == kLocalYolo26ModelPath)) {
    return kDefaultBundledModelPath;
  }
  return stored;
}

/// Reads the capture trigger from a saved config, accepting both the new
/// `captureTrigger` string and the legacy round-95 `motionOnlyCapture` boolean
/// it replaced (true meant what is now [CaptureTrigger.motion]).
CaptureTrigger _captureTriggerFromJson(Map<String, dynamic> j) {
  final name = j['captureTrigger'] as String?;
  if (name != null) {
    for (final t in CaptureTrigger.values) {
      if (t.name == name) return t;
    }
  }
  if (j['motionOnlyCapture'] as bool? ?? false) return CaptureTrigger.motion;
  return CaptureTrigger.detector;
}

/// Reads the time-lapse break between bursts (round 174 key
/// `timeLapseGapSeconds`), migrating pre-174 configs: their
/// `timeLapseIntervalSeconds` was START-TO-START burst spacing, so the
/// equivalent break is interval − photo duration, clamped to ≥ 0 (an old
/// interval ≤ duration meant continuous, which is now gap 0). The effective
/// burst timing of a migrated config is unchanged.
double _timeLapseGapFromJson(Map<String, dynamic> j) {
  final gap = (j['timeLapseGapSeconds'] as num?)?.toDouble();
  if (gap != null) return gap < 0 ? 0.0 : gap;
  final legacy = (j['timeLapseIntervalSeconds'] as num?)?.toDouble();
  if (legacy == null) return 1800.0;
  final duration = (j['durationSeconds'] as num?)?.toDouble() ?? 10.0;
  final migrated = legacy - duration;
  return migrated < 0 ? 0.0 : migrated;
}

/// Config keys (as written by [SessionConfig.toJson]) that have NO effect
/// under [trigger]. The start record carries this list as
/// `config_not_applicable`, next to the `config` block, so analysis code can
/// tell which of the always-present settings were inert in that session
/// (round 147). Deliberately additive: the values themselves keep their
/// normal types — replacing them with "n/a" or null would break typed
/// parsing downstream (e.g. a numeric pandas column turning into strings).
List<String> notApplicableConfigKeys(CaptureTrigger trigger) {
  // Settings that only matter while the detector actually runs.
  const aiKeys = [
    'modelPath',
    'task',
    'confidenceThreshold',
    'iouThreshold',
    'useGpu',
    'cpuThreads',
    'inferenceFps',
    'autoThrottle',
    'minInferenceFps',
    'throttleDutyTarget',
    'occlusionSeconds',
    'minHitsSeconds',
    'trackerAlgorithm',
    'trackerParams',
    'cbiouParams',
    'logRawDetections',
    'showBoxes',
  ];
  // The motion gate and its sensitivity tuning; used by the AI mode (as the
  // heat-saving sleep) AND by the motion trigger (as the capture sensitivity),
  // but forced off natively in time-lapse mode.
  const gateKeys = [
    'motionGateEnabled',
    'motionGatePixelDelta',
    'motionGateAreaFraction',
    'motionGateWakeSeconds',
    'motionGateGridSize',
    'motionGateIdleFps',
  ];
  switch (trigger) {
    case CaptureTrigger.detector:
      return const [
        'timeLapseGapSeconds',
        'timeLapseCameraSleep',
        'timeLapseWakeLeadSeconds',
        'timeLapseTorch',
        'timeLapseTorchLeadSeconds',
      ];
    case CaptureTrigger.motion:
      return [
        ...aiKeys,
        'timeLapseGapSeconds',
        'timeLapseCameraSleep',
        'timeLapseWakeLeadSeconds',
        'timeLapseTorch',
        'timeLapseTorchLeadSeconds',
      ];
    case CaptureTrigger.timelapse:
      // Reference photos are inert here too: the whole session is already
      // clock-driven photos, so a second periodic sampler would only
      // duplicate them.
      return [...aiKeys, ...gateKeys, 'gtFramesEnabled', 'gtFrameSeconds'];
  }
}

class SessionConfig {
  /// User-facing inference-rate bounds. A positive camera cap is an upstream
  /// ceiling because the detector can only analyze frames the camera supplies.
  static const int defaultInferenceFps = 15;
  static const int minimumInferenceFps = 5;
  static const int maximumInferenceFps = 120;
  static const int defaultCameraFpsCap = 15;
  static const int minimumCameraFpsCap = 5;
  static const int maximumCameraFpsCap = 30;

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
  /// Ignored during a scheduled run ([scheduleEnabled]) — there each window's
  /// end time decides when recording stops.
  final int sessionMinutes;

  /// Scheduled recording (opt-in). When on, the record button starts a
  /// *scheduled run* instead of a single manual session: the app records
  /// during each of [scheduleWindows] every day for [scheduleDays] days, and
  /// between windows it sleeps (screen dark at minimum brightness, camera
  /// fully off) while staying in the foreground so the OS can't kill it.
  /// Each window is logged as its own separate session folder.
  final bool scheduleEnabled;

  /// The daily recording windows (1–3, sorted by start, non-overlapping).
  /// The same windows repeat every day of the run.
  final List<ScheduleWindow> scheduleWindows;

  /// How many days the scheduled run lasts (1 = today only). Day 1 is the
  /// day the run is started; windows already past at start time are skipped.
  final int scheduleDays;

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

  /// CPU inference threads when the model runs on CPU (0 = let the runtime
  /// decide). The CPU backend can spread the model's math over several cores:
  /// often faster, but draws more power and heat. Use the engine benchmark in
  /// Settings to see what this device actually gains before raising it.
  final int cpuThreads;

  /// Cap on how many camera frames per second the detector analyzes. This is
  /// the inference FPS, not the camera preview FPS. It is always a positive,
  /// explicit value so the setting never needs an ambiguous "0 = Max" mode.
  /// A positive [cameraFpsCap] is its upper bound because the detector cannot
  /// analyze frames the camera did not capture. Default 15 FPS.
  final int inferenceFps;

  /// Cap on the CAMERA's own frame rate (round 82). Unlike [inferenceFps] —
  /// which only decides how many of the delivered frames the detector looks
  /// at — this slows the camera hardware itself: with no cap the sensor and
  /// image processor capture and process ~30 frames every second even while
  /// the motion gate has the detector asleep, which is the main reason a
  /// "sleeping" phone still warms up. Lower = cooler but a less smooth
  /// preview. 0 = device default (uncapped). The phone only supports certain
  /// rates; the closest supported one at or below this is used. Default 15:
  /// it matches the inference default and roughly halves the standing camera
  /// load on phones whose uncapped camera runs at ~30 FPS.
  final int cameraFpsCap;

  /// When true (default), the app **automatically** adjusts the inference rate
  /// during a session to keep the CPU cool enough to hold a steady frame rate,
  /// instead of running flat-out and overheating into a ~3 fps collapse. When
  /// on, [inferenceFps] acts as the *maximum* rate (the ceiling); when off,
  /// [inferenceFps] is a fixed manual cap.
  final bool autoThrottle;

  /// Lowest inference rate the auto-throttle will fall to (fps). Keeps a session
  /// usable even when the phone is hot. Only used when [autoThrottle] is true.
  final int minInferenceFps;

  /// Target CPU busy fraction for inference (0..1) used by the auto-throttle.
  /// Lower = cooler and steadier but fewer fps; higher = more fps but more heat.
  /// Only used when [autoThrottle] is true.
  final double throttleDutyTarget;

  /// Motion gate (opt-in, experimental). When on, the detector only runs while
  /// something is *moving* inside the ROI, or moved / was detected within the
  /// last [motionGateWakeSeconds] — the rest of the time inference is skipped
  /// entirely, so the phone stays cool during the (usually long) empty-flower
  /// periods of a field session. A cheap per-frame brightness comparison
  /// against a slowly-learned background does the watching (native side, <1 ms
  /// per frame). Off by default until validated against always-on recall.
  final bool motionGateEnabled;

  /// How much a single pixel's brightness (0..255) must differ from the learned
  /// background to count as "changed". Lower = more sensitive (better recall,
  /// more false wake-ups from petal shadows); higher = stricter.
  final int motionGatePixelDelta;

  /// Fraction (0..1) of ROI pixels that must be "changed" in one frame to wake
  /// the detector. Kept small on purpose — an insect covers little of the ROI.
  /// 0.005 means half a percent of the ROI area.
  final double motionGateAreaFraction;

  /// How long (seconds) the detector keeps running after the last motion OR the
  /// last detection. Longer is safer for recall (a still insect keeps being
  /// re-detected, which itself extends the window) but saves less heat.
  final double motionGateWakeSeconds;

  /// Cells per side of the square thumbnail the ROI is shrunk to for the
  /// motion check (a count, not pixels). Each cell watches 1/N of the ROI
  /// width, so an insect narrower than roughly ROI-width/N may not register.
  /// Raise it when the insects of interest are small *relative to the ROI box*
  /// (e.g. 96–128), and consider lowering [motionGateAreaFraction] with it.
  /// Costs slightly more CPU per frame (still ~1 ms at 160). Range 16–160.
  final int motionGateGridSize;

  /// How many camera frames per second the motion check inspects while the
  /// gate keeps the detector asleep (round 63/64). All other idle frames are
  /// dropped BEFORE the costly image conversion — the main idle heat source.
  /// Higher = faster wake-up but a warmer idle phone; an arriving insect is
  /// noticed within ~1/rate seconds. Range 1–30; while the gate is awake every
  /// frame flows regardless.
  final int motionGateIdleFps;

  /// The session's operating mode — see [CaptureTrigger]. Replaces the
  /// round-95 `motionOnlyCapture` boolean (old saved configs migrate in
  /// [_captureTriggerFromJson]).
  ///
  /// [CaptureTrigger.motion]: photos are taken whenever the motion gate sees
  /// movement in the ROI — the AI detector NEVER runs (the model still loads
  /// at start but is never used). No species/track data is recorded; the
  /// photo step/duration and photo-source settings apply to the
  /// motion-triggered photos. Requires the motion gate (forced on).
  /// Trade-off: wind/shadow false triggers become junk photos.
  ///
  /// [CaptureTrigger.timelapse]: photo bursts on a pure clock, no AI and no
  /// motion check — the cheapest mode. Each burst: first photo at the burst
  /// start, then every [stepSeconds] for [durationSeconds]; then a
  /// [timeLapseGapSeconds] break before the next burst (round 174; 0 = a
  /// CONTINUOUS time-lapse). Meant for offline detection/tracking on the
  /// saved photos afterwards.
  final CaptureTrigger captureTrigger;

  /// Convenience: motion-triggered photo mode (round 95 name, kept so call
  /// sites read naturally).
  bool get motionOnlyCapture => captureTrigger == CaptureTrigger.motion;

  /// Convenience: clock-triggered time-lapse mode (round 97).
  bool get timeLapseCapture => captureTrigger == CaptureTrigger.timelapse;

  /// Convenience: the AI pipeline (detector + tracker) actually runs.
  bool get detectorEnabled => captureTrigger == CaptureTrigger.detector;

  /// Time-lapse mode only: the BREAK between photo bursts, in seconds — from
  /// one burst's end to the next burst's start ("Time between bursts"). This
  /// break is exactly when [timeLapseCameraSleep] may power the camera off.
  /// 0 = no break, photos flow continuously every [stepSeconds].
  ///
  /// Round 174 (owner decision, after the session_2 surprise): replaces the
  /// r97 `timeLapseIntervalSeconds`, which was START-TO-START spacing and
  /// silently meant "continuous" whenever ≤ [durationSeconds]. Legacy configs
  /// migrate in [SessionConfig.fromJson]: gap = old interval − duration
  /// (clamped to ≥ 0), so their effective timing is unchanged.
  final double timeLapseGapSeconds;

  /// Time-lapse mode only (round 163, perf review E3): fully turn the camera
  /// off ("park" it) between bursts and turn it back on ~10 s before the next
  /// one — the big heat/power saver for sparse time-lapses, at the cost of a
  /// frozen preview and a small wake risk. Only takes effect when the bursts
  /// leave ≥ 30 s of idle time between them; a failed wake disables parking
  /// for the rest of the session (camera stays on — reliability first).
  /// Off by default: turning the camera hardware off/on is the riskier path.
  final bool timeLapseCameraSleep;

  /// Time-lapse camera sleep only (round 164): how many seconds BEFORE the
  /// next scheduled burst the camera is turned back on, so it is warm when
  /// the first photo is due. Default 10 s (owner field test, r164): a full
  /// power-off parks the lens actuator and discards auto-exposure state, so
  /// a wake needs real time for the motor to travel back to the locked
  /// manual focus and for AE to ramp — at 5 s the burst's first photo came
  /// out dark and blurry on the test phone. Larger = safer warm-up, smaller
  /// = more camera-off time.
  final double timeLapseWakeLeadSeconds;

  /// Time-lapse mode only (round 180): keep the phone's LED torch on during
  /// every burst so nocturnal sessions produce usable photos, switching it on
  /// [timeLapseTorchLeadSeconds] before each burst so auto-exposure settles
  /// under the final lighting, and off again in the break. Composes with
  /// [timeLapseCameraSleep] (the torch is re-asserted after the wake rebind)
  /// and with the screen-off blackout (the torch sits on the camera, not the
  /// screen). Off by default: a light source changes insect behaviour and
  /// only night sessions want it. (Distinct from `flashOnCapture`, which is
  /// the on-SCREEN capture cue.)
  final bool timeLapseTorch;

  /// Time-lapse torch only (round 180): how many seconds BEFORE each burst
  /// the torch comes on. Auto-exposure runs in the camera hardware's own
  /// loop, and re-converging after the big darkness→torch illumination step
  /// typically takes 1–2 s at 15 fps — default 5 s gives margin for slow
  /// low-light AE. With [timeLapseCameraSleep] the camera wakes at
  /// max(wake lead, torch lead), so a raised torch lead still finds a bound
  /// camera; the torch itself can only physically ignite once the camera is
  /// rebound. The first burst of a recording starts immediately, so it gets
  /// no lead.
  final double timeLapseTorchLeadSeconds;

  /// Requested camera analysis-stream resolution (4:3). The device delivers the
  /// nearest it supports; its short side caps how large a fast (no-stall) ROI
  /// crop can be. Higher = bigger crops but can cost FPS on weaker phones.
  final int streamWidth;
  final int streamHeight;

  /// Whether [streamWidth]×[streamHeight] was picked BY THE USER in Settings
  /// (round 109). While false, the app may auto-default the stream once per
  /// screen to the smallest device-supported size with short side ≥ 1024
  /// ([autoStreamResolution] in roi_capture.dart) so fast ROI crops can reach
  /// the saved-photo target without the laggy high-res path; a manual dropdown
  /// choice sets this true and is never overridden.
  final bool streamResolutionExplicit;

  /// ROI photo source policy — see [RoiCaptureMode]. Default
  /// [RoiCaptureMode.fast] (round 117, previously auto): every photo is a
  /// crop of the live analysis frame. High-res photos sound desirable but
  /// each one pauses the analysis stream 0.13–1.5 s (measured, session_16),
  /// lands a fraction of a second after its trigger, and often shows motion
  /// blur — a smaller but crisp live crop usually carries MORE usable detail
  /// for later classification, especially on older phones. [RoiCaptureMode.auto]
  /// takes the high-res path per photo when the fast crop would come out
  /// below [targetRoiSavedPx]. (Replaces the old `fullResPhotos` boolean; an
  /// old saved config with `fullResPhotos: true` loads as
  /// [RoiCaptureMode.highRes].)
  final RoiCaptureMode captureMode;

  /// The ONE side (pixels) the user wants saved ROI photos to have (round 63,
  /// replacing the earlier min/max pair the owner found confusing). It is both
  /// the decision threshold and the downscale cap, so every photo saves at
  /// exactly this size whenever the ROI can physically supply it:
  ///
  ///  * in [RoiCaptureMode.auto], a photo takes the high-res path when the
  ///    fast live-frame crop would come out below this;
  ///  * crops larger than this are downscaled to it before saving (bounding
  ///    storage — a big ROI cut from a high-res photo can be 3000+ px, 1–2 MB);
  ///  * photos are **never upscaled** to reach it — enlarging pixels invents
  ///    no detail and would degrade later insect classification. When even a
  ///    high-res photo can't reach it, the photo saves smaller and the on-screen
  ///    readout shows a ⚠ (the only fixes are physical: move the phone closer
  ///    or switch to a telephoto lens).
  ///
  /// Multiple of 32. Uniform photo sizes also suit a downstream classifier.
  final int targetRoiSavedPx;

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

  /// Whether the crop-and-export tool in the summary photo viewer forces the
  /// dragged rectangle to a square (1:1). Free aspect (default) hugs the
  /// insect's shape; the square option suits identification apps/models that
  /// prefer square inputs. The "1:1" chip in the viewer's crop bar toggles
  /// this same setting.
  final bool cropSquareLock;

  /// Which rear camera lens to use, expressed as the lens's effective zoom
  /// factor (1.0 = main "wide" lens, 0.5 = ultra-wide, 2.0/3.0 = telephoto). The
  /// app snaps to the available lens whose factor is closest to this value at
  /// session start; on a single-lens phone it simply stays on the only lens.
  /// Default 1.0 (the main wide lens, as before). See the lens-switch button on
  /// the camera screen and the camera-diagnostics dialog for what each phone
  /// actually exposes.
  final double selectedLensZoom;

  /// Which frame-association algorithm links detections into visits
  /// (round 105). `bytetrack` (default) is the field-tested tracker;
  /// `cbiou` is the buffered-overlap alternative for A/B evaluation.
  /// Both share the seconds-based occlusion/min-visit settings above;
  /// each has its own advanced tuning block below.
  final TrackerAlgorithm trackerAlgorithm;

  /// ByteTrack tuning (AI tab → Visit tracking → Advanced).
  final ByteTrackParams trackerParams;

  /// C-BIoU tuning (AI tab → Visit tracking → Advanced). Only used when
  /// [trackerAlgorithm] is [TrackerAlgorithm.cbiou].
  final CBiouParams cbiouParams;

  /// Debug/evaluation toggle (round 105): while recording in detector mode,
  /// also write one `raw_detections` record per processed frame with the
  /// detector's boxes BEFORE tracking. This is what the offline tracker
  /// replay harness consumes to compare algorithms on real field data. Off by
  /// default — at 10 FPS it adds roughly 1–2 MB per hour to the session log.
  final bool logRawDetections;

  /// "Reference photos" (UI name; wire names frozen from the round-107
  /// "ground-truth frames" original: JSON keys `gtFramesEnabled` /
  /// `gtFrameSeconds`, folder `gt_frames/`, record `gt_capture`): save a
  /// periodic ROI photo every [gtFrameSeconds] REGARDLESS of detections — an
  /// unbiased visual sample of what the camera saw, so users (and the model
  /// owner) can spot pollinators the AI missed, and tracker output is never
  /// checked only against photos the tracker itself triggered. ON by default
  /// since the promotion round; inert in time-lapse mode (the session is
  /// already clock-driven photos). Size follows [targetRoiSavedPx]
  /// (Photos tab); the capture path is always the fast live-frame crop.
  final bool gtFramesEnabled;

  /// Interval between reference photos, in seconds (default 30 — about 120
  /// photos per hour). Wire name frozen (`gtFrameSeconds`).
  final double gtFrameSeconds;

  /// Round 108: when a photo takes the HIGH-RES path, also save the live-frame
  /// fast crop of the trigger moment next to it (`<name>_live.jpg`). A high-res
  /// photo physically lands ~0.5–1 s after the detection that scheduled it, so
  /// a fast insect is often gone from it; the companion is small (stream
  /// resolution) but shows the trigger moment. Default on — dataset
  /// completeness beats the extra ~50–200 KB per photo. (Saved-config/JSON key
  /// stays `stillSyncCompanion` — frozen wire name, see [_captureModeWireName].)
  final bool highResSyncCompanion;

  const SessionConfig({
    this.modelPath = kDefaultBundledModelPath,
    this.task = YOLOTask.detect,
    this.confidenceThreshold = 0.25,
    this.iouThreshold = 0.7,
    this.stepSeconds = 1.0,
    this.durationSeconds = 10.0,
    this.sessionMinutes = 60,
    this.scheduleEnabled = false,
    this.scheduleWindows = const [ScheduleWindow(360, 600)], // 06:00–10:00
    this.scheduleDays = 1,
    this.folderName = 'session',
    this.showFps = true,
    this.showBoxes = true,
    this.showOverlayInfo = true,
    this.flashOnCapture = true,
    this.useGpu = true,
    this.cpuThreads = 0,
    this.inferenceFps = defaultInferenceFps,
    // Low default stream (≈ model input) so inference runs at full speed like the
    // original; the stream-resolution setting can raise it for bigger fast crops.
    this.cameraFpsCap =
        defaultCameraFpsCap, // 0 removes the camera hardware cap
    this.autoThrottle = true,
    this.minInferenceFps = 3,
    this.throttleDutyTarget = 0.5,
    this.motionGateEnabled = false,
    this.motionGatePixelDelta = 25,
    this.motionGateAreaFraction = 0.005,
    this.motionGateWakeSeconds = 3.0,
    this.motionGateGridSize = 48,
    this.motionGateIdleFps = 5,
    this.captureTrigger = CaptureTrigger.detector,
    this.timeLapseGapSeconds = 1800.0, // 30 min break between bursts
    this.timeLapseCameraSleep = false,
    this.timeLapseWakeLeadSeconds = 10.0,
    this.timeLapseTorch = false,
    this.timeLapseTorchLeadSeconds = 5.0,
    this.streamWidth = 640,
    this.streamHeight = 480,
    this.streamResolutionExplicit = false,
    this.captureMode = RoiCaptureMode.fast,
    this.targetRoiSavedPx =
        1024, // ÷32; photos save at exactly this when possible
    this.occlusionSeconds = 3.0,
    this.minHitsSeconds = 0.2,
    this.fpsSampleSeconds = 5,
    this.thermalSampleSeconds = 10,
    this.powerSampleSeconds = 10,
    this.cropSquareLock = false,
    this.selectedLensZoom = 1.0,
    this.trackerAlgorithm = TrackerAlgorithm.bytetrack,
    this.trackerParams = const ByteTrackParams(),
    this.cbiouParams = const CBiouParams(),
    this.logRawDetections = false,
    this.gtFramesEnabled = true,
    this.gtFrameSeconds = 30.0,
    this.highResSyncCompanion = true,
  });

  /// True when the schedule can actually run: 1–3 windows, each with
  /// start < end, and no two windows overlapping. The settings sheet warns
  /// when this is false (mirroring [isTimeLapseValid]); the camera screen
  /// refuses to *start* an invalid schedule.
  bool get isScheduleValid {
    if (scheduleWindows.isEmpty || scheduleWindows.length > 3) return false;
    if (scheduleDays < 1) return false;
    for (var i = 0; i < scheduleWindows.length; i++) {
      if (!scheduleWindows[i].isValid) return false;
      for (var k = i + 1; k < scheduleWindows.length; k++) {
        if (scheduleWindows[i].overlaps(scheduleWindows[k])) return false;
      }
    }
    return true;
  }

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
    bool? scheduleEnabled,
    List<ScheduleWindow>? scheduleWindows,
    int? scheduleDays,
    String? folderName,
    bool? showFps,
    bool? showBoxes,
    bool? showOverlayInfo,
    bool? flashOnCapture,
    bool? useGpu,
    int? cpuThreads,
    int? inferenceFps,
    int? cameraFpsCap,
    bool? autoThrottle,
    int? minInferenceFps,
    double? throttleDutyTarget,
    bool? motionGateEnabled,
    int? motionGatePixelDelta,
    double? motionGateAreaFraction,
    double? motionGateWakeSeconds,
    int? motionGateGridSize,
    int? motionGateIdleFps,
    CaptureTrigger? captureTrigger,
    double? timeLapseGapSeconds,
    bool? timeLapseCameraSleep,
    double? timeLapseWakeLeadSeconds,
    bool? timeLapseTorch,
    double? timeLapseTorchLeadSeconds,
    int? streamWidth,
    int? streamHeight,
    bool? streamResolutionExplicit,
    RoiCaptureMode? captureMode,
    int? targetRoiSavedPx,
    double? occlusionSeconds,
    double? minHitsSeconds,
    int? fpsSampleSeconds,
    int? thermalSampleSeconds,
    int? powerSampleSeconds,
    bool? cropSquareLock,
    double? selectedLensZoom,
    TrackerAlgorithm? trackerAlgorithm,
    ByteTrackParams? trackerParams,
    CBiouParams? cbiouParams,
    bool? logRawDetections,
    bool? gtFramesEnabled,
    double? gtFrameSeconds,
    bool? highResSyncCompanion,
  }) => SessionConfig(
    modelPath: modelPath ?? this.modelPath,
    task: task ?? this.task,
    confidenceThreshold: confidenceThreshold ?? this.confidenceThreshold,
    iouThreshold: iouThreshold ?? this.iouThreshold,
    stepSeconds: stepSeconds ?? this.stepSeconds,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    sessionMinutes: sessionMinutes ?? this.sessionMinutes,
    scheduleEnabled: scheduleEnabled ?? this.scheduleEnabled,
    scheduleWindows: scheduleWindows ?? this.scheduleWindows,
    scheduleDays: scheduleDays ?? this.scheduleDays,
    folderName: folderName ?? this.folderName,
    showFps: showFps ?? this.showFps,
    showBoxes: showBoxes ?? this.showBoxes,
    showOverlayInfo: showOverlayInfo ?? this.showOverlayInfo,
    flashOnCapture: flashOnCapture ?? this.flashOnCapture,
    useGpu: useGpu ?? this.useGpu,
    cpuThreads: cpuThreads ?? this.cpuThreads,
    inferenceFps: inferenceFps ?? this.inferenceFps,
    cameraFpsCap: cameraFpsCap ?? this.cameraFpsCap,
    autoThrottle: autoThrottle ?? this.autoThrottle,
    minInferenceFps: minInferenceFps ?? this.minInferenceFps,
    throttleDutyTarget: throttleDutyTarget ?? this.throttleDutyTarget,
    motionGateEnabled: motionGateEnabled ?? this.motionGateEnabled,
    motionGatePixelDelta: motionGatePixelDelta ?? this.motionGatePixelDelta,
    motionGateAreaFraction:
        motionGateAreaFraction ?? this.motionGateAreaFraction,
    motionGateWakeSeconds: motionGateWakeSeconds ?? this.motionGateWakeSeconds,
    motionGateGridSize: motionGateGridSize ?? this.motionGateGridSize,
    motionGateIdleFps: motionGateIdleFps ?? this.motionGateIdleFps,
    captureTrigger: captureTrigger ?? this.captureTrigger,
    timeLapseGapSeconds: timeLapseGapSeconds ?? this.timeLapseGapSeconds,
    timeLapseCameraSleep: timeLapseCameraSleep ?? this.timeLapseCameraSleep,
    timeLapseWakeLeadSeconds:
        timeLapseWakeLeadSeconds ?? this.timeLapseWakeLeadSeconds,
    timeLapseTorch: timeLapseTorch ?? this.timeLapseTorch,
    timeLapseTorchLeadSeconds:
        timeLapseTorchLeadSeconds ?? this.timeLapseTorchLeadSeconds,
    streamWidth: streamWidth ?? this.streamWidth,
    streamHeight: streamHeight ?? this.streamHeight,
    streamResolutionExplicit:
        streamResolutionExplicit ?? this.streamResolutionExplicit,
    captureMode: captureMode ?? this.captureMode,
    targetRoiSavedPx: targetRoiSavedPx ?? this.targetRoiSavedPx,
    occlusionSeconds: occlusionSeconds ?? this.occlusionSeconds,
    minHitsSeconds: minHitsSeconds ?? this.minHitsSeconds,
    fpsSampleSeconds: fpsSampleSeconds ?? this.fpsSampleSeconds,
    thermalSampleSeconds: thermalSampleSeconds ?? this.thermalSampleSeconds,
    powerSampleSeconds: powerSampleSeconds ?? this.powerSampleSeconds,
    cropSquareLock: cropSquareLock ?? this.cropSquareLock,
    selectedLensZoom: selectedLensZoom ?? this.selectedLensZoom,
    trackerAlgorithm: trackerAlgorithm ?? this.trackerAlgorithm,
    trackerParams: trackerParams ?? this.trackerParams,
    cbiouParams: cbiouParams ?? this.cbiouParams,
    logRawDetections: logRawDetections ?? this.logRawDetections,
    gtFramesEnabled: gtFramesEnabled ?? this.gtFramesEnabled,
    gtFrameSeconds: gtFrameSeconds ?? this.gtFrameSeconds,
    highResSyncCompanion: highResSyncCompanion ?? this.highResSyncCompanion,
  );

  /// Highest inference FPS the settings UI may accept for this camera cap.
  /// When the camera cap is removed (`0`), the inference field keeps its own
  /// generous safety bound instead of guessing the device's hardware maximum.
  int get maximumAllowedInferenceFps => cameraFpsCap > 0
      ? cameraFpsCap.clamp(minimumInferenceFps, maximumInferenceFps).toInt()
      : maximumInferenceFps;

  /// Applies a user-entered inference cap while keeping the throttle floor and
  /// camera/inference relationship valid.
  SessionConfig withInferenceFps(int requested) {
    final fps = requested
        .clamp(minimumInferenceFps, maximumAllowedInferenceFps)
        .toInt();
    return copyWith(
      inferenceFps: fps,
      minInferenceFps: minInferenceFps.clamp(1, fps).toInt(),
    );
  }

  /// Applies a user-entered camera cap. Lowering a positive camera cap also
  /// lowers inference FPS when needed, because the detector cannot run more
  /// often than the camera supplies frames. Camera `0` remains uncapped.
  SessionConfig withCameraFpsCap(int requested) {
    final cameraFps = requested <= 0
        ? 0
        : requested.clamp(minimumCameraFpsCap, maximumCameraFpsCap).toInt();
    final inferenceMax = cameraFps > 0 ? cameraFps : maximumInferenceFps;
    final currentInference = inferenceFps > 0
        ? inferenceFps
        : defaultInferenceFps;
    final normalizedInference = currentInference
        .clamp(minimumInferenceFps, inferenceMax)
        .toInt();
    return copyWith(
      cameraFpsCap: cameraFps,
      inferenceFps: normalizedInference,
      minInferenceFps: minInferenceFps.clamp(1, normalizedInference).toInt(),
    );
  }

  /// Migrates old/invalid combinations into the explicit linked-cap model.
  /// In particular, the former inference value `0` becomes the 15 FPS default.
  SessionConfig normalizedFpsCaps() => withCameraFpsCap(cameraFpsCap);

  Map<String, dynamic> toJson() => {
    'modelPath': modelPath,
    'task': task.name,
    'confidenceThreshold': confidenceThreshold,
    'iouThreshold': iouThreshold,
    'stepSeconds': stepSeconds,
    'durationSeconds': durationSeconds,
    'sessionMinutes': sessionMinutes,
    'scheduleEnabled': scheduleEnabled,
    'scheduleWindows': [for (final w in scheduleWindows) w.toJson()],
    'scheduleDays': scheduleDays,
    'folderName': folderName,
    'showFps': showFps,
    'showBoxes': showBoxes,
    'showOverlayInfo': showOverlayInfo,
    'flashOnCapture': flashOnCapture,
    'useGpu': useGpu,
    'cpuThreads': cpuThreads,
    'inferenceFps': inferenceFps,
    'cameraFpsCap': cameraFpsCap,
    'autoThrottle': autoThrottle,
    'minInferenceFps': minInferenceFps,
    'throttleDutyTarget': throttleDutyTarget,
    'motionGateEnabled': motionGateEnabled,
    'motionGatePixelDelta': motionGatePixelDelta,
    'motionGateAreaFraction': motionGateAreaFraction,
    'motionGateWakeSeconds': motionGateWakeSeconds,
    'motionGateGridSize': motionGateGridSize,
    'motionGateIdleFps': motionGateIdleFps,
    'captureTrigger': captureTrigger.name,
    // Legacy key kept one generation (mirrors the captureMode/fullResPhotos
    // pattern) so round-95/96 parsers still recognise motion-only sessions.
    'motionOnlyCapture': motionOnlyCapture,
    'timeLapseGapSeconds': timeLapseGapSeconds,
    'timeLapseCameraSleep': timeLapseCameraSleep,
    'timeLapseWakeLeadSeconds': timeLapseWakeLeadSeconds,
    'timeLapseTorch': timeLapseTorch,
    'timeLapseTorchLeadSeconds': timeLapseTorchLeadSeconds,
    'streamWidth': streamWidth,
    'streamHeight': streamHeight,
    'streamResolutionExplicit': streamResolutionExplicit,
    // Frozen wire name: highRes writes "still" (see _captureModeWireName).
    'captureMode': _captureModeWireName(captureMode),
    'targetRoiSavedPx': targetRoiSavedPx,
    // Legacy key kept one round so an older build can still read this config.
    'fullResPhotos': captureMode == RoiCaptureMode.highRes,
    'occlusionSeconds': occlusionSeconds,
    'minHitsSeconds': minHitsSeconds,
    'fpsSampleSeconds': fpsSampleSeconds,
    'thermalSampleSeconds': thermalSampleSeconds,
    'powerSampleSeconds': powerSampleSeconds,
    'cropSquareLock': cropSquareLock,
    'selectedLensZoom': selectedLensZoom,
    'trackerAlgorithm': trackerAlgorithm.name,
    'trackerParams': trackerParams.toJson(),
    'cbiouParams': cbiouParams.toJson(),
    'logRawDetections': logRawDetections,
    'gtFramesEnabled': gtFramesEnabled,
    'gtFrameSeconds': gtFrameSeconds,
    // Frozen wire key from the r108 name; the Dart field renamed in r112.
    'stillSyncCompanion': highResSyncCompanion,
  };

  factory SessionConfig.fromJson(Map<String, dynamic> j) => SessionConfig(
    modelPath: migrateModelPath(j['modelPath'] as String?),
    task: YOLOTaskParsing.tryParse(j['task'] as String?) ?? YOLOTask.detect,
    confidenceThreshold: (j['confidenceThreshold'] as num?)?.toDouble() ?? 0.25,
    iouThreshold: (j['iouThreshold'] as num?)?.toDouble() ?? 0.7,
    stepSeconds: (j['stepSeconds'] as num?)?.toDouble() ?? 1.0,
    durationSeconds: (j['durationSeconds'] as num?)?.toDouble() ?? 10.0,
    sessionMinutes: (j['sessionMinutes'] as num?)?.toInt() ?? 60,
    scheduleEnabled: j['scheduleEnabled'] as bool? ?? false,
    scheduleWindows: _scheduleWindowsFromJson(j['scheduleWindows']),
    scheduleDays: ((j['scheduleDays'] as num?)?.toInt() ?? 1).clamp(1, 365),
    folderName: j['folderName'] as String? ?? 'session',
    showFps: j['showFps'] as bool? ?? true,
    showBoxes: j['showBoxes'] as bool? ?? true,
    showOverlayInfo: j['showOverlayInfo'] as bool? ?? true,
    flashOnCapture: j['flashOnCapture'] as bool? ?? true,
    useGpu: j['useGpu'] as bool? ?? true,
    cpuThreads: (j['cpuThreads'] as num?)?.toInt() ?? 0,
    inferenceFps: (j['inferenceFps'] as num?)?.toInt() ?? defaultInferenceFps,
    cameraFpsCap: (j['cameraFpsCap'] as num?)?.toInt() ?? defaultCameraFpsCap,
    autoThrottle: j['autoThrottle'] as bool? ?? true,
    minInferenceFps: (j['minInferenceFps'] as num?)?.toInt() ?? 3,
    throttleDutyTarget: (j['throttleDutyTarget'] as num?)?.toDouble() ?? 0.5,
    motionGateEnabled: j['motionGateEnabled'] as bool? ?? false,
    motionGatePixelDelta: (j['motionGatePixelDelta'] as num?)?.toInt() ?? 25,
    motionGateAreaFraction:
        (j['motionGateAreaFraction'] as num?)?.toDouble() ?? 0.005,
    motionGateWakeSeconds:
        (j['motionGateWakeSeconds'] as num?)?.toDouble() ?? 3.0,
    motionGateGridSize: (j['motionGateGridSize'] as num?)?.toInt() ?? 48,
    motionGateIdleFps: (j['motionGateIdleFps'] as num?)?.toInt() ?? 5,
    captureTrigger: _captureTriggerFromJson(j),
    timeLapseGapSeconds: _timeLapseGapFromJson(j),
    timeLapseCameraSleep: j['timeLapseCameraSleep'] as bool? ?? false,
    timeLapseWakeLeadSeconds:
        (j['timeLapseWakeLeadSeconds'] as num?)?.toDouble() ?? 10.0,
    timeLapseTorch: j['timeLapseTorch'] as bool? ?? false,
    timeLapseTorchLeadSeconds:
        (j['timeLapseTorchLeadSeconds'] as num?)?.toDouble() ?? 5.0,
    streamWidth: (j['streamWidth'] as num?)?.toInt() ?? 640,
    streamHeight: (j['streamHeight'] as num?)?.toInt() ?? 480,
    // Pre-round-109 configs lack the key. A stored size that differs from the
    // old factory default (640×480) can only mean the user once picked it in
    // Settings — treat that as explicit so the auto default never stomps it.
    streamResolutionExplicit:
        j['streamResolutionExplicit'] as bool? ??
        (((j['streamWidth'] as num?)?.toInt() ?? 640) != 640 ||
            ((j['streamHeight'] as num?)?.toInt() ?? 480) != 480),
    captureMode: _captureModeFromJson(j),
    // Round-62 configs stored a min/max pair; the min carries the intent
    // ("photos must be at least this"), so it becomes the target.
    targetRoiSavedPx:
        (j['targetRoiSavedPx'] as num?)?.toInt() ??
        (j['minRoiSavedPx'] as num?)?.toInt() ??
        1024,
    // Fallback must match the constructor default (3.0). A legacy config saved
    // before this key existed should load the current bee-tuned buffer, not an
    // old 1.0 that silently fragments tracks.
    occlusionSeconds: (j['occlusionSeconds'] as num?)?.toDouble() ?? 3.0,
    minHitsSeconds: (j['minHitsSeconds'] as num?)?.toDouble() ?? 0.2,
    fpsSampleSeconds: (j['fpsSampleSeconds'] as num?)?.toInt() ?? 5,
    thermalSampleSeconds: (j['thermalSampleSeconds'] as num?)?.toInt() ?? 10,
    powerSampleSeconds: (j['powerSampleSeconds'] as num?)?.toInt() ?? 10,
    cropSquareLock: j['cropSquareLock'] as bool? ?? false,
    selectedLensZoom: (j['selectedLensZoom'] as num?)?.toDouble() ?? 1.0,
    // Configs saved before round 105 carry no algorithm choice: they were
    // all ByteTrack, which is also the fallback for an unknown name.
    trackerAlgorithm:
        TrackerAlgorithm.values.asNameMap()[j['trackerAlgorithm'] as String? ??
            ''] ??
        TrackerAlgorithm.bytetrack,
    trackerParams: j['trackerParams'] is Map
        ? ByteTrackParams.fromJson(
            (j['trackerParams'] as Map).cast<String, dynamic>(),
          )
        : const ByteTrackParams(),
    cbiouParams: j['cbiouParams'] is Map
        ? CBiouParams.fromJson(
            (j['cbiouParams'] as Map).cast<String, dynamic>(),
          )
        : const CBiouParams(),
    logRawDetections: j['logRawDetections'] as bool? ?? false,
    // Default flip (reference-photos promotion round): only configs MISSING
    // these keys (fresh installs, configs last saved before r107) get the new
    // on/30 s defaults — toJson always writes the keys, so an explicitly
    // saved value (including an explicit `false`) always survives.
    gtFramesEnabled: j['gtFramesEnabled'] as bool? ?? true,
    gtFrameSeconds: (j['gtFrameSeconds'] as num?)?.toDouble() ?? 30.0,
    highResSyncCompanion: j['stillSyncCompanion'] as bool? ?? true,
  ).normalizedFpsCaps();

  static const String _prefsKey = 'faunapulse_session_config';

  /// Loads the last-saved config, or defaults if none/invalid.
  static Future<SessionConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const SessionConfig();
    try {
      return SessionConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      // Corrupt saved settings: start over from defaults, but say so.
      logSwallowed('config_load', e);
      return const SessionConfig();
    }
  }

  /// Persists this config as the new last-used settings.
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }
}

/// Reads the schedule windows list from a saved config. Defensive like every
/// other fromJson field: a missing/garbage value falls back to the default,
/// malformed entries are dropped, the rest are sorted by start time and capped
/// at 3 (the UI maximum). May legitimately return an overlapping set — that is
/// [SessionConfig.isScheduleValid]'s job to flag, not a load failure.
List<ScheduleWindow> _scheduleWindowsFromJson(dynamic raw) {
  const fallback = [ScheduleWindow(360, 600)];
  if (raw is! List) return fallback;
  final windows = <ScheduleWindow>[];
  for (final entry in raw) {
    final w = ScheduleWindow.fromJson(entry);
    if (w != null) windows.add(w);
  }
  if (windows.isEmpty) return fallback;
  windows.sort((a, b) => a.startMinute.compareTo(b.startMinute));
  return List.unmodifiable(windows.take(3));
}
