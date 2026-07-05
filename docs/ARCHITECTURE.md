# Architecture

**Who this is for:** a new developer joining the project. It explains how a
camera frame becomes a logged visit, where the native (Kotlin) and Dart sides
meet, and which pieces must be kept in sync. For per-directory file summaries,
see [`lib/pollinator/README.md`](../lib/pollinator/README.md); for current
defaults and invariants, see [POLLINATOR_OVERVIEW.md](POLLINATOR_OVERVIEW.md).

---

## 1. The two sides

The app is a **Flutter (Dart)** application running on top of a **vendored,
modified Ultralytics YOLO plugin** whose performance-critical code is **native
Android (Kotlin)**.

- **App (Dart):** `lib/pollinator/` — all custom code (ROI, tracking, capture
  scheduling, logging, screens). `lib/main.dart` is the entry point.
- **Vendored plugin:** `packages/ultralytics_yolo/` — the camera + detector.
  Dart widget (`YOLOView`) plus native Kotlin (CameraX capture + LiteRT
  inference). Forked from upstream commit `22b2e5d` and modified for
  ROI-crop inference and fast ROI capture.
- **App native shell:** `android/app/src/main/kotlin/com/ultralytics/yolo/MainActivity.kt`
  — hosts the full-resolution still crop and the device/thermal/keep-alive
  method channels. App id: `com.pollinatormonitor.app` (the Kotlin namespace
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
   │   └─ append detection records                         (logging/session_logger.dart)
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

**Method channels (request/response), app-specific (`pollinator/*`):**

| Channel | Direction | Purpose |
|---|---|---|
| `pollinator/crop` | Dart → native | `MainActivity.cropRoiJpeg` — take a full-resolution still and region-crop the ROI out of it. |
| `pollinator/thermal` | Dart → native | Battery temperature, current/voltage, charge counter, OS thermal status. Also `getFreeStorage` (round 68): free/total bytes of the session volume via `StatFs`. |
| `pollinator/keepalive` | Dart → native | Start/stop the foreground service that keeps a long session alive. |
| `pollinator/diagnostics` | Dart → native | Capture logcat into the session folder. |

The plugin also exposes ROI push, motion-gate config, lens/focus, and a fast
live-frame ROI crop through the `YOLOView` controller.

## 4. Keep-in-sync pairs (edit both or neither)

Some logic is duplicated across the language boundary or across capture paths;
changing one without the other causes subtle field bugs (documented in
POLLINATOR_MONITOR.md rounds 57, 62, 63):

- **ROI ÷32 snapping.** Three crop paths must all snap the side to a multiple
  of 32 and cap it to the source's short side: the fast live-frame crop
  (`ImageUtils.cropRoiFromFrame`, plugin Kotlin), the full-res still crop
  (`MainActivity.cropRoiJpeg`, app Kotlin), and the Dart fallback `_cropJpeg`
  (`capture/roi_capture.dart`). The shared math lives in
  `models/roi.dart` (`Roi.snapSideToGrid`, `snapToMultipleOf32`). Don't
  "fix" snapping in one place only.
- **Rotation/mirror of the saved crop.** Only the small ROI square is rotated,
  not the full frame — the Dart side (`rawRectForUpright` / `uprightStillDims`
  in `roi_capture.dart`) and the Kotlin mirror in `MainActivity.kt` must
  agree. Do **not** reintroduce full-frame `normalizeJpegOrientation`.
- **ROI box geometry lives in one scale** (the analysis/stream grid). The
  on-screen size readout, resize snapping, and inference ROI all use the
  analysis frame; the still source only feeds the separate "saves N×N" label.
  See the invariants in POLLINATOR_OVERVIEW.md before touching ROI code.

## 5. What the plugin fork changed vs upstream

The vendored `packages/ultralytics_yolo/` is **not** stock — a new developer
reading its (upstream) docs won't see these. Forked from `22b2e5d`, with:

- **GPU-crash guard** (`LiteRtModel.kt`): a 2-strike blocklist that drops a
  model to CPU permanently if it crashes the GPU compile, plus a GPU program
  cache. See the [litert-gpu memory] rationale in POLLINATOR_MONITOR.md.
- **ROI-crop inference**: the detector runs on the cropped ROI square (better
  small-insect recall) instead of the whole letterboxed frame.
- **Fast ROI capture** from the live analysis frame (no camera stall).
- **Motion gate** (`MotionGate.kt`, opt-in): native brightness-diff gate that
  sleeps the detector on a still ROI.

## 6. Session lifecycle (Dart)

`camera_session_screen.dart` orchestrates a session: it opens the
`SessionLogger`, writes `start_of_session`, wires up the `RoiCaptureScheduler`,
starts the wakelock + keep-alive foreground service and the sample timers
(thermal/FPS/power), processes every frame in `_onStreamingData`, and on stop
writes `end_of_session` and tears everything down in `dispose()`. This file is
large and slated for extraction — see the "god-class split" item in
[PERF_AND_ROBUSTNESS_REVIEW.md](PERF_AND_ROBUSTNESS_REVIEW.md) before adding to
it.

## 7. Where to look next

- Output format & analysis: [DATA_GUIDE.md](DATA_GUIDE.md)
- Photo resolution pipeline: [HOW_PHOTO_RESOLUTION_WORKS.md](HOW_PHOTO_RESOLUTION_WORKS.md)
- Full round-by-round rationale: [POLLINATOR_MONITOR.md](POLLINATOR_MONITOR.md)
- Build, test, conventions: [CONTRIBUTING.md](CONTRIBUTING.md)
