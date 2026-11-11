# Architecture

**Who this is for:** a new developer on the project. It explains how a camera
frame becomes a logged track ID, where the native (Kotlin) and Dart sides meet,
and which pieces must be kept in sync. For short file summaries per folder, see
[`lib/fauna_pulse/README.md`](../lib/fauna_pulse/README.md); for current
defaults and rules, see [AGENT_CHANGELOG_OVERVIEW.md](AGENT_CHANGELOG_OVERVIEW.md).

---

## 1. The two sides

The app is a **Flutter (Dart)** application on top of a **modified copy of the
Ultralytics YOLO plugin**, whose speed-critical code is **native Android
(Kotlin)**.

- **App (Dart):** `lib/fauna_pulse/` holds all app code (ROI, tracking, photo
  scheduling, logging, screens). `lib/main.dart` is the entry point.
- **Ultralytics plugin:** `packages/ultralytics_yolo/`, the camera and the
  detector: a Dart widget (`YOLOView`) plus native Kotlin (CameraX capture and
  LiteRT 2.3.2 inference). Forked from upstream commit `22b2e5d` (§5).
- **App native shell:** `android/app/src/main/kotlin/com/ultralytics/yolo/MainActivity.kt`
  holds the full-resolution photo crop and the app's method channels (§3). App
  id: `com.faunapulse.app` (the Kotlin namespace stays `com.ultralytics.yolo`,
  to match the plugin).

## 2. Per-frame data flow

```
 CameraX frame (RGBA)                         [native, camera thread]
   │  packages/.../YOLOView.kt  onFrame()
   ▼
 Motion gate check (if enabled) ── idle? ─────► drop frame (stay asleep)
   │  MotionGate.kt                              heartbeat "gateIdle" → Dart
   ▼
 Detector rate ── too early? ─────────────────► drop frame
   │
   ▼
 ROI crop + resize to model input             ImageUtils.kt / ObjectDetector.kt
   │
   ▼
 LiteRT inference (GPU, or CPU in 16-bit       LiteRtModel.kt (CompiledModel)
 or 32-bit maths)
   │
   ▼
 NMS / postprocess (native C++)                ObjectDetector.kt
   │
   ▼
 Result map over EventChannel  ───────────────► Dart
   │  YOLOPlatformView.sendStreamData
   ▼
 _onStreamingData()                            [Dart]  screens/camera_session/frames.dart
   │   ├─ keep only detections whose centre is in the ROI  (models/roi.dart)
   │   ├─ ByteTrack: assign/continue track IDs             (tracking/byte_track.dart)
   │   ├─ schedule ROI photos                              (capture/roi_capture.dart)
   │   └─ append the frame's detections record (async queue) (logging/session_logger.dart)
   ▼
 session.jsonl  +  roi_frames/*.jpg
```

Key point: **YUV→RGB conversion and ROI cropping happen natively**; do not
write them again in Dart. Frames dropped by the motion gate or the detector
rate never leave the native layer. The camera runs only at the frame rates its
lens offers; detector rate 0 = same as the camera.

On the CPU, detectors and
the identification model use 16-bit maths when the model and the phone allow
it (`CPU_FP16` in `ObjectDetector.kt` and `Embedder.kt`), else 32-bit (always
for files with 8-bit weights); records save this as `cpu_16bit`.

## 3. Native ↔ Dart contract

Two mechanisms cross the boundary:

**Streaming (per frame), the plugin's `EventChannel`:** one result map per
emitted frame: detections (class, confidence, pixel and normalised boxes),
timestamp, frame number, image size, ROI-active flag, motion-gate idle flag and
score, accelerator, CPU 16-bit flag, camera FPS. **By default no image bytes
are sent.** `_onStreamingData` reads it.

**Method channels (request and answer), app-specific (`faunapulse/*`):**

| Channel | Direction | Purpose |
|---|---|---|
| `faunapulse/crop` | Dart → native | `cropRoiJpeg`: take a full-resolution photo and cut the ROI out of it; also gallery saves. |
| `faunapulse/thermal` | Dart → native | `getThermal` (Dart `DeviceThermal.read`): every phone reading in one call: battery temperature, current, voltage and charge counter, the OS heat status, chip temperatures (where the phone allows it), memory, and this process's memory and CPU time ("cores busy" comes from two readings). Also `getFreeStorage` (free and total bytes of the session volume). |
| `faunapulse/keepalive` | Dart → native | Start and stop `RecordingService`, the foreground service that keeps a long session alive (`services/recording_keepalive.dart`). `startAnalysis`/`stopAnalysis`: `AnalysisService` (type `dataSync`, `mediaProcessing` on Android 15+), held with a reference count by `services/analysis_keepalive.dart` while *Find animals in videos/photos* or Identify runs. Also phone state and phone settings. |
| `faunapulse/diagnostics` | Dart → native | Save logcat into the session folder; send a problem report by email. |

The identification run (`IdentificationRun` in
`identification/identification_run.dart`, one per session) lives apart from its
screen, so it runs while the app is in the background. The `YOLOView`
controller sends the ROI, motion-gate settings, lens and focus, and asks for a
fast ROI crop of the live frame.

## 4. Keep-in-sync pairs (edit both or neither)

Some logic exists twice (on both sides of the language boundary, or in several
photo paths). Changing one copy alone causes subtle field bugs
(AGENT_CHANGELOG.md rounds 57, 62, 63):

