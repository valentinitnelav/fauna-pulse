# FaunaPulse — Current-State Overview (for Claude Code)

This file is a *current* picture of the app, meant to ground a new Claude session cheaply 
(instead of reading the full thousands-line log history from AGENT_CHANGELOG.md).
**Rewrite this file in place instead of appending to avoid unnecessary verbosity** 
Update it whenever a change alters a default, an invariant, or the file map. 
Keep it short (e.g. ≤ ~300 lines). 
The round-by-round narrative, details and rationale belong in `AGENT_CHANGELOG.md`, **not** here.

## What the app is about

An Android field app that detects flower-visiting insects in real time on-device
(Ultralytics YOLO via LiteRT) inside a draggable square **Region of Interest (ROI)** over a
flower, tracks each insect with a stable **track id**, and logs every visit. The scientific
deliverable is the **visitation rate** (how often + how long insects visit a flower). Built
on a clone of `ultralytics/yolo-flutter-app`.

## Where the code lives

- **App (Dart):** `fauna-pulse/lib/fauna_pulse/` — all custom code. `lib/main.dart`
  points to the home screen.
- **Plugin:** `packages/ultralytics_yolo/` — Dart widget + native Kotlin
  (CameraX + LiteRT inference). Modified for ROI-crop inference and fast ROI capture.
- **Native app shell:** `android/app/src/main/kotlin/com/ultralytics/yolo/MainActivity.kt`
  — hosts the full-res `cropRoiJpeg` method channel.
- **Ignore / off-limits:** `ios/` is git-ignored. `sessions/` (recorded field data) and
  other sibling folders under `/InsectDetectApp/` are owner data and **deny-listed** — do
  not read them unless the owner points you at a specific path.

## Module map (`lib/fauna_pulse/`)

| Area | Files | Purpose |
|------|-------|---------|
| Models | `models/roi.dart`, `models/track.dart`, `models/session_config.dart` | Square ROI math (resolution-independent), track/detection types, all user settings + persistence |
| Tracking | `tracking/tracker.dart`, `tracking/byte_track.dart`, `tracking/c_biou_track.dart`, `tracking/tracker_replay.dart` | `InsectTracker` interface + two pure-Dart trackers (ByteTrack-style default, C-BIoU-style alternative) + offline replay harness for comparing them on recorded raw detections |
| Logging | `logging/session_logger.dart`, `logging/device_thermal.dart` | Append-only JSONL writer; phone-temperature reader |
| Capture | `capture/roi_capture.dart` | Time-lapse scheduler + background-isolate JPEG crop of the ROI |
| Session (round 73) | `session/frame_processor.dart`, `session/session_recorder.dart`, `session/camera_diagnostics_controller.dart` | Per-frame mapping/tracking + gate-idle state (unit-testable), recording lifecycle (folder/logger/photos/keep-alive/stop order), one-time camera probes + lens cycling |
| Widgets | `widgets/roi_overlay.dart`, `widgets/track_box_painter.dart`, `widgets/preview_transform.dart`, `widgets/calibrating_banner.dart`, `widgets/session_info_dialog.dart`, `widgets/roi_size_sheet.dart` | Draggable ROI, track-id boxes, camera "cover-fit" coordinate mapping, calibration banner, setup dialog, exact-ROI-size sheet |
| Screens | `screens/home_screen.dart`, `screens/camera_session_screen.dart`, `screens/settings_sheet.dart`, `screens/session_summary_screen.dart` | Entry/permissions, live orchestration (UI only since round 73 — logic in `session/`), settings, end-of-session dashboard |
| Tests | `test/fauna_pulse/*` | Unit tests for ROI math, tracker, logger, throttle, capture scheduler, frame processor |

## Current defaults

Source of truth: `lib/fauna_pulse/models/session_config.dart` constructor (~`:161-192`).

