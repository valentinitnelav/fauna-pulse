# Architecture

**Who this is for:** a new developer joining the project. It explains how a
camera frame becomes a logged visit, where the native (Kotlin) and Dart sides
meet, and which pieces must be kept in sync. For per-directory file summaries,
see [`lib/fauna_pulse/README.md`](../lib/fauna_pulse/README.md); for current
defaults and invariants, see [AGENT_CHANGELOG_OVERVIEW.md](AGENT_CHANGELOG_OVERVIEW.md).

---

## 1. The two sides

The app is a **Flutter (Dart)** application running on top of a **vendored,
modified Ultralytics YOLO plugin** whose performance-critical code is **native
Android (Kotlin)**.

- **App (Dart):** `lib/fauna_pulse/` — all custom code (ROI, tracking, capture
  scheduling, logging, screens). `lib/main.dart` is the entry point.
- **Vendored plugin:** `packages/ultralytics_yolo/` — the camera + detector.
  Dart widget (`YOLOView`) plus native Kotlin (CameraX capture + LiteRT
  inference). Forked from upstream commit `22b2e5d` and modified for
  ROI-crop inference and fast ROI capture.
- **App native shell:** `android/app/src/main/kotlin/com/ultralytics/yolo/MainActivity.kt`
  — hosts the full-resolution high-res photo crop and the device/thermal/keep-alive
  method channels. App id: `com.faunapulse.app` (the Kotlin namespace
  stays `com.ultralytics.yolo` for compatibility with the plugin).

## 2. Per-frame data flow

```
 CameraX frame (RGBA)                         [native, camera thread]
   │  packages/.../YOLOView.kt  onFrame()
   ▼
 Motion gate check (if enabled) ── idle? ─────► drop frame (stay asleep)
   │  MotionGate.kt                              heartbeat "gateIdle" → Dart
   ▼
 Inference FPS cap ── over cap? ──────────────► drop frame
   │
   ▼
 ROI crop + resize to model input             ImageUtils.kt / ObjectDetector.kt
   │
   ▼
 LiteRT inference (GPU or CPU)                 LiteRtModel.kt (CompiledModel)
   │
   ▼
 NMS / postprocess (native C++ for detect)    ObjectDetector.kt
   │
   ▼
 Result map over EventChannel  ───────────────► Dart
   │  YOLOPlatformView.sendStreamData
   ▼
 _onStreamingData()                            [Dart]  camera_session_screen.dart
   │   ├─ keep only detections whose centre is in the ROI  (models/roi.dart)
   │   ├─ ByteTrack: assign/continue track IDs             (tracking/byte_track.dart)
   │   ├─ schedule ROI photos                              (capture/roi_capture.dart)
   │   └─ append the frame's detections record (async queue) (logging/session_logger.dart)
   ▼
 session.jsonl  +  roi_frames/*.jpg
```

Key point: **YUV→RGB conversion and ROI cropping happen natively** and must not
be reimplemented in the Dart path (the plugin already does it). Frames the
motion gate or FPS cap drop never leave the native layer.

## 3. Native ↔ Dart contract

Two mechanisms cross the boundary:

**Streaming (per frame), plugin's `EventChannel`:** the native side sends a
result map per emitted frame (detections with class, confidence, pixel +
normalized boxes; timestamp; frame number; image size; ROI-active flag;
motion-gate idle flag + score; accelerator; camera FPS). **No image bytes are
sent per frame by default.** Consumed by `_onStreamingData`.

**Method channels (request/response), app-specific (`faunapulse/*`):**

| Channel | Direction | Purpose |
|---|---|---|
| `faunapulse/crop` | Dart → native | `MainActivity.cropRoiJpeg` — take a full-resolution high-res photo and region-crop the ROI out of it. |
| `faunapulse/thermal` | Dart → native | Battery temperature, current/voltage, charge counter, OS thermal status. Also `getFreeStorage` (round 68): free/total bytes of the session volume via `StatFs`. |
| `faunapulse/keepalive` | Dart → native | Start/stop the foreground service that keeps a long session alive. |
| `faunapulse/diagnostics` | Dart → native | Capture logcat into the session folder. |

