# Pollinator Monitor — Current-State Overview (for Claude Code)

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

- **App (Dart):** `pollinator-monitor/lib/pollinator/` — all custom code. `lib/main.dart`
  points to the home screen.
- **Plugin:** `packages/ultralytics_yolo/` — Dart widget + native Kotlin
  (CameraX + LiteRT inference). Modified for ROI-crop inference and fast ROI capture.
- **Native app shell:** `android/app/src/main/kotlin/com/ultralytics/yolo/MainActivity.kt`
  — hosts the full-res `cropRoiJpeg` method channel.
- **Ignore / off-limits:** `ios/` is git-ignored. `sessions/` (recorded field data) and
  other sibling folders under `/InsectDetectApp/` are owner data and **deny-listed** — do
  not read them unless the owner points you at a specific path.

## Module map (`lib/pollinator/`)

| Area | Files | Purpose |
|------|-------|---------|
| Models | `models/roi.dart`, `models/track.dart`, `models/session_config.dart` | Square ROI math (resolution-independent), track/detection types, all user settings + persistence |
| Tracking | `tracking/byte_track.dart` | Lightweight pure-Dart ByteTrack-style multi-object tracker (stable track ids) |
| Logging | `logging/session_logger.dart`, `logging/device_thermal.dart` | Append-only JSONL writer; phone-temperature reader |
| Capture | `capture/roi_capture.dart` | Time-lapse scheduler + background-isolate JPEG crop of the ROI |
| Session (round 73) | `session/frame_processor.dart`, `session/session_recorder.dart`, `session/camera_diagnostics_controller.dart` | Per-frame mapping/tracking + gate-idle state (unit-testable), recording lifecycle (folder/logger/photos/keep-alive/stop order), one-time camera probes + lens cycling |
| Widgets | `widgets/roi_overlay.dart`, `widgets/track_box_painter.dart`, `widgets/preview_transform.dart`, `widgets/calibrating_banner.dart`, `widgets/session_info_dialog.dart`, `widgets/roi_size_sheet.dart` | Draggable ROI, track-id boxes, camera "cover-fit" coordinate mapping, calibration banner, setup dialog, exact-ROI-size sheet |
| Screens | `screens/home_screen.dart`, `screens/camera_session_screen.dart`, `screens/settings_sheet.dart`, `screens/session_summary_screen.dart` | Entry/permissions, live orchestration (UI only since round 73 — logic in `session/`), settings, end-of-session dashboard |
| Tests | `test/pollinator/*` | Unit tests for ROI math, tracker, logger, throttle, capture scheduler, frame processor |

## Current defaults

Source of truth: `lib/pollinator/models/session_config.dart` constructor (~`:161-192`).

| Setting | Default | Notes |
|---|---|---|
| Model | `yolo26n` | Only nano ships bundled; others need an added `.tflite` |
| Confidence | `0.25` | min detection score |
| IoU (NMS) | `0.7` | overlap threshold |
| Time-lapse step | `1.0 s` | first photo on detection, then every step |
| Capture duration | `10.0 s` | per track id; must be > step |
| Session length | `60 min` | user-editable |
| Inference FPS cap | `10` | deliberate heat cap (r58); `0` = uncapped benchmark mode; explicitly saved `0` survives reload |
| Camera FPS cap | `15` | r82: caps the camera HARDWARE rate (Camera2 AE fps range) — the standing sensor/ISP load the gate can't touch; `0` = device default (~30); explicitly saved `0` survives reload |
| Auto-throttle | on | min `3` FPS, duty target `0.5`; cap above is its ceiling |
| Motion gate | off (opt-in) | r58: detector sleeps while ROI is still; pixelDelta `25`, area `0.5%`, wake `3 s`, grid `48` cells/side (r60: 16–160; the check is 2× supersampled so coarse grids stay calm), idle check rate `5` fps (r64: 1–30, frames dropped pre-conversion while asleep) |
| Stream resolution | `640×480` | ≈ model input; short side caps the fast ROI crop |
| Photo source mode | `auto` | r61: per-photo `chooseCapturePath` — fast live-frame crop when it meets the min target, full-res still otherwise; `fast`/`still` force one path (legacy `fullResPhotos:true` loads as `still`, `false` as `fast`) |
| Saved photo side | `1024 px` | r63 single target (replaces r61's min/max pair): auto-decision threshold AND downscale cap, so photos save at exactly this when the ROI can supply it; **never upscaled**, ⚠ readout when even a still can't reach it |
| Occlusion tolerance | `3.0 s` | track buffer |
| Min hits | `0.2 s` | before a track is confirmed |
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
- **Tracker.** Pure-Dart ByteTrack (`tracking/byte_track.dart`) with a distance-association
  fallback that fixed track-id fragmentation (one insect → dozens of ids).
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
  gate-idle grey > recording red > yellow). Handheld shake keeps the gate awake by
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
  (`saveImageToGallery` on the `pollinator/crop` channel →
  Pictures/PollinatorMonitor; < Android 10 or MediaStore failure →
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
  pops; home list rescans on return from a summary).

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

- Analyze: `flutter analyze` — Test suite: `flutter test test/pollinator`.
- Build: `flutter build apk --debug` (the app deploys as debug).
- Pre-existing build warnings (KGP deprecation, optional `fetch_bundled_models.sh`) are
  unrelated to app logic.
- do not git commit or run git push without owner's consent.