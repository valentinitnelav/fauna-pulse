# Pollinator Monitor — Current-State Overview

This file is a *current* picture of the app, meant to ground a new session cheaply 
(instead of reading the full ~1800-line log history from POLLINATOR_MONITOR.md).
**Rewrite it in place; never append.** Update it whenever a change alters a default, an
invariant, or the file map. Keep it short (≤ ~250 lines). The round-by-round narrative
and rationale belong in `POLLINATOR_MONITOR.md`, **not** here.

> Last synced with: round 66 (review-and-document pass, no code changes: PERF_AND_ROBUSTNESS_REVIEW.md roadmap added; FIELD_GUIDE / SETTINGS_REFERENCE / DATA_GUIDE / ARCHITECTURE / CONTRIBUTING docs added; see Pointers).

## What the app is about

An Android field app that detects flower-visiting insects in real time on-device
(Ultralytics YOLO via LiteRT) inside a draggable square **Region of Interest (ROI)** over a
flower, tracks each insect with a stable **track id**, and logs every visit. The scientific
deliverable is the **visitation rate** (how often + how long insects visit a flower). Built
on a clone of `ultralytics/yolo-flutter-app`.

## Where the code lives

- **App (Dart):** `pollinator-monitor/lib/pollinator/` — all custom code. `lib/main.dart`
  points to the home screen.