The plugin also exposes ROI push, motion-gate config, lens/focus, and a fast
live-frame ROI crop through the `YOLOView` controller.

## 4. Keep-in-sync pairs (edit both or neither)

Some logic is duplicated across the language boundary or across capture paths;
changing one without the other causes subtle field bugs (documented in
AGENT_CHANGELOG.md rounds 57, 62, 63):

- **ROI ÷32 snapping.** Three crop paths must all snap the side to a multiple
  of 32 and cap it to the source's short side: the fast live-frame crop
  (`ImageUtils.cropRoiFromFrame`, plugin Kotlin), the high-res photo crop
  (`MainActivity.cropRoiJpeg`, app Kotlin), and the Dart fallback `_cropJpeg`
  (`capture/roi_capture.dart`). The shared math lives in
  `models/roi.dart` (`Roi.snapSideToGrid`, `snapToMultipleOf32`). Don't
  "fix" snapping in one place only.
- **Rotation/mirror of the saved crop.** Only the small ROI square is rotated,
  not the full frame — the Dart side (`rawRectForUprightRect` / `uprightHighResDims`
  in `roi_capture.dart`) and the Kotlin mirror in `MainActivity.kt` must
  agree. Do **not** reintroduce full-frame `normalizeJpegOrientation`.
- **ROI box geometry lives in one scale** (the analysis/stream grid). The
  on-screen size readout, resize snapping, and inference ROI all use the
  analysis frame; the high-res source only feeds the separate "saves N×N" label.
  See the invariants in AGENT_CHANGELOG_OVERVIEW.md before touching ROI code.

## 5. What the plugin fork changed vs upstream

The vendored `packages/ultralytics_yolo/` is **not** stock — a new developer
reading its (upstream) docs won't see these. The authoritative fork document
(upstream base and audit history, the full change list, fork-only invariants,
and the re-audit checklist) is
[`packages/ultralytics_yolo/FAUNAPULSE_FORK.md`](../packages/ultralytics_yolo/FAUNAPULSE_FORK.md).
The headline changes:

- **ROI-crop inference**: the detector runs on the cropped ROI square (better
  small-insect recall) instead of the whole letterboxed frame.
- **Fast ROI capture** from the live analysis frame (no camera stall).
- **Motion gate** (`MotionGate.kt`, opt-in): native brightness-diff gate that
  sleeps the detector on a still ROI.
- **GPU-crash guard** (`LiteRtModel.kt`): a 2-strike blocklist that drops a
  model to CPU permanently if it crashes the GPU compile, plus a GPU program
  cache.
- **Camera2 interop funnel + power controls** (round 82): manual focus and the
  camera-hardware FPS cap applied in one place (`applyInteropOptions`),
  preview detach for blackout, and the round-129 inference deadline scheduler.
- **Native lifecycle overhaul** (round 161): real model/instance disposal,
  plugin-owned coroutine scope, terminal `YOLOView.release()`.

## 6. Session lifecycle (Dart)

`camera_session_screen.dart` orchestrates a session: it receives every frame
in `_onStreamingData` and owns the UI, but since round 73 the actual logic
lives in `session/`: `frame_processor.dart` (per-frame ROI mapping, tracking,
gate-idle state), `session_recorder.dart` (recording lifecycle: folder,
logger, photos, keep-alive, stop order), plus the camera probes, schedule
plan, and time-lapse camera parking. A recording opens the `SessionLogger`,
writes `start_of_session`, wires the `RoiCaptureScheduler`, starts the
wakelock + keep-alive foreground service and the sample timers
(thermal/FPS/power), and on stop writes `end_of_session` and tears down in
order. Rule: new session logic goes into `session/` (unit-testable), not into
the screen.

## 7. Where to look next

- Output format & analysis: [DATA_GUIDE.md](DATA_GUIDE.md)
- Photo resolution pipeline: [HOW_PHOTO_RESOLUTION_WORKS.md](HOW_PHOTO_RESOLUTION_WORKS.md)
- Full round-by-round Claude Code rationale: [AGENT_CHANGELOG.md](AGENT_CHANGELOG.md)
- Build, test, conventions: [CONTRIBUTING.md](CONTRIBUTING.md)