- **ROI ÷32 snapping.** Three crop paths must all snap the side to a multiple
  of 32 and cap it to the source's short side: the fast live-frame crop
  (`ImageUtils.cropRoiFromFrame`, plugin Kotlin), the high-res photo crop
  (`MainActivity.cropRoiJpeg`, app Kotlin) and the Dart fallback `_cropJpeg`
  (`capture/roi_capture.dart`). The shared maths is in `models/roi.dart`
  (`Roi.snapSideToGrid`, `snapToMultipleOf32`). Never fix snapping in one place
  only.
- **Rotation and mirroring of the saved crop.** Only the small ROI square is
  rotated, not the full frame. The Dart side (`rawRectForUprightRect` and
  `uprightHighResDims` in `roi_capture.dart`) and its Kotlin mirror in
  `MainActivity.kt` must agree. Do **not** bring back full-frame
  `normalizeJpegOrientation`.
- **ROI box geometry uses one scale** (the analysis stream grid): the
  on-screen size readout, resize snapping and inference ROI; the high-res
  source only feeds the separate "saves N×N" label. Read the rules in
  AGENT_CHANGELOG_OVERVIEW.md before touching ROI code.
- **Phone readings of the jobs that run afterwards.** `VideoDetector` (video
  analysis) and `IdentifyPhoneLog` (identification) write the same kinds of
  records (`thermal`, `power`, a speed record, pause and resume). One parser,
  `VideoRunSamples` (`postprocess/video_run_samples.dart`), reads both files
  for the summary's graphs and the two CSV tables. Check a change to a writer
  or the parser against the other file (DATA_GUIDE §8 and §9).
- **Across repositories: the PC export tools.** The model files are made in [fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models),
  whose `docs/AGENT_OVERVIEW.md` lists every shared rule. The main pairs: the
  `.fpack` writer `bioclip_export/fpack.py` and `identification/label_pack.dart`
  (plus the fixtures in `test/fauna_pulse/fixtures/`);
  `fpack.class_probabilities` and `identification/track_fusion.dart`; the naming
  rule (`tool/model_downloads/README.md`) and the file names the export scripts
  write. File size needs no pair: the app takes model files and name lists up
  to 2 GiB, with no separate limit for detectors (`kMaxModelFileBytes` in
  `models/model_file_security.dart`; an `.onnx` file cannot be larger, and the
  native reader of class names and input size maps the whole file into memory,
  which stops at 2 GiB), and the export tools set no limit.

## 5. What the plugin fork changed vs upstream

The plugin is **not** stock, and the upstream docs do not show these changes.
The upstream base, the audit history, every change, the fork-only rules and the
re-audit checklist are in
[`packages/ultralytics_yolo/FAUNAPULSE_FORK.md`](../packages/ultralytics_yolo/FAUNAPULSE_FORK.md).
The main changes:

- **ROI-crop inference:** the detector runs on the ROI square (finds more
  small insects), not on the whole letterboxed frame.
- **Fast ROI photos** from the live analysis frame (no camera stall).
- **Motion gate** (`MotionGate.kt`, opt-in): a native brightness-difference
  gate that lets the detector sleep while the ROI is still.
- **GPU-crash guard** (`LiteRtModel.kt`): a 2-strike blocklist moves a model
  that crashes the GPU compile to the CPU for good; plus a GPU program cache.
- **LiteRT 2.3.2 and 16-bit CPU maths** (§2). The GPU accelerator is the
  separate `litert-gpu` artifact (same version as `litert`); without it every
  model runs on the CPU.
- **Camera2 options and power controls:** manual focus and the camera
  frame-rate cap set in one place (`applyInteropOptions`), the preview detached
  for blackout, and a deadline scheduler for the detector rate.
- **Native lifecycle:** real model and instance disposal, a coroutine scope
  owned by the plugin, and a final `YOLOView.release()`.
- **Detection only:** the example app, the showcase, the upstream-only docs and
  the Kotlin code for segmentation, pose, OBB and classification are deleted;
  the app refuses such model files at import.

## 6. Session lifecycle (Dart)

`screens/camera_session_screen.dart` runs a session; its methods sit in `part`
files under `screens/camera_session/`, one per part of the screen. It receives
every frame in `_onStreamingData` and owns the UI. The logic lives in
`session/`: `frame_processor.dart` (per-frame ROI mapping, tracking, gate-idle
state), `session_recorder.dart` (folder, logger, photos, keep-alive, stop
order), the camera probes, the schedule plan and the time-lapse camera sleep.

A recording opens the `SessionLogger`, writes `start_of_session`, connects the
`RoiCaptureScheduler`, starts the wake lock, the keep-alive service and the
sample timers (heat, FPS, power). On stop it writes `end_of_session` and shuts
down in order. Rule: new session logic goes into `session/` (unit-testable),
not into the screen.

## 7. Where to look next

- Output format and analysis: [DATA_GUIDE.md](DATA_GUIDE.md)
- How photo resolution works: [HOW_PHOTO_RESOLUTION_WORKS.md](HOW_PHOTO_RESOLUTION_WORKS.md)
- Reasons, round by round: [AGENT_CHANGELOG.md](AGENT_CHANGELOG.md)
- Build, test, conventions: [CONTRIBUTING.md](CONTRIBUTING.md)