- **Vendored plugin:** `packages/ultralytics_yolo/` — Dart widget + native Kotlin
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
| Widgets | `widgets/roi_overlay.dart`, `widgets/track_box_painter.dart`, `widgets/preview_transform.dart` | Draggable ROI, track-id boxes, camera "cover-fit" coordinate mapping |
| Screens | `screens/home_screen.dart`, `screens/camera_session_screen.dart`, `screens/settings_sheet.dart`, `screens/session_summary_screen.dart` | Entry/permissions, live orchestration, settings, end-of-session dashboard |
| Tests | `test/pollinator/*` | Unit tests for ROI math, tracker, logger, throttle |

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
| Auto-throttle | on | min `3` FPS, duty target `0.5`; cap above is its ceiling |
| Motion gate | off (opt-in) | r58: detector sleeps while ROI is still; pixelDelta `25`, area `0.5%`, wake `3 s`, grid `48` cells/side (r60: 16–160; the check is 2× supersampled so coarse grids stay calm), idle check rate `5` fps (r64: 1–30, frames dropped pre-conversion while asleep) |
| Stream resolution | `640×480` | ≈ model input; short side caps the fast ROI crop |
| Photo source mode | `auto` | r61: per-photo `chooseCapturePath` — fast live-frame crop when it meets the min target, full-res still otherwise; `fast`/`still` force one path (legacy `fullResPhotos:true` loads as `still`, `false` as `fast`) |
| Saved photo side | `1024 px` | r63 single target (replaces r61's min/max pair): auto-decision threshold AND downscale cap, so photos save at exactly this when the ROI can supply it; **never upscaled**, ⚠ readout when even a still can't reach it |
| Occlusion tolerance | `3.0 s` | track buffer |
| Min hits | `0.2 s` | before a track is confirmed |
| GPU when faster | on | see GPU/CPU note below |

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
  by int8 vs fp16** (log §6). A 2-strike GPU-crash blocklist demotes crashing models to
  CPU. The chosen engine is logged and shown on screen.
- **Stream resolution honesty (round 56).** The settings dropdown can over-promise; the
  live "Stream: W×H" readout is ground truth (CameraX may cap the analysis stream). Stream
  size only affects fast-crop sharpness, **not** detection (every frame is downscaled to the
  model's input tensor). Logs record both requested and delivered (`analysis_w/h`).
- **Logging.** Append-only JSONL (crash/battery-loss safe): start metadata, per-detection
  entries with track id + ROI-relative `box_in_roi` (0..1) + saved filenames, ROI geometry
  updates, and stop metadata with `ended_normally`.
- **Tracker.** Pure-Dart ByteTrack (`tracking/byte_track.dart`) with a distance-association
  fallback that fixed track-id fragmentation (one insect → dozens of ids).
- **No reimplementing YUV→RGB** in the Dart path — the native pipeline already does it.
- **Motion gate (round 58, opt-in).** Native `MotionGate.kt` (48×48 EMA background diff on
  the ROI) skips inference while nothing moves; motion, detections, and ROI drags all
  extend a `wakeSeconds` window, and the gate always starts awake. While idle the native
  side heartbeats `gateIdle: true` ~1 Hz — `_onStreamingData` short-circuits on it (no
  watchdog, "Gate: idle" stat line). On wake after sleeping > `occlusionSeconds`,
  `ByteTracker.expireLostTracks()` runs so a newcomer never inherits a stale id. Gate
  transitions are logged as `motion_gate` JSONL entries. Don't gate in Dart — frames
  never leave the native layer. UI (r59): green "DETECTOR ON" / grey "SLEEPING" chip
  atop the status strip + ROI border turns grey while idle (priority: capture flash >
  gate-idle grey > recording red > yellow). Handheld shake keeps the gate awake by
  design — it is meant for a mounted phone. r60: the thumbnail is drawn 2× supersampled
  and box-averaged (bilinear minification is point-sampling; without this, coarse grids
  were NOISIER than fine ones — session_89 observation).
- **Session summary is tabbed (round 60):** Overview | Settings | Photos | Graphs
  (`DefaultTabController`, `session_summary_screen.dart`). The Settings tab reads the
  `config` block from the start record, so every new `SessionConfig` field appears in
  the JSON automatically — but add a display row in `_settingsSection()` when adding
  a setting.

## Device quirks (test phones)

- **Xiaomi `2107113SG`** (adb `2b2dc560`): primary test device. Deploy **debug build only**,
  **Install via USB** (MIUI quirk). Adreno GPU.
- **Samsung `RF8T403A3AT`** (Galaxy M12-class): analysis stream caps around **960×720**
  (selecting higher falls back); used to validate the round-56 "truthful stream readout".

## Pointers

- **Full history & rationale:** `POLLINATOR_MONITOR.md` (append-only journal with many rounds entries).
- **Human-facing docs (r66):** `FIELD_GUIDE.md` (run a session + troubleshoot), `SETTINGS_REFERENCE.md` (per-setting meanings), `DATA_GUIDE.md` (session.jsonl dictionary + R/Python visitation-rate), `ARCHITECTURE.md` (data flow, channel contract, keep-in-sync pairs), `CONTRIBUTING.md` (build/test/rules + docs index). These are the durable references; this OVERVIEW stays the short AI-grounding snapshot.
- **Perf/robustness roadmap (r66):** `PERF_AND_ROBUSTNESS_REVIEW.md` (prioritized checkbox list; nothing implemented yet — includes the `occlusionSeconds` 3.0-vs-1.0 fromJson bug and the "no real CPU/GPU benchmark" finding).
- **Photo-resolution explainer for collaborators:** `HOW_PHOTO_RESOLUTION_WORKS.md` (plain-language: why a small on-screen ROI still yields sharp 1024 px photos; where each number lands in session.jsonl).
- **Archived Claude chats:** `/InsectDetectApp/exported_claude_conversations/` (dated txt files, 
large; avoid to parse unless owner points to them; they are ignored also in `/.claude/settings.local.json`).
- **General spec:** `/InsectDetectApp/CLAUDE.md`.
- **Deny-listed:** see `.claude/settings.local.json`.
These are large txt files - avoid to parse unless owner points to them.

## Build / test quick reference

- Analyze: `flutter analyze` — Test suite: `flutter test test/pollinator` (38 tests as of r57).
- Build: `flutter build apk --debug` (the app deploys as debug).
- Pre-existing build warnings (KGP deprecation, optional `fetch_bundled_models.sh`) are
  unrelated to app logic.
- do not git commit or run git commands without owner's consent.