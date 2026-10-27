# FaunaPulse fork of the Ultralytics YOLO Flutter plugin

**Who this is for:** a developer or reviewer who needs to know how this copy of
the plugin relates to its upstream, what was changed, and how to audit a newer
upstream release safely. Written in round 169 (perf review E10).

## Provenance

- **Upstream:** [`ultralytics/yolo-flutter-app`](https://github.com/ultralytics/yolo-flutter-app),
  the official Ultralytics YOLO Flutter plugin.
- **Base:** upstream commit `22b2e5d` (upstream label 0.6.4), copied into the
  FaunaPulse repo at `packages/ultralytics_yolo/` and consumed via a `path:`
  dependency. This copy is never published to pub.dev.
- **License:** AGPL-3.0, unchanged (the app inherits it; see the repo root
  `LICENSE`).
- **Scope of the fork:** the Android side (Kotlin) and the plugin's Dart API
  surface. The iOS side is untouched upstream code and is **not maintained or
  tested** (FaunaPulse is Android-only; the app's `ios/` folder is git-ignored).
- The plugin's `README.md` stays upstream-verbatim below a short fork banner,
  on purpose: keeping it byte-close to upstream makes future diffs cleaner.
  This file is the fork's own documentation. Parts of that README (pub.dev
  install instructions, the example app) do not apply to this copy.

## Upstream audit history

| Round | Upstream version | Outcome |
|---|---|---|
| r128 (review Part C) | 0.6.10 | Live pipeline at parity; the C1 inference-cap finding led to the round-129 deadline scheduler. |
| r153 (review Part D) | still 0.6.10 | Nothing on the live path worth porting; D1-D3 landed as fork improvements instead. |
| r160 (review Part E) | 0.6.11 | Glanced: iOS-only change, Android parity stands. |
| r226 (review Part F) | 0.6.15 | Ported the multi-threaded CPU default with a measured choice (2 threads, not upstream's up to 4) and the `output$i` output names; the rest was already in the fork or not applicable. |
| r312 (review Part G) | 0.6.16 | Nothing to port: Android changes are depth-only (stretched depth input), the rest is iOS (Core AI) and docs. Upstream's export docs now use `nms=None` (needs ultralytics >= 8.4.142); noted for any future YOLO26 export. |

Details and rationale: the round named in the first column, in `docs/AGENT_CHANGELOG.md`.
One piece of upstream work-in-progress was adopted early: `OrtQnnModel.kt`
(Snapdragon-NPU `*_qnn.onnx` context binaries) originates from upstream PR
#526; the model picker exposes it since round 150. Note QNN context binaries
are per-Hexagon-generation (`min_arch`; the SD888 test phone is v68 and cannot
run v73/v81 binaries, round 151).

## What the fork changes (Android)

The headline changes, with the round that introduced each (full rationale in
`docs/AGENT_CHANGELOG.md`; current invariants in
`docs/AGENT_CHANGELOG_OVERVIEW.md`):

- **ROI-crop inference:** the detector runs on the user's square Region of
  Interest instead of the whole letterboxed frame (better small-insect
  recall), with the ROI pushed from Dart.
- **Fast ROI capture** from the live analysis frame,
  `ImageUtils.cropRoiFromFrame` (no camera stall; asynchronous on the still
  executor since r154, review D1). Since r290 it (and the `captureFrame`
  preview snapshot) refuses to cut when the camera delivered no frame for
  1.5 s or the preview is detached, and `pauseCamera`/`stop`/`onStop` clear
  the frame cache, so a stopped camera (power button) can never yield copies
  of an old frame.
- **Motion gate**, `MotionGate.kt` (fork-new, r58): native background-diff
  gate that sleeps the detector while the ROI is still, with pre-conversion
  frame drops while idle (r63/64), a motion-only capture mode that never runs
  the model (r95), and a time-lapse frame sampler (r97/r146).
- **Camera2 interop funnel**, `applyInteropOptions()` in `YOLOView.kt` (r82):
  the single place manual focus and the camera-hardware FPS cap are applied
  (the API replaces the whole option set, so a second call site would silently
  erase the other setting). Includes the per-lens AE fps-range menu logging
  (r166, review E4).
- **Preview detach**, `setPreviewEnabled()` (r82): unbinds only the preview
  use case for the app's blackout power-save mode.
- **Zero-shutter-lag only when wanted** (r294): `stillZsl` creation param
  and `setStillZsl`; `startCamera` binds ImageCapture with ZSL only when
  wanted (upstream always used it where supported).
- **Camera lifecycle hold** (r292): CameraX binds to the view's own
  `CameraLifecycle` (a `LifecycleRegistry`) that follows the Activity unless
  Dart holds it (`setCameraHold`), so a recording keeps the camera with the
  screen off; the preview is attached only while the screen shows the app.
- **Inference deadline scheduler** (r129, review C1): the FPS cap advances a
  deadline per allowed start, so cap 10 on a 15 fps camera really runs ~10
  (an elapsed-time check beat against the camera cadence at 7.5).
- **GPU-crash guard** in `LiteRtModel.kt`: 2-strike blocklist that demotes a
  GPU-crashing model to CPU, plus a GPU program cache; engine choice is logged.
- **NCHW `format=litert` model support** (r155, review D2) and the
  **`includeAnnotatedImage: false`** predict opt-out for batch/SAHI analysis
  (r156, review D3).
- **`predictTiledImage`** (r177, review E6): one-call tiled inference for the
  app's batch/SAHI analysis — decode the photo once natively, crop each
  Dart-planned tile rectangle, run the detector sequentially per tile
  (plus an optional whole-photo pass), reply with per-tile box lists.
  Dart API `YOLO.predictTiled`, detect task only, never renders an
  annotated image. Removed the pure-Dart tile pipeline that measured
  83-86% of a SAHI run's wall time.
- **User-triggered engine benchmark**, `benchmarkAccelerators` in
  `YOLOPlugin.kt` (r76): GPU vs CPU thread variants on noise input;
  deliberately never run automatically.
- **CPU thread default** (r226, review F): "0 = automatic" resolves to 2
  threads (`LiteRtModel.automaticCpuThreads`); LiteRT's own default is 1,
  upstream 0.6.12 uses up to 4. Measured on both test phones with
  `integration_test/cpu_threads_check_test.dart`.
- **Native lifecycle overhaul** (r161, review E2): real `YOLO.close()`,
  remove-then-close instance dispose, a plugin-owned cancellable scope instead
  of `GlobalScope`, one owned model-load executor with a generation token, and
  the terminal `YOLOView.release()` called from platform-view dispose
  (`stop()` stays restartable).
- **Engine change applies at once** (r313): `YOLOView.didUpdateWidget` loads
  the same model again when `useGpu` or `cpuThreads` change (upstream reacted to
  a model or task change only, so the GPU switch and the CPU thread count of
  the app's Settings did nothing until the view was rebuilt).
- **Model-load failure signal** (r151): a failed initial load emits
  `onInitialModelLoadFailed` so the app can revert to a runnable model instead
  of hanging calibration. Since r319 a failed in-place model switch is only
  logged (not passed to `FlutterError.reportError`) when the host handles
  `onModelError` and the error is not a programming `Error`, so a damaged model
  chosen by the user no longer writes an app crash file.
- **Embedder memory** (r319): `NativeMemory.kt` plus a JNI `purge()` in
  `native-lib.cpp` (bionic `mallopt` M_PURGE_ALL or M_PURGE, found with
  `dlsym`; `CMakeLists.txt` links libdl) asks the allocator to give freed pages
  back after `embedderClose`, after a replaced embedder and before
  `embedderMemory`. `embedderMemory` (Dart `ImageEmbedder.memory`) reports the
  model size, the estimated need (GPU 4.5 x file, CPU
  `Embedder.CPU_MEMORY_FACTOR` 2.15 x file) and Android's free-memory numbers,
  so the app can decide whether a background load fits. `Embedder`'s
  constructor closes a loaded model when a later check fails.
- **Model and photo files as user input** (r200, r326): bounded metadata reads
  (`MAX_METADATA_BYTES`); every model-file parser in `YOLOFileUtils.kt`, the
  `inspectModel` handler, the model loads in `YOLOView.kt` and
  `YOLOInstanceManager.kt`, the per-frame camera analysis and both photo-predict
  handlers catch `Throwable`, so a
  crafted length or shape (OutOfMemoryError) is reported as a failure instead of
  closing the app; ONNX `metadata_props` keeps only `task` and `names`; photos
  over `MAX_DECODE_PIXELS` (120 MP, read from the file header) are refused before
  decoding; the Dart resolver treats only a bare name as an official model, so a
  file path is always used as it is (no GitHub download for a user's
  `yolo26n.tflite`; one upstream test expectation changed accordingly); unit
  tests run with `returnDefaultValues` (Android stubs return defaults). Since
  r329 a model path that is an `http(s)` link is refused, never downloaded (the
  app downloads and checks every model itself; only the official test models of
  development builds, given by bare name, are still fetched by the plugin; upstream's link-download test
  became a refusal test), and `YOLO.predict(imageUrl)` is removed (no caller;
  it opened any address with no size limit).
- **Upstream CI files:** `packages/ultralytics_yolo/.github/` holds upstream's
  workflows and Dependabot file. GitHub runs workflows only from the
  repository root, so they never run here; the app's own Dependabot file
  watches this plugin's Gradle libraries (r329).
- **Diagnostics:** `FRAMEPERF` per-second pipeline log line, the FPS resume
  guard after gate sleeps (r85, mirrored in the app's Dart side), and
  sensor-timestamp mapping `sensorNanosToEpochMs` (r114).

Most-modified files: `YOLOView.kt`, `YOLOPlugin.kt`, `LiteRtModel.kt`,
`ImageUtils.kt`, `Predictor.kt`, `YOLOInstanceManager.kt`,
`YOLOPlatformView.kt`; fork-new: `MotionGate.kt`; adopted early:
`OrtQnnModel.kt`. On the Dart side: the `YOLOView` controller surface (ROI
push, gate config, lens/focus, fast crop) and `YOLO.predict` options.

## Fork-only invariants (do not regress when porting)

- `setCaptureRequestOptions` is called **only** inside `applyInteropOptions()`.
- `YOLOView.stop()` is restartable; `YOLOView.release()` is the terminal step
  that shuts the view-lifetime executors (r161).
- `YOLOView.stop()` never frees a model while a frame is still inside
  `predict()` (r278): when the camera executor has not ended after its two
  500 ms waits (one picture can take seconds on the main processor), the
  predictors are closed on a `yolo-predictor-close` thread once it ends
  (up to 60 s; after that the model is left open, logged). Closing at once
  crashed the app (SIGSEGV in `LiteRtRunCompiledModelWithOptions`).
- Idle/time-lapse frame drops happen **before** bitmap conversion and above
  the native frame counter (the low camera-FPS readout while the gate sleeps
  is the fix working, not a bug).
- Asset model paths are keyed by `flutter_assets/` on the native side.
- The cross-language keep-in-sync pairs (ROI ÷32 snapping, crop rotation, the
  FPS resume guard) are listed in `docs/ARCHITECTURE.md` §4.

## Re-audit checklist (when a newer upstream release appears)

1. Read the upstream CHANGELOG/diff since the last audited version in the
   table above. Only Android and plugin-Dart changes matter (iOS is not ours).
2. **Never overwrite fork files wholesale** with upstream versions; the files
   listed above will conflict by design. Port one upstream change at a time.
3. After each port, re-check the fork-only invariants above and the
   ARCHITECTURE §4 pairs.
4. Verify: `flutter analyze`, `flutter test test/fauna_pulse`,
   `flutter build apk --debug`, then a device smoke test (live detection,
   photo capture, model switch, gate sleep/wake).
   If upstream changes the CPU or GPU engine setup, re-time it on both phones
   with `integration_test/cpu_threads_check_test.dart` (the header has the
   command; always pass `--no-uninstall`).
5. Record the audit: a round entry in `docs/AGENT_CHANGELOG.md` and a new row
   in this file's audit table.
