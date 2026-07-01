# Pollinator Monitor — Current-State Overview

This file is a *current* picture of the app, meant to ground a new session cheaply 
(instead of reading the full ~1800-line log history from POLLINATOR_MONITOR.md).
**Rewrite it in place; never append.** Update it whenever a change alters a default, an
invariant, or the file map. Keep it short (≤ ~250 lines). The round-by-round narrative
and rationale belong in `POLLINATOR_MONITOR.md`, **not** here.

> Last synced with: round 57 (ROI ÷32 WYSIWYG).

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
| Inference FPS cap | `0` (uncapped) | raise only to limit heat/battery |
| Auto-throttle | on | min `3` FPS, duty target `0.5` |
| Stream resolution | `640×480` | ≈ model input; short side caps the fast ROI crop |
| Full-res ROI photos | `false` | false = fast crops from the live analysis frame |
| Occlusion tolerance | `3.0 s` | track buffer |
| Min hits | `0.2 s` | before a track is confirmed |
| GPU when faster | on | see GPU/CPU note below |

## Key invariants — don't re-derive these

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
  (default) crops the live frame; full-res path takes a still then region-crops.
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

## Device quirks (test phones)

- **Xiaomi `2107113SG`** (adb `2b2dc560`): primary test device. Deploy **debug build only**,
  **Install via USB** (MIUI quirk). Adreno GPU.
- **Samsung `RF8T403A3AT`** (Galaxy M12-class): analysis stream caps around **960×720**
  (selecting higher falls back); used to validate the round-56 "truthful stream readout".

## Pointers

- **Full history & rationale:** `POLLINATOR_MONITOR.md` (append-only journal with many rounds entries).
- **Archived Claude chats:** `/InsectDetectApp/exported_claude_conversations/` (dated txt files, 
large; avoid to parse unless owner points to them; they are ignored also in `/.claude/settings.local.json`).
- **General spec:** `/InsectDetectApp/CLAUDE.md`.
- **Deny-listed:** `sessions/` and other sibling data folders (see `.claude/settings.local.json`).
These are large txt files - avoid to parse unless owner points to them.

## Build / test quick reference

- Analyze: `flutter analyze` — Test suite: `flutter test test/pollinator` (38 tests as of r57).
- Build: `flutter build apk --debug` (the app deploys as debug).
- Pre-existing build warnings (KGP deprecation, optional `fetch_bundled_models.sh`) are
  unrelated to app logic.
- do not git commit or run git commands without owner's consent.