# Pollinator Monitor — Building a Field Ecology Tool on the Ultralytics YOLO Flutter Plugin

This document records, transparently and in full, how the **Pollinator Monitor**
Android application was built on top of the open-source
[`ultralytics/yolo-flutter-app`](https://github.com/ultralytics/ultralytics-yolo-flutter)
plugin, using **Claude Code** (Anthropic's agentic coding assistant) driven by a
field ecologist with statistical/R/Python experience but no prior app-development
background.

> **Path note (read before older entries):** This log predates the move to the
> standalone `pollinator-monitor` repository (see section 10b). Entries written before
> that move refer to the **old layout**, where the app lived inside the plugin's
> `example/` folder. In the current repository the app is at the **root**, so when an
> older entry mentions a path like `example/lib/pollinator/…` or `example/android/…`,
> it now maps to `lib/pollinator/…` / `android/…` at the repository root. The modified
> plugin itself now lives under `packages/ultralytics_yolo/`.
>
> **Platform note:** This repository is **Android-only**. iOS support is intentionally
> *not* committed here (a separate iOS repository is planned for a later phase), so the
> `ios/` folders are git-ignored even though they may exist locally.

Its purpose is twofold:

1. **Scientific transparency** — so reviewers and readers of the accompanying
   paper can see exactly what was changed relative to the upstream repository,
   and why.
2. **A worked example** — a reproducible account of how ecologists can combine a
   large language model coding assistant with an existing open-source repository
   to build the custom field tools they need.

> Code-level changes can additionally be tracked with `git diff` against the
> upstream commit; this file is the human-readable narrative and rationale.

---

## 1. What the app does

Pollinator Monitor measures **flower-visitation rate** — how often insects visit
a flower and for how long — which is a core quantity in pollination ecology. It
runs entirely **on-device** (no internet/streaming needed in the field):

- Live camera detection of flower-visiting insects using an on-device YOLO model.
- A draggable **square region of interest (ROI)** placed over the target flower.
- **Object tracking** that assigns each insect a stable `track id`, turning a
  stream of detections into countable, timeable *visits*.
- **Time-lapse JPEG crops** of the ROI saved while a visit is active.
- An **append-only JSON log** (crash/battery-loss safe) of all detections,
  tracks, ROI geometry and session metadata.
- An end-of-session **visit-timeline dashboard**.

Data is transferred off the phone by USB at the end of the day.

---

## 2. Base repository (upstream)

The starting point was a clone of the Ultralytics YOLO Flutter plugin, which
provides:

- A Flutter/Dart front end with a `YOLOView` camera widget.
- Native **Kotlin** (Android) / Swift (iOS) inference using LiteRT, with CameraX
  on Android and automatic GPU→CPU fallback.
- Bundled nano YOLO models.

The upstream plugin had **no object tracking, no ROI, no session logging, no
time-lapse capture, and no scientific dashboard** — those are the contributions
here. The project is **Android-first**; an iOS build is left for future work.

---

## 3. How the tool was built (method)

Development was **iterative and test-driven on a real Android phone**. The
ecologist described requirements in plain language (captured in `CLAUDE.md`),
Claude Code implemented them, and the app was repeatedly built, installed and
tested on-device. Bugs and unexpected behaviours observed in the field-style
testing were fed back in natural language and fixed in the next iteration. Every
non-trivial term is defined in plain language in the source comments, because the
maintainer is a scientist rather than a professional developer.

Two design rules were followed throughout:

- **Reuse, don't reinvent.** The native camera pipeline, YUV→RGB conversion,
  inference, and non-max-suppression were left untouched and reused.
- **Port to lower-level code only when it pays off.** The performance-critical
  paths (model inference, NMS) are already native/JNI; image preprocessing is a
  single hardware-assisted blit. No additional C++ was warranted.

---

## 4. Changes relative to upstream

### 4a. New application code (all under `/lib/pollinator/`)
A self-contained module added to the app:

| Area | Files | Purpose |
|------|-------|---------|
| Models | `models/roi.dart`, `models/track.dart`, `models/session_config.dart` | Square ROI math (resolution-independent), track/detection types, all user settings (+ persistence) |
| Tracking | `tracking/byte_track.dart` | A lightweight, pure-Dart ByteTrack-style multi-object tracker producing stable track ids |
| Logging | `logging/session_logger.dart`, `logging/device_thermal.dart` | Append-only JSONL writer; phone-temperature reader |
| Capture | `capture/roi_capture.dart` | Time-lapse scheduler + background-isolate JPEG crop of the ROI |
| Widgets | `widgets/roi_overlay.dart`, `widgets/track_box_painter.dart`, `widgets/preview_transform.dart` | Draggable ROI, track-id boxes, and the camera "cover-fit" coordinate mapping |
| Screens | `screens/home_screen.dart`, `screens/camera_session_screen.dart`, `screens/settings_sheet.dart`, `screens/session_summary_screen.dart` | Entry/permissions, live orchestration, settings, dashboard |
| Tests | `test/pollinator/*` | Unit tests for ROI math, the tracker, and the logger |

`/lib/main.dart` was repointed to the new home screen.

### 4b. Plugin (native + Dart) modifications — the ROI-crop inference
To make detection **truly operate only on the ROI** (and to give small insects
the model's full input resolution), the inference path was modified to crop to
the ROI *before* running the model, rather than running on the whole frame and
filtering afterwards:

- `android/.../Predictor.kt` — added an `InferenceRoi` type and an
  `inferenceRoi` field on `BasePredictor`.
- `android/.../ImageUtils.kt` — added `prepareBitmapForModelRoi(...)`, which
  rotates and **crops the ROI square** into the model-input bitmap in a single
  `Canvas.drawBitmap` (the same cost as the existing full-frame preprocessing —
  no extra allocation). Because the ROI is square and the model input is square,
  this is a clean zoom with zero letterbox padding.
- `android/.../ObjectDetector.kt` — when a ROI is set, preprocesses with the crop
  and uses the ROI's pixel size as the reference frame, so detections come back
  **normalized to the ROI** and reuse the existing letterbox-inverse unchanged.
- `android/.../YOLOView.kt` — stores the ROI, applies it to the predictor each
  frame, exposes `setInferenceRoi(...)`, and continues to stream the **full**
  frame dimensions (plus a `roiActive` flag) so the Flutter overlay still maps
  onto the whole preview.
- `android/.../YOLOPlatformView.kt` — method-channel handler for `setInferenceRoi`.
- `lib/widgets/yolo_controller.dart` — Dart `setInferenceRoi({cx, cy, side})`.

The Dart side maps the ROI-relative detections back onto the full frame for the
tracker and overlay, and logs box coordinates relative to the ROI.

### 4c. Native temperature method channel
- `.../MainActivity.kt` — a `pollinator/thermal` method channel reading
  battery temperature (°C) and the OS thermal-throttling status, so heat build-up
  during long real-time sessions can be displayed and logged.

### 4d. Accelerator (GPU/CPU) reporting
- `android/.../YOLOView.kt` — streams the **actual** inference processor
  (`accelerator` = "GPU"/"CPU"/"NPU") to Flutter each frame. The plugin already
  picks GPU-first with CPU fallback; this just surfaces what was chosen. It is
  shown on the preview ("Engine: …") and recorded in `start_of_session`, which
  also now records the **full camera resolution** (the still size the ROI is
  cropped from). This made it visible that the bundled int8 model runs on CPU —
  see §7.

### 4e. Build, dependencies, branding
- `pubspec.yaml` — added `image`, `fl_chart` (later replaced by a custom
  painter), `battery_plus`, `device_info_plus`, `screen_brightness`,
  `permission_handler`, `shared_preferences`, `wakelock_plus`.
- `/android/app/build.gradle` — pinned Kotlin `jvmTarget = 17` to match
  Java (the build runs under JDK 21), fixing an "Inconsistent JVM-target" error.
- `/android/app/src/main/AndroidManifest.xml` — app label
  "Pollinator Monitor".
- Custom **flower-and-bee launcher icon** (all densities + adaptive icon),
  replacing the Ultralytics logo. Generated with a small PIL script.

---

## 5. Iteration log (the journey)

Each round below was prompted by hands-on testing on the phone.

1. **Initial build blocker.** First on-device build failed with an "Inconsistent
   JVM-target" Gradle error (Java 17 vs Kotlin 21 under JDK 21). Fixed by pinning
   Kotlin's `jvmTarget` to 17. The app then installed (after clearing a signing
   conflict with the pre-installed upstream example).
2. **ROI not square on screen.** The ROI looked stretched. Cause: the native
   preview uses CameraX `FILL_CENTER` ("cover") fit, but the overlay was
   stretching normalized coordinates onto the full screen. Fixed with a shared
   `PreviewTransform` that reproduces the cover fit, so the ROI and track boxes
   render as true squares and align with the live image.
3. **Unrealistic ROI resolution.** The readout showed a small pixel size because
   it used the downscaled *analysis* frame. Fixed by probing the full-resolution
   still once at startup and snapping the saved-crop resolution to a multiple of
   32 (model-friendly), with a "measuring…" state to avoid placeholder flicker.
4. **Default ROI too large.** The default covered 60% of frame width, pushing the
   resize handle off-screen under the cover crop. Reduced to 45%.
5. **Preview lag.** The app updated the whole widget tree (including the native
   camera view) ~30×/s. Fixed by moving per-frame updates to `ValueNotifier`s +
   `RepaintBoundary` (so only the thin overlay repaints), throttling the
   recording disk-flush, and adding a configurable **detector-rate cap**
   (default 15/s) — the main lever for heat and battery on a long session.
6. **Heat.** Added the native temperature channel (4c) to display and log battery
   temperature and thermal-throttle status.
7. **Dashboard.** Replaced the initial bar chart with a **Gantt/phenology-style
   visit timeline**: one lane per insect, bars from first to last sighting, so
   overlapping visits are visible at a glance.
8. **True ROI inference.** Confirmed (by reading the native code) that the whole
   frame was being fed to the model and only filtered afterwards, then
   implemented the native ROI-crop pipeline (4b) so the model sees only the ROI
   at full resolution.
9. **UI clarity round.** From field testing: a horizontal status bar overflowed
   (Flutter's yellow/black overflow stripes) → moved to a vertical top-left
   stack; a full-screen red "recording" border implied full-frame detection →
   removed it, the ROI border now turns red while recording, with a "● REC mm:ss"
   banner and a Preview/Recording label; everything outside the ROI is dimmed;
   the startup probe shows a clear "Calibrating…" banner; the dashboard became
   opt-in (headline numbers shown instantly from the first/last log lines, graphs
   computed only on a button press) and gained temperature- and FPS-over-time
   line charts alongside the visit timeline, which now shrinks lanes to handle
   hundreds of tracks.
10. **Data verification.** A recorded session was pulled off the phone over USB
    and inspected: valid JSONL, `ended_normally: true`, ROI-relative `box_in_roi`
    in 0..1 (with only sub-percent edge overruns — confirming detections are
    confined to the ROI), saved crops square and ÷32, and the unique-track count
    matching the timeline. The cheap end-of-session count was corrected to mean
    *total distinct insects over the session* (each confirmed id counted once),
    not just those active at the moment of stopping.
11. **Performance — GPU vs CPU.** The pulled log showed ~5.5 FPS. Surfacing the
    actual accelerator (4d) revealed inference was running on **CPU**: the bundled
    `yolo26n_int8.tflite` is int8-quantised, which the LiteRT GPU backend cannot
    compile, so it falls back to CPU. *(This initial conclusion was later corrected:
    the int8 model does compile on this device's GPU once the program cache is
    healthy — see rounds 13–15 and §6. Precision is not what decides the engine.)*
12. **ROI ergonomics & summary tidy-up.** Field feedback drove four fixes: (a) the
    final summary no longer prints any camera/ROI resolution — the ROI can change
    mid-session, so a single resolution there was misleading; (b) the ROI can no
    longer be dragged or grown off the visible preview — both the direct-manipulation
    overlay and the size slider now clamp the square to the on-screen ("cover"-cropped)
    region (`PreviewTransform.visibleNormalizedRect` + `Roi.clampToVisible`); (c) the
    awkward corner resize handle was replaced with **two-finger pinch** (spread to
    enlarge, pinch to shrink) plus a tappable size chip that opens a **slider for an
    exact ROI side in pixels** (snapped to multiples of 32, updating live as you
    slide); (d) the "frame rate is identical across nano/small/medium/large" puzzle
    was traced to model bundling — **only the nano model ships in the app**, so picking
    a larger size silently kept running nano. The model dropdown now marks nano as
    "(bundled)" and the others as "(add file)", with an inline warning explaining that
    until the chosen size's `.tflite` is added the frame rate will not change.
13. **Custom insect detectors + a GPU-cache crash fix.** The scientist's own
    YOLO11 detectors (fp16 and fp32 `.tflite` files) were bundled under
    `/assets/models/custom/` and added to the model dropdown (custom models
    listed first, labelled by precision), so they can be selected without rebuilding
    the selection logic. While deploying this, the app started **hard-crashing at
    launch** inside the native LiteRT GPU library. Root cause: LiteRT serializes the
    compiled GPU "program cache" to disk to speed up later launches; if the app is
    killed *during* that first compile (which had just happened during an install
    cycle), the half-written cache makes the next launch crash in native code — a
    crash Kotlin cannot catch, because it kills the whole process, so the existing
    GPU→CPU fallback never ran. Fixed in `LiteRtModel.kt` with a **self-healing
    crash guard**: a marker file is written just before the GPU compile and deleted
    on success; if it is still present at the next startup the previous compile must
    have crashed, so the app wipes the (now isolated) GPU cache directory and runs on
    CPU for that one launch, retrying the GPU with a clean cache afterwards. This also
    confirmed that on this Adreno device the **int8 model does compile and run on the
    GPU** once the cache is healthy (see §6).

14. **Full-frame preview, runtime models, manual focus, in-summary photo review.**
    A larger round driven by field testing:
    - **ROI could not reach full sensor resolution** (capped ~1792 px on a 3000-wide
      sensor) and **could be dragged past the bottom edge**. Both came from the
      native preview using `FILL_CENTER` (crop-to-fill), which hid part of the
      sensor. Switched the preview to `FIT_CENTER` (show the whole frame with thin
      letterbox bars) and flipped `PreviewTransform` from "cover" to "contain" to
      match. The ROI now reaches the full sensor square (e.g. 3000×3000) and is
      clamped to the fully-visible frame, so it can never leave the preview.
      Detection still runs only on the ROI crop — never the full frame.
    - **A custom model crashed the app** (`yolo11n_float16_MaxS_platform.tflite`).
      It was a native GPU-compile crash (uncatchable in Kotlin). The crash guard
      from round 13 was upgraded to a **per-model GPU blocklist**: a model that
      fails to compile on the GPU **twice** is routed to CPU from then on, while
      every other model keeps the GPU. The 2-strike rule deliberately tolerates a
      single benign interruption (the OS reclaiming memory, or a force-stop during
      the first compile) so a healthy model is never silently demoted to CPU; a
      genuinely GPU-incompatible export fails twice and then sticks to CPU.
    - **Runtime custom-model loading.** Models no longer have to be bundled at
      build time. The settings sheet scans the app's models folder on every open
      and offers an **Import…** button (system file picker) so the user can pull a
      `.tflite` from anywhere on the phone (e.g. Downloads). Imported models are
      copied into `Android/data/<pkg>/files/models/` (also reachable over USB).
    - **Clearer model list.** Each entry shows its **full file name** plus the
      precision (int8 / fp16 / fp32, parsed from the name) and **input resolution**
      (read from embedded metadata), and the app **warns when two models share a
      name**.
    - **Manual focus.** Added a native focus-distance control (Camera2 interop:
      `LENS_FOCUS_DISTANCE` with autofocus off) exposed as a **Far↔Near slider**
      with an "Auto" reset, so the user can lock focus on the flower in the ROI.
      Hidden automatically on fixed-focus lenses.
    - **Recording is blocked until calibration finishes** (the record button greys
      out and the label says "Calibrating…"), since the ROI pixel size logged at
      session start isn't known until the one-time full-res probe completes.
    - **ROI size sheet** no longer clips its helper text (scroll-controlled, keyboard
      inset, SafeArea) and gained a **type-in field** alongside the slider.
    - **In-summary photo review.** The end-of-session dashboard can now sample a
      user-chosen number (1–10) of saved ROI photos spread across the session and
      show them in a **swipeable viewer with the recorded detection boxes overlaid**,
      for a quick visual sanity check of the results.

15. **Bug fixes & the GPU/CPU diagnosis confirmed.** From the next field test:
    - **Photos never appeared in the summary.** The photo review (round 14) looked
      for the JPEGs in the session folder, but captures are written to its
      `roi_frames/` subfolder — so every file lookup failed silently. Fixed the path;
      sampled photos now display.
    - **"Calibrating…" could hang forever** with a model that stalls the camera
      pipeline (the one-time full-res probe never returned). The probe now **retries
      up to 6× with a 4 s timeout each**, then falls back to the analysis-frame size
      (shown with a `~`), so the banner always clears and the app stays usable.
    - **Long model names overflowed the dropdown.** The open menu now **wraps names
      onto multiple lines**; the collapsed button stays a single ellipsised line.
    - **Bundled YOLO26 nano now shows its precision** (`int8`) and input size, like
      the custom models.
    - **GPU/CPU diagnosis confirmed from `logcat`** (see §6 table): the int8 YOLO26
      compiles on the GPU, a YOLO11 fp16 export returns `Failed to compile model` and
      runs on CPU, and the `MaxS_platform` variant was found on the on-device GPU
      blocklist — exactly as the crash-guard intends. This disproved the earlier
      "int8 ⇒ CPU" assumption (round 11).

16. **Frame-rate investigation (instrumented).** The app felt slow (~2–6 FPS) vs
    the Ultralytics HUB app's 20–30 FPS on the same phone, so a per-stage timing
    readout was added — on-screen and to `logcat` — splitting the pipeline into
    camera delivery, YUV→RGB conversion, preprocessing, inference and NMS. The
    measurements (see §6a) showed the model and camera are *not* the limit: the
    GPU inference is ~20 ms, the camera delivers ~23 FPS, and YUV→RGB is ~2 ms on
    the fast (RGBA) path. The cost is the **CPU preprocessing** (crop + pixel→float
    at the model's 640 input), which is ~25 ms when the device is idle between
    frames but **balloons to 100–186 ms under sustained flat-out load as the SoC
    thermally throttles** — so running uncapped actually *lowered* the steady FPS
    over time. Conclusion: this phone with a 640-input nano model is
    preprocessing/thermally limited to ~6–8 FPS sustained; the real lever is a
    **smaller model input** (e.g. 320/416), which cuts both preprocessing and
    inference. A moderate inference cap is kept as the default because it runs
    cooler and steadier than uncapped.

17. **FPS roughly doubled (throttle fix + release build), and a faster capture
    path.** Two further causes were found and fixed:
    - **Inference-cap throttle bug:** the rate cap timed itself from the *end* of
      each inference, so the configured interval effectively included the whole
      inference time (a "15/s" cap yielded ~6/s). Fixed with a dedicated gate
      timestamp set at inference *start* (`shouldRunInference`).
    - **Debug/profile vs release:** debug *and* profile builds are `debuggable`,
      so ART runs the native code interpreted ("verify"), inflating the CPU
      preprocessing. A real non-debuggable **release** build (here debug-signed so
      it installs) plus a cooled device brought the **default-capped** rate from
      ~6 to **~12 FPS** at 640 int8 on the test phone (camera delivering 30, GPU
      inference ~20 ms, preprocess ~20 ms when cool). So debug-mode and thermal
      state were as important as the cap. (Profile mode alone did *not* help,
      because it is still `debuggable`.)
    - Three **explicitly-labelled FPS readouts** were added — *Camera* (analysis
      delivery), *Detector* (preprocess+inference+NMS) and *Pipeline* (app-side:
      tracking + overlay; photo saving runs async in the background) — so the
      three are never conflated.
    - **Faster ROI photo capture:** each saved photo previously decoded the whole
      ~12 MP still in pure Dart (the `image` package) and `_busy`-serialised, so a
      10 s / 1 s-step visit yielded ~1 image instead of ~10. Now a native
      `BitmapRegionDecoder` method channel decodes **only the ROI rectangle**
      (no whole-image decode), with the Dart path kept as a fallback, so captures
      keep up with the step interval. Fair-comparison note: the reference model is
      kept as the **int8 YOLO26 nano**; a fp16 single-class model isn't a like-for
      -like speed comparison, so single-class speedups await an int8 export.

18. **Photo capture stopped stalling the camera.** Field testing showed that
    *recording* tanked the frame rate (camera → 1–2 FPS, `pre` 51→443 ms) — and
    crucially **the file write was not the cause**: each photo called
    `capturePhoto` (a full-resolution `ImageCapture.takePicture`), which makes the
    camera HAL reconfigure/stall the analysis stream. Efficient time-lapse setups
    (e.g. a Raspberry Pi) never trigger a separate full-res capture — they grab
    from the already-running stream. So a native **`captureRoiFromFrame`** was
    added: it crops the ROI straight from the most-recent in-memory analysis frame
    (no `takePicture`), and is now the **default** photo path — recording no longer
    drops the FPS, and 1 s-step captures keep up (≈10 images per 10 s visit). The
    analysis resolution was raised to 1280×960 so these live-frame crops stay
    reasonably sharp (~576 px ROI); a **"Full-resolution ROI photos"** toggle
    keeps the old full-sensor stills for users who want maximum quality and accept
    the per-save FPS dip. (A memory-buffer/queue was considered and rejected: the
    bottleneck was the capture call, not the write, so buffering wouldn't help.)
    Also: three FPS readouts are labelled explicitly (Camera / Detector /
    Pipeline — pipeline is ≤ detector by definition, as it's the downstream
    stage), and the summary's photo viewer gained a **"View all"** option with a
    saved-count line and a height cap so the page scrolls to the graphs.

---

19. **Saved ROI resolution now matches the readout, and the capture count is
    correct.** Two issues from pulling a session: (a) fast-mode crops were saved
    at the analysis-frame size (~416 px) while the preview showed the full-still
    size (~1344 px). Fixed by deriving the on-screen ROI resolution from the
    *actual* crop source (analysis frame in fast mode, full still in full-res
    mode) and aligning the native crop's 32-snap to the Dart rounding, so saved
    size == displayed size. (b) A 60 s visit produced 20 photos instead of 10:
    the capture window was deleted on a single-frame "lost" blip and re-created
    when the same (never-reused) id returned, restarting a fresh 10 s window. Now
    a window is only forgotten after the track has been gone longer than the
    capture duration, so a brief blip can't double the photos. The summary also
    gained a **"View all"** photo option + a "showing N of M" count to verify the
    exact number against the step/duration settings.

20. **Higher-resolution fast crops (no FPS cost).** The live ROI crops were
    capped at the analysis stream's short side (~960 → ~448 px ROI). Enabling
    CameraX's `PREFER_HIGHER_RESOLUTION_OVER_CAPTURE_RATE` and requesting a larger
    analysis size let the test phone deliver **1600×1200** (its real-time max) at
    the **same ~30 delivered / ~13 inferred FPS** (only `toBitmap` rose ~0.8→4 ms,
    inference unchanged as it still downscales to the model input). Fast ROI crops
    now reach **~1184×1184** with no stall. A "Stream: W×H" readout was added so
    the analysis cap is visible. True full-sensor (~2976) still needs the full-res
    still toggle (per-capture stall) — real-time streams are HAL-downscaled and
    cannot deliver full sensor per frame, unlike a dedicated ISP (e.g. Luxonis OAK).

21. **Saved size exactly matches the readout, and the stream resolution is a
    setting.** The readout rounded the ROI up (e.g. 1216) while the crop got
    clamped to the frame's short side (1200) — different, and 1200 isn't a 32-
    multiple. Fixed by capping both the display and the native crops to the
    largest 32-multiple that fits the short side (e.g. 1184 for a 1200 short
    side), so display == saved and always ÷32. The analysis-stream resolution is
    now a **user setting** (640×480 … 2560×1920); its short side caps the
    no-stall ROI crop, so capable phones can push fast crops higher (the device
    delivers the nearest it supports, shown in the "Stream" readout).

22. **Stream-resolution changes now actually apply.** Changing the stream
    resolution in settings had no effect: the Dart `YOLOView` only sent
    `streamingConfig` at creation, never in `didUpdateWidget`, so the native
    camera was never re-bound and the ROI stayed at the old size. Fixed by
    re-applying the streaming config on change (native rebinds only when the
    analysis resolution truly differs, so ROI dragging causes no spurious
    restart). After Apply, the "Stream" line and the ROI cap now update to the
    new resolution (e.g. a 640×480 stream caps the ROI at 480). Presets are
    standard 4:3 sizes; the device still picks the nearest it supports.

23. **Stream-resolution change applies live + HAL-queried options.** The
    setting previously only took effect after an app restart (the in-place
    streaming-config update didn't reliably rebind the camera). Fixed by keying
    the camera view on the stream resolution, so changing it recreates/rebinds
    the camera immediately (the key ignores ROI/threshold/model changes, so those
    don't restart it). The settings dropdown now lists the **camera's actual
    supported analysis sizes**, read from the HAL
    (`SCALER_STREAM_CONFIGURATION_MAP.getOutputSizes`, filtered to 4:3, largest
    first, labelled with megapixels), instead of fixed presets — so no
    unsupported/unrealistic options are offered. Falls back to standard presets
    if the query is unavailable.

24. **Realistic stream-resolution menu.** `getOutputSizes(YUV)` also returns
    big *still-only* sizes (e.g. 4000×3000) the HAL won't stream for real-time
    analysis — selecting one just fell back to the device's real max. The list is
    now capped to realistically streamable sizes (≤ ~2 MP, the practical
    ImageAnalysis ceiling) and labelled short-side-first (e.g. 1200×1600), since
    the short side is what caps the square ROI.

25. **FPS restored + OAK-style zero-shutter-lag capture.** Root-caused (by
    diffing against the clean upstream example) why the app ran ~2x slower even at
    a matched 480x640 stream: (a) a default inference cap of 15/s (upstream is
    uncapped ~30), and (b) the inflated default analysis stream (1920x1440 →
    ~1600x1200) plus `PREFER_HIGHER_RESOLUTION_OVER_CAPTURE_RATE`. No bug / no
    harmful over-engineering — both were our settings. Fixes: default inference
    **uncapped** (cap stays an optional heat lever), default stream back to
    **640x480** (≈ model input), and `PREFER_HIGHER` applied only when the user
    requests a >720p stream. Measured result on the test phone: detector FPS rose
    from ~12 to **~21** (uncapped), approaching the upstream rate; the small
    remaining gap is the inherent cost of streaming detections to Dart for the
    tracker + custom track-id overlay (upstream has no tracker and draws boxes
    natively).
    Also implemented the Android equivalent of the Luxonis-OAK Insect Detect
    pipeline (continuous high-res buffer): the bound `ImageCapture` now uses
    **`CAPTURE_MODE_ZERO_SHUTTER_LAG`** when the device supports it
    (`CameraInfo.isZslSupported`), with fallback to `MINIMIZE_LATENCY` then to
    no-capture — keeping a ring buffer of full-res frames so on-detection ROI
    stills are grabbed near-instantly with a much smaller per-save FPS dip. ZSL
    engaged on the test phone. Out of scope (assessed): dual physical cameras and
    a custom Linux OS — not worth the deployability cost for citizen science.

26. **Stop heating on the summary screen + typed HAL-bounded stream size.**
    The phone kept heating after stopping a session because the camera + detector
    kept running while the session-summary screen was on top. Now the camera is
    **paused** (`controller.pause()` → unbinds ImageAnalysis, stopping inference)
    when the summary opens and **resumed** on return — no AI drain while reviewing
    results. Also replaced the stream-resolution dropdown with a **typed short-side
    field**: enter a value (snapped to a multiple of 32, clamped 160…device-max),
    where the device max is the largest 4:3 short side the **HAL** reports
    (`SCALER_STREAM_CONFIGURATION_MAP.getOutputSizes`, ÷32). The 4:3 long side is
    derived automatically; a "Camera supports: …" line lists the real HAL short
    sides for reference. (Note: the recording FPS dip during a photo window is the
    cost of the high-res capture itself; ZSL shrinks it, and a longer photo step
    or fast-crop mode reduces it further.)

27. **Pause AI in settings, browse past sessions, HAL dropdown, sensor info.**
    Four field-feedback items: (a) the camera/detector now **pauses while the
    settings sheet is open** (it was heating the phone behind the sheet) and
    resumes on close — same pause/resume used for the summary. (b) The welcome
    screen now **lists previously recorded sessions** (scanned from the sessions
    folder, newest first) and opens any of them in the existing summary view
    (stats + graphs + photos); "New session" still starts recording. (c) Reverted
    the stream-resolution control from a typed ÷32 field back to a **dropdown of
    the camera's real HAL sizes** (verbatim, no rounding — fixes the 240→256
    surprise), labelled "short × long". (d) Moved the **full-sensor resolution
    info off the preview into Settings**, shown in the "Full-resolution ROI
    photos" description as "up to W×H on this phone" (read from the device).

28. **One-time setup reminder + focus mode logged (single-tap record kept).** The
    manual-focus plumbing existed (round 14: native `setManualFocus`/`setAutoFocus`
    via Camera2 `LENS_FOCUS_DISTANCE`, a Far↔Near slider with an "Auto" reset), but
    focus defaulted to Auto and nothing told the user to lock it. A first attempt
    gated the record button behind a focus-choice checklist, but in field testing
    that meant **tapping ● several times before recording actually began** — too
    intrusive. Replaced with a **one-time info dialog** (`_SessionInfoDialog` in
    `camera_session_screen.dart`), shown via an `initState` post-frame callback when
    the camera screen opens. It reminds the user to **fix the target flower in place
    (e.g. tie it to a pole)** so it can't sway in the wind, to **centre the yellow
    ROI on the target flower(s)/inflorescence(s)**, and — the key point — to **tap
    the focus button (just right of the record button) and lock focus on the flower
    before recording**, noting that focus then stays fixed for the whole session and
    that autofocus can drift onto the background in wind. A **"Don't show again"**
    checkbox persists to SharedPreferences (key `pollinator_hide_session_info`), so
    a returning user goes straight to the preview. **Settings → Session → "Show
    setup tips at session start"** is a `SwitchListTile` bound to that flag
    (`_setShowSetupTips`/`_loadSetupTipsPref`) so the reminder can be turned back
    on (e.g. when handing the phone to a collaborator), with the switch giving
    clear on/off feedback; the pref key `kHideSessionInfoPrefKey` lives in
    `session_config.dart` so both screens share it. The **record button starts in
    a single tap** again. The focus state in effect at start is still logged in
    `session.jsonl` start metadata as **`focus_mode`** (`manual`/`auto`/`fixed`,
    derived from `_focusModeForLog()`), plus **`focus_value`** (0..1, far→near) when
    locked manually. No native changes — reuses the existing focus controller methods.

29. **Per-photo info panel in the summary's photo review.** Each sampled ROI photo
    in the summary's swipeable viewer now shows a small metadata panel underneath
    (`_infoPanel`/`_infoRow` in `session_summary_screen.dart`): **Resolution**
    (short × wide px), the **Track IDs** visible in that image, the **capture time**
    as `hh:mm:ss:milliseconds` local time (`_formatStamp`), and the **file name**.
    All of it is read straight from `session.jsonl` while parsing for the viewer —
    no image decoding. `_loadPhotos` now also tracks the ROI pixel size carried
    forward from the `start_of_session`/`roi_update` records (so each photo gets the
    size that applied when it was saved), collects the unique `track_id`s per JPEG,
    and keeps each photo's first `time_ms` as its capture time; `_PhotoSample` gained
    `name`, `trackIds`, `captureMs`, `width`, `height` fields.

30. **Configurable graph sampling + dynamic time axis + clearer settings tabs.**
    The FPS and temperature graphs in the summary used to share a single 10 s timer
    that logged both into one `thermal` record. They are now **sampled on two
    independent, user-configurable timers**, so neither slows the detection
    pipeline:
    - **Frame-rate sample — default 5 s.** The FPS value is already maintained
      every frame, so logging it is essentially free; written as its own `fps`
      record via the new `SessionLogger.logFps`.
    - **Temperature sample — default 10 s.** Reading the phone temperature is a
      platform call, so it's kept coarser (heat changes slowly); still a `thermal`
      record (now temperature-only).
    Both intervals are new `SessionConfig` fields (`fpsSampleSeconds`,
    `thermalSampleSeconds`, persisted + logged in `start_of_session`), exposed as
    sliders in a **new "Summary graphs" settings tab**. The settings tabs were
    relabelled for clarity: **"Session" → "Session setup"**, and the new tab is
    **"Summary graphs"** (tabs are now Session setup / AI Pipeline / Camera /
    Summary graphs). The summary parser reads the new `fps` records and still reads
    FPS embedded in old `thermal` records (backward compatible). Finally, the graphs'
    **X (time) axis now adapts to session length** via a shared `_timeAxisLabel`
    helper used by both the FPS/temperature series and the Gantt timeline: seconds
    for sessions under 90 s, minutes up to 90 min, then hours — so a 1-minute and a
    multi-hour session both read cleanly (previously every axis was labelled in raw
    seconds).

31. **Model input resolution for any model, higher detector-rate ceiling, always-
    visible settings tabs.** Three field-feedback items:
    - **Input resolution now shown for every model.** The AI Pipeline tab had a
      readout, but it only knew the size from Ultralytics' optional `imgsz`
      metadata, so most models showed "unknown". Added
      `YOLOFileUtils.inputImageSize()` (native) which reads the **input tensor
      shape directly from the TFLite graph** (always present; handles NHWC and
      NCHW); `inspectModel` fills `imgsz` from it when metadata lacks it. **The
      first attempt still read "unknown"** because it loaded the file via
      `YOLOUtils.loadModelFile`, which doesn't find Flutter-bundled assets: they
      live at `flutter_assets/<declared path>` inside the APK (the bare
      `assets/...` key fails `AssetManager.openFd`), and the bundled nano was
      inspected by its bare `yolo26n` id (no file on disk). Fixed with a dedicated
      `openModelBuffer()` that tries the **`flutter_assets/` prefix** and absolute
      imported-file paths, plus inspecting the nano via its real asset
      (`assets/models/yolo26n_int8.tflite`). **Verified on device** (debug build,
      installed over adb): the dropdown now shows 640px (nano), 416px (the flower
      model), 320px (the yolo11n variants); "(add file)" sizes correctly stay
      blank as their files aren't present.
    - **Detector-rate cap raised 30 → 120/s** (steps of 5) in the Camera tab.
      Confirmed there is **no 30 fps cap in the pipeline** — `inferenceFrequency`
      just sets a time gate (`1e9/freq` ns) in `YOLOView`; the real limit is camera
      frame delivery (often ~30/s, higher on some phones) and model speed. The help
      text now explains the cap is a *ceiling, not a guarantee*.
    - **Settings tabs always visible.** The tab strip was `isScrollable`, so a
      fourth tab could sit off the right edge unnoticed. Switched to a **fixed
      (non-scrolling) `TabBar`** with short labels + icons (Setup / AI / Camera /
      Graphs) so all four share the width and are always on screen.

32. **Custom models with a non-"images" input tensor now work (broader model
    compatibility).** A custom model (`yolo11n_float16_MaxS_platform.tflite`, 320px)
    loaded but every frame threw `LiteRtException: TensorBuffer host memory buffer
    size is smaller than the given data size, 1228800 vs 4915200` (caught as "Error
    during prediction") → 0 FPS and an endless "Calibrating…". Root cause: `LiteRtModel`
    read the input shape via `getInputTensorType(inputName = "images")`; this export's
    input tensor isn't named "images", so the lookup threw, `dims` came back empty,
    and `ObjectDetector` fell back to a **640** input — which overflowed the model's
    real **320** input buffer (640²·3·4 = 4,915,200 B written into a 320²·3·4 =
    1,228,800 B buffer). Fixed with `YOLOFileUtils.inputTensorShapeFromPath()`, used
    as a fallback in `LiteRtModel.prepareModel` to read the input shape **by index**
    straight from the TFLite graph (no dependency on the tensor name). **Verified on
    device**: the same model now logs `Input dims via TFLite graph … [1, 320, 320, 3]`
    and runs at ~10 FPS on CPU with calibration completing — no crash, no hang. This
    broadens compatibility to older/renamed YOLO exports and other tflite detectors
    whose input isn't named "images". (Caveat: still assumes an **NHWC** float input
    and a YOLO-style output `[1, features, anchors]`; NCHW inputs and DETR-style
    outputs (RF-DETR/D-FINE) would need a dedicated preprocessor/decoder.) Separately,
    a genuinely GPU-incompatible export can still hard-crash once or twice on first
    load before the round-13/14 2-strike GPU blocklist routes it to CPU — that native
    GPU-compile crash is uncatchable from Kotlin.

33. **In-app error reporting (user-facing errors + shareable diagnostic report).**
    Detector failures used to be silent (the native exception only hit logcat). Now:
    - **Native** `YOLOView` emits a throttled (≤ once / 3 s) typed `error` event from
      its prediction catch block; the Dart `YOLOViewController` exposes it as
      `errorEvents`. `MainActivity` gained a `pollinator/diagnostics` channel with
      `captureLogcat` (runs `logcat -d --pid <self>` — a non-rooted app sees only its
      own logs, exactly what we want).
    - **Dart** `ErrorReporter` (`logging/error_reporter.dart`) builds a single
      plain-text report — app version, device/Android, the trigger + error text,
      session settings JSON, the tail of the active/last `session.jsonl`, and the
      captured logcat — and saves it to `error_reports/report_<ts>.txt` under the
      app's external files dir (browsable over USB, `adb pull`-able). It reports the
      file **size in human units** and can **share** it (share_plus → email/Drive/…).
      Developer contact is the `developerEmail` constant; `githubIssuesUrl` is a
      placeholder for when a public repo exists.
    - **UI**: the camera screen shows a dismissible red **error banner** when the
      detector errors (native event) *or* stalls (watchdog: camera delivering > 1 FPS
      but detector stuck at 0 for > 8 s). Its "Report" button opens a dialog with the
      **selectable/copyable** error text and a "Create report" action that saves the
      report, then shows its size with a "Send…" option. The home screen has an
      always-available **"Report a problem"** button (works after a crash+restart,
      since the lingering logcat is still captured).
    - **Verified on device**: "Report a problem" produced `report_…U+200B.txt`
      (`adb pull` confirmed, 34 KB–109 KB depending on log volume) containing all
      sections; the "Report saved (NN KB)" dialog and the OS share sheet (Gmail etc.)
      both work.

34. **Required user description (with markdown preview) + removed the hardcoded
    email.** Two follow-ups to round 33:
    - **Problem-description editor.** Both report entry points (the camera error
      banner's "Report" and the home screen's "Report a problem") now open a new
      full-screen editor — `screens/problem_description_screen.dart` — *before* a
      report is built. The user must type a description of what went wrong in
      their own words (the "Continue" button stays disabled until the text is
      non-empty; "Cancel" aborts and writes nothing). The editor has an
      **Edit / Preview** toggle: Edit is a multi-line text box, Preview renders the
      text as formatted **markdown** ("markdown" = a plain-text way to add
      formatting, e.g. `**bold**` or `- ` lists). The typed text is threaded into
      `ErrorReporter.build(userDescription:)` and written as the **first** section
      of the report — `-- What the user reported --` — verbatim (markdown kept
      as-is, since the report is a `.txt`).
    - **New dependency:** `flutter_markdown_plus` (the maintained drop-in fork of
      the Flutter-team-discontinued `flutter_markdown`) for the live preview.
    - **Email removed.** The hardcoded developer email was deleted from
      `ErrorReporter` (the `developerEmail` constant), the report footer, the
      share-sheet text, and both "Report saved" dialogs. The footer now gives
      provider-neutral guidance ("send via email or any messaging app of your
      choice"); users still send the `.txt` to whatever app they like via the
      unchanged OS share sheet (Gmail, Drive, WhatsApp, Signal, Telegram, …). The
      `githubIssuesUrl` placeholder is retained for when a public repo exists.
    - **Verified**: `flutter analyze` clean on all changed files + the new screen;
      `flutter build apk --debug` succeeded and installed on the Xiaomi
      (`2b2dc560`); the app launches with no `E/flutter`/`MissingPlugin` errors
      (markdown package loads); `grep` confirms the email no longer appears in any
      shipped code. (The on-device tap-through of the editor + preview is left for
      manual confirmation.)

35. **Settings sliders replaced with typed number boxes (sliders were unusable
    in the swipeable tabs).** In the session-settings sheet, the Confidence and
    IoU sliders on the AI tab (and in fact every slider across all four tabs)
    could not be dragged: the settings tabs live in a horizontally-swipeable
    `TabBarView`, so a horizontal drag on a slider was stolen by the tab
    page-swipe — the whole tab slid to the neighbour instead of the value
    moving. Rather than fight the gesture arbitration, **every numeric control is
    now a typed number box** — the new `NumericSettingField`
    (`/lib/pollinator/widgets/numeric_setting_field.dart`), a small
    labelled `TextField` with a unit suffix and a help line. It has no horizontal
    drag (so it can't conflict with the tab swipe), lets the user enter an exact
    value, and **clamps** the typed number into each setting's documented range.
    The box commits the clamped value on every valid keystroke and only
    re-formats the visible text on focus-loss, so typing (e.g. `0.3`) is never
    rewritten mid-entry. Controls converted: Setup → Photo step, Photo duration;
    AI → Confidence threshold, IoU threshold, Occlusion tolerance, Match overlap,
    Low-score association; Camera → Detector rate cap (still `0` = Max); Graphs →
    Frame-rate sample, Temperature sample. **No pipeline change** — the existing
    `SessionConfig`/`copyWith` plumbing already fed every one of these into the
    detector, tracker, capture timer and JSONL `start_of_session` metadata
    (verified: `setThresholds` on Apply, `inferenceFrequency`, `occlusionFramesFor`,
    `stepMs`/`durationMs`, the two sample timers); only the input widget changed.
    Replaced the iOS-style `ThresholdSliderRow` (`CupertinoSlider`) usage here for
    the same gesture reason. `flutter analyze` clean on the new widget and the
    settings sheet. (On-device tap-through left for manual confirmation.)

36. **Detection confidence shown on the live boxes and in the summary gallery.**
    The detector's confidence for each box (0..1, two decimals) is now displayed
    everywhere a box appears, with **no extra runtime cost** — the value was
    already on the `Track` (`track.dart`, straight from the model output) and
    already written into every `detection` record in `session.jsonl`
    (`'confidence': t.confidence`), so this is purely a display change.
    - **Live overlay** (`track_box_painter.dart`): the box label went from
      `#7 bee` to `#7 bee  Conf.: 0.83`.
    - **Summary gallery** (`session_summary_screen.dart`), both for a just-stopped
      session and when reopening an old one: `_loadPhotos` now collects a per-photo
      `track id → confidence` map (`byFileConf`) while parsing the log; each photo's
      drawn box label gains the confidence (`#7 bee  0.83`), and the per-photo info
      panel gained a **"Confidence"** row listing `#id Conf.: 0.xy` for every track
      visible in that image. `_PhotoSample` gained a `trackConf` field. Falls back
      to `—`/`n/a` if a record lacks the value (older logs).
    - `flutter analyze` clean on both changed files. (On-device confirmation of the
      on-screen text left for manual check.)

37. **Recording clock now scales to days for very long sessions.** The REC-banner
    elapsed clock already promoted `mm:ss` → `hh:mm:ss` past one hour, but a
    multi-day session (sessions can be set in hours) would have kept counting hours
    past 24 (e.g. `36:20:05`). `_formatElapsed` (`camera_session_screen.dart`) now
    adds a day tier so the unit always matches the duration: **mm:ss** under an
    hour, **hh:mm:ss** for 1–24 h, **dd:hh:mm:ss** at 24 h+. Coarser units only
    appear once relevant, so short sessions stay compact. Pure display formatting,
    called once per second from the banner (not in the detection path) — **no FPS
    impact**. `flutter analyze` clean.

38. **Opt-out overlay toggles + photo-capture flash cue (Setup tab).** The live
    overlays (track-id boxes and the top-left status strip) repaint on the Flutter
    UI thread as the per-frame notifiers fire; detection/tracking run separately
    (native), so the overlays don't change the *detector* loop rate, but on a
    shared mobile GPU/CPU the per-frame UI repaints add some load. Gave the user
    control via three new `SessionConfig` bools (persisted + in `start_of_session`),
    all shown as on/off `SwitchListTile`s under a new **"On-screen display"** group
    in the **Setup** tab:
    - **`showBoxes`** (default on) — the blue `#id … Conf.: 0.xy` boxes. When off,
      the `TrackBoxPainter` layer is omitted from the `Stack` entirely, so there is
      **no per-frame box repaint at all** (tracking still runs and is still logged).
    - **`showOverlayInfo`** (default on) — the whole top-left status strip (FPS,
      model, engine, stream, ROI size, temperature, track count). Off = only the
      ROI box, the REC indicator and the controls remain, removing those periodic
      chip rebuilds. (The AI-tab `showFps` toggle is a finer control nested inside
      this strip.)
    - **`flashOnCapture`** (default on) — the ROI border blinks bright green
      (`0xFF00FF6A`, thickened to 4 px) for ~180 ms each time a photo is saved, as
      a visual cue that capture is happening. Implemented with a `ValueNotifier<bool>`
      (`_captureFlashVN`) + a 180 ms `Timer`, triggered from `_recordFrame` right
      where the capture is dispatched. Only the `RoiOverlay` border rebuilds (via a
      `ValueListenableBuilder`), at the photo cadence (≈ once per step) — **never per
      frame**, so it can't affect the FPS. `RoiOverlay` gained a `borderWidth` param
      for the thicken-on-flash.
    `flutter analyze` clean on the module; files `dart format`ted.

39. **Energy consumption — measured power (W), session energy (Wh), and aligned
    time cues across all graphs.** The summary (for a just-finished session and
    when re-opening a past one) now reports how much energy a recording used, so
    energy cost can be compared across plant types/treatments like other
    camera-trap projects.
    - **Direct power measurement.** The native `pollinator/thermal` channel
      (`MainActivity.readThermal`) was extended to also read, from the framework
      `BatteryManager` (no root needed): instantaneous **current**
      (`BATTERY_PROPERTY_CURRENT_NOW`, µA), **voltage** (`EXTRA_VOLTAGE`, mV),
      **remaining charge** (`BATTERY_PROPERTY_CHARGE_COUNTER`, µAh), and a
      **charging** flag (`EXTRA_STATUS`). `ThermalReading` (`device_thermal.dart`)
      gained these fields plus a computed `powerW` = |current A| × voltage V; its
      `toJson` now also emits the derived `power_w`. (Units/sign of `CURRENT_NOW`
      vary by OEM, so the magnitude is used and 0/sentinel values are treated as
      "unavailable".)
    - **Plain-language units.** Power **now** is reported in **watts (W)**; the
      **total** over a session is **watt-hours (Wh)** — not "watts per hour",
      which is a common misnomer (W is already a rate). These are defined in the
      code comments and in on-screen captions.
    - **New `power` JSONL record + its own sample timer.** A new
      `SessionLogger.logPower` writes `power` records (`power_w`,
      `battery_current_ua`, `battery_voltage_mv`, `charge_counter_uah`,
      `is_charging`) on a dedicated timer in `camera_session_screen.dart`, at a
      new user-configurable interval **`powerSampleSeconds`** (default 10 s),
      added to `SessionConfig` and exposed as a "Power sample" number box in the
      **Summary graphs** settings tab (alongside Frame-rate and Temperature
      samples). Start/stop now take a **fresh** battery reading so the
      `start_of_session`/`end_of_session` `thermal` blocks carry an accurate
      baseline/closing charge counter.
    - **Two new graphs + two headline numbers.** The summary adds a **Power draw
      (W)** line and a **Cumulative energy (Wh)** line (the running integral of
      the power samples, trapezoidal). Two headline stats are read cheaply from
      the start/end records: **Battery used** (% drop, e.g. "8% (from 74% to
      66%)") and **Energy used (battery drain)** (`ΔchargeAh × avg voltage`, the
      reliable ground-truth, which should roughly match the cumulative-energy
      graph's final value). A warning is shown if the phone was **plugged in**
      during the session (estimate invalid). Old sessions without `power` records
      degrade gracefully ("Not enough samples." / "unknown").
    - **Aligned vertical time cues.** `_SeriesPainter` now draws **dim vertical
      gridlines** at the **same 4 time fractions** (5 lines) as the Gantt visit
      timeline, sharing the same 44 px left gutter and `startMs..endMs` mapping —
      so the temperature, FPS, power and energy graphs line up on the X (time)
      axis with the Gantt, not just at matching tick labels.
    - `flutter analyze` clean on the module; files `dart format`ted. (On-device
      verification — `power` records present, plausible ~2–6 W, graphs aligned —
      left for the next device run.)

40. **Energy graphs read ≈0 on Samsung (current-unit bug) + human-readable axes.**
    Field test on a Samsung (unplugged, ~7 min) showed the power and energy lines
    sitting at ≈0 W / ≈0 Wh. Root cause confirmed via `adb shell dumpsys battery`
    on both phones: the **charge counter (µAh) and voltage (mV) are reported
    correctly** (Samsung 5000 mAh / 4.26 V; Xiaomi 4326 mAh / 8.85 V), but
    Samsung — like many devices — reports the instantaneous **`CURRENT_NOW` in
    milliamps, not the microamps Android specifies**, so the native `power_w`
    (which divided by 1e6) came out ~1000× too small (≈0).
    - **Robust fix (in `session_summary_screen.dart`, `_buildEnergySeries`).** The
      summary no longer trusts the logged `power_w`. It now recomputes power from
      the **charge-counter drop** (spec-reliable µAh units) and uses that
      start↔end drop as ground truth to **auto-calibrate the current readings'
      scale**: if treating them as µA makes them ≳30× too small versus the
      charge-counter truth, they are taken as mA (×1000). Per-sample power then
      prefers (scale-corrected) current × voltage, falls back to the
      charge-counter delta between samples, then to the logged value; a light
      3-point moving average smooths coarse-counter jitter. Cumulative energy (Wh)
      is taken straight from the (monotonic, unit-safe) charge-counter drop. The
      headline "Energy used (battery drain)" was already charge-counter-based, so
      it was unaffected. The raw `battery_current_ua`/`battery_voltage_mv`/
      `charge_counter_uah` are still logged, so this is a pure post-processing fix
      that also repairs the **already-recorded** Samsung session. A new
      `_PowerSample` holds the raw fields during parsing.
    - **Human-readable axes (all line graphs + the Gantt).** Replaced the old
      fixed min/mid/max Y ticks and the fixed-fraction X ticks (which produced
      awkward values like "2.5m") with a **"nice number" (Heckbert) axis**:
      `_niceNum`, `_timeTicks`, `_niceValueAxis`, `_decimalsFor`. The **time (X)
      axis** now picks the unit dynamically (seconds / minutes / hours / days —
      the largest unit giving ≥3 whole units, so never "0.5 h") and places ticks
      at round multiples (e.g. every 2 min, every 5 h), shared by the series
      graphs **and** the Gantt so they stay aligned. The **value (Y) axis** now
      rounds the data range to readable bounds with a round step and ~5 gridlines
      (e.g. 0/10/20/30/40/50 °C), with decimals chosen to suit small ranges (so
      fractional-Wh energy still reads clearly). Auto-scales to the data's actual
      spread (temperature, FPS, W, Wh).
    - `flutter analyze` clean; `dart format`ted. Rebuilt and installed on **both**
      the Samsung (`RF8T403A3AT`) and Xiaomi (`2b2dc560`); both launch cleanly.
      (On-device confirmation of non-zero W/Wh and the new axis labels during a
      live unplugged session left for the next field run.)

41. **Realistic energy values: voltage-doubling fix + power-integral energy; plus
    why temperature/FPS differ across phones.** Two ~10–12 min no-detection
    sessions were pulled (`adb pull`) from a Samsung (SM-M127F / Galaxy M12) and a
    Xiaomi (2107113SG / Mi 11 Lite 5G) and compared field-by-field.
    - **Xiaomi power & energy were ~2× too high (voltage bug).** The Xiaomi
      reports its battery voltage as a **2-cell series value (~8.85 V)** while the
      charge counter is the pack capacity — so `charge × voltage` implied an
      impossible 38 Wh battery and doubled both power and energy. Added
      `_singleCellVoltageV` (`session_summary_screen.dart`): any voltage above
      ~4.6 V (a single Li-ion cell's ceiling) is halved back to a per-cell figure.
      Result on the pulled logs: Xiaomi power 9→6 W became a realistic **4.8→3 W**,
      energy 1.5 Wh became **0.61 Wh**; Samsung's correct 4.2 V is unchanged
      (~2 W, 0.43 Wh). The native raw `battery_voltage_mv` is still logged verbatim
      (transparency); the correction is applied only when computing the graphs.
    - **Energy now integrates the power curve, not the charge counter.** The charge
      counter is very coarse on some phones (the Xiaomi reported only **3 distinct
      values in 10 min**), which made a staircase Wh graph and an unreliable total.
      Cumulative energy is now the trapezoidal **integral of the (fine,
      per-second) corrected power**, which is smooth and — cross-checked against the
      charge drop and the battery-% drop — just as accurate. The total is shown as
      a caption under the graph (`_energyTotalWh`), e.g. "≈ 0.61 Wh • battery level
      dropped 1% …". The coarse charge-counter headline stat was removed (battery %
      is kept as a rough independent check; Android's % itself can lag).
    - **Temperature & FPS differences are real, not bugs.** The Samsung sat flat
      (FPS 2.6–2.7, battery 32.5–32.9 °C) while the Xiaomi fell 16→5 FPS and rose
      34→45 °C. This is internally consistent: the budget Samsung is CPU-bound at a
      low, steady rate that never pushes the SoC hard enough to heat the battery or
      trigger throttling, so everything stays flat; the faster Xiaomi (also doing
      USB tethering + more background apps) starts hot, heats up, and **thermally
      throttles** down. The app reports **battery temperature** (the only sensor a
      non-rooted app can read), which is a real but *damped, lagging* proxy for
      chip heat — so a slow phone genuinely shows little variation. (A future
      option: `PowerManager.getThermalHeadroom()`, an API-30+ 0–1 "closeness to
      throttling" signal, would show the throttle directly — noted, not yet added.)
    - `flutter analyze` clean; `dart format`ted. Rebuilt and reinstalled on both
      the Samsung (`RF8T403A3AT`) and Xiaomi (`2b2dc560`); both launch cleanly. The
      corrected algorithm was validated offline against the two pulled logs (values
      above); on-device confirmation of the new on-screen numbers left for the next
      field run.

42. **Robust current-unit detection, energy reported as numbers (Wh graph
    dropped), and a direct throttling signal (thermal headroom).** A second pair of
    unplugged sessions exposed that round-40/41's mA fix was too fragile, plus two
    requested UX changes.
    - **mA-vs-µA now detected by magnitude, not the charge counter.** On a fresh
      Samsung session the charge counter **never moved** (stuck at 5,000,000 µAh
      over 6 min), so the charge-counter calibration produced nothing and Samsung's
      milliamp readings were again treated as microamps → power back to ≈0.002 W.
      Replaced it with a magnitude test (`_buildEnergySeries`): a recording phone
      draws ~0.1–3 A, i.e. 100k–3M as µA but only 100–3k as mA (a clean ~10× gap),
      so a **median |reading| below 10,000 ⇒ milliamps** (×1000). This needs no
      charge counter, so it works on short sessions and stuck counters. Validated
      on the pulled logs: Samsung **avg 2.13 W** (1.78–2.34), 0.21 Wh; Xiaomi (µA,
      voltage halved per round 41) **avg 3.49 W** (3.30–4.49), 0.37 Wh — a ~1.6×
      between-phone difference (heavier Xiaomi load + USB tethering), not the
      "orders of magnitude" the unit bug had caused.
    - **Energy as numbers; cumulative-Wh graph removed.** Per request, the Wh graph
      was dropped (a rising line added little). The W graph stays, and below it a
      line now reports **average power (with min/max)** and **total energy (Wh)**
      for the session, plus the battery-% drop as a rough check —
      `_powerAvg/_powerMin/_powerMax/_energyTotalWh`. Energy is still the integral
      of the (corrected) power, so it's available even when the charge counter is
      stuck.
    - **Thermal headroom graph (direct throttling signal).** Added
      `PowerManager.getThermalHeadroom(0)` (API 30+) to the native thermal read —
      a normalized **0 = cool → 1 = throttling-threshold** figure from the SoC/skin
      sensors that reacts far faster than battery temperature and is comparable
      across phones, so it **directly shows when a phone throttles and its FPS
      drops**. Surfaced as `ThermalReading.thermalHeadroom`, logged in the existing
      `thermal` records (no new timer), and drawn as a new summary graph
      ("Thermal headroom (0 = cool → 1 = throttling)") that is **omitted when the
      device returns NaN** (unsupported). This explains the earlier puzzle: the
      Xiaomi (HAL ready) should show headroom rising into throttling as FPS falls,
      while the slow Samsung (no skin-throttle sensor exposed; likely NaN → no
      graph) simply never gets hot enough to throttle — consistent with its flat
      battery temperature and flat ~2.6 FPS.
    - `flutter analyze` clean; `dart format`ted. Native changed → full rebuild;
      reinstalled on both the Samsung (`RF8T403A3AT`) and Xiaomi (`2b2dc560`);
      both launch cleanly. Energy/power validated offline against the two pulled
      logs (values above); on-device confirmation of the headroom graph + on-screen
      numbers left for the next field run.

43. **Session duration on the home list + a full settings recap in the summary.**
    Two requested recall features, both read straight from each session's
    `session.jsonl` (no new data needed):
    - **Start, end and duration in "Previous sessions" (`home_screen.dart`).** Each
      list row now shows, on two compact lines under the session name: the calendar
      **date**, then the **start → end** wall-clock times (`hh:mm:ss`) on the left and
      a colour-coded **duration pill** on the right. All three come from the
      start↔end records read with the same **cheap head/tail trick** the summary
      uses (`_readSessionSpan` — first 8 KB for the `start_of_session` `time_ms`,
      last 16 KB for the `end_of_session` `time_ms`), so listing many sessions never
      scans a full (possibly huge) log; the row's date/time now reflect the **real
      session start** (from the log) rather than the file's modified time, and the
      list is sorted by it. Duration formatting (`_formatDuration`) is **dynamic and
      unit-matched**, mirroring the live REC clock: **mm:ss** under an hour,
      **hh:mm:ss** for 1–24 h, **dd:hh:mm:ss** at a day or more (sessions can run for
      days). The pill (`_durationPill`) is **amber with a timer icon** for a clean
      run; a session with no end record (crash / force-stop) instead shows the end
      time as "—" and an **orange "incomplete" pill with a warning icon**.
    - **Full configuration logged at start.** `logStart` (`camera_session_screen.dart`)
      now also writes the entire user configuration as one self-describing
      `config` block (`_config.toJson()`), alongside the individual keys it already
      logged. This makes the start record a complete, future-proof record of what
      the user chose — any setting later added to `SessionConfig` appears
      automatically with no schema change here.
    - **"Session settings" card in the summary (`session_summary_screen.dart`).**
      A new grouped section lists **every** parameter the run used — Model &
      detection (model, task, GPU requested, engine actually used, confidence/IoU
      thresholds, inference-rate cap), Photos & capture (output folder, step
      interval, capture duration, full-res toggle, camera/stream/analysis
      resolutions, initial ROI, focus mode), Session & sampling (max length, screen
      dimming, FPS/temperature/power sample intervals), and Tracking/ByteTrack
      (occlusion tolerance, high/low match thresholds, high-score threshold, track
      buffer, min hits to confirm). Values are read **config-first, top-level
      fallback** (`_setting`) so sessions recorded *before* the `config` block still
      show everything that was logged individually; rows whose value is missing are
      simply omitted. The card is built from the already-parsed start record (the
      log's first line) — no extra file work.
    - `flutter analyze` clean on all three files; `flutter test test/pollinator`
      all pass. Pure Dart/UI change (no native), so a normal `flutter run` rebuild
      picks it up; on-device confirmation left for the next run.

44. **Live status-overlay polish (`camera_session_screen.dart`, `model_catalog.dart`).**
    A batch of small readability fixes to the top-left status strip shown on the
    live preview (and during recording), all reading data that already existed:
    - **Model input resolution added — in brackets after the model name.** The
      `Model:` line now reads e.g. `Model: yolo26n_int8.tflite (640×640 px)`. The
      square input size is read from the model's metadata via a new public helper
      `ModelCatalog.inputSizeOf(modelPath)` — which reuses the existing private
      `_inspect`/`_imgszFrom` and the same official-id→bundled-asset mapping
      `build()` uses (so the bare `yolo26n` id resolves to
      `assets/models/yolo26n_int8.tflite`), the very path that already handles the
      `flutter_assets/` quirk. The screen probes it in `initState` and again after
      a mid-session model switch (`_openSettings`). The bracketed value is
      **tri-state and never blank**: `(input: reading…)` until the probe returns,
      then `(640×640 px)`, or a clear `(input: cannot read)` when the metadata
      lacks it.
    - **Long model names wrap instead of clipping.** Flutter only breaks lines at
      allowed points, and a space-less custom filename (e.g.
      `flower_yolo11n_416_epochs200_float16.tflite`) has none, so it could overflow
      the chip. A new `_wrappable()` helper inserts invisible zero-width spaces
      (`U+200B`) after `_ - . /` separators, giving the text engine break
      opportunities so the name flows onto multiple lines — the visible text is
      unchanged. (The overlay column is already width-bounded, so ordinary names
      with spaces already wrapped; this covers the unbroken-filename case.)
    - **Engine moved above Model.** `Engine: GPU/CPU/NPU` now sits just under the
      `pre · inf · post ms` line, immediately before `Model:` (was after it).
    - **`px` added to Stream.** `Stream: W×H` → `Stream: W×H px`, matching the
      `ROI:` line's format.
    - **No-blank-line policy for Engine/Model/Stream.** These previously vanished
      until their value arrived; they now always render with a waiting placeholder
      (`Engine: detecting…`, `Model: loading…`, `Stream: measuring…`, like the
      existing `ROI: measuring…`), so the overlay layout doesn't jump as it loads.
    - **Temperature labelled.** The bare `31.2°C` chip is now `Battery temp.: 31.2°C`
      — prefixed only when the reading is a real battery temperature
      (`ThermalReading.batteryTempC != null`); a bare thermal-status string is left
      unprefixed. (The value genuinely is the battery sensor, so the label is
      accurate, not just "phone".)
    - **Total tracks added.** Under `Current tracks: N` there is now
      `Total tracks: N` — the running count of unique confirmed tracks
      (`_tracker.totalConfirmed`, the same figure as the summary's "Unique insects"
      and the log's `unique_track_count`). Both lines share one per-frame
      `_tracksVN` builder, so the total stays live with no new notifier.
    - Resulting order: FPS trio → perf ms → **Engine** → **Model (+ input px)** →
      **Stream (px)** → ROI → **Battery temp.** → Current tracks → **Total tracks**.
    - `flutter analyze` clean on both files; `flutter test test/pollinator` all
      pass. Pure Dart/UI (no native), so a normal `flutter run` rebuild picks it
      up; on-device visual confirmation left for the next run.

45. **Graph summary stats (avg/median/min/max) + auto-compute setting
    (`session_summary_screen.dart`, `session_config.dart`, `settings_sheet.dart`).**
    - **Stats under every metric graph.** The temperature and detector-FPS graphs
      now print an `Average … (median …); min …, max …` line underneath — the same
      style the power graph already had — and the power line gained a **median**
      too. A small reusable `_seriesStats()` computes mean/median/min/max for any
      `(ms, value)` series, and `_statsText()` renders the grey caption. **Median**
      is the middle of the sorted samples (robust to a few spikes, unlike the
      mean) and needs **no new dependency** — just a sort.
    - **Works for past sessions, no schema change.** These are derived live from
      the per-sample `fps` / `thermal` / `power` records **already in every
      `session.jsonl`** (exactly how the power stats were already computed), so
      they show for any old session re-opened from the home screen without writing
      new aggregate fields into the log. (The raw samples already *are* the data in
      the file; pre-aggregating them into the log would only help brand-new
      sessions and is redundant for the on-screen summary, so it was intentionally
      not done — can be added later purely for downstream R/Python convenience if
      wanted.)
    - **"Compute graphs automatically" setting (Graphs tab).** New
      `SessionConfig.autoComputeGraphs` (default **true**), a switch at the top of
      the existing Graphs settings tab. When on, the summary builds its graphs as
      soon as it opens (no button press); when off, the old **"Generate graphs"**
      button remains as a manual, on-demand fallback (handy for very long sessions
      whose full-log parse takes a moment). The summary reads the **current global
      preference** via `SessionConfig.load()` in a new `_init()` (so it applies
      both at end-of-session and when re-opening a past session) and auto-calls
      `_loadGraphs()` when enabled. The flag is also captured in the start record's
      `config` block automatically (logged via `_config.toJson()`).
    - `flutter analyze` clean on all three files; `flutter test test/pollinator`
      all pass. Pure Dart/UI (no native); a normal `flutter run` rebuild picks it
      up. On-device confirmation of the auto-compute toggle + new stats lines left
      for the next run.

46. **Blackout power-save mode (real implementation) + removal of the dead dim
    settings (`camera_session_screen.dart`, `session_config.dart`,
    `session_summary_screen.dart`).**
    - **The old "Screen dimming" setting was inert.** Investigation prompted by the
      summary showing `Screen dimming: On, after 5 min`: the `dimEnabled` /
      `dimImmediately` / `dimAfterMinutes` fields existed **only** in `SessionConfig`
      (and were printed by the new settings list) — they were **never exposed in any
      tab and never read by any runtime code**, i.e. a stub from the original
      `CLAUDE.md` spec that did nothing. The `screen_brightness` dependency was
      already in `pubspec.yaml` but **unused**. Those three fields (+ their toJson/
      fromJson/copyWith and the summary's "Screen dimming" row) were **removed**.
    - **Real blackout mode, built to the user's choices** (manual button; always
      fully black; also lower hardware brightness). A new `dark_mode` button in the
      preview controls calls `_enterBlackout()`, which shows an opaque black
      `Positioned.fill` cover on top of everything, enables a **wakelock** so the OS
      can't sleep the screen and pause the camera, and parks the display.
      **Tapping anywhere** (`HitTestBehavior.opaque` on the cover) calls
      `_exitBlackout()`, restoring brightness and the normal UI.
    - **Gentle dim-down so the hint is readable (refined after testing).** First
      cut dropped the brightness to 0 *immediately*, which made the white "Screen
      off to save power — tap to wake" hint unreadable at once. Now the screen is
      **held at normal brightness while the hint fades out over `_blackoutFade`
      (6 s, `Curves.easeIn`)**, and **only then** is the app window brightness
      dropped to 0 via `ScreenBrightness().setApplicationScreenBrightness(0.0)` —
      window-level, so **no `WRITE_SETTINGS` permission** (restored on wake with
      `resetApplicationScreenBrightness`). One `_blackoutFade` constant keeps the
      fade animation and the brightness-drop timer in sync; waking before the timer
      fires just restores brightness harmlessly.
    - **Pipeline keeps running; UI work is genuinely paused.** While blacked out the
      `YOLOView` stays mounted (inference continues) and photo capture / logging /
      FPS-thermal-power timers are all independent of the UI, so they carry on. The
      per-frame overlays — **RoiMask, detection boxes, the draggable ROI overlay and
      the status strip** — are skipped with `if (!_blackout …)`, so there's **no
      per-frame painting** behind the cover (not just hidden). On wake the overlays
      rebuild honouring the user's existing on-screen display toggles (boxes / info
      panel / capture-flash).
    - **Power button:** documented that Android does **not** deliver `KEYCODE_POWER`
      to apps, so it can't be repurposed to blackout-instead-of-lock without
      device-owner/root; the on-screen button + tap-to-wake is the robust
      equivalent (and avoids the real screen-off that would pause the camera).
    - `dart format` + `flutter analyze` clean (used the non-deprecated
      `setApplicationScreenBrightness`/`resetApplicationScreenBrightness`);
      `flutter test test/pollinator` all pass. Dart-only (the `screen_brightness`
      plugin was already a dependency), so a normal `flutter run` rebuild picks it
      up; on-device confirmation of the blackout button + brightness drop left for
      the next run.

47. **Keep long sessions alive on Android (foreground service + battery-opt
    exemption + wakelock hardening) and hide the system bars in blackout
    (`MainActivity.kt`, new `RecordingService.kt`, `AndroidManifest.xml`, new
    `services/recording_keepalive.dart`, `camera_session_screen.dart`).** Prompted
    by the question: over a multi-hour/day field run, won't Android sleep or kill
    the app? Investigation found the **only** thing protecting a session was the
    screen-on wakelock (`FLAG_KEEP_SCREEN_ON` via `wakelock_plus`) — **no foreground
    service, no battery-optimization handling** (manifest had only INTERNET+CAMERA).
    The user chose the strongest option; implemented:
    - **Foreground service (native).** New `RecordingService` runs a `camera`-typed
      foreground service with an ongoing **low-importance notification** ("Pollinator
      Monitor — recording") and a `PARTIAL_WAKE_LOCK`, started in `_startRecording`
      and stopped in `_stopRecording` via a new `pollinator/keepalive` method channel
      (mirrors the existing thermal/crop/diagnostics channels). This is the canonical
      "don't reclaim this process" signal. `camera` type chosen over `dataSync`
      (Android-15 caps dataSync at 6 h/day — fatal for long runs) and over
      `specialUse` (documented as fallback); it's started from the foreground with
      CAMERA granted, satisfying the Android-14 typed-FGS start rule.
    - **Battery-optimization exemption.** `pollinator/keepalive` also exposes
      `isIgnoringBatteryOptimizations` / `requestIgnoreBatteryOptimizations`. On the
      first record press, if not already exempt, a **one-time dialog**
      (`_ensureUnrestricted`, remembered via a SharedPreferences flag) explains why
      it matters for unattended runs and opens the system "run unrestricted" screen
      — the key fix for OEM/MIUI killers (the Xiaomi test device). Recording proceeds
      regardless of the choice.
    - **Wakelock lifecycle hardening.** The screen State now
      `with WidgetsBindingObserver` re-asserts `WakelockPlus.enable()` on
      `AppLifecycleState.resumed` while recording, so a long session reliably keeps
      the screen on (and the app foreground).
    - **Manifest:** added `WAKE_LOCK`, `FOREGROUND_SERVICE`,
      `FOREGROUND_SERVICE_CAMERA`, `POST_NOTIFICATIONS`,
      `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, and the `<service>` (camera type). The
      notification permission is requested (Android 13+) in `_startRecording`.
    - **Blackout now hides the OS system bars too.** `_enterBlackout` calls
      `SystemChrome.setEnabledSystemUIMode(immersiveSticky)` (hides the status bar's
      clock/battery and the 3 navigation buttons for a truly black screen);
      `_exitBlackout`/`dispose` restore `edgeToEdge` (matching the Activity's
      `enableEdgeToEdge`). Explained to the user that those bars are **OS-drawn**
      (SystemUI), which is why the app's black cover couldn't hide them by painting.
    - **Documented hard limit:** the camera lives in the Activity (the plugin view),
      so recording only runs while the app is open and the screen is on (blackout is
      fine — screen technically on). Pressing Home or a real screen-off releases the
      camera and stops recording; a foreground service can't run the camera in the
      background. The FGS protects the **process**, not background capture.
    - `flutter analyze` clean; `flutter test test/pollinator` all pass; **`flutter
      build apk --debug` succeeds** (native Kotlin compiles). On-device validation
      (notification appears, battery-opt dialog, bars hidden in blackout, session
      survives lock/unlock for minutes) left for the next field run on the Xiaomi.

48. **Rear-lens selection (2×/telephoto where the device allows it) + a camera
    diagnostics dialog (`camera_session_screen.dart`, `session_config.dart`,
    `lib/widgets/yolo_controller.dart`, `YOLOView.kt`, `YOLOPlatformView.kt`).**
    Prompted by the question of whether the app could use a dedicated 2×/telephoto
    lens instead of the default main camera, for more reach on a small insect.
    - **Finding — true physical-lens switching already existed but was unused.** The
      upstream Ultralytics plugin already enumerates and switches rear lenses
      (`YOLOView.computeLensInfos`/`setLens`, exposed in Dart as
      `YOLOViewController.getAvailableLenses`/`setLens`), but **no Pollinator screen
      ever called it** — those APIs were only wired into the plugin's own showcase
      widgets (`yolo_showcase.dart`/`lens_picker.dart`). So most of this round was
      wiring existing native capability into the Pollinator UI, not new camera code.
    - **How camera selection actually works here (verified by reading the native
      code).** `buildCameraSelector()` binds CameraX to a specific lens with
      `addCameraFilter { it == target }` when the lens has a public CameraX
      `CameraInfo`. `computeLensInfos()` enumerates **both** CameraX's public
      `availableCameraInfos` **and** the Camera2 *physical* IDs hidden under a
      logical multi-camera (`CameraCharacteristics.physicalCameraIds`), classifying
      each Wide / Ultra-wide / Telephoto by 35mm-equivalent focal length. `setLens()`
      has two paths: a lens **with** a public `CameraInfo` is bound for real (rebind
      via `startCamera()` — fully usable for ImageAnalysis/inference); a lens that is
      a **hidden physical-only sub-camera** cannot be bound by CameraX 1.x, so the
      code degrades to `setZoomRatio()` digital zoom through the wide camera (and
      bails if the requested zoom is outside the logical camera's range).
    - **CameraX/HAL conclusion (the honest answer).** A telephoto is *truly* openable
      only when the device exposes it as a separately-bindable logical camera. When
      it is hidden as a physical-only sub-camera under one logical camera (common on
      flagships), **CameraX cannot bind ImageAnalysis to it** — there is no safe,
      non-fragile way to feed the detector that lens's frames, so the app does not
      pretend to. This is exactly why the diagnostic exists.
    - **Lens-switch button (reuses existing APIs, no native change for the button).**
      A small button immediately right of the record button cycles the available
      rear lenses and shows a short label (`1×`, `0.5×`, `2×`, …). It is **disabled
      while recording** (and when only one lens exists), because a lens change
      rebinds the camera and shifts the field of view (the ROI would need re-aiming)
      — the same before-recording-only policy as the stream-resolution control. The
      lenses are probed once on the first frame (`_fetchAvailableLenses`, alongside
      the existing focus/stream probes) and the choice is **persisted** in
      `SessionConfig.selectedLensZoom` (new field, default 1.0 = main wide) so the
      next session reopens on the same lens. The ROI survives the rebind untouched:
      `inferenceRoi` is a `@Volatile` field re-applied to the predictor every frame,
      independent of binding — so cropping, tracking, capture, overlays and logging
      are unaffected.
    - **Camera diagnostics dialog (one new native method).** A new
      `YOLOView.cameraDiagnostics()` walks every camera (`CameraManager.cameraIdList`
      plus each logical camera's `physicalCameraIds`) and reports, per lens:
      `cameraId`, `lensFacing`, `focalLengthsMm`, `equiv35mm`, `lensType`, logical vs
      physical-only, **`usableForInference`** (true only when CameraX exposes it as a
      bindable `CameraInfo`), a plain-language `reason`, and the 4:3 `analysisSizes`
      it supports. Exposed via a `getCameraDiagnostics` method-channel case and a new
      `YOLOViewController.getCameraDiagnostics()`; surfaced by an `info` button on the
      camera screen that opens a scrollable, **selectable-text** dialog (green
      "Usable for inference" / amber "Zoom-only (hidden lens)" / grey "Not bindable"
      badges) so a researcher can see exactly which lenses any given phone offers the
      pipeline — and copy it into a problem report for future device-specific support.
    - **Session metadata.** `start_of_session` now records `selected_lens_zoom` and
      `selected_lens_label` (and the field rides along in the `config` block too), so
      the lens used is part of the scientific record.
    - **Supported devices / limitations.** The two test phones (Xiaomi Mi 11 Lite 5G
      / 2107113SG, Samsung Galaxy M12 / SM-M127F) are mid-range with no true optical
      telephoto, so the value there is mainly the diagnostic plus access to whatever
      ultra-wide/extra lens each exposes as bindable; phones that expose multiple
      bindable rear logical cameras get real lens switching. True access to a
      physical-only telephoto would need CameraX's concurrent-camera / physical-camera
      APIs (or Camera2 directly) and a separate ImageAnalysis path — out of scope here
      and noted as future work. The existing zoom-through-logical fallback is left as
      is; no fragile hacks were added.
    - `flutter analyze` clean (pollinator module + plugin controller);
      `flutter test test/pollinator` all pass; **`flutter build apk --debug` succeeds**
      (native Kotlin compiles). On-device confirmation (lens cycling + FOV change on a
      multi-lens phone, the diagnostic listing, and `selected_lens_*` in a pulled
      `session.jsonl`) left for the next field run on the Xiaomi and Samsung.

49. **Lens-feature field fixes: control-strip overflow, diagnostic relocated to
    Settings, and the per-device enumeration confirmed correct
    (`camera_session_screen.dart`, `settings_sheet.dart`, `YOLOView.kt`).** First
    on-device run of round 48 on both phones exposed two UI defects and a question
    about why each phone surfaces a different number of lenses. Investigated with
    `adb shell dumpsys media.camera` on both devices plus the app's own diagnostic.
    - **Finding — the enumeration is correct; the differences are real platform
      limits, not a bug.** **Xiaomi Mi 11 Lite 5G (MIUI):** the HAL lists **8** camera
      devices (several back logical multi-cameras with hidden `physicalIds`), but MIUI
      exposes only **one logical back camera + one front** to third-party apps, so the
      ultra-wide/macro are hidden physical sub-cameras CameraX cannot bind
      ImageAnalysis to → **one usable rear lens, switch correctly disabled**. This is a
      documented MIUI restriction with no non-privileged workaround. **Samsung Galaxy
      M12:** the app sees **4** rear devices, of which CameraX exposes the **2
      bindable** lenses (wide 1× + ultra-wide 0.5×); the remaining rear cameras are
      **macro** (fixed-focus, low-res) and **depth** (not an imaging sensor), correctly
      excluded because they can't run the detector usefully. So "4 physical but 2
      selectable" is expected. We deliberately do **not** invent privileged/unsupported
      access to hidden lenses.
    - **Overflow fix.** Round 48 added both a lens button *and* an info button to the
      bottom control strip, pushing the `Row` past the screen width → Flutter's
      yellow/black "RIGHT OVERFLOWED BY 26/17 px" stripes on both phones (independent
      of switch state). Fixed by removing the on-screen info button, tightening the
      inter-control spacing (24→16 px), and **wrapping the control `Row` in
      `FittedBox(BoxFit.scaleDown)`** so the strip can never overflow on any width or
      text scale (it shrinks to fit) — the same defensive approach as the round-9
      overflow fix.
    - **Diagnostic moved off the live screen into Settings → Camera.** The
      tap-to-open camera-metadata dialog read as developer clutter on the recording
      screen, so it was **removed from there** (`_CameraDiagnosticsDialog` and
      `_showCameraDiagnostics` deleted) and relocated to a collapsed **"Camera & lens
      info (advanced)" `ExpansionTile`** at the bottom of the Camera settings tab. The
      camera screen now reads the diagnostics once while the preview is live
      (`_fetchCameraDiagnostics`) and passes them into `SettingsSheet` via a new
      `cameraDiagnostics` parameter (same pattern as `streamResolutions`). The cards
      keep the green/amber/grey "usable for inference / zoom-only / not bindable"
      badges, focal lengths, analysis sizes and plain-language reason, with selectable
      text for problem reports. The native `cameraDiagnostics()` method, its channel
      handler and the Dart `getCameraDiagnostics()` are unchanged — only the entry
      point moved.
    - **Lens-switch button** kept exactly as before: visible, enabled only when ≥2
      usable rear lenses exist, disabled otherwise — matching the observed (correct)
      behaviour on both phones. `computeLensInfos`/`setLens` were **not** changed.
    - **No change** to ROI, detection/tracking, session logging, thermal/FPS/energy,
      the summary screen, or camera-preview performance; no per-frame work added. The
      round-48 `selectedLensZoom` persistence and `selected_lens_*` start metadata are
      retained. On-device findings were also recorded as comments on
      `YOLOView.enumerateLenses()`.
    - `flutter analyze lib/` clean; `flutter test test/pollinator` all pass;
      **`flutter build apk --debug` succeeds**. On-device confirmation (no overflow on
      either phone; Settings → Camera shows the lens list; Samsung cycles 1× ↔ 0.5×;
      Xiaomi switch disabled) left for the next field run.

50. **Why the camera list doesn't match the lenses you can count — diagnostic made
    clear (`settings_sheet.dart`, `YOLOView.kt` comment).** The user, seeing the
    round-49 "Camera & lens info" panel, was confused that it listed fewer cameras
    than the phone physically has, and that front cameras appeared. Diagnosed deeply
    from the `flutter run` logs (`cat_logs/flutter_output_{xiaomi,samsung}_*.log`)
    plus `dumpsys media.camera`.
    - **Root cause (not a bug): `getCameraIdList()` is a manufacturer-curated subset,
      not a 1:1 map of the glass lenses.** On the **Xiaomi Mi 11 Lite 5G (MIUI)** the
      CameraX pipe logs `Expected minimum camera count = 2`, camera `0` =
      `Back (Physical, Level 3)`, camera `1` = front, and the framework explicitly
      logs `ignore the torch status update of camera: 2,3,4,5,6` — the ultra-wide /
      macro / 2× lenses **physically exist but MIUI does not expose them to
      third-party apps** (reserved for the built-in camera app). So the app correctly
      sees **one rear + one front**, and the lens switch is correctly disabled. On the
      **Samsung Galaxy M12** the pipe logs
      `Loaded CameraIdList [CameraId-0..3]` — **2 rear** (wide 1× + ultra-wide 0.5×,
      exactly the switchable pair) **+ 2 front**, where the second front is a Samsung
      firmware quirk (a duplicate front camera id), not an extra physical lens. The
      diagnostic was therefore **accurate**; it just lacked context.
    - **Fix — clarity, not enumeration.** The Settings → Camera info panel now: (a)
      opens with a plain-language explanation that Android only exposes a maker-chosen
      subset of lenses and that ultra-wide/macro/telephoto are often reserved for the
      system camera app (so they won't appear even though you can see them on the
      back); (b) splits the list into **"Rear cameras (used for monitoring)"** first,
      with human-friendly titles (**Main (wide) camera / Ultra-wide camera /
      Telephoto camera**, derived from facing + 35mm-equivalent focal) and the
      technical `id • focal` as a secondary line; (c) when only one usable rear camera
      exists, shows an amber note explaining why the switch is off and that extra
      lenses are reserved by the manufacturer (the Xiaomi case); (d) tucks **front
      cameras** into a **collapsed** "Front cameras — not used for monitoring"
      subsection that also explains the duplicate-front quirk (the Samsung case). The
      green/amber/grey "usable for inference" badge is kept.
    - **No enumeration / lens-switch / native change** — `computeLensInfos`/`setLens`
      and `cameraDiagnostics()` are unchanged (they were already correct); the only
      native edit is a clarifying comment on `enumerateLenses()` recording that the
      camera-id list is a curated subset, not the physical lens count. We do not
      attempt privileged/unsupported access to reach hidden lenses (CameraX
      concurrent/physical-camera APIs remain noted as future work, and would not help
      on MIUI, which withholds the lenses entirely).
    - `flutter analyze lib/` clean; `flutter test test/pollinator` all pass (Dart-only
      UI change). On-device confirmation of the reworded panel left for the next run.

51. **Tracker tuning: "Min hits to confirm" exposed (in seconds), AI-tab/old-session
    naming unified, and clearer help text (`session_config.dart`, `settings_sheet.dart`,
    `camera_session_screen.dart`, `session_summary_screen.dart`).** Prompted by the
    user (a pollination ecologist) asking for an explanation of the tracker and noting
    that the AI tab and the old-session viewer named the same knobs differently.
    - **New user knob — minimum visit length.** `minHitsToConfirm` (how many matched
      frames before a track is *confirmed* and counted as a visit) was hardcoded at 3
      frames, so a genuine brief touchdown shorter than 3 frames was silently dropped —
      biasing the visitation rate against short visits. It is now exposed on the AI tab
      as **"Min hits to confirm"** in **seconds** (default **0.2 s** ≈ the old 3 frames
      at 15 FPS; range 0–2 s). Like occlusion tolerance, it is converted to a frame
      count **live** from the smoothed detector FPS via the new
      `SessionConfig.minHitsFramesFor()` (mirrors `occlusionFramesFor`: round, 15-FPS
      fallback, clamped ≥1). `_trackerParamsForFps` now sets both `trackBuffer` and
      `minHitsToConfirm`, and the per-second live refresh in the camera screen keeps
      both in step as FPS drifts. Persisted in `SessionConfig` (`minHitsSeconds`) and
      reloaded across restarts; older logs without the field default to 0.2 s.
    - **Naming unified.** The old-session viewer used raw internal names that didn't
      match the AI tab. Renamed so the *same knob is never called two things*:
      "Match threshold (high pass)" → **Match overlap (IoU)**, "Match threshold (low
      pass)" → **Low-score association**, "Track buffer" → **Occlusion buffer
      (derived)** frames, and Min hits now shows the user's **seconds** (falling back to
      the raw frame count for older logs). High-score threshold stays shown (recorded
      but not user-editable in the AI tab). The logged `tracker_params` now records the
      *effective* (live-derived) frame counts, not the static class defaults.
    - **Help text clarified.** Match overlap now explains it is "movement tolerance"
      inverted (lower = tolerates faster motion; keep low ~0.1–0.2 for small fast
      insects) and *why* the range is 0.05–0.90 (0 → matches unrelated boxes / id chaos;
      1.0 → demands pixel-identical boxes / a new id every frame). Low-score association
      explains the faint-detection recovery and why the 0.02 floor exists.
    - **Verified correct (no change):** the occlusion-tolerance seconds→frames
      conversion is genuine (`round(seconds × smoothed FPS)`, clamped 1–600, refreshed
      live), not cosmetic.
    - `flutter analyze` clean on all four files; `flutter test test/pollinator` 18/18
      pass (added `session_config_test.dart` covering `minHitsFramesFor` rounding/
      fallback/clamp and JSON round-trip). On-device check left for the next run.

52. **All tracker knobs now exposed + bee-tuned defaults + proof of impact + a
    settled threading question (`byte_track.dart`, `session_config.dart`,
    `settings_sheet.dart`, `camera_session_screen.dart`, `session_summary_screen.dart`,
    tests).** The user (pollination ecologist) asked for full control over the tracker,
    defaults suited to their data (~11 s median visits, ~87% bees, slow once landed,
    rare co-occurrence, brief low-score occlusions), proof the knobs really act, and
    whether the tracker should be threaded.
    - **Every adjustable tracker parameter is now on the AI tab** (six total):
      Occlusion tolerance (s), Min hits to confirm (s), Match overlap (IoU),
      Low-score association, and the two newly surfaced — **High-score threshold**
      (`highThresh`) and **Velocity smoothing** (`velocitySmoothing`, moved out of a
      hardcoded `ByteTracker` field into `ByteTrackParams` so it persists and is
      live-tunable). A plain-language **intro paragraph** now heads the Tracker
      section explaining what tracking does, the ID-fragmentation risk, and the
      Confidence↔High-score relationship; every knob's help text was expanded.
    - **High-score auto-tracks Confidence.** The high/low split must stay above the
      detector Confidence threshold or the "faint detection" recovery band collapses.
      Raising **Confidence** now automatically raises **High-score** to at least
      `Confidence + 0.10` (`_highScoreBuffer`, capped 0.95), and the High-score
      field's minimum follows Confidence live (`_minHighScore`). This guarantees a
      band of weak detections that can keep an existing insect's ID alive (the
      half-hidden-bee case) without being strong enough to spawn a new ID.
    - **Bee-tuned defaults (anti-fragmentation):** Occlusion tolerance 1 s → **3 s**
      (covers a few-second occlusion under a petal), Occlusion max 5 s → **10 s**,
      Match overlap 0.2 → **0.1** (slow insects + rare co-occurrence → low swap risk,
      fewer split IDs). Low-score association stays generous (0.1), Min hits 0.2 s,
      Velocity smoothing 0.5. **Saved configs keep their stored values**; new defaults
      apply on fresh install or after a settings reset.
    - **Threading: decided NOT to thread the tracker.** Inference (LiteRT) already
      runs natively, off the Dart isolate; `_onStreamingData` only fires when a result
      arrives, so the heavy work is already parallel to the UI/tracker. `update()` is
      pure-Dart greedy IoU over 2–3 tracks — microseconds. A separate isolate would
      force per-frame copying of the detection list across the isolate boundary (no
      shared memory) → slower; per-track isolates break ByteTrack's *joint* assignment
      and add pure overhead. To prove it empirically, a `track=<ms>` figure was added
      to the once-a-second PERF `debugPrint` (expected ~0.0–0.1 ms vs tens of ms for
      `inf`).
    - **Proof of impact:** `byte_track_test.dart` gained four knob-impact groups —
      same synthetic sequence, two settings, two outcomes: occlusion buffer longer vs
      shorter than a 5-frame gap (1 vs 2 unique IDs), low-score association loose vs
      strict (id kept vs lost), high-score below vs above a 0.4 score (track starts vs
      never), and velocity smoothing high vs low (predicted box shifted further). The
      old-session viewer also gained a **Velocity smoothing** row (names still mirror
      the AI tab).
    - `flutter analyze lib/pollinator test/pollinator` clean; `flutter test
      test/pollinator` **28/28** pass. On-device check (AI tab shows all six knobs;
      toggle Occlusion tolerance low↔high and watch live **Total tracks** jump↔hold
      during a brief occlusion; confirm `track=` ≈ 0 ms in logcat) left for the next
      run.

53. **On-device diagnostic logging for the FPS/throttle problem (`session_logger.dart`,
    `roi_capture.dart`, `camera_session_screen.dart`, `session_summary_screen.dart`,
    tests).** A Xiaomi recording (`sessions/Xiaomi/session_64`) dropped from ~10→3 fps
    after ~25 s while **battery temp barely moved (39→40 °C)** and `thermal_status`
    stayed `none` — i.e. **SoC/CPU-core throttling the battery sensor can't see**. The
    timing that proves this (`inf`/`track`/engine) only went to `debugPrint`→logcat, so
    it was lost on an **uncoupled** run. The drop also happened on **int8**, pointing at
    the **large analysis stream + sustained workload** (Xiaomi: 1200×1600 on CPU after a
    GPU compile failure — `GPU accelerator could not run model … Failed to compile
    model`; cooler Samsung runs: 480×640 on GPU), not just the float16 CPU fallback.
    - **Rich per-second perf record.** `_sampleFps()` now logs the full fingerprint into
      `session.jsonl` (record type still `fps`, with the `fps` key kept for the existing
      graph + old sessions): `camera_fps, detector_fps, pipeline_fps, pre_ms, inf_ms,
      post_ms, track_ms, engine, analysis_w/h`. `inf_ms` rising while temp is flat is the
      throttle signal. Off the inference path, no new timer.
    - **App logcat saved to the session folder.** Reusing the existing
      `Diagnostics.captureLogcat` (native `logcat -d --pid <self>`, works uncoupled),
      `_startRecording` writes `logcat_start.txt` (engine decision) and `_stopRecording`
      writes `logcat_end.txt` (throttle-era native logs + persisted PERF lines).
      Best-effort; never breaks a recording.
    - **Per-photo save timing.** `RoiCaptureScheduler` gained an `onStat` callback +
      `CaptureStat` (grab+crop+write ms, bytes, full-res flag); each save logs a
      `capture` record, isolating whether photo-saving adds to the dip.
    - **Throttle graph.** The end-of-session summary parses `inf_ms` and draws an
      "Inference time (ms) — throttle signal" graph beneath Detector FPS, on the shared
      time axis with the temperature graph, so the throttle is visible without parsing
      JSON. Gated by `autoComputeGraphs`.
    - **Photo/stream strategy deliberately deferred** until a clean uncoupled
      battery run produces this data (also corrected the owner's "stream grab is free"
      assumption: the *grab* is cheap, but a high stream makes *every* inference frame's
      YUV→RGB + crop+scale heavier — the standing heat cost; sharp photos are better got
      via small stream + full-res stills).
    - `flutter analyze lib/pollinator test/pollinator` clean; `flutter test
      test/pollinator` **30/30** pass (added `capture`-record and enriched-`fps` logger
      tests). Real test = an uncoupled battery run, then pull the session folder and read
      `inf_ms` vs `fps`, `logcat_*.txt`, `capture` records, and the throttle graph.

54. **Auto thermal-aware inference throttle (`perf/adaptive_inference_throttle.dart`,
    `session_config.dart`, `camera_session_screen.dart`, `settings_sheet.dart`, tests).**
    The uncoupled battery run (`sessions/Xiaomi/session_66`) proved the FPS collapse is
    **CPU thermal throttling**: at ~62–70 s `inf_ms` jumped 75→285 ms and `pre_ms`
    8→26 ms *together* (uniform clock cut), detector fps 10→3.1 and flatlined, while
    battery temp moved only 36→39 °C, `thermal_status` stayed `none`, `thermal_headroom`
    was `null` (sensor blind), and power held ~7 W (CPU pegged by **uncapped** inference;
    model still on XNNPACK CPU). The new diagnostics captured all of it, incl. the GPU
    compile-fail in `logcat_start.txt`.
    - **Controller (`AdaptiveInferenceThrottle`, pure Dart, unit-tested).** Targets a CPU
      **duty cycle**: `desiredFps = dutyTarget·1000/infMsEma`, clamped `[minFps, ceilFps]`.
      Self-correcting with no thermometer — as the chip warms, `inf_ms` rises so the rate
      auto-drops, the chip cools, then the rate **ramps back up ≤ +1 fps/tick** (asymmetric:
      fast down, slow up) to avoid bouncing back into the overheat.
    - **Wiring (Dart-only, no native change).** Feasibility verified: `setStreamingConfig`
      updates the native frame-skip interval **live** and `YOLOView.setStreamConfig` only
      rebinds the camera when the *analysis resolution* changes (`YOLOView.kt:190`), which
      it doesn't here. The controller runs in the existing once-a-second perf block, feeds
      `inf_ms`, and on a change sets `_appliedCapFps`, which drives the `YOLOView`
      `streamingConfig.inferenceFrequency` declaratively (`didUpdateWidget` re-sends).
      `applied_cap_fps` + `throttle_inf_ms_ema` added to the per-second `fps` record and
      `cap=` to the PERF line, so the controller is visible in an uncoupled run.
    - **Settings (Camera tab).** New **"Auto-adjust inference rate"** switch (default ON);
      the rate field becomes the **"Max inference rate"** ceiling when on; added **"Min
      inference rate"** floor (default 3) and advanced **"Target processor load"**
      (`throttleDutyTarget`, 0.3–0.8, default 0.5). Auto off = previous manual-cap
      behaviour. New config fields persist; older configs default auto ON.
    - **In-app mitigation, not the cure:** holds a steady sustainable fps while CPU-bound;
      the durable fix remains a GPU/NPU-runnable model export.
    - `flutter analyze` clean; `flutter test test/pollinator` **37/37** pass (new
      `adaptive_inference_throttle_test.dart` + config round-trip). Real test = an uncoupled
      battery run with auto ON: expect fps to plateau (not cliff) and `applied_cap_fps` to
      adapt down then hold; if the plateau is still <5 fps, CPU can't meet target → GPU/NPU
      export required.

55. **Tracker ID fragmentation fixed (distance-association fallback) + summary UX
    (`tracking/byte_track.dart`, `models/track.dart`, `screens/session_summary_screen.dart`,
    tests).** Two auto-throttle battery runs of a **single** bee video produced dozens of
    ids (Xiaomi `session_68`: 47; Samsung `session_11`: 33).
    - **Diagnosis (from the new diagnostics):** association failure, not detector dropout.
      Samsung had **zero** detection gaps >3 s yet 33 ids with 22 id-switches between frames
      <1.5 s apart; at every switch the boxes still *overlapped* (IoU 0.24–0.33, never 0) with
      centres only ~0.05 of the ROI apart. Cause: the IoU passes compare detections against
      the **velocity-coasted predicted box**, which overshoots for a near-stationary insect at
      low fps and drops IoU below `matchThresh`. (Both phones are CPU-bound on the float16
      model — Samsung pinned ~2 fps the whole run, Xiaomi throttling to 285–900 ms — so the low
      fps amplifies the overshoot. GPU/NPU export remains the durable fix for both fps *and*
      fragmentation.)
    - **Fix — `_associateByDistance` third pass.** After the high/low IoU passes, still-unmatched
      **confirmed/lost** tracks are re-linked to a leftover detection whose centre is within an
      **auto-derived** gate (`1.5 × detection box-diagonal`, clamped [0.05, 0.20] of the frame)
      of the track's **last *observed* centre** (new `Track.lastObservedCenter`, not the coasted
      box). High-confidence detections consumed here don't also spawn a new track. Greedy by
      nearest; only revives real tracks; gate is bounded so far-apart insects aren't merged
      (rare co-occurrence anyway). No new user knob (`distanceGateFactor` is a code/test param).
      Re-links all 22 observed switches in both sessions.
    - **Summary UX:** (a) the visit-timeline (Gantt) is now collapsible with a **floating
      Hide/Show button** that appears only while the timeline is on screen (tracked via a
      `GlobalKey` RenderBox vs viewport on a `ScrollController`) and vanishes when you scroll to
      other graphs; collapsed it shows a one-line placeholder. (b) When a device doesn't report
      **thermal headroom** (e.g. Xiaomi: 0 samples; Samsung: 18/18), the summary now shows a
      "not reported by this phone — not a bug" note instead of silently omitting the graph.
    - Existing low-score-association unit test revised (a small-shift faint box is now *expected*
      to re-link via the distance fallback); added two anti-fragmentation tests (close drift keeps
      one id; a jump beyond the gate stays a new id). `flutter analyze` clean; `flutter test
      test/pollinator` **37/37** pass. Real test: re-run the bee video on both phones — expect the
      unique-insect count to drop from dozens to a handful.

56. **Stream resolution: the dropdown stopped over-promising; delivered size is now
    truthful (`YOLOView.kt`, `YOLOPlatformView.kt`, `yolo_controller.dart`,
    `camera_session_screen.dart`, `settings_sheet.dart`).** On the Samsung
    (`RF8T403A3AT`, Galaxy M12-class) selecting **1080×1440** in the Camera tab gave a
    live "Stream:" readout of only **720×960** (exactly ×2/3). Traced end-to-end (Dart
    + native CameraX).
    - **Root cause (not a data bug).** The stream dropdown is built natively from
      `SCALER_STREAM_CONFIGURATION_MAP.getOutputSizes(YUV_420_888)`
      (`YOLOView.supportedStreamResolutions()`), filtered only to ~4:3 and a loose
      ≤2.1 MP cap. Those are sizes the **still/preview** path supports. But the app
      binds **Preview + ImageAnalysis + ImageCapture together**, and CameraX
      `ImageAnalysis` cannot stream 1440×1080 on this phone — it falls back (via
      `FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER`) to the largest 4:3 analysis size it
      truly supports, **960×720** (reported back oriented as 720×960). The dropdown
      over-promised; the readout was already honest. (`PREFER_HIGHER_RESOLUTION_OVER_CAPTURE_RATE`
      *is* applied here — 1.55 MP > the 0.92 MP threshold — so that was not the cause;
      the cap is CameraX's PREVIEW-size bound for the 3-stream combination, ~the
      smaller of 1080p and the screen size.)
    - **Why it does not corrupt data (the implications).** Detection accuracy is
      **unaffected** — every frame is downscaled to the model's own input tensor
      (640/416/320) regardless of stream size. Stream resolution only changes
      **fast-mode ROI crop sharpness** (capped at the *delivered* short side), and the
      crop math + `analysis_w/h` logging already key off the **delivered** frame, so
      saved crops and logs were already correct. The session log also already records
      both the requested (`config.streamWidth/Height`) and delivered (`analysis_w/h`)
      sizes, so past Samsung sessions remain fully interpretable. On this Samsung
      (likely CameraX `legacy`/`limited`, 720-wide screen), 960×720 is probably the
      genuine analysis-stream ceiling — higher is only reachable via the full-res still.
    - **Fix — truthful UI + a native ceiling query** (chosen over chasing a higher
      stream, which is likely impossible on this device; same "don't pretend" stance as
      the rounds 48–50 lens diagnostics):
      - **Native `YOLOView.analysisStreamCeiling()`** returns, for the bound camera, the
        `hardwareLevel` (`INFO_SUPPORTED_HARDWARE_LEVEL`) and an **estimated
        `recommendedMax`** = the largest 4:3 `getOutputSizes(YUV)` size whose area ≤
        `min(1080p, displayArea)` (CameraX's PREVIEW bound), reusing the existing 4:3/≤2 MP
        filter chain. Documented as an *estimate* — the live readout is the ground truth.
        Exposed via a `getAnalysisStreamCeiling` method-channel case and
        `YOLOViewController.getAnalysisStreamCeiling()`.
      - **Truthful Stream readout** (`camera_session_screen.dart`): when the delivered
        frame is >5% smaller by area than requested, the line now reads e.g.
        `Stream: 720×960 px (asked 1080×1440 — device max)`.
      - **Dropdown annotation + help note** (`settings_sheet.dart`): sizes above the
        ceiling stay selectable but are labelled `(may cap to W×H)`, and a plain-language
        note explains the stream is capped by the phone, that it does **not** affect
        detection (only fast-crop sharpness), and to use "Full-resolution ROI photos" for
        sharper crops. The **Camera & lens info (advanced)** panel gained a block showing
        the hardware level + estimated ceiling + screen size.
    - **No change** to detection, tracking, ROI math, capture, or the logging schema.
    - `flutter analyze` clean (app module + plugin controller); `flutter test
      test/pollinator` **37/37** pass; **`flutter build apk --debug` succeeds** (native
      Kotlin compiles). On-device confirmation (Samsung readout shows the cap; Camera &
      lens info shows level + ceiling; a size the Xiaomi can deliver shows no suffix)
      left for the next field run.

## 6. Performance note: what actually decides GPU vs CPU

The processor actually used is now logged and shown on screen, and observing it
across several models corrected an initial assumption. **Precision (int8 vs fp16)
does *not* decide the accelerator.** What decides it is whether the device's LiteRT
GPU backend can *compile that specific model's operation graph*; if it can't, the
plugin falls back to CPU (and if the GPU compile *crashes*, a 2-strike blocklist
routes the model to CPU — see rounds 13–14).

Confirmed on the test phone (Adreno GPU), straight from `logcat`:

| Model | GPU compile | Engine |
|---|---|---|
| `yolo26n` (int8, YOLO26) | succeeds (all nodes delegated) | **GPU** |
| `yolo11n_float16` (fp16, YOLO11) | `Failed to compile model` → clean fallback | **CPU** (works) |
| `yolo11n_float16_MaxS_platform` (fp16) | hard crash → blocklisted after 2 strikes | **CPU** |

So an fp16 export is **not** a guarantee of GPU execution — a YOLO11 fp16 graph
failed to compile on this GPU while an int8 YOLO26 graph ran on it. GPU-compilability
is a property of the model's architecture/exported ops and the device's GPU driver,
read from the model file at load time, **not** from any metadata field.

Practical guidance:
- If a custom model runs on CPU and you want the GPU, try **different export
  variants** (e.g. YOLO26 vs YOLO11, with/without end2end NMS in the graph, fp16 vs
  fp32) and watch the on-screen **"Engine"** readout to see which compiles on GPU.
- If a model **crash-loops at load**, that is a hard GPU-compile crash; toggling
  **"Use GPU when faster" off** loads it straight on CPU and skips the risky compile
  (the blocklist also demotes it automatically after two crashes).
- The detector-rate cap (default 15/s) remains the lever for trading temporal
  precision against heat and battery once the model runs fast enough to exceed it.

```bash
yolo export model=best.pt format=tflite half=True   # one export variant to try (fp16)
```

### 6a. Frame rate: how it's measured, what limits it, what's enough

**What "FPS" means here.** The displayed FPS is the **detector loop** rate — the
rolling rate of `predict()` calls, where each call = preprocess (crop + resize +
pixel→float) + model inference + non-max-suppression. It does **not** include the
Dart-side tracking, JSON logging, or ROI-photo saving, which run after the
callback off the camera thread.

**Measured pipeline (test phone, nano @ 640 input, GPU):**

| Stage | Time | Notes |
|---|---|---|
| Camera analysis delivery | ~23 FPS | not the bottleneck |
| YUV→RGB (`toBitmap`) | ~2 ms | fast RGBA path (`format=1`) |
| Preprocess (`pre`) | ~25 ms idle → **100–186 ms saturated** | CPU; the bottleneck |
| Inference (`inf`) | ~20–30 ms | GPU |
| NMS (`post`) | ~5–25 ms | JNI |

So the system is **CPU-preprocess- and thermally-limited**, not model- or
camera-limited, and the preprocessing cost scales with the **model input size**
squared — which is why a 320/416-input model is the main lever for higher FPS.

**How much FPS does the science need?** For the target use case — an insect that
**lands and stays** on a flower — far less than a fast-tracking system needs. The
tracker only needs enough frame-to-frame overlap to keep the same ID:
- landed / slow visitor: **5–10 FPS is sufficient** for visit timing;
- fast fly-bys / hovering: 15–30 FPS helps.

For reference, the Sittinger *Insect Detect* setup reaches ~40 FPS using a Luxonis
OAK (a dedicated on-camera vision processor). A phone doing on-device inference is
in a different class, but **~6–10 FPS sustained is scientifically adequate for
visitation-rate and visit-duration of landed pollinators**, which is the metric
this app targets.

---

## 7. Verification

- **Unit tests** (`flutter test test/pollinator/`): ROI normalized↔pixel math and
  the in-ROI filter; tracker stability, distinct ids, and occlusion survival;
  JSONL logging validity, crash-detectability, and timestamp format.
- **Static analysis**: `flutter analyze` clean for the app module and the
  modified plugin Dart.
- **On-device**: built and run repeatedly on a physical Android 14 phone; ROI
  drag/resize, track-id overlays, capture, logging, temperature and the dashboard
  were exercised interactively, and a session was pulled over USB and validated
  field-by-field (round 10 above).

---

## 8. Reproducing the build

```bash
# From the repository root:
flutter pub get
flutter test test/pollinator      # unit tests
flutter run                        # build, install and launch on a connected Android device
```

Requirements: the Flutter SDK, an Android SDK, and a connected Android device
with USB debugging enabled.

---

## 9. Limitations and future work

- **Android only** for now; an iOS build (including the native ROI crop in Swift)
  is future work.
- Re-identifying the *same* individual insect across separate visits is **out of
  scope** — visitation rate is derived purely from within-session detection and
  tracking.
- The full-resolution time-lapse crop assumes the still-capture and analysis
  aspect ratios are compatible (the saved crop is always square in the still's
  own pixels).
- The detector-rate cap trades temporal precision for battery/heat; very fast
  insects may warrant a higher setting.
- **Lens selection is limited to lenses CameraX can bind** (rounds 48–49): a lens
  exposed only as a hidden physical sub-camera of a logical multi-camera cannot be
  used by the detector (CameraX 1.x cannot bind ImageAnalysis to it), and some
  vendors (e.g. MIUI on the Xiaomi test phone) expose only one rear camera to
  third-party apps at all. The **Settings → Camera "Camera & lens info"** panel
  reports which lenses each device actually offers the pipeline; true access to a
  hidden physical telephoto would need CameraX concurrent/physical-camera APIs (or
  Camera2) and a separate analysis path — future work. We do not attempt
  privileged/unsupported access to lenses the platform hides.

---

## 10. Attribution & licence

Built on the Ultralytics YOLO Flutter plugin (AGPL-3.0). This project inherits
that licence. The Pollinator Monitor additions were implemented with Claude Code.
See `/lib/pollinator/README.md` for the module-level developer notes and
the `session.jsonl` schema used by downstream R/Python analysis.

### 10a. Licensing & repository decision (2026-06-26)

Reviewed how to move from "uncommitted work inside the upstream clone" to a
tracked repository, and whether this is compatible with the upstream AGPL-3.0
licence and the goal of a **free, openly distributed** app for scientists and
citizen scientists.

**How the app is wired.** Pollinator Monitor lives in
`/lib/pollinator/` and consumes the plugin as a local **path dependency**
(`ultralytics_yolo: path: ../`). It also **modifies the plugin's own native
Kotlin source** (section 4b: ROI-crop inference). Because of those native edits,
this project is genuinely a **fork** of the plugin, not a mere consumer of it —
a plain pub.dev dependency (the quickstart route) would have been read-only and
could not host the ROI-crop change.

**AGPL-3.0 conclusions (not legal advice):**

- AGPL-3.0 is strong copyleft but **fits the free/open goal** — it forbids making
  the *combined* app proprietary when distributed, which we never intend.
- A **private GitHub repo triggers no obligations**: AGPL attaches to
  *distribution* of the app and to *network-served* interaction, neither of which
  a private repo is. Development can stay private indefinitely.
- The **§13 network clause does not bite**: inference runs **on-device**, and the
  planned iNaturalist feature makes our app the *client* of someone else's server.
  In practice AGPL behaves like ordinary GPL-3.0 here.
- **On distribution of the APK** (to citizen scientists, an app store, or with the
  preprint) we must: license the whole combined app under AGPL-3.0, provide the
  corresponding source to recipients, keep Ultralytics' copyright + `LICENSE`
  intact, and **state our changes** — which this document already does.
- We may **not** relicense the plugin or its native modifications under a
  permissive licence (MIT/Apache).

**Repository plan (chosen): fork-style single repo.** Keep `yolo-flutter-app/`
as the repo root with upstream history preserved; rename the upstream remote to
`upstream`, develop on a `pollinator-monitor` branch, and push to a **private**
GitHub repo (name TBD by the owner). This keeps `git diff upstream/main` as the
exact, paper-ready change-set and preserves attribution automatically. Build
artifacts (`build/`, `.dart_tool/`, `.gradle/`) are already git-ignored; model
assets total ~50 MB with an 11 MB max single file, so **no Git LFS is needed**.
The owner will run the git/GitHub steps manually.

### 10b. Git restructure actually executed (2026-06-27) — supersedes the 10a plan

Section 10a proposed a *fork-style single repo* that kept the upstream layout
(plugin at root, app in `example/`) and preserved Ultralytics git history. We
**changed approach** to an **app-centric repository** so the app — not the plugin
— is the main thing, which is clearer for ecologists and future maintainers.

**New repository: `pollinator-monitor`** (private; built at
`/home/vs66tavy/InsectDetectApp/pollinator-monitor/`, non-destructively copied from
`yolo-flutter-app/`, which is left intact as a fallback).

Layout (app at root, plugin):

```
pollinator-monitor/
├── lib/ android/ ios/ assets/ test/ …   # the app (was example/)
├── pubspec.yaml        # name: pollinator_monitor; ultralytics_yolo: path: packages/ultralytics_yolo
├── README.md           # app-first, with a "Built on" attribution section
├── POLLINATOR_MONITOR.md  # this dev log, moved to the repo root
├── LICENSE             # AGPL-3.0 (copied; plugin keeps its own copy too)
└── packages/ultralytics_yolo/   # the modified plugin (was the repo root), minus example/
```

Decisions and what was done:

- **Fresh git history** (`git init -b main`), not preserved upstream history.
  Provenance is documented instead: README credits
  `ultralytics/yolo-flutter-app @22b2e5d`, AGPL-3.0 is retained, and the modified
  plugin keeps its own `LICENSE`. AGPL change-statement obligations are still met
  via this document + the README.
- **Dart package renamed** `ultralytics_yolo_example` → `pollinator_monitor`;
  self-imports updated across `lib/`, `test/`, `integration_test/`, `test_driver/`.
- **Path dependency rewired** `../` → `packages/ultralytics_yolo`.
- **Models:** stock demo models (`yolo26n*`, generic `yolo11n*`, incl. the ones that
  sat inside `custom/`) are gitignored; only custom detectors
  (`arthropod_yolov11_float16/int8`, `flower_yolo11n_416_epochs200_float16`) are
  tracked. The model catalog is built dynamically, so a fresh clone just lists
  fewer models — nothing breaks.
- **Verified:** `flutter pub get` resolves the path dep; `flutter analyze` →
  "No issues found"; first commit created on `main` with a clean working tree.

**Remaining step (owner-run, needs GitHub credentials):** create the private
GitHub repo and push. `gh` is not installed, so either install it
(`gh repo create pollinator-monitor --private --source . --push`) or create the
repo in the browser and `git remote add origin <url> && git push -u origin main`.
