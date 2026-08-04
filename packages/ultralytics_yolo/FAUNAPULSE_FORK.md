# FaunaPulse fork of the Ultralytics YOLO Flutter plugin

**Who this is for:** a developer or reviewer who needs to know how this vendored
plugin relates to its upstream, what was changed, and how to audit a newer
upstream release safely. Written in round 169 (perf review E10).

## Provenance

- **Upstream:** [`ultralytics/yolo-flutter-app`](https://github.com/ultralytics/yolo-flutter-app),
  the official Ultralytics YOLO Flutter plugin.
- **Base:** upstream commit `22b2e5d` (upstream label 0.6.4), vendored into the
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
  install instructions, the example app) do not apply to this vendored copy.

## Upstream audit history

| Round | Upstream version | Outcome |
|---|---|---|
| r128 (review Part C) | 0.6.10 | Live pipeline at parity; the C1 inference-cap finding led to the round-129 deadline scheduler. |
| r153 (review Part D) | still 0.6.10 | Nothing on the live path worth porting; D1-D3 landed as fork improvements instead. |
| r160 (review Part E) | 0.6.11 | Glanced: iOS-only change, Android parity stands. |

Details and rationale live in `docs/PERF_AND_ROBUSTNESS_REVIEW.md` Parts C-E.
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
  executor since r154, review D1).
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
- **Native lifecycle overhaul** (r161, review E2): real `YOLO.close()`,
  remove-then-close instance dispose, a plugin-owned cancellable scope instead
  of `GlobalScope`, one owned model-load executor with a generation token, and
  the terminal `YOLOView.release()` called from platform-view dispose
  (`stop()` stays restartable).
- **Model-load failure signal** (r151): a failed initial load emits
  `onInitialModelLoadFailed` so the app can revert to a runnable model instead
  of hanging calibration.
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
5. Record the audit: a note in `docs/PERF_AND_ROBUSTNESS_REVIEW.md`, a round
   entry in `docs/AGENT_CHANGELOG.md`, and a new row in this file's audit
   table.