| Setting | Default | Notes |
|---|---|---|
| Model | `yolo26n` | Only nano ships bundled; others need an added `.tflite` |
| Confidence | `0.25` | min detection score |
| IoU (NMS) | `0.7` | overlap threshold |
| Time-lapse step | `1.0 s` | first photo on detection, then every step; min 0.1 s since r96 (sub-second steps need the fast photo source — stills can't keep up) |
| Capture duration | `10.0 s` | per track id; must be > step |
| Session length | `60 min` | user-editable; ignored during scheduled runs |
| Scheduled recording | off | r94: 1–3 daily windows (default 06:00–10:00) × N days (default 1); REC starts the run; sleeps dark between windows |
| Inference FPS cap | `10` | deliberate heat cap (r58); `0` = uncapped benchmark mode; explicitly saved `0` survives reload |
| Camera FPS cap | `15` | r82: caps the camera HARDWARE rate (Camera2 AE fps range) — the standing sensor/ISP load the gate can't touch; `0` = device default (~30); explicitly saved `0` survives reload |
| Auto-throttle | on | min `3` FPS, duty target `0.5`; cap above is its ceiling |
| Motion gate | off (opt-in) | r58: detector sleeps while ROI is still; pixelDelta `25`, area `0.5%`, wake `3 s`, grid `48` cells/side (r60: 16–160; the check is 2× supersampled so coarse grids stay calm), idle check rate `5` fps (r64: 1–30, frames dropped pre-conversion while asleep) |
| Capture trigger | `detector` | r97 enum `CaptureTrigger {detector, motion, timelapse}` (Setup-tab dropdown; replaces r95 `motionOnlyCapture` bool — legacy configs migrate). `motion`: photos on ROI motion, detector NEVER runs (model loads, `predict()` never called), gate forced on, gate tunables = sensitivity, logs `motion_capture` records. `timelapse`: clock-driven bursts, no AI + no gate, logs `timelapse_capture` records. Both: NO `detections` records |
| Time-lapse burst interval | `30 min` | r97 "Repeat burst every" (`timeLapseIntervalSeconds`, s/min/h input): START-TO-START burst spacing; burst = photo every step for the photo duration; interval ≤ duration ⇒ continuous. Photo duration max now 24 h (unit-aware `DurationSettingField`) |
| Stream resolution | `640×480` | ≈ model input; short side caps the fast ROI crop |
| Photo source mode | `auto` | r61: per-photo `chooseCapturePath` — fast live-frame crop when it meets the min target, full-res still otherwise; `fast`/`still` force one path (legacy `fullResPhotos:true` loads as `still`, `false` as `fast`) |
| Saved photo side | `1024 px` | r63 single target (replaces r61's min/max pair): auto-decision threshold AND downscale cap, so photos save at exactly this when the ROI can supply it; **never upscaled**, ⚠ readout when even a still can't reach it |
| Occlusion tolerance | `3.0 s` | track buffer |
| Min hits | `0.2 s` | before a track is confirmed (UI label now "Minimum visit length") |
| Tracker algorithm | `bytetrack` | r105: AI-tab "Visit tracking" dropdown; `cbiou` = buffered-IoU alternative (search margins 0.30/0.50, own highThresh 0.5); both share the seconds-based settings above |
| Log raw detections | off | r105 eval toggle (tracking Advanced): one `raw_detections` JSONL record per frame (pre-tracking boxes) for the offline tracker replay harness; ~1–2 MB/h |
| Ground-truth frames | off / every `5 s` | r107 eval toggle (tracking Advanced): periodic ROI photo → `gt_frames/` + `gt_capture` records, independent of detections (hand-count ground truth); interval 1 s–1 h; size follows `targetRoiSavedPx`; second RoiCaptureScheduler driven by a 1 s screen timer via `SessionRecorder.recordGtFrame` |
| Crop 1:1 lock | off | r91: forces the summary-viewer crop-export box square; viewer chip ↔ Settings → Summary switch |
| GPU when faster | on | see GPU/CPU note below |
| CPU threads | `0` (auto) | r76: XNNPACK thread count when running on CPU; user-triggered engine benchmark (Settings → AI) times GPU vs CPU thread variants and can apply the fastest |

## Key invariants

- **ROI is ÷32 WYSIWYG (round 57).** The ROI box, the on-screen resolution readout, the
  saved JPEG crop, and the inference ROI are all the **same** square. The side snaps to a
  multiple of 32 and is capped to the frame's short side, so the saved size can **never
  exceed** the short-side floor (e.g. a 720 short edge → 704, never 720). When maxed, the
  box leaves a small exact margin (~8 px/side at 720) from the preview edge to indicate that band is
  the pixels *not* in the saved crop. Reuse `Roi.snapSideToGrid` / `snapToMultipleOf32` and
  `Roi.copyClamped` in `models/roi.dart`; the single mutation funnel is `_onRoiChanged` in
  `screens/camera_session_screen.dart`.
- **Crop/save paths all already ÷32-snap and cap to short side** — don't "fix" them again:
  fast `ImageUtils.cropRoiFromFrame` (plugin Kotlin), full-res `MainActivity.cropRoiJpeg`
  (app Kotlin), and the Dart fallback `_cropJpeg` (`capture/roi_capture.dart`). Fast path
  crops the live frame; the still path takes a full still then region-crops (and, above
  `maxRoiSavedPx`, downscales — never upscales).
- **The photo source is chosen PER PHOTO (round 61).** `chooseCapturePath` /
  `savedSidePx` / `capSavedSidePx` in `capture/roi_capture.dart` are the single source of
  the decision + size math; the single `targetRoiSavedPx` (r63) is both threshold and
  cap. Capture records log `path` + `saved_px` per photo, ROI records log `roi_source`
  + `saves_px`. Still-path caveat (logged, not solved): the still lands after the
  detection that scheduled it, so `box_in_roi` may not align pixel-perfectly.
- **Stills are processed off the main thread and NEVER full-frame-rotated (round 63).**
  `capturePhotoRaw` returns the unrotated JPEG + rotation/mirror info; CameraX's
  callback runs on `stillExecutor` (handing it the main executor froze UI/preview/
  detector ~1.5 s per photo — session_96 PerfMonitor). The ROI is mapped into raw
  coordinates by `rawRectForUprightRect` (Dart original with unit tests in
  `roi_capture.dart`; Kotlin mirror in `MainActivity.kt` — KEEP IN SYNC) and only the
  small square is rotated. Don't reintroduce `normalizeJpegOrientation` on this path.
- **While the motion gate is idle, only `motionGateIdleFps` frames/s are inspected
  (round 63; user-tunable since round 64, default 5).** The early skip in
  `YOLOView.onFrame` closes the rest BEFORE bitmap conversion (idle heat fix).
  Consequence: the delivered/camera FPS readout legitimately shows ~that number while
  the gate sleeps — that is the fix working, not a camera fault.
- **Still dims from the probe must go through `uprightStillDims` (round 64).** The
  probe's JPEG decode is EXIF-aware and may return the still already upright; a blind
  w/h swap for rotation 90/270 double-rotates (session_97: predicted 1024, saved 992,
  summary showed un-snapped 1304). The summary photo browser shows each file's exact
  `saved_px` from its capture record, not box geometry.
- **Owner rule: every new tunable parameter ships user-adjustable** — Settings control
  + SessionConfig JSON + summary row + round-trip test, in the same round it appears.
- **ROI box geometry lives in ONE scale: the stream grid (round 62).** The box's px
  readout, resize slider and ÷32 snapping always use the analysis frame
  (`_roiSourceWidth` == `_imageWidth`); the still source only feeds the separate
  "saves N×N (path)" part of the label (`_savedSideNow`) and the crops themselves.
  Do NOT make the box grid follow `_activePath` again — field-tested (session_95):
  the scale-flipping readout misled the owner into shrinking the box to ~17% of the
  frame without realising it.
- **GPU vs CPU is decided by whether the GPU backend can compile the model's op graph — not
  by int8 vs fp16** (log §6; re-verified r77: `arthropod_yolov11_int8` runs on GPU). A
  2-strike GPU-crash blocklist demotes crashing models to CPU. The chosen engine is logged
  and shown on screen. Engine choice is user-informed via the benchmark (r76:
  `benchmarkAccelerators` in `YOLOPlugin.kt`, noise input at the model's own resolution,
  3 warm-up + 20 timed runs per config; deliberately never run automatically).
- **Stream resolution honesty (round 56).** The settings dropdown can over-promise; the
  live "Stream: W×H" readout is ground truth (CameraX may cap the analysis stream). Stream
  size only affects fast-crop sharpness, **not** detection (every frame is downscaled to the
  model's input tensor). Logs record both requested and delivered (`analysis_w/h`).
- **Logging.** Append-only JSONL (crash/battery-loss safe): start metadata, one
  `detections` record per frame (round 69) whose `tracks[]` entries carry track id +
  ROI-relative `box_in_roi` (0..1) + saved filenames, ROI geometry updates, and stop
  metadata with `ended_normally`. Sessions ≤ round 68 used per-track `detection`
  records — parsers (summary screen, DATA_GUIDE snippets) must accept both. Writes go
  through an in-logger queue drained by one async writer loop (I/O on the Dart VM's
  background thread pool — never sync file I/O in the frame callback); fsync every
  ~0.5 s; `close()` is async and must be awaited so `end_of_session` lands.
- **A session never dies silently (round 67).** `SessionLogger` swallows + counts write
  failures (storage full) instead of throwing in the frame callback; `onWriteError` fires
  once → persistent red banner; writes keep being attempted so logging resumes if space
  frees. Global traps in `logging/app_error_hooks.dart` (installed in `main()`) route
  uncaught errors to the live session's `app_error` lines via `appErrorSink` (rate-limited
  to 1 per 2 s) and mark uncaught async errors handled (app stays alive). Don't add naked
  fire-and-forget futures — route failures to `_logAsyncError` / `RoiCaptureScheduler.onError`.
  Best-effort `catch` blocks (probes, platform calls, cleanup) must not be empty (r79, review
  B7): call `logSwallowed(site, e)` from `app_error_hooks.dart` — rate-limited debugPrint
  (reaches `logcat_end.txt`) + `app_error` JSONL line while recording.
- **Photo filenames (rounds 98–99).** `roi_<token>_<yyyy-MM-dd>_<HHmmss>_<SSS>.jpg`
  (e.g. `roi_elhp_2026-07-14_155813_119.jpg`): 4-char per-session random token
  (grouping: pooled multi-session folders sort by session), then the TRIGGER moment —
  the frame that made the photo due, not the write-completion time — as a fixed-width
  LOCAL-time stamp (`roiPhotoFileName` in `capture/roi_capture.dart`; token from
  `session_recorder.dart`, logged as `file_token` in the start record). Invariants:
  token first + fixed-width stamp (within a session, path sort == capture order —
  gallery export relies on it); track ids never in the name (one photo can serve
  several tracks); the same trigger moment is logged as `captured_at_ms` in
  `capture`/`motion_capture`/`timelapse_capture` records (the records' own `time_ms`
  is stamped later — at enqueue / after the JPEG write) and the summary's Photos tab
  shows it as "Captured". Saved crops carry NO EXIF (all paths re-encode raw pixels);
  filename + JSONL are the capture-time ground truth. `session.jsonl` stays strict
  one-object-per-line JSON Lines — never pretty-print it.
- **Tracker.** Two pure-Dart trackers behind the `InsectTracker` interface
  (`tracking/tracker.dart`, r105): ByteTrack-style (`byte_track.dart`, default —
  its distance-association fallback fixed track-id fragmentation) and
  C-BIoU-style (`c_biou_track.dart`, cascaded buffered-IoU matching for big
  between-frame jumps). Both share visit semantics (high-score spawn rule,
  frame-count buffers re-derived live from the user's seconds). The camera
  screen swaps the instance only on settings close (settings are locked while
  recording, so ids never restart mid-log); the start record's
  `tracker_params.algorithm` says which tracker produced a session. The
  "Log raw detections" toggle writes pre-tracking `raw_detections` records
  that `tracking/tracker_replay.dart` replays through either tracker
  (`flutter test test/fauna_pulse/tracker_replay_test.dart
  --dart-define=REPLAY_SESSION=…/session.jsonl` — prints the full variant
  matrix incl. a throttle-staircase stress stream); judge reports against a
  hand count from the session's `gt_frames/` photos, not MOT benchmarks.
  r107: both trackers carry INTERNAL evaluation flags (constructor-only,
  never SessionConfig): `timeAwareMotion` (velocity per second of real
  elapsed time; helps at irregular FPS — reduced C-BIoU fragmentation on the
  r106 screen sessions, never hurt ByteTrack) and ByteTracker's
  `FallbackMode.bufferedIou` (over-merged on that data — bridges ~0.15
  teleports). Adoption rule: a variant becomes default only after it wins on
  field sessions with gt-frame hand counts (less fragmentation, no new
  merges); until then live behavior is unchanged.
- **No reimplementing YUV→RGB** in the Dart path — the native pipeline already does it.
- **Camera2 interop options go through ONE funnel (round 82).**
  `applyInteropOptions()` in `YOLOView.kt` is the only place
  `setCaptureRequestOptions` may be called: that API REPLACES the whole option
  set, so manual focus and the camera fps cap must always be applied together
  (a separate call would silently erase the other — e.g. unlock the focus).
  The funnel re-runs after every camera (re)bind and after a preview reattach.
  The fps cap picks a HAL-advertised AE range (closest ≤ requested; logged as
  "Camera fps cap: requested=X applied=[a, b]"). Xiaomi accepts a fixed [15,15].
- **Blackout (power save) detaches the Preview use case (round 82).** The black
  scrim + min brightness alone saved ~nothing (measured: camera HAL ~2 cores,
  app ~1 core kept running under it). `setPreviewEnabled(false)` unbinds ONLY
  the preview stream — analysis (detector/gate) + ImageCapture stay bound and
  a recording continues; wake reattaches it (~0.2 s) and re-asserts the interop
  funnel. A timed session end must (and does, r83) `_exitBlackout()` before
  pushing the summary — the window-brightness override is per-Activity, so a
  summary pushed over the cover would render unreadably dim with no cover to tap. 
  Measured effect (r82, gate asleep, USB-charging): total CPU ~490%→
  ~225%, skin temp plateau ~58 °C → flat ~48 °C. The r78 "idle warming is real"
  analysis is the *why*; r81/82 in AGENT_CHANGELOG.md carry the numbers.
- **Field power invariant (owner, 2026-07-11):** the phone is assumed to be on
  a power bank during field sessions — charging heat is a given, plan heat
  budgets with it; don't build features that assume battery-only operation.
- **Scheduled recording (round 94).** `SchedulePlan` (`session/schedule_plan.dart`,
  pure Dart, clock-injected) plans "1–3 daily windows × N days";
  `_scheduleTick()` in the camera screen reconciles real state against
  `phaseAt(now)` on a timer capped at 60 s (doze/clock jumps self-heal — never
  accumulate). Each window = its OWN session (folder `<name>_d<day>w<win>`,
  normal `ended_normally` end; log format unchanged); between windows =
  scheduled sleep: session closed, camera FULLY unbound via `_controller.pause()`
  (blackout alone only detaches preview), blackout cover in a status-tap
  variant (tap shows next-window info, never wakes). `SessionRecorder.stop(
  retainKeepAlive: true)` keeps the foreground service + wakelock across
  sleeps; only the run's very end (or abort/dispose) releases them. In schedule
  mode `_sessionTimer` (session length) is NOT armed. Deliberately NO
  AlarmManager/deep sleep: staying foreground with a wakelock is the app's
  MIUI-survival strategy, and the phone is on a power bank anyway.
- **Motion gate (round 58, opt-in).** Native `MotionGate.kt` (48×48 EMA background diff on
  the ROI) skips inference while nothing moves; motion, detections, and ROI drags all
  extend a `wakeSeconds` window, and the gate always starts awake. While idle the native
  side heartbeats `gateIdle: true` ~1 Hz — `_onStreamingData` short-circuits on it (no
  watchdog, "Gate: idle" stat line). On wake after sleeping > `occlusionSeconds`,
  `ByteTracker.expireLostTracks()` runs so a newcomer never inherits a stale id. Gate
  transitions are logged as `motion_gate` JSONL entries. r77: while idle, per-second
  `fps` records OMIT all inference-derived fields and carry `gate_idle: true` instead
  (absent = detector off — never log stale/zero inference numbers), the on-screen
  Pipeline/FPS/inference values read 0, and summary graphs break lines across the gap.
  r85: a wake (or any long pause — settings sheet, summary screen) must NOT blend the
  gap into the fps EMAs — `Predictor.finishTiming` (native) and
  `FrameProcessor.updatePipelineFps` (Dart) share a resume guard (gap > max(2 s, 5×
  interval) → skip blend; KEEP IN SYNC), and the summary FPS graph plots
  `pipeline_fps ?? fps` so pre-r85 sessions read honestly too.
  Don't gate in Dart — frames never leave the native layer. UI (r59): green "DETECTOR ON" / grey "SLEEPING" chip
  atop the status strip + ROI border turns grey while idle (priority: capture flash >
  gate-idle grey > recording red > yellow).
  r95 **motion-only capture**: a `motionOnlyMode` branch in `onFrame` sits BEFORE
  `predictor?.let` (needs nothing from the model; detector path untouched when off) —
  gate check on every converted frame, awake stream maps `{motionOnly:true,
  gateIdle:false, motionScore, cameraFps, imageWidth/Height, roiActive}` at ≤10 Hz
  (fixed 100 ms, NOT shouldRunInference — that cap needs inference timings; wake
  transition emits immediately; dims are MANDATORY — the Dart probe/ROI bootstrap
  needs them), idle heartbeat via the shared `maybeEmitGateIdleHeartbeat` helper.
  Dart: `camera_session_screen` branches on `motionOnly:true` maps → zeroes
  inference numbers → `SessionRecorder.recordMotionFrame` →
  `RoiCaptureScheduler.evaluateMotion` (ONE shared window, step/duration cadence)
  → returns BEFORE the 0-FPS watchdog (critical). r96: a new motion event = a
  gate sleep→wake CYCLE — `_setGateIdle` (idle transition, motion-only) calls
  `recorder.onMotionGateIdle()` → `resetMotionWindow()`; the in-window
  gap>durationMs rule is a paused-stream backstop ONLY (awake emissions flow
  every 100 ms for the whole wakeSeconds window, so it can never fire while
  awake — relying on it required ~wake+duration of stillness, the r96 field bug).
  No ROI video (VideoCapture is full-frame; 4th use case exceeds device combos);
  ≥5 fps bursts = fast photo source + step ≤ 0.2 s (fast crops cap at the
  stream short side).
- **Time-lapse capture (round 97, `CaptureTrigger.timelapse`).** Photos on a pure
  Dart clock: `TimeLapsePlan` (`capture/time_lapse_plan.dart`, pure + clock-
  injected like SchedulePlan) + a self-rescheduling `_timeLapseTick` timer in the
  camera screen (armed per recording, capped 60 s) → `recordTimeLapseFrame`
  reuses the scheduler's motion window (`evaluateMotion` + `resetMotionWindow`
  at each burst start via `beginTimeLapseBurst`). Native `setTimeLapse(enabled,
  sampleFps)`: pre-conversion frame drop (Dart pushes ceil(2/step) during a
  burst, 1 fps between) + ~1 Hz `{timeLapse:true, dims…}` heartbeats emitted
  BEFORE `predictor?.let` — predict() never runs; the Dart branch returns before
  the 0-FPS watchdog. Gate forced OFF natively in this mode. Chip: green
  "TIME-LAPSE: CAPTURING" / grey "NEXT BURST in mm:ss". `recordFrame` is gated
  on `detectorEnabled` (startup race guard for both no-AI modes). Scheduled
  windows compose (each window anchors its own plan); session length applies.
  Future (not built): camera full-unbind between long bursts via the r94 pause
  machinery; on-device post-processing detector/tracker on saved photos.
  `recordFrame` is skipped in this mode (startup race must not write `detections`
  records). `fps` records omit inference fields even while awake + carry
  `motion_only:true` (r77 rule). Summary: `motion_capture` records (and, backstop,
  `capture` records) seed the Photos list; timeline/unique-insects show a
  motion-only note. Chip reads "CAPTURING"/"WAITING FOR MOTION". Handheld shake keeps the gate awake by
  design — it is meant for a mounted phone. r60: the thumbnail is drawn 2× supersampled
  and box-averaged (bilinear minification is point-sampling; without this, coarse grids
  were NOISIER than fine ones — session_89 observation). r74 (review A5): on frames that
  run inference the thumbnail is derived from the detector's already-rasterized
  model-input bitmap (`motionDetectedFromModelInput` ← `BasePredictor.lastRoiModelInput()`,
  checked right after `predict`) so the ROI is copied out of the camera frame once per
  frame; idle and FPS-capped frames keep the gate's own direct draw (no model raster
  exists there), so the gate still sees every converted frame while awake.
- **Session summary is tabbed (round 60):** Overview | Settings | Photos | Graphs
  (`DefaultTabController`, `session_summary_screen.dart`). The Settings tab reads the
  `config` block from the start record, so every new `SessionConfig` field appears in
  the JSON automatically — but add a display row in `_settingsSection()` when adding
  a setting. r84: the power (W) graph + energy numbers render only for sessions with
  NO charging detected (per-sample `is_charging` in `power` records; start/end thermal
  flags as fallback for older logs) — battery-terminal current measures charging, not
  consumption, while plugged in, so a note replaces the graph. Raw `power` records are
  still always logged. r86: the Photos tab draws EVERY insect of the photo's trigger
  frame (the `jpeg` filename is shared across the record's entries at parse time —
  only due tracks carry it in the log): cyan box = triggered the photo, amber =
  co-detected in the same frame, with a legend line; legacy per-track records (≤ r68)
  stay trigger-only. r87: photo viewer has a top-right tool column — boxes on/off +
  pinch/slider zoom (per-page `TransformationController`, overlay inside the
  transform, double-tap resets). r91 crop-and-export: a crop tool button enters a
  mode where a one-finger drag draws a box over the photo (drag layer ABOVE the
  InteractiveViewer, points mapped via `toScene` so it works while zoomed; ancestor
  scrollables freeze exactly as in zoom mode); optional 1:1 lock
  (`cropSquareLock` — the in-viewer chip and the Settings → Summary switch are the
  same setting). r92: a drag starting INSIDE the drawn box MOVES it (size and 1:1
  preserved — `moveSceneRect`; four-arrow glyph at the box's top-right as the cue),
  outside redraws. Save cuts the box FROM THE ORIGINAL JPEG (never the screen;
  `capture/crop_export.dart`, background isolate) into the Gallery via MediaStore
  (`saveImageToGallery` on the `faunapulse/crop` channel →
  Pictures/FaunaPulse; < Android 10 or MediaStore failure →
  `<session>/crops/`); Share opens the share sheet (Google Lens / iNaturalist).
  The crop bar shows the crop's real saved-pixel size (⚠ tiny under 100 px).
  In-app API identification (Observation.org NIA / iNaturalist upload) stays
  future work — needs GPS in session logs + platform decisions first.
  r88/r89: while zoomed, ALL ancestor scrollables freeze (`NeverScrollableScrollPhysics`
  on the inner PageView, the Photos ListView AND the TabBarView via `onZoomChanged` —
  each otherwise wins drags meant as photo panning); ‹ › buttons change photo
  (resetting zoom first), a chip shows the zoom mode, a 4-arrow pan pad nudges the
  view without any drag gesture, and `_BoxPainter` divides stroke/label size by the
  zoom so boxes stay thin on screen. r90: Overview shows Date/Start/End (home-list
  formats) above Duration, plus a storage section (session folder size via shared
  `folderSizeBytes`/`formatBytes` in `logging/device_storage.dart`; phone free GB)
  and a red confirm-guarded "Delete session" button (recursive folder delete →
  pops; home list rescans on return from a summary). r103: the home screen has
  a top-right ⋮ overflow menu (`_HomeMenuAction` — the intended home for future
  all-session bulk actions) with a type-to-confirm "Delete all sessions"
  (user must type `delete`; deletes each recognized session folder, never the
  `sessions/` root). r93 "Export photos to
  Gallery" (Overview button): batch-copies the session's `roi_frames/*.jpg`
  into the shared album `Pictures/FaunaPulse/<session>` so the phone's
  own Gallery shows each session as an album — `saveImagesToGallery` on
  `faunapulse/crop` takes file PATHS (never bytes; Kotlin reads the JPEGs
  itself), Dart sends chunks of 25 (`exportPhotosToGallery` in
  `capture/crop_export.dart`) for a determinate progress bar, re-export is
  idempotent (native DISPLAY_NAME query per RELATIVE_PATH — stored WITH a
  trailing slash), < Android 10 replies `supported:false` (clear message, no
  legacy permission), Delete is disabled while exporting. Photos only —
  session.jsonl stays private. Capture path untouched.

## Device quirks (test phones)

- **Xiaomi `2107113SG`** (adb `2b2dc560`): primary test device. Deploy **debug build only**,
  Install via USB, MIUI quirk.
- **Samsung `RF8T403A3AT`** (Galaxy M12-class): secondary test device

## Pointers

- **Full history & rationale:** `AGENT_CHANGELOG.md` (append-only journal with many rounds entries). These is a large txt file - avoid to parse unless owner points to them.
- **Human-facing docs (r66):** `FIELD_GUIDE.md` (run a session + troubleshoot), `SETTINGS_REFERENCE.md` (per-setting meanings), `DATA_GUIDE.md` (session.jsonl dictionary + R/Python visitation-rate), `ARCHITECTURE.md` (data flow, channel contract, keep-in-sync pairs), `CONTRIBUTING.md` (build/test/rules + docs index). These are the durable references; this OVERVIEW stays the short AI-grounding snapshot. These are large txt files - avoid to parse unless owner points to them.
- **Perf/robustness roadmap (r66):** `PERF_AND_ROBUSTNESS_REVIEW.md` (prioritized checkbox list; **complete** — every item ticked in place with its round number as of round 79).
- **Photo-resolution explainer for collaborators:** `HOW_PHOTO_RESOLUTION_WORKS.md` (plain-language: why a small on-screen ROI still yields sharp 1024 px photos; where each number lands in session.jsonl).
- **Archived selected Claude chats:** `/InsectDetectApp/exported_claude_conversations/` (dated txt files, 
large; avoid to parse unless owner points to them; they are ignored also in `/.claude/settings.local.json`).
- **General spec:** `/InsectDetectApp/CLAUDE.md`. This should load at the beginning of each session for general context.
- **Deny-listed:** see `.claude/settings.local.json`.


## Build / test quick reference

- Analyze: `flutter analyze` — Test suite: `flutter test test/fauna_pulse`.
- Build: `flutter build apk --debug` (the app deploys as debug).
- Pre-existing build warnings (KGP deprecation, optional `fetch_bundled_models.sh`) are
  unrelated to app logic.
- do not git commit or run git push without owner's consent.