# FaunaPulse (renamed from "Pollinator Monitor") — Building a Field Ecology Tool on the Ultralytics YOLO Flutter Plugin

> **For the current state at a glance, read [`AGENT_CHANGELOG_OVERVIEW.md`](AGENT_CHANGELOG_OVERVIEW.md)
> first** (a short living snapshot: current defaults, file map, key invariants, device
> quirks). **This** file is the full append-only history — open it when you need the
> round-by-round narrative or the rationale behind a past decision.

This document records, transparently and in full, how the **FaunaPulse**
Android application was built on top of the open-source
[`ultralytics/yolo-flutter-app`](https://github.com/ultralytics/ultralytics-yolo-flutter)
plugin, using **Claude Code** (Anthropic's agentic coding assistant) driven by a
field ecologist with statistical/R/Python experience but no prior app-development
background.

Important note on app name: Initially this app was called "Pollinator Monitor" and it was
renamed to FaunaPulse on 2026-07-14. The older name was not changed everywhere in this 
file so that the history of changes stays unaltered.

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

57. **ROI box now snaps to the saved-crop ÷32 grid (what you see = what you save)
    (`lib/pollinator/models/roi.dart`, `camera_session_screen.dart`,
    `test/pollinator/roi_test.dart`).** Field observation: on a 720×960 stream, maxing
    the ROI showed `ROI: 704×704` in the readout (704 = largest multiple of 32 that fits
    the 720 short side — the model-friendly rule), but a saved file the owner inspected
    was **720×720**, and the box outline appeared to touch the preview edges.
    - **Diagnosis (the 720 file was a stale-build artifact).** Traced all four crop/save
      paths end-to-end. The current source **already** snaps every saved crop to a
      multiple of 32 and caps it to the frame's short side, using `min(w,h)`:
      `ImageUtils.cropRoiFromFrame` (fast live-frame crop, `:288-291`),
      `MainActivity.cropRoiJpeg` (full-res still, `:215-217`), and the Dart fallback
      `_cropJpeg` (`roi_capture.dart:270-272`). Because the cap uses `min(w,h)`, a
      720 short edge **mathematically can only ever save 704** — in any orientation. So
      the 720×720 file came from an APK built **before** this snap-and-cap fix (rounds
      19/21/26); the fast-crop path the owner was using cannot emit 720 in current source.
      **No crop/save code change was needed.**
    - **The real, still-present defect was purely visual.** The draggable ROI *box*
      (and the inference-ROI it pushes natively) used the raw continuous `sideFraction`,
      so a maxed box could span the full 720 px width while only the 704-px centre was
      saved/readout — "what you see" ≠ "what you save", the ~8 px-per-side (~2 %) margin
      the owner noticed.
    - **Fix — snap the box geometry too.** New `Roi.snapSideToGrid(sourceWidth,
      maxSidePx, frameAspect)` quantises the side to `snapToMultipleOf32(side*sourceWidth)
      .clamp(32, maxSidePx)` then re-clamps the centre (reuses the existing
      `snapToMultipleOf32` and `copyClamped`). It is applied in `_onRoiChanged` — the
      single funnel for drag, two-finger pinch, **and** the size slider — so all three
      become WYSIWYG at once; the readout and `_pushInferenceRoi` already read
      `_roi.sideFraction`, so the box, the readout, the saved crop, **and** the inference
      ROI are now identical by construction. A one-time re-snap also runs when the crop
      source size first becomes known (first analysis frame, or full-res still probe), so
      a box loaded from a persisted session lands on the grid without the user touching it.
    - **Deliberate edge margin.** When maxed, the box no longer touches the preview edge:
      it leaves an exact, symmetric margin (8 px per side at a 720 short edge, ≈2 %). That
      thin band is precisely the stream pixels that are **not** in the ÷32 saved crop —
      the honest, correct behaviour. Snapping only shrinks the side, so it is idempotent
      and pure *moves* don't fight it; only *resizes* step in 32-px increments, matching
      the readout which already stepped.
    - **No change** to the crop/save code, the logging schema, tracking, or detection.
    - `flutter analyze` clean (changed files); `flutter test test/pollinator` **38/38**
      pass (added a `snapSideToGrid` test: 720 short side → 704, idempotent, and source
      size 0 → unchanged); **`flutter build apk --debug` succeeds**. On-device
      confirmation (fresh build: readout 704, box leaves a thin even margin, a pulled
      `roi_frames/roi_*.jpg` measures **704×704**) left for the next field run.

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
`~/InsectDetectApp/pollinator-monitor/`, non-destructively copied from
`yolo-flutter-app/`, which is left intact as a fallback).

Layout (app at root, plugin):

```
pollinator-monitor/
├── lib/ android/ ios/ assets/ test/ …   # the app (was example/)
├── pubspec.yaml        # name: pollinator_monitor; ultralytics_yolo: path: packages/ultralytics_yolo
├── README.md           # app-first, with a "Built on" attribution section
├── AGENT_CHANGELOG.md  # this dev log, moved to the repo root
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

---

## Round 58 (2026-07-02): motion gate + deliberate default FPS cap

Field-deployment heat is the binding constraint (see round-53 throttle
diagnosis): mounted in direct sun the SoC throttles within ~30 s when the
detector runs flat-out. Two changes attack the duty cycle directly.

### 1. Motion gate (opt-in, experimental)

The detector now can *sleep while the flower is empty*. A cheap per-frame
check (native, <1 ms) watches the ROI; inference runs only while something
moves — or moved / was detected recently.

**Algorithm** (`packages/ultralytics_yolo/.../MotionGate.kt`): every analysis
frame, the ROI is shrunk to a 48×48 grayscale thumbnail (reusing
`prepareBitmapForModelRoi`, so the gate watches exactly what the model would
see). A per-pixel exponential-moving-average background (alpha 0.05, ~20-frame
memory) absorbs slow drift — sun, clouds, auto-exposure. A pixel "changed" when
its brightness differs from background by > `pixelDelta` (default 25/255); a
frame is "motion" when > `areaFraction` (default 0.5%) of pixels changed.

**Recall protection** (the deliverable is visitation *rate*; missing a visit is
worse than wasted inference):
- Gate starts AWAKE (`setMotionGate` primes a full wake window) so the user
  sees the detector working before it first sleeps.
- Motion AND every non-empty detection result extend the wake window
  (`wakeSeconds`, default 3 s) — a sitting insect keeps being re-detected,
  which itself keeps the gate open.
- ROI drag resets the learned background AND wakes the gate (old background is
  invalid at the new position).
- The gate check runs BEFORE the FPS-cap check in `onFrame`, so the background
  keeps learning even on frames the cap would skip.

**Pipeline honesty while idle:** the native side emits a ~1 Hz heartbeat map
(`gateIdle: true`, `motionScore`, `cameraFps`) through the streaming callback.
`_onStreamingData` short-circuits on it: updates the "Gate: idle (detector
asleep)" stat line + live motion %, and never reaches the 0-FPS watchdog (an
idle gate is intentional, not a model failure).

**Tracker staleness fix:** while the gate sleeps no frames reach the tracker,
so "lost" tracks cannot age out via `trackBuffer`. On the idle→awake
transition, if the sleep exceeded `occlusionSeconds`, the session screen calls
the new `ByteTracker.expireLostTracks()` — otherwise a newly arriving insect
could inherit the stale id of one that left before the gate closed (silently
merging two visits). Unit-tested (`byte_track_test.dart`).

**Logging:** new `motion_gate` JSONL entries on every transition (state,
motion score, idle duration on wake) make gated periods auditable when
validating a gated session against an always-on one. Config fields ride along
in the start metadata via `config.toJson()`.

**Plumbing:** `SessionConfig.motionGate{Enabled,PixelDelta,AreaFraction,WakeSeconds}`
(off by default) → settings sheet (switch + three numeric fields, shown only
when enabled) → `_pushMotionGate()` → `YOLOViewController.setMotionGate` →
platform channel → `YOLOView.setMotionGate`.

### 2. Default inference FPS cap: 0 (uncapped) → 10/s

Insect visits last seconds; ~10 inferences/s is plenty for stable tracking,
and a deliberate cap delays the thermal collapse far better than running
flat-out until the SoC throttles to ~3 fps. `fromJson` fallback for a
*missing* key is now 10, but an explicitly saved 0 (uncapped) survives the
round-trip — existing saved settings are respected, so the owner's device
keeps its stored value until changed in settings. Auto-throttle still treats
the cap as its ceiling.

### Verification

`flutter analyze` clean; `flutter test test/pollinator` 42/42 (4 new: config
round-trip + defaults, missing-key fallbacks, cap semantics, expireLostTracks);
`flutter build apk --debug` succeeds (same two pre-existing warnings: KGP
deprecation, optional fetch_bundled_models.sh).

**Field validation still pending (owner):** run one gated + one always-on
session over the same flower and compare unique-track counts and `motion_gate`
log entries before trusting the gate for real counts.

---

## Round 59 (2026-07-02): gate visibility + tunable motion grid (owner feedback on r58)

Owner's first handheld test of the motion gate raised three points:

**1. "The gate is always on."** Expected: hand shake is constant ROI motion, so
handheld the gate never sleeps — it is designed for a mounted phone over a
still flower. Documented in the settings switch subtitle ("Designed for a
MOUNTED phone: handheld shake counts as motion… normal, not a fault") so it is
never mistaken for a bug.

**2. Detector on/off state was too subtle** (one small stat line). Added:
- A prominent chip at the top of the status strip, shown only while the gate
  is enabled: green dot + "DETECTOR ON" while inference runs, grey dot +
  "SLEEPING" while gated (`_gateStateChip()` in `camera_session_screen.dart`).
- The ROI border turns grey while the gate is idle. Border color priority is
  now: capture flash (green) > gate-idle (grey) > recording (red) > default
  yellow. `RoiOverlay` already exposed `borderColor`, so this is one
  expression change at the construction site.

**3. Is a 48×48 motion grid too coarse for tiny insects?** It can be. Each
grid cell covers ROI-side/N of the scene: on a 15 cm ROI, 48 gives ~3 mm
cells — a honeybee (~12 mm) spans ~16 cells (0.7% > the 0.5% trigger area ✓),
but a ~4 mm hoverfly spans barely one cell (0.04% ✗ would NOT wake the
detector). New setting **Motion grid resolution** (32–128, default 48,
`motionGateGridSize`), with helper text giving exactly this math and the
advice to also lower Trigger area for very small insects.

Implementation: `MotionGate.GRID` const → `@Volatile var gridSize` (clamped
16–160 natively); comparison buffers are lazily (re)allocated **on the
analyzer thread** at the start of the next `motionDetected()` call when the
size changed (no cross-thread buffer swap), and the background is relearned.
Plumbed through `YOLOView.setMotionGate(gridSize=…)` → platform channel →
`YOLOViewController.setMotionGate(gridSize:)` → `SessionConfig.motionGateGridSize`
→ settings sheet → `_pushMotionGate()`.

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
42/42 (grid size added to the motion-gate round-trip + fallback tests);
`flutter build apk --debug` builds. On-device check (owner): mounted phone →
chip flips to grey "SLEEPING" ~3 s after motion stops and ROI border greys;
wave a finger over the flower → chip flips green "DETECTOR ON" within a frame
or two. Raising grid to 96 should make the motion % readout react to smaller
movements.

---

## Round 60 (2026-07-02): gate noise fix (supersampling), grid units/range, tabbed summary

Owner's first tripod test (indoors, orchid, no insects/wind; session_89):
grid 48 → detector never slept; grid 128 → slept correctly, woke on a hand
wave and slept again ~3 s later. That inversion (coarser grid = MORE
triggering) exposed a real sampling bug.

### 1. Root cause + fix: bilinear minification is point-sampling

Drawing the ROI into a 48×48 target shrinks ~8×, and Android's bilinear
filter only blends the nearest 2×2 source pixels — each thumbnail cell was a
near-point sample carrying full per-pixel sensor noise (large indoors at high
ISO), not the average of the ~64+ pixels the cell nominally covers. Scattered
noise flips > pixelDelta easily exceeded the 0.5% trigger area. At 128 the
shrink factor is mild, so samples covered most of each cell → calm.

Fix (`MotionGate.kt`): the ROI is now drawn **2× supersampled** (side =
2×grid) and each cell takes the mean luma of its 2×2 block — 4× noise-variance
reduction and, more importantly, consistent behaviour across grid sizes
(coarser = calmer, as intended). Cost at grid 160: 320² = 102k pixels, still
~1 ms.

### 2. Grid setting: units clarified, range widened

- The value is **cells per side of the comparison thumbnail** — a count, not
  pixels (and never cm). Each cell watches 1/N of the ROI *width*; an insect
  narrower than ~ROI-width/N may not register. Helper text and the
  `SessionConfig` doc now say exactly this in relative terms (the old "15 cm
  ROI" example was misleading — nobody knows their ROI in cm).
- Settings range widened 32–128 → **16–160**, matching the native clamp.

### 3. Session summary: four tabs

`session_summary_screen.dart` restructured with a `DefaultTabController`:
**Overview** (headline stats) | **Settings** | **Photos** | **Graphs**. The
graphs tab keeps its own scroll controller, the timeline-visibility tracker,
and the floating show/hide button (safe when unmounted: `_timelineKey.
currentContext` is null on other tabs). Photos/graphs stay lazy-loaded.

Settings tab additions: a **Heat management** group (auto-throttle, min
inference rate, duty target) and the **motion gate** rows (enabled, pixel
sensitivity, trigger area %, wake duration, grid resolution). The session
JSON always had these — `logStart` logs the whole `config` block — only the
display rows were missing.

### Notes

- Hand tremble waking the gate is *physics*, not over-sensitivity: trembling
  shifts every textured edge in the ROI, which is genuine frame-to-frame
  motion. The gate is a mounted-phone feature. If field wind-shake proves
  problematic, a possible future option is global-motion rejection (ignore
  frames where changes are spread uniformly across the ROI) — deliberately
  NOT added yet to protect recall.
- Claude cannot read `sessions/**` (owner's deny rule), so session_89 was
  diagnosed from the reported symptom + code; the mechanism fully explains it.

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
42/42; `flutter build apk --debug` builds. On-device (owner): with grid 48 on
the tripod the gate should now sleep indoors like 128 did; the Settings tab
of a new session's summary should list the gate + throttle rows.

## Round 61 (2026-07-02): per-photo capture path — min saved-size target + max-side cap

**Why.** Saved ROI photos feed a future insect classifier, so pixels on the
insect matter. The old `fullResPhotos` boolean was all-or-nothing: off, a
small ROI (small flower) saved uselessly tiny crops from the 640×480 stream
(e.g. 20% of frame width → 128 px); on, EVERY photo paid the still's costs —
brief camera stall (tracker-gap risk), ~0.3–1 s shutter lag, heat, and 1–2 MB
files when the ROI was big. Upscaling was rejected outright: enlarging pixels
invents no detail and would poison the classifier.

**What.** The source is now chosen per photo (owner picked "hybrid auto"):

- `SessionConfig.captureMode` (`auto`|`fast`|`still`, default `auto`),
  `minRoiSavedPx` (default 640, ÷32), `maxRoiSavedPx` (default 1280, ÷32,
  `0` = no cap). Legacy migration: `fullResPhotos:true` → `still`,
  `false` → `fast` (an old setup must not silently start taking stills);
  missing both → `auto`. `toJson` still writes the legacy key one round.
- `capture/roi_capture.dart`: pure `chooseCapturePath` + `savedSidePx` +
  `capSavedSidePx` (same ÷32/short-side math as all crop paths, so the saved
  size is predictable without decoding). Scheduler takes `fastCaptureFn` +
  `stillCaptureFn` + dims getters and decides per capture; auto uses the fast
  crop when it already meets the target, else a still; a failed still-size
  probe degrades to fast (a small photo beats none). Dart fallback `_cropJpeg`
  and native `MainActivity.cropRoiJpeg` (new `maxPx` arg,
  `Bitmap.createScaledBitmap` filtered) downscale above the cap — never up.
- Session screen: `_activePath` getter drives `_roiSourceWidth/Height`,
  `_maxRoiPx`, `_roiLogDims` and grid snapping, so the WYSIWYG readout stays
  truthful when the path flips mid-resize. Readout now shows the path and the
  cap ("ROI: 1888 px → saves 1280×1280 (still)") and a "⚠ below N px" tag when
  even a still can't reach the target — the honest fixes are physical (move
  closer / telephoto). Capture records add `path` + `saved_px`; ROI records
  add `roi_source`.
- Settings sheet: mode dropdown + two ÷32-snapped px fields with plain-language
  helper text; summary Settings tab shows the three rows (legacy row only for
  pre-r61 sessions).

**Known trade-offs (accepted).** On the default 640×480 stream, fast crops max
out at 480 px, so `auto` + 640 target sends most in-visit photos through the
still path — cost is bounded (photos only during visits, ≥ step apart, busy
flag serialises) but heat/FPS impact should be watched on the Xiaomi. Shutter
lag means still pixels lag `box_in_roi` slightly; mitigated by logging
(`total_ms`, per-photo `saved_px`/`path`), not solved.

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
59/59 (new: chooseCapturePath decision table, savedSidePx/capSavedSidePx math,
config migration); `flutter build apk --debug` builds. On-device (owner):
tiny ROI → readout "(still)" and stills saved at target size; large ROI in
still mode → files capped at 1280; watch FPS/thermal during a burst of stills.

## Round 62 (2026-07-03): ROI box geometry pinned to the stream grid

**Field test (session_95, Xiaomi, stream 1200×1600, still 3000×4000, auto /
min 1024 / max 1280) exposed a UX defect in round 61, not a crop bug.** The
two saved photos (512² and 608²) matched the logged ROI exactly — but the
owner never meant to set a box that small. Cause: the box's px readout,
resize slider and ÷32 snap grid all followed `_activePath`, so when shrinking
the box crossed the auto threshold the SAME box jumped scales mid-drag
("992 px" → "2464 px"; slider max 1184 → 2976). Reading the still-grid number
as if it were still the stream-grid number, the owner kept shrinking until
the box was ~17% of the frame width.

**Fix.** One scale for geometry, everywhere: `_roiSourceWidth/Height` are now
ALWAYS the analysis frame, so the box readout falls monotonically while
shrinking and the slider tops out at the stream's ÷32 short side (1184 here).
What the chosen source turns the box into is a separate label part from the
new `_savedSideNow` getter (still-crop snap math + max-side cap, mirrors the
native crop exactly): `ROI: 992×992 px → saves 1280×1280 (still)`, with the
"⚠ below N px" tag unchanged. The two post-probe `_snapRoiToSourceGrid()`
calls were removed (the grid no longer depends on the still); ROI records now
also log `saves_px` next to `roi_source` so post-processing never re-derives
file sizes from fractions. Crops, `chooseCapturePath`, and per-photo
`path`/`saved_px` logging are untouched.

**Also learned from session_95:** a full still takes ~2.4–2.9 s end-to-end on
the Xiaomi (`total_ms` in capture records), so still-path photos arrive ~3 s
apart even with a 1 s step — visitation math is unaffected (detections, not
photos, drive it) but expect fewer stills per visit.

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
59/59. On-device (owner): shrink the box across the auto threshold — the
first number must keep falling smoothly while "saves N×N (still)" appears and
holds at the cap; the pencil slider must max out at 1184 on this stream.

## Round 63 (2026-07-03): still-lag fix, cooler idle gate, single target side

Driven by the owner's session_96 field test + questions. Round 62 verified
good there (photos saved at 1280/1216/960 as displayed), but three problems
remained; all three fixes were approved and implemented together.

**1. Still-capture lag — root cause found and fixed.** Each still froze the
pipeline ~1.5 s (camera fps 25 → 4 → once 0.7). Logcat PerfMonitor blamed
`TakePictureRequest` running `wall=1570ms` ON THE MAIN THREAD: the plugin
passed CameraX's takePicture the main executor, and the callback then ran
`normalizeJpegOrientation` — a full 12 MP JPEG decode → rotate → re-encode —
before Dart ever saw the bytes. (ZSL was already active; the capture itself
was never the problem.) Fix, two parts:
- `YOLOView.stillExecutor` (single background thread) now receives the
  takePicture callback; results are marshalled back to the main thread for
  the platform channel. `capturePhoto` keeps its old semantics (upright JPEG)
  but does the heavy work off-main.
- New `capturePhotoRaw` (channel + controller) returns the still EXACTLY as
  delivered — unrotated + `rotationDegrees`/`isFront` — so the 12 MP frame is
  never rotated at all. `cropRoiJpeg` (MainActivity) maps the upright ROI
  into raw coordinates via `rawRectForUprightRect` (Kotlin mirror of the
  Dart original in `roi_capture.dart`, which carries the unit tests — keep in
  sync), region-decodes there, downscales to target, then rotates ONLY the
  small square (~15 ms instead of ~1.4 s). The Dart fallback `_cropJpeg` does
  the same, with an EXIF guard (skips mapping if the decoder already returned
  a portrait image). The session-start size probe stores UPRIGHT dims (swaps
  w/h for 90/270) so all downstream math keeps one frame of reference.

**2. Cooler idle (gate).** Owner observed the phone warming while "sleeping"
on a desk in preview. The detector truly slept, but every frame still paid
the YUV→RGB bitmap conversion (7–16 ms × ~30 fps) BEFORE the gate check.
`onFrame` now closes frames untouched while the gate is idle, sampling only
one per 200 ms for the motion check (~6× less idle conversion work; wake
latency ≤ ~0.2 s). Consequence: delivered/camera FPS legitimately reads ~5
while idle. A camera-open, screen-on phone will never be cold — but this
removes the main app-side heat source at idle.

**3. Single saved-side setting.** Owner found min+max confusing ("should be
just a single threshold"). `targetRoiSavedPx` (default 1024, ÷32) replaces
`minRoiSavedPx`/`maxRoiSavedPx`: it is both the auto-decision threshold and
the downscale cap, so photos save at EXACTLY the target whenever the ROI can
supply it, smaller (with ⚠) only when physically impossible. Uniform sizes
also suit the future classifier. The fast path now honours the cap too
(`captureRoiFromFrame`/`ImageUtils.cropRoiFromFrame` gained `maxPx`, so a
1184 px fast crop saves as 1024). Migration: old configs' `minRoiSavedPx`
becomes the target; summary shows legacy min/max rows only for old sessions.

**Also answered for the owner (session_96 review):** the low-res analysis
stream is genuine Android architecture, not a hallucination — the stream menu
comes from the HAL (`getOutputSizes(YUV_420_888)`), CameraX caps ImageAnalysis
near PREVIEW size when Preview+Analysis+Capture are bound
(`analysisStreamCeiling()`), and streaming 12 MP YUV for analysis would be
~0.5 GB/s + ~100 ms/frame conversion on a phone that already throttles.

**Verification:** `flutter analyze` clean (app + plugin Dart); `flutter test
test/pollinator` 66/66 (new: rawRectForUprightRect mapping incl. per-rotation
centring/bounds, target migration); `flutter build apk --debug` builds.
On-device (owner): (a) during a visit burst the preview/FPS should no longer
freeze per photo and stills should arrive faster than the old ~2.4–2.9 s;
(b) photos must still be upright and centred on the flower — if a crop comes
out sideways or shows the wrong region, the rotation mapping is the suspect
(check `rotationDegrees` in logcat and compare with the Dart tests);
(c) idle on the desk with gate on: delivered FPS ~5, phone noticeably cooler;
(d) all photos exactly 1024×1024 while the ROI readout shows no ⚠.

## Round 64 (2026-07-03): probe double-rotation fix, exact per-photo size in summary, gate idle rate exposed

**Session_97 mismatch diagnosed — one bug, three symptoms, photos themselves
fine.** Screen said "saves 1024", files were 992²; summary browser showed
1304×1304 (not ÷32). Root cause: round 63's size probe swapped w/h for
rotation 90/270 assuming raw (EXIF-blind) dims, but `probeJpegSize` decodes
with `package:image`, which HONOURS the EXIF orientation tag and already
returned the still upright (3000×4000) — the swap rotated it BACK to
4000×3000. Every prediction (readout, `saved_px`, `_roiLogDims`) then ran
against a 4000-px-wide frame while the native crop correctly used the
3000-px upright width: predicted `capSaved(snap32(f×4000)) = 1024`, saved
`snap32(f×3000) = 992` (crops upright + centred — the round-63 mapping
worked). The 1304 was the un-snapped `f×4000` from the ROI geometry record.
Fixes:
- `uprightStillDims(rot, w, h)` in `capture/roi_capture.dart` (unit-tested):
  swaps only when a sideways rotation reports landscape dims, so it is
  correct for BOTH EXIF-aware and EXIF-blind decoders; the probe now uses it.
  With correct dims the readout in session_97's situation would honestly say
  "saves 992×992 ⚠ below 1024" — slightly enlarge the box to get 1024 files.
- The summary photo browser now overrides its ROI-geometry estimate with each
  capture record's exact `saved_px`, so per-photo resolution always equals
  the file on disk (older logs without the field keep the estimate).

**Gate idle rate exposed (owner rule established).** Round 63's hardcoded
~5 fps idle sampling is now `motionGateIdleFps` (default 5, range 1–30):
SessionConfig + Settings field (gate tab) + summary row + native
`setMotionGate(idleFps)` → `gateIdleSampleNs`. Owner's standing rule, saved
to memory: EVERY new tunable ships user-adjustable, persisted in the config
JSON and shown in the summary, in the same round it is introduced.

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
70/70 (new: uprightStillDims both decoder behaviours, idleFps round-trip);
`flutter build apk --debug` builds. On-device (owner): readout, capture
`saved_px`, summary per-photo resolution and the file on the computer must
all show the SAME number; with no ⚠ visible that number is exactly 1024.

## Round 65 (2026-07-03): session_99 verified clean; error persistence; edit-sheet hardening; explainer doc

**Session_99 audit: rounds 63–64 confirmed working.** All 20 files match
their capture records exactly (1024² while the box met the target, honest
704² during a smaller-box phase that carried the ⚠), probe stored upright
3000×4000, stills ~0.8–1.5 s (vs 2.2–2.9 s pre-r63).

**Owner saw a brief unreadable error while opening the pencil ROI editor;
nothing in either logcat window.** Two responses:
- **Errors are now persisted**: new `SessionLogger.logAppError` →
  `{"type":"app_error","source":"detector"|"watchdog","message":…}` written
  whenever the red banner is raised (native detector errors auto-clear when
  the next frame succeeds, so they can flash briefly by design). "I saw an
  error but couldn't read it" is now answerable from session.jsonl.
- **Likeliest culprit hardened**: in a DEBUG build (all field builds are),
  the pencil sheet's Column could momentarily overflow while the keyboard
  animates in for the px text field — Flutter then flashes the striped
  "BOTTOM OVERFLOWED" banner, which reads like an app error. The sheet body
  is now a `SingleChildScrollView`, which cannot overflow. If the message
  reappears it will be in the log as `app_error`.

**New doc for collaborators:** `docs/HOW_PHOTO_RESOLUTION_WORKS.md` —
plain-language explanation of the two camera streams, why a 416 px on-screen
box can yield a genuine 1024 px photo (same box fraction cut from the 12 MP
still), the never-upscale rule, the label anatomy, and which JSON field to
trust (`saved_px`). Linked from the overview.

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
70/70; `flutter build apk --debug` builds. On-device (owner): open the pencil
editor and tap the px field — no striped banner should flash; if any error
appears again, `grep app_error session.jsonl` will contain its full text.

## Round 66 (2026-07-04): perf/robustness review + collaborator/user documentation set

**No code changes this round** — a review-and-document pass in response to the
owner's request to (a) suggest inference-speed improvements, (b) surface
robustness/refactoring opportunities for field deployment, and (c) add general
user + collaborator documentation.

**Performance & robustness review** written to
`docs/PERF_AND_ROBUSTNESS_REVIEW.md` as a prioritized, checkbox roadmap (nothing
implemented yet). Findings were gathered by reading the native hot path and the
Dart session code with file:line anchors. Headline items:

- *Speed (native):* the inference FPS-cap drop happens **after** the per-frame
  RGBA→Bitmap conversion (`YOLOView.onFrame`), so capped frames pay full
  conversion cost — hoist the drop like the motion-gate idle sampler already
  does; the analyzer thread blocks up to 100 ms per emitted frame on a
  main-thread `CountDownLatch` in `YOLOPlatformView.sendStreamData`; per-frame
  `Bitmap` (`ImageUtils.toBitmap`) and LiteRT output `FloatArray`
  (`LiteRtModel.readAsFloats`) allocations churn the heap; and the
  CPU-vs-GPU **startup benchmark named in CLAUDE.md does not actually exist** —
  `LiteRtModel` uses a static GPU-first try/fallback ladder, the "benchmark" is
  only a doc comment.
- *Robustness (Dart):* the per-frame log write (`SessionLogger._append` →
  `writeStringSync`) is **unguarded synchronous I/O in the frame callback** —
  storage-full or permission loss can crash a long session; `main.dart` has no
  global error trap; several fire-and-forget futures lack `.catchError`;
  lifecycle handling covers only `resumed` (no `paused`→flush); the watchdog
  catches detector-stall but not camera-delivery-stall; and a **config bug** —
  `occlusionSeconds` constructor default is `3.0` but the `fromJson` absent-key
  fallback is `1.0`, so legacy configs load the wrong occlusion buffer.
  `camera_session_screen.dart` (~2,590 lines) is a god-class with an extraction
  plan noted.

**New documentation** (all in `docs/`, filled first drafts sourced from the
code, TODO markers only where owner field knowledge is needed):

- `FIELD_GUIDE.md` — end-user session walkthrough (ROI placement, live UI
  meaning, blackout, summary, file retrieval) + field troubleshooting.
- `SETTINGS_REFERENCE.md` — plain-language entry per setting, cross-checked 1:1
  against the `SessionConfig` constructor defaults.
- `DATA_GUIDE.md` — full `session.jsonl` data dictionary (every record type,
  cross-checked against `session_logger.dart`) + R/Python snippets computing
  visitation rate and mean visit duration.
- `ARCHITECTURE.md` — native↔Dart data flow, the `pollinator/*` method-channel
  contract, the keep-in-sync pairs, and what the plugin fork changed vs upstream.
- `CONTRIBUTING.md` — build/test/analyze commands, device quirks (re-homed from
  the overview), the "every tunable ships user-adjustable + test" rule, doc
  maintenance rules, git etiquette, AGPL note, and a docs index by audience.

Rationale: much reference material (defaults, invariants, device quirks) had
lived **only** in `AGENT_CHANGELOG_OVERVIEW.md`, which is explicitly a rewrite-in-place
AI-grounding file — not durable human documentation. This round gives both
audiences (field researchers, collaborators) stable homes and leaves OVERVIEW as
the short grounding snapshot it's meant to be.

**Verification:** documentation-only round; no build/test needed and
`flutter analyze` untouched (no code changed). Settings entries and JSONL field
names were spot-checked against `session_config.dart` and `session_logger.dart`.

## Round 67 (2026-07-05): crash-proof logging + global error trap (review items B1 guard + B2)

Implements sequencing item 1 of `PERF_AND_ROBUSTNESS_REVIEW.md` — "a session
should never die silently". B5 was already done in round 66; this round adds
the **B1 guard** and all of **B2**. B1's batching/queueing follow-ups were
deliberately deferred (their checkboxes remain open in the review).

**B1 guard — the per-frame log write can no longer crash a session**
(`logging/session_logger.dart`):

- `_append`, `flushNow` and `close` are now wrapped: an I/O failure (storage
  full mid-session, permission revoked) is swallowed instead of throwing
  inside the per-frame detection callback. Failed lines are counted
  (`writeFailures`); writes keep being *attempted*, so if the user frees
  space the log simply resumes.
- New `onWriteError` callback fires **once** per logger on the first failure.
  The camera screen wires it to (a) a best-effort `app_error` line (lands if
  the failure was transient) and (b) a new persistent red banner
  (`_logWriteError`) telling the user storage is full — kept separate from
  `_inferenceError` because the watchdog auto-clears that one as soon as
  frames flow.
- `close()` is also best-effort so the stop sequence can always finish and
  `end_of_session` is never blocked by a failing flush.
- Test seam `debugInjectWriteError` + two new tests: failure path (no throw,
  notify once, counter, recovery after space is freed) and no-recursion when
  the `onWriteError` handler itself logs.

**B2 — global error trap** (new `logging/app_error_hooks.dart`, `main.dart`,
`camera_session_screen.dart`, `capture/roi_capture.dart`):

- `main()` now calls `installGlobalErrorHooks()` before `runApp`:
  `FlutterError.onError` (framework errors; default console dump preserved)
  and `PlatformDispatcher.instance.onError` (all uncaught async errors —
  returns `true`, so a background hiccup no longer kills the app/session).
  Both route into a module-level `appErrorSink`, rate-limited to one JSONL
  record per 2 s with a `suppressed_since_last` count and a 12-line stack
  head, so an error thrown per-frame cannot flood the log.
- The camera screen points `appErrorSink` at the live logger's `logAppError`
  when recording starts and clears it right after `_logger?.close()` in
  `_stopRecording` — so even stop-sequence errors leave a trace.
- `RoiCaptureScheduler.capture()` gained the missing `catch` (the
  Dart-fallback `compute()` crop and `writeAsBytes` were only inside
  `try/finally`) plus an `onError` sink; the screen wires it — and new
  `.catchError` handlers on `setInferenceRoi`/`setMotionGate` — to a small
  `_logAsyncError(source, error)` helper (debugPrint + `app_error` line).

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
73/73 pass (includes the 2 new logger failure-path tests). On-device smoke
test pending (owner).

## Round 68 (2026-07-05): native heat/latency wins (review A1 + A2) + free-storage readout

Implements sequencing item 2 of `PERF_AND_ROBUSTNESS_REVIEW.md`, plus an
owner-requested field feature: show how much storage is left on the phone.

**A1 — FPS-capped frames dropped before the bitmap conversion**
(`packages/ultralytics_yolo/.../YOLOView.kt` `onFrame`):

- When the motion gate is **off**, `shouldRunInference()` now runs *before*
  `ImageUtils.toBitmap`, so a frame the inference cap will discard never pays
  the RGBA→Bitmap copy (with a 10/s cap on a 30 fps camera, ~2/3 of all
  conversions were pure heat). The check is stateful (advances the cap
  clock), so its verdict is remembered in `inferenceApproved` and the old
  post-gate check is skipped for that frame — asking twice would veto its
  own approval.
- When the gate is **on**, behaviour is unchanged: every frame is still
  converted (the gate's background model must keep seeing frames; the review
  caveat), and the cap applies at its original position after the gate check.
- The per-second FRAMEPERF stats block moved above the new drop so
  `deliveredFps` — which feeds `cameraFps` in the stream data, the Dart
  camera watchdog, and the session FPS graphs — keeps meaning "frames CameraX
  handed the analyzer" (UI-numbers-one-scale rule). A new `convertedFps`
  value in the FRAMEPERF logcat line shows the savings, and `toBitmapMs` now
  averages over converted frames only (`perfConverted` counter).
- Accepted side effect: `lastFrameBitmap` (the fast ROI-photo crop source)
  refreshes at the capped rate, so a photo can be up to one cap interval
  (e.g. 100 ms at 10/s) older than before — same idea as the round 63 idle
  sampler, and photos are triggered by detections that happen at that rate
  anyway.

**A2 — camera thread no longer blocks on every result send**
(`packages/ultralytics_yolo/.../YOLOPlatformView.kt` `sendStreamData`):

- The old path posted the result to the main thread and parked the camera
  thread on `CountDownLatch.await(100 ms)` — and then *discarded* the latch
  result, so the wait bought nothing while stalling frame delivery whenever
  the UI was busy (photo saves, settings rebuilds).
- Replaced with a latest-result slot: an `AtomicReference` the camera thread
  overwrites plus a single posted drain runnable (guarded by an
  `AtomicBoolean`, flag cleared *before* draining so a result arriving
  mid-drain schedules a fresh drain). Dropping an overwritten stale detection
  frame is harmless; dropping camera frames was not. If the sink is gone at
  drain time, the existing `scheduleRetry`/`recreateEventChannel` path takes
  over; `stopStreaming` clears the slot.

**Free-storage readout (owner request):**

- New `getFreeStorage` method on the existing `pollinator/thermal` channel
  (`MainActivity.kt`, `StatFs` on the session volume, climbing to the nearest
  existing ancestor path) + Dart `logging/device_storage.dart`
  (`StorageReading`/`DeviceStorage`; never throws).
- Camera screen shows "Storage free: N.N GB" in the status strip (always GB
  with one decimal — one scale; ⚠ prefix under `StorageReading.lowGb` = 1 GB),
  sampled together with the temperature on the thermal cadence — no new timer,
  no new tunable.
- Logged: `free_storage_bytes`/`total_storage_bytes` in `start_of_session`
  and in every `thermal` record, so a session's disk fill rate is plottable.
  Docs updated (DATA_GUIDE, FIELD_GUIDE, ARCHITECTURE channel table).

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
76/76 pass (3 new `StorageReading` tests); `:ultralytics_yolo:compileDebugKotlin`
and `:app:compileDebugKotlin` both BUILD SUCCESSFUL. On-device check pending
(owner): confirm detector FPS holds with gate off/on, and that the storage
line appears and updates.

## Round 69 (2026-07-05): batched detection records + async writer queue (B1 fully closed)

Implements the two B1 follow-ups deferred in round 67, closing B1 completely.
Also answers the owner's question about detection temporal resolution (below).

**One JSONL line per frame** (`session_logger.dart`, `camera_session_screen.dart`):

- `logDetection` (one line per tracked insect per frame) is replaced by
  `logDetections`: one `"type": "detections"` record per processed frame with
  a `tracks` array — entry fields unchanged (`track_id`, `class_index`,
  `class_name`, `confidence`, `box_in_roi`), except `jpeg` is now present
  only on entries the saved photo actually covered (it was `null` elsewhere).
- **Schema change** — consumers updated to accept both shapes: the summary
  screen's visit-span parser and photo browser (`session_summary_screen.dart`)
  and the R/Python snippets in `DATA_GUIDE.md` (flatten `tracks[]`, then
  `rbind`/`concat` with legacy `detection` rows). Sessions recorded ≤ round 68
  keep working everywhere.

**Writes queued and drained off the UI thread** (`session_logger.dart`):

- `_append` now encodes the record and pushes the line onto an in-memory
  queue; a single async writer loop (started on demand, one at a time) joins
  everything queued in the same event-loop turn into ONE
  `RandomAccessFile.writeString` call. Dart executes async file I/O on the
  VM's background I/O thread pool, so a slow-flash hiccup stalls the writer
  loop, never the frame callback. (A dedicated isolate was considered and
  rejected: it would only move ~µs of JSON encoding per frame at the cost of
  real complexity — the I/O, which is the actual stall risk, is already
  off-thread this way.)
- Durability model preserved: records that asked for `flush` (start/roi/end/
  error) trigger an fsync after their batch; the frame path still requests
  one fsync per ~0.5 s via `flushNow()` (now returning a `Future` tests can
  await). The B1 failure guard carries over: a failed batch is dropped and
  counted (`writeFailures` += lines lost), `onWriteError` fires once, the
  loop keeps attempting so logging resumes if storage frees up.
- `close()` is now **async**: it drains the queue (including a last-gasp
  `app_error` from an `onWriteError` handler), flushes, then releases the
  handle — awaited in `_stopRecording` so `end_of_session` is on disk before
  the summary opens. Tests updated/extended (77/77 pass; new test covers a
  multi-track frame batching into one record with per-entry `jpeg`).

**Temporal resolution decision (owner question):** keep logging detections at
full processed-frame rate — no downsampling, no new tunable. Rationale: after
this round the UI-thread cost of detection logging is one small map build +
one `jsonEncode` per frame (~tens of µs), with disk I/O off-thread; data
volume is ~250–500 B per frame *with insects present* (~5–15 MB/h worst case
at 10 inference FPS with continuous occupancy — negligible next to the JPEGs),
and the full-rate track history is exactly what workstation postprocessing of
true visitation rates needs (visit durations, gap structure between track
fragments, box trajectories for filtering false tracks). If measurements ever
say otherwise, downsample in postprocessing, not at capture.

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
77/77 pass. On-device check pending (owner): record a short session with >1
insect, then confirm the summary's photo browser shows boxes/track ids and
the session graphs populate (both parsers now walk the new `tracks[]` array).

## Round 70 (2026-07-05): lifecycle hardening + camera-delivery watchdog (review B3 + B4)

Implements sequencing item 3 of `PERF_AND_ROBUSTNESS_REVIEW.md`.

**B3.1 — flush on backgrounding** (`camera_session_screen.dart`):
`didChangeAppLifecycleState` now also handles `hidden`/`paused`/`detached`
while recording → `_logger?.flushNow()`. If an aggressive OEM battery manager
(the Xiaomi test device's is one) kills the backgrounded app, the detection
loss window shrinks from ≤0.5 s to ~zero.

**B3.2 — stop sequence reordered critical-path-first**
(`camera_session_screen.dart` `_stopRecording`, `session_logger.dart`):

- `_recording` flips false at the START (plain assignment — this runs
  synchronously from `dispose()`, where `setState` is off-limits), so the
  frame path stops logging instantly.
- The end battery/thermal reads are time-bounded (2 s `timeout` each) and
  guarded: a platform channel hung mid camera-teardown can no longer stall
  the stop. Then, in order: `logEnd` → `await close()` (queue drained,
  `end_of_session` on disk) → `appErrorSink = null` → keep-alive service
  stop — and only after that the best-effort extras (`logcat_end.txt`,
  wakelock release), each in its own try/catch so being torn down mid-way
  can't abort later steps.
- New `_stopping` flag: `_recording` dropping early would have let a quick
  second tap fall into the "start recording" branch mid-teardown;
  `_toggleRecording` and `_stopRecording` now bail while a stop is in
  flight.
- `SessionLogger` gained a `_closed` latch: appends after `close()` (late
  detector events, a watchdog tick racing the stop) are silently dropped
  instead of throwing `StateError`. New test covers it (78/78 pass).

**B4 — camera-delivery watchdog** (`camera_session_screen.dart`):

- The round-65 watchdog catches "camera delivers, detector silent". The
  opposite — the camera itself dying (HAL crash, another app grabbing it,
  OS reclaim) — produced *no signal at all*, because it also stops the
  stream callbacks the old check lived in. The new check therefore rides
  the existing 1 s recording ticker.
- Every stream event stamps `_lastStreamEventMs` — including the ~1 Hz
  motion-gate idle heartbeats, so a deliberately sleeping detector never
  false-alarms. 10 s without any event while recording (constant
  `_cameraSilentAfterMs`, deliberately not a tunable) → one flushed
  `app_error` (source `watchdog`) + the red banner. If delivery resumes,
  the banner clears itself and a "delivery resumed" line is logged, so the
  outage is bracketed in the data.
- The optional camera rebind from the review was left out: the plugin
  exposes no safe rebind today; revisit if a field session actually hits
  this.

**Verification:** `flutter analyze` clean; `flutter test test/pollinator`
78/78 pass. On-device check pending (owner): normal stop still lands
`end_of_session` + summary; optionally background the app mid-session and
pull it back (log should show no gap), and the camera-lost banner can be
provoked by starting a recording and opening the system camera app on top.

## Round 71 (2026-07-05): ROI-size sheet fixes (owner report, session_107)

Field test of rounds 67–70 on the Xiaomi device (session_107, ~32 s, gate on,
GPU): data all healthy — batched `detections` records correct (227 frames /
297 track entries, all 13 photos referenced), `end_of_session` clean, storage
fields present, no watchdog false alarms. `convertedFps == deliveredFps` in
FRAMEPERF is *expected* here (motion gate enabled → A1 keeps converting every
frame for the gate's background model). The round-67 global error trap proved
itself: the owner's "split-second red screen" was captured as two `app_error`
lines with stacks, pinpointing the bug without a repro.

**Bug 1 — disposed-controller crash (the red flash):** `_editRoiSize` used an
inline StatefulBuilder and disposed its `TextEditingController` as soon as
`showModalBottomSheet`'s future completed — but the sheet still rebuilds
during its closing animation (keyboard inset animating away), and the builder
wrote `controller.text` to the disposed controller. Fix: the sheet is now a
real widget, `_RoiSizeSheet`, whose State owns the controller (+ FocusNode)
and disposes them when the widget is actually gone.

**Bug 2 — typed ROI sizes neither applied nor snapped:** the old field only
applied input via `onSubmitted` (the keyboard's submit action). Typing a
value and tapping Done applied nothing, and the field kept showing an
arbitrary, non-multiple-of-32 number that was never the real ROI. Fix, in
`_RoiSizeSheet`: digits-only input filter; typed values apply on keyboard
submit, on the field losing focus, AND on Done (applied before pop); every
apply snaps to the multiple-of-32 grid + clamps to min/max and **writes the
applied value back into the field**, so the number on screen always equals
the actual ROI size.

Observation, no action: session_107 carries 276 `roi_update` lines from
slider dragging — one per change is by design (post-processing needs the
exact ROI at every detection), and outside ROI adjustments they don't occur.

**Verification:** `flutter analyze` clean; 78/78 tests pass. On-device check
pending (owner): open the pencil sheet, drag the slider, type a non-multiple
(e.g. 1000) and tap Done — the field should snap (→ 992), the ROI should
resize, and no red flash should appear while the sheet closes.

## Round 72 (2026-07-06): per-frame buffer reuse (review A3)

Perf review item A3, all native Kotlin in the ultralytics plugin. Goal: stop
allocating multi-megabyte objects on every camera frame, so the garbage
collector (the runtime's periodic memory sweep, which pauses the app briefly)
runs far less often over a multi-hour session.

**Bitmap reuse (`ImageUtils.kt`, `YOLOView.kt`):** new
`ImageUtils.BitmapFrameBuffer`, one instance owned by `YOLOView`. Instead of
`toBitmap` creating a fresh Bitmap per frame (and a second one when the
camera pads its rows), the converter keeps one published bitmap plus a
private staging bitmap for the row-padded case and overwrites them in place;
it reallocates only when the stream size changes (old bitmaps are left for
the GC, never recycled, since a photo crop may still hold one). The
YUV_420_888 fallback path still allocates — its JPEG round-trip does anyway,
and it's a rare legacy path. `YOLO.kt`'s single-shot path keeps the old
allocating `toBitmap` (its result may be held by the caller).

**The safety wrinkle:** the converted bitmap doubles as `lastFrameBitmap`,
the fast ROI-photo source that `cropRoiFromFrame` reads from the
platform-channel thread. With reuse, the camera thread now *overwrites* that
bitmap while a photo crop may be reading it — a torn (half-old/half-new)
photo. Fix: writer (`BitmapFrameBuffer.convert`) and reader
(`cropRoiFromFrame`'s source draw — only the draw, not the JPEG encode) both
`synchronized` on the bitmap instance. The camera thread can block only for
the few ms of a crop draw, at most once per photo (photos are ≤1/s); for
fresh bitmaps the lock is uncontended and free. Same-thread readers (motion
gate, model preprocessing) need no lock. `MotionGate` was checked: it copies
the ROI into its own persistent `ssBitmap` synchronously, so reuse is safe.

**Model-output reuse (`LiteRtModel.kt`, `Predictor.kt`):** `readAsFloats` now
widens integer outputs (INT/INT8/INT64) into reused per-output `FloatArray`
targets — valid until the next `run()`, the same contract `OrtQnnModel`
already established for the NPU path. `widenToFloats` gained an optional
destination parameter. **Honest caveat:** the float path *cannot* mirror
`OrtQnnModel` — LiteRT 2.x `TensorBuffer` exposes only `readFloat():
FloatArray`, which allocates a fresh array inside the runtime on every call
(verified with `javap` against the litert 2.1.5 AAR; write* methods take
arrays, read* methods only return new ones). All shipped models have float
outputs, so that one per-inference allocation stays until the LiteRT API
grows a read-into-buffer variant; noted in the review doc for a future
revisit.

**Verification:** `flutter build apk --debug` compiles clean (only the
pre-existing KGP/fetch-script warnings); 78/78 tests pass (no Dart touched).
On-device check pending (owner): run a session with time-lapse photos and
confirm photos look whole (no tearing), detections unchanged, and FRAMEPERF
`toBitmapMs` similar or lower.

## Round 73 (2026-07-06): god-class split (review B6, all four steps) + B8 tests

**What was asked:** implement review item B6 — split `camera_session_screen.dart`
incrementally and behaviour-preservingly — plus the two still-open B8 test gaps
(`RoiCaptureScheduler.evaluate()` and the motion-gate `expireLostTracks` trigger,
which B6(a) makes testable).

**The split (new `lib/pollinator/session/`):**

- **B6(a) `frame_processor.dart` — `FrameProcessor`.** A plain class (no widgets,
  no timers, no platform calls) owning the per-frame pipeline state that isn't UI:
  `process()` maps native detections (ROI-normalized when the native crop is
  active, else full-frame filtered by ROI centre) onto the frame, confines them to
  the ROI, drops degenerate slivers, and advances the ByteTracker, returning a
  `FrameResult` (tracks, roiRect, trackMs, timestamp); `setGateIdle()` holds the
  motion-gate idle state and expires lost tracks when a sleep exceeded the
  occlusion tolerance, returning a `GateChange` for the screen to log;
  `updatePipelineFps()` keeps the smoothed pipeline-FPS estimate. The clock is
  injectable so tests can fake long gate sleeps. `forceGateAwake()` mirrors the old
  "gate disabled while idle" bypass (no logging, no expiry — exactly as before).
- **B6(b) `session_recorder.dart` — `SessionRecorder`.** Owns one session's disk +
  lifecycle work: session folder resolution (`sessions/<name>[_N]`), JSONL logger
  open/close + `onWriteError` app_error line + `appErrorSink` routing, the start
  record (device/battery/storage/thermal read here; screen-state fields supplied
  via a `startMetadata()` callback so key order and values match the old record
  exactly), the `RoiCaptureScheduler` via a `captureBuilder` callback (capture
  functions and ROI provider are screen wiring), wakelock + notification permission
  + keep-alive service, the ordered stop sequence (unchanged: recording=false
  first, time-bounded end readings, logEnd, close, sink off, keep-alive down,
  logcat_end, wakelock off), `recordFrame()` (one `detections` record per frame,
  ~0.5 s flush cadence, shared-photo trigger — returns true so the screen can
  blink the capture cue), and `saveLogcat()`.
- **B6(c) `camera_diagnostics_controller.dart` — `CameraDiagnosticsController`.**
  The six one-time probes (still size incl. analysis-frame fallback, manual-focus
  support, stream resolutions, analysis ceiling, available lenses + persisted-lens
  snap, per-camera diagnostics) plus `cycleLens()`. A `_disposed` flag replaces the
  screen's `mounted` guards; results land in plain fields and fire one `onChanged`
  (screen: `setState`).
- **B6(d) widgets:** `_CalibratingBanner` → `widgets/calibrating_banner.dart`,
  `_SessionInfoDialog` → `widgets/session_info_dialog.dart`, `_RoiSizeSheet` →
  `widgets/roi_size_sheet.dart` (now public, otherwise verbatim).

**How the screen stayed behaviour-identical:** it keeps its original vocabulary
through thin getters (`_recording`, `_logger`, `_gateIdle`, `_captureWidth`,
`_lenses`, `_minFocusDistance`, …) mapping onto the three collaborators, so the
~480-line `build()` and every read site are textually unchanged; only write sites
and the moved method bodies changed. The screen went ~2,870 → ~2,180 lines.
Ordering was preserved deliberately: the once-a-second housekeeping (tracker-param
re-derivation, throttle update, PERF debug line) still runs BEFORE the tracker
update, so updated params apply from this frame and the PERF line still shows the
previous frame's tracker cost, exactly as before. Two accepted micro-deviations,
noted in the review doc: session/REC timers now start a few ms later (after
`SessionRecorder.start()` returns instead of between keep-alive start and the
logcat snapshot), and probe results now rebuild via a plain `setState(() {})`
instead of field-assigning setStates (same rebuild, same values).

**B8 tests (both remaining items closed):**

- `test/pollinator/roi_capture_scheduler_test.dart` — `evaluate()`: first-sight
  photo with deterministic `roi_<session>_<ts>.jpg` name; step interval counted
  from the last photo; per-track duration window; ONE shared photo for concurrent
  due tracks; a late-starting track gets its own full window; a momentary lost
  blip does NOT reset an expired window (the id-reuse double-capture guard); the
  window is forgotten only after the id is gone longer than the duration; and
  `evaluate()` returns null while a capture is in flight (busy flag, tested with a
  Completer-gated capture function).
- `test/pollinator/frame_processor_test.dart` — mapping (full-ROI and half-ROI
  boxes land exactly on/inside the ROI rect; fallback path filters by ROI centre
  and clamps), clock fallback, and the gate rule: waking after a sleep longer than
  the occlusion tolerance expires lost tracks (a returning insect gets a fresh id)
  while a shorter sleep keeps the old id revivable; no-op re-reports; the
  `forceGateAwake` bypass; pipeline-FPS EMA.

**Verification:** `flutter analyze lib/pollinator test/pollinator` → no issues;
`flutter test test/pollinator` → 95/95 pass (78 before, 17 new);
`flutter build apk --debug` → ✓ (only the pre-existing KGP deprecation warning and
missing `fetch_bundled_models.sh` note, both unrelated). On-device check pending
(owner): start/stop a short session, confirm the JSONL start/end records and
time-lapse photos look as before, lens/focus/settings probes populate, and the
motion-gate indicator behaves.

**Docs:** review doc B6 (a–d) and both open B8 boxes ticked with done-notes;
overview module map gained the `session/` row and the widgets/tests updates.

## Round 74 (2026-07-07): rasterize the ROI once per frame (review A5)

**What was asked:** implement review item A5 — while the motion gate is awake,
the same ROI was being drawn out of the camera frame twice per frame: once by
`MotionGate.motionDetected` into its tiny supersampled thumbnail, and again by
`ObjectDetector.predict` into the model-input bitmap.

**Design (which direction to share):** the review offered "downscale the
model-input bitmap for the gate, or vice versa". Only the first direction is
viable, and only on frames that actually run inference:

- The model input must stay full quality, so it can never be derived from the
  tiny gate thumbnail.
- On **idle** frames (gate asleep, sampling a few frames/s) and on **awake but
  FPS-capped** frames, the detector never rasterizes anything — forcing a
  640×640 model raster there just to feed the gate would cost ~45× more
  destination pixels than the gate's own ~96×96 draw. Those frames keep the
  direct path, which also keeps the background-EMA cadence unchanged (the gate
  still sees every converted frame while awake).
- On frames that **do** run inference, the model input already contains the
  rasterized ROI (a square ROI letterboxes into the square model input with
  zero padding, so the ROI is exactly the centered square — the whole bitmap
  for square models). The gate now downscales that instead of touching the
  camera frame again.

**How it's wired (all Kotlin, plugin + view):**

- `MotionGate.kt`: shared tail extracted (`ensureBuffers()` grid realloc +
  `scoreThumbnail()` fold/compare/EMA); new entry point
  `motionDetectedFromModelInput(modelInput)` draws the centered square of the
  model input into the supersampled thumbnail (reused `Rect`s + filter paint,
  allocation-free). The r60 2×-supersample noise averaging applies identically;
  for typical ROIs the model input is an *upscaled* (smoother) copy, so this
  path is if anything calmer than the direct one.
- `Predictor.kt` (`BasePredictor`): new `open fun lastRoiModelInput(): Bitmap?`
  (default null). Valid only on the analyzer thread until the next `predict`
  overwrites the reused buffer.
- `ObjectDetector.kt`: overrides it, returning `scaledBitmap` only when the
  last `predict` actually took the ROI branch (`lastPredictUsedRoi`).
- `YOLOView.onFrame`: the gate block now branches on wake state first. Awake →
  consult the FPS cap once (stateful — the old code consulted it once too, just
  later); approved frames set `gateFromModelInput` and run the gate right
  after `p.predict(...)` from `lastRoiModelInput()` (falling back to the direct
  draw if no ROI is set or the predictor doesn't expose its input); capped
  frames run the direct gate and close. Idle frames keep the old direct
  check-heartbeat-or-wake behaviour. The triplicated `motionDetected(...)`
  argument list moved into a `gateMotionFromFrame()` helper.

**Behaviour deltas (intended, small):** on inferred frames the motion check now
runs a few ms later (after inference, same frame data, same wake-extension
semantics); the gate thumbnail on those frames is resampled via the model input
instead of straight from the frame, so its pixel values differ slightly from
the idle/capped path (well under the default `pixelDelta` 25 — no observed
effect expected, worth a glance at gate behaviour on the next field test).
Everything else — cap accounting, `perfInferred`, heartbeat, detection-keeps-
awake, `motionScore` in stream data — unchanged.

**Verification:** `flutter build apk --debug` → ✓ compiles (pre-existing KGP
deprecation warning only); `flutter analyze lib/pollinator test/pollinator` and
`flutter test test/pollinator` untouched by a Kotlin-only change but re-run →
clean / 95/95. On-device check pending (owner): with the gate enabled, confirm
"DETECTOR ON"/"SLEEPING" transitions and the motion score still behave during a
short session.

**Docs:** review A5 ticked with a done-note; overview motion-gate bullet gained
the shared-raster sentence and the sync line moved to round 74.

## Round 75 (2026-07-08): review A6 small-cleanups batch (Kotlin-only)

All four A6 items from `PERF_AND_ROBUSTNESS_REVIEW.md`, batched as the review
suggested. Behaviour-preserving; no Dart touched.

1. **Orientation read once per frame** (`YOLOView.kt`). `onFrame` used to ask
   `context.resources.configuration.orientation` up to three times per frame
   (frame-cache write, `gateMotionFromFrame` — the round-74 helper that
   inherited one of the reads — and the inference block). A single
   `frameIsLandscape` val is now computed right after bitmap conversion and
   passed everywhere; `gateMotionFromFrame` takes it as a parameter instead of
   reading it itself. Resources/Configuration lookups aren't free and this ran
   on the camera analyzer thread 10–30×/s.
2. **Stream-data map copy dropped, hot maps pre-sized** (`YOLOView.kt`).
   `convertResultToStreamData` now returns `HashMap<String, Any>` (pre-sized to
   32) and `onFrame` enriches that same map in place — the per-frame
   `HashMap<String, Any>(streamData)` full copy is gone. In the detect-box loop
   (the only branch this app streams) the per-detection map (12) and the two
   4-entry box maps (8) are pre-sized so they never rehash mid-build; the
   `detections` list is sized to `result.boxes.size`. Pose/OBB/classification
   branches deliberately untouched.
3. **Pixel-normalization lookup table** (`ImageUtils.kt`). A "lookup table"
   (LUT) is a precomputed array: since a colour channel can only be one of 256
   values, the normalized float for each value is computed once into a
   256-entry array and the per-pixel loop becomes three array reads instead of
   three subtract+divides. Applied to `copyRgbBitmapToFloatArray` (the LiteRT
   2.x path all predictors use) and the `copyRgbBitmapToFloatBuffer` sibling.
   The table is cached in the `ImageUtils` object and rebuilt only if a caller
   passes different mean/std (none currently does); copies only run on the
   camera analyzer thread, so no locking is needed.
4. **`includeOriginalImage` documented as a footgun.** ⚠️ comments now sit at
   the flag definition (`YOLOStreamConfig.kt`) and at the encode site in
   `convertResultToStreamData`: enabling it JPEG-encodes the FULL camera frame
   at quality 90 on every streamed frame, on the camera thread. The app never
   enables it (ROI photos have their own capture path) — the comments exist so
   nobody flips it on casually.

**Verification:** `./gradlew :ultralytics_yolo:compileDebugKotlin` → ✓ clean.
No Dart changes, so analyzer/tests unaffected. Stream-map change is
shape-identical on the wire (same keys, same values — only allocation pattern
changed), so no on-device check is strictly required; behaviour will get
covered incidentally by the next field session anyway.

**Docs:** all four A6 boxes ticked with done-notes; overview sync line moved to
round 75 and its stale "nothing implemented yet" note on the review pointer
replaced (A1/A3/A5/A6/B6/B8 are done as of this round).

## Round 76 (2026-07-08): user-triggered engine benchmark (review A4) + CPU thread tunable (A7 correction)

Owner redefined A4's design: the CPU-vs-GPU benchmark must NOT run
automatically at session start (it costs seconds of full-speed inference and
heats the phone). Instead it is an explicit action the user takes when it
matters — typically after switching models. CLAUDE.md's "Hardware
Acceleration" spec bullet was updated to match.

**A7 correction (checked before building anything):** the review's claim that
LiteRT 2.x has "no CPU thread-count or XNNPACK tuning surface" is wrong for
the litert 2.1.5 we ship — `javap` against the AAR shows
`CompiledModel.CpuOptions(numThreads, xnnPackFlags, xnnPackWeightCachePath)`.
Also clarified for the owner: **XNNPACK is not something to "implement" — it
is already the default CPU engine inside LiteRT.** The only meaningful knob is
its thread count, which is exactly what this round exposes and what the
benchmark measures. `xnnPackFlags` left untouched (exotic); the XNNPACK weight
cache deliberately skipped — a mid-write kill could leave a corrupt file that
native code re-reads at next launch with no crash-guard, for a small
load-time-only win.

**Native (Kotlin):**

- `LiteRtModel` takes `cpuThreads: Int = 0` (0 = runtime default) and sets
  `CompiledModel.CpuOptions(numThreads=…)` on CPU compiles. Plumbed through
  `InferenceModel.create`, all six predictors, `YOLOView.setModel` (also part
  of the predictor cache key), and `YOLOPlatformView` (creation params + the
  in-place `"setModel"` call).
- `YOLOPlugin` gains `"benchmarkAccelerators"`: resolves the model path, then
  on a dedicated thread compiles once per configuration — GPU, then CPU per
  thread variant (default 0/2/4) — and times 20 inferences each after 3
  warm-ups, fixed-seed random input. Reuses `LiteRtModel`, so the GPU attempt
  inherits the compile crash-guard, 2-strike blocklist and program cache; a
  blocklisted model reports "GPU unavailable" instead of retrying. Returns
  label/accelerator/avgMs/minMs/compileMs or an error string per config.
- Fixed in passing: `YOLOViewController.switchModel` never passed `useGpu`, so
  an in-place model switch silently reverted to GPU-first regardless of the
  session setting. It now passes `useGpu` and `cpuThreads` from the widget.

**App (Dart):**

- `YOLO.benchmarkAccelerators(modelPath)` static in the plugin (resolves
  asset models to real files first, same as the live view).
- `SessionConfig.cpuThreads` (default 0), persisted + copyWith + JSON.
- Settings → AI: "CPU threads (0 = automatic)" numeric field and a
  "Benchmark engines (GPU vs CPU)" button (spinner while running, ~10–30 s);
  results dialog lists each configuration's ms/inference and offers
  "Use <fastest>" — GPU winner sets `useGpu=true`, CPU winner sets
  `useGpu=false` + its thread count. Helper text warns the live preview keeps
  detecting during the benchmark, which can slow all numbers slightly but not
  their ranking.
- Session metadata logs `cpu_threads`; summary screen shows
  "CPU threads (0 = automatic)" under Model & detection.

**Verification:** `flutter analyze lib/pollinator test/pollinator
packages/ultralytics_yolo/lib` → clean; `flutter test test/pollinator` →
95/95; `flutter build apk --debug` → ✓ (pre-existing fetch_bundled_models.sh
warning only). On-device check pending (owner): run the benchmark on the
Xiaomi with yolo26n, confirm GPU/CPU numbers look sane and "Use <fastest>"
updates the two controls.

## Round 77 (2026-07-09): gate-idle honesty pass (session_120 findings)

Owner field-tested round 76 (session_120, arthropod_yolov11_int8 320px, GPU,
uncapped, motion gate on, phone charging). Three findings, three fixes, plus
a factual correction.

**Finding 1 — stale numbers while the gate sleeps.** With the detector asleep,
the UI showed "Pipeline: ~11–12 fps" and the per-second `fps` records kept
logging `pipeline_fps=11.7`, `inf_ms=7.2`, `fps=11.5` — all frozen last-awake
values, NOT live work (native FRAMEPERF proved `inferredFps=0.0`,
`deliveredFps≈4.6` throughout the idle stretch; 436 of 503 fps records were
affected). Causes: the gate-idle heartbeat branch reused `pipelineFpsEma` and
never cleared `_fpsVN`/`_perfVN`/`_lastTrackMs`; the EMA itself never decays
without callbacks. Fixes:
- `FrameProcessor.setGateIdle(idle=true)` resets the pipeline EMA and its
  timestamp (also stops the first post-wake frame averaging across the gap).
- The heartbeat branch zeroes `_fpsVN`, `_perfVN`, `_lastTrackMs` and the
  trio's pipeline slot — on-screen Pipeline now reads 0 while sleeping.
- `_sampleFps` while gate-idle **omits** every inference-derived field
  (`fps`, `detector_fps`, `pipeline_fps`, `pre_ms`, `inf_ms`, `post_ms`,
  `track_ms`) and writes `gate_idle: true` instead; `camera_fps`, `engine`,
  throttle fields stay. Owner's explicit preference: absent = gate idle
  (missing data for stats), present = the detector really ran at that value.
- Summary-graph painter breaks the polyline across sampling holes (gap > 3×
  the series' median interval, floor 3 s) instead of drawing a bridge that
  looks like data. Graph parsing already skipped absent fields, so old
  sessions render unchanged.

**Finding 2 — phone warms while "sleeping" (no bug).** Session thermal log:
31→36 °C, but `is_charging: true` the whole session at ~2–6.5 W — charging
alone is a heater. Beyond that, the camera sensor+ISP keep streaming at
30 fps for the live preview (only the analyzer drops to ~4.6 fps sampled
frames), the screen is on, and the gate costs one bitmap conversion (~4.7 ms)
+ tiny grid diff 5×/s. No zombie AI threads — FRAMEPERF shows inferred=0.
Told owner: unplug during sessions if heat matters; the gate is emphatically
still worth it (the detector at uncapped GPU speed is far hotter).

**Finding 3 — benchmark dialog units unclear.** Result lines now read
"X ms per inference — up to ~N inferences/s" and the footer explains: ms per
inference = one frame through the model, averaged over the timed runs; the
/s figure is 1000÷that, a back-to-back ceiling, not the session rate.

**Correction — "int8 can't use GPU" was wrong (my error, round 76 summary).**
Session_120 proves `arthropod_yolov11_int8` compiles and runs on the Adreno
GPU ("LiteRT compiled on GPU", engine=GPU all session). GPU-vs-CPU fallback
is decided per model by whether the GPU backend can compile that graph —
never by dtype; the GPU dequantizes int8 internally. Purged the three stale
"int8 → CPU" comments (YOLOView.kt accelerator note, LiteRtModel.kt header,
camera_session_screen metadata comment) that seeded the myth.

**Verification:** analyze clean; 95/95 tests; `flutter build apk --debug` ✓.
On-device check pending (owner): sleep the gate and confirm Pipeline reads 0,
end-of-session FPS/inference graphs show real gaps, and fps records during
idle carry `gate_idle: true` with no `inf_ms`.

## Round 78 (2026-07-09): benchmark transparency (input size + duration) + idle-heat analysis (session_122)

**Benchmark questions (owner):** what resolution do the benchmark timings
apply to, and how long does the test take?
- The benchmark never touches camera frames: the native side generates
  fixed-seed random noise at **exactly the model's input tensor size**
  (e.g. 320×320 for arthropod_yolov11_int8, 640×640 for yolo26n). No
  downscaling happens and none is included in the timings — they are pure
  model-execution time. In a real session the capture/downscale cost shows
  up separately as `pre_ms`.
- Changes: `benchmarkAccelerators` now returns `inputDims` per config; the
  results dialog header shows "Model input: W×H px · benchmark took N s"
  (Dart stopwatch around the call), and the dialog/footer texts spell out
  the noise-input detail and the 3 warm-up + 20 timed runs per config.
- Kept **iteration-based** (not user-set seconds): with 20 runs the average
  is already stable (min vs avg spread is visible in the log), and a longer
  benchmark mostly measures thermal drift — which would make configs run
  later in the list look unfairly slow. Can add a user knob later if wanted.

**Idle warming is real and not charging (session_122).** On battery,
motion gate idle for the entire 6.8 min (detector ran 0 frames), the phone
still drew a steady **~4.4 W** and warmed 30→35 °C. That draw is the
always-on baseline the gate cannot remove: camera sensor + image processor
streaming 30 fps for the live preview (only the *analysis* stream drops to
~5 fps while idle), the screen at field brightness, display compositing,
and system base load. The gate removes the detector's *additional* load
(which previously drove thermal collapse in ~25–30 s uncapped — round 55
sessions), so it is working as designed. Mitigations available today:
blackout power-save mode (drops brightness to minimum while recording).
Roadmap candidate (NOT implemented): request a lower CameraX frame-rate
range while the gate is idle, to cut sensor/ISP load — the preview would
visibly stutter while asleep.

**Docs:** overview updated in place (CPU-threads defaults row, benchmark
note in the GPU/CPU invariant, r77 gate-idle logging note, roadmap pointer
now lists A4). Verification: Kotlin compiles, analyze clean, 95/95 tests,
`flutter build apk --debug` ✓.

## Round 79 (2026-07-10): silent catches leave a trace (review B7) + B9 closed — review complete

- **B7:** added `logSwallowed(site, error, [stack])` to `logging/app_error_hooks.dart`:
  debugPrints at most once per 10 s per site (debugPrint reaches logcat, so failures
  land in the session folder's `logcat_end.txt`), and forwards to the existing
  rate-limited `app_error` JSONL sink while a session is recording, with the site
  name as `source`. `resetAppErrorRateLimitsForTest()` added for tests.
- Routed all ~30 legitimately best-effort `catch (_) {}` sites through it, with
  stable site names, e.g.: camera probes (`still_size_probe`, `min_focus_probe`,
  `stream_resolutions_probe`, `analysis_ceiling_probe`, `lens_probe`,
  `camera_diagnostics_probe`), recorder stop path (`end_thermal_read`,
  `wakelock_disable`, `save_logcat`, `battery_level`, `device_info`), keep-alive
  channel (`battery_optimizations_query`/`_request`, `keepalive_<method>`),
  periodic readers (`thermal_read`, `storage_read` — rate limit matters here),
  `config_load`, `logcat_capture`, `native_still_crop` (Dart fallback still saves
  the photo), `models_dir_external`, `model_import_copy`, `model_delete`,
  `model_inspect`, `screen_dim`, `screen_brightness_reset`, home/summary scans
  (`session_list_scan`, `session_duration_scan`, `error_report_build`,
  `summary_stats_scan`, `summary_graphs_scan`, `summary_photos_scan`),
  `reports_dir_external`.
- Three deliberate silents remain: the reporter's own recursion guard in
  `app_error_hooks.dart`, and the two per-line `_tryDecode` JSONL parse guards
  (truncated lines are expected after a crash) — commented "B7-reviewed" so a
  future grep knows they were assessed. `SessionLogger.close()` uses a plain
  debugPrint because the logger cannot write to itself while closing.
- New `test/pollinator/app_error_hooks_test.dart`: sink routing, rate-limit
  suppression, no-session/throwing-sink safety. Suite: 98 tests green;
  `flutter analyze` clean.
- **B9 closed without a code change:** the duplicated `_fpsTrioVN` assignment is
  intentional since round 77 (gate-idle zeroing), and the two per-frame closures
  moved into the unit-tested `FrameProcessor.process` in round 73; hoisting two
  tiny allocations at ≤10 fps would only hurt readability.
- With B7/B9 done, **every item in PERF_AND_ROBUSTNESS_REVIEW.md is now ticked**.

## Round 80 (2026-07-10): session storage size in the previous-sessions list

- Each entry in the home screen's "Previous sessions" list now shows how much
  storage the whole session folder uses (log + JPEGs + diagnostic files),
  right-aligned on the date line with a small storage icon.
- `_PastSession` gained `sizeBytes`; `_loadSessions` sums it per folder via the
  new `_folderSizeBytes()` (recursive `dir.list`, metadata-only — no file
  contents are read, so it stays quick even with thousands of photos; errors go
  through `logSwallowed('session_size_scan', …)`).
- `_formatBytes()` picks the unit by magnitude — "412 KB", "8.3 MB", "1.2 GB"
  (1024-based, same convention as the problem-report `humanSize`, extended to
  GB because photo-heavy sessions can reach gigabytes).
- UI-only change: no new tunables, no SessionConfig/log-format change.
  `flutter analyze` clean, all 98 tests pass.


## Round 81 (2026-07-11): live adb thermal diagnosis — where "sleeping" heat actually comes from

Owner question: even with the motion gate asleep (phone face down, no motion) the
phone warms significantly — is the gate not helping? Diagnosis was run **live over
adb** on the Xiaomi (Claude Code drove the UI via `input tap` + screenshots and
sampled thermal zones / per-process CPU every ~18 s; session_124, 10 min recording,
gate asleep the whole time, 0 tracks — safe to delete).

**The gate itself is working perfectly.** While asleep: `FRAMEPERF` showed
convertedFps≈4.5, inferredFps=0, toBitmap≈5 ms → the app's frame pipeline uses
~2–3 % of one core. Inference contributes nothing to idle heat.

**The heat is the standing cost of everything around the detector** (phase-mean
numbers; CPU % of 800 total; temps °C):

| Phase | camera HAL CPU | app CPU | total CPU | skin (quiet_therm) | battery |
|---|---|---|---|---|---|
| Idle baseline (app closed) | 0 | 0 | ~40 | 41.7 | 32.0 |
| Camera preview open | ~200 | ~75 | ~410 | 44→47.5 (50 s) | 33 |
| Recording, gate asleep, bright | ~210 | ~85 | ~440 | 49.6→55.7 (5 min) | 33→38 |
| Recording, gate asleep, power-save dim | ~230 | ~100 | ~490 | 56.4→57.9 (plateau) | 38→40 |
| Stopped (summary screen) / cooldown | 0 | 0 | ~60 | 58.4→45 (8 min) | 40→36 |

- **Camera subsystem ≈ 2 full cores** (`vendor.qti.camera.provider`): sensor + ISP
  stream 30 fps regardless of the gate (1080×1440 analysis + preview + ZSL still
  ring buffer). This is the dominant heater and confirms round 78's ~4.4 W estimate.
- **App process ≈ 1 core even in power-save mode** — the black scrim drops
  brightness but the preview surface + Flutter compositing keep rendering; dim
  mode produced **no** CPU reduction and only a small thermal one.
- CPU junction hit 69–73 °C, MIUI cooling level escalated 10→18 (big core pinned
  at 844 MHz). Note the phone throttles at level 9–10 **at idle before launch**
  (charging at 100 % + USB tethering modem: pa_therm 39–43 °C baseline) — field
  runs start from a warm floor even "doing nothing".
- **Config observation:** owner's saved stream is 1080×1440, but with ROI 480 px →
  target 1024 the per-photo path is *still* anyway, so the big analysis stream buys
  no photo sharpness and costs ISP/conversion work. Dropping stream to 640×480
  should be a free heat win in this configuration.

**Proposed next steps (not implemented — owner to choose):**

1. Stream back to 640×480 (settings only, no code).
2. Camera2Interop `CONTROL_AE_TARGET_FPS_RANGE` ≈ 10–15 fps for the session
   (inference is capped at 10 anyway) — cuts sensor/ISP load; roadmap item from r78.
3. Power-save mode could *unbind the Preview use case* + pause stats UI instead of
   just a scrim (app ~1 core → near 0; also removes one HAL output stream).
4. Evaluate unbinding/disabling ZSL ImageCapture while the gate is idle (part of
   the HAL standing cost; rebind-on-wake latency needs measuring).
5. Field hygiene: don't charge during sessions; disable USB tethering/hotspot.

Raw samples: scratchpad `thermals.csv` (session-ephemeral); key numbers preserved
in the table above.

## Round 82 (2026-07-11): camera hardware fps cap + real power-save (preview detach) — verified live on-device

Follow-up to the round-81 diagnosis. Owner asked: (1) let the user cap the camera's
frame rate ("I thought this was already set at 10 FPS" — no: that was the *inference*
cap, which only skips frames in software after the sensor/ISP already produced them
at ~30/s); (2) make power-save real; (3) treat field charging (power bank) as an
invariant; (4) explain ZSL in plain language.

**1. Camera frame rate cap (new tunable, default 15/s).**

- `SessionConfig.cameraFpsCap` (0 = device default; explicitly saved 0 survives,
  missing key → 15). Settings → Camera control, summary Settings-tab row under
  Heat management, SETTINGS_REFERENCE entry, round-trip test — all same round.
- Native: `YOLOView.setCameraFpsCap` sets the Camera2 `CONTROL_AE_TARGET_FPS_RANGE`
  at RUNTIME via `Camera2CameraControl` (no rebind needed). `chooseAeFpsRange`
  picks the closest HAL-advertised range ≤ the request (else smallest above;
  narrower preferred) and logs `Camera fps cap: requested=X applied=[a,b]`.
- **Interop funnel:** `setCaptureRequestOptions` REPLACES the whole option set, so
  the old `setManualFocus`/`setAutoFocus` and the new fps cap were merged into one
  `applyInteropOptions()` funnel (single place that API is called). It re-runs
  after every bind and preview reattach — as a side effect the manual-focus lock
  now also survives lens-switch rebinds instead of silently resetting.

**2. Real power-save.** Blackout's brightness-drop was measured (r81) to save
~nothing: camera HAL ~2 cores and the app ~1 core kept running under the scrim.
Now, when the "tap to wake" hint finishes fading, Dart calls the new
`setPreviewEnabled(false)`: native unbinds ONLY the Preview use case (analysis +
ImageCapture stay bound; recording untouched). Wake reattaches it and re-asserts
the funnel. A power-save preview-off also survives full rebinds (honored in the
bind path).

**3. Measured on the Xiaomi (session_125, ~7.5 min, gate asleep, USB-charging —
same live-adb method as r81):**

| state | cam HAL CPU | app CPU | total | skin temp |
|---|---|---|---|---|
| r81 recording asleep (dim) | ~230% | ~100% | ~490% | climbing → plateau ~58 °C @ throttle 18 |
| r82 recording asleep (blackout) | **~115%** | **~30%** | **~225%** | **flat ~48 °C @ throttle 11** |
Battery 35 °C flat (was 38→40). Awake check: gate-start window showed
convertedFps=15.0 / inferredFps=10.3 — camera cap and inference cap compose
correctly. HAL accepted a fixed [15,15]. Blackout logs "Preview use case
detached (power save)" / "…reattached"; recording ran through the whole cycle
(REC survived, summary shows the new settings row). Wake-by-ROI-nudge via
synthetic `adb input swipe` did not register (gesture slop — untouched code
path); motion-wake itself is unchanged native MotionGate logic.

**4. ZSL (explained, deliberately NOT changed).** Zero-Shutter-Lag keeps a rolling
ring buffer of full-resolution frames so a still can be grabbed instantly; that
buffer refills at the sensor rate, so the 15/s cap already halves its standing
cost. Unbinding ImageCapture while the gate sleeps was considered and deferred:
rebinding on wake takes hundreds of ms right when the first insect photo is due
(risking a lost/late first still on every wake), for a saving the fps cap already
shrinks. Revisit only if measurements still show ImageCapture dominating.

**Owner constraints recorded:** field phone is ALWAYS on a power bank (charging
heat is an invariant — plan with it; energy estimates stay unreliable while
plugged); USB tethering/hotspot is a home-office-only confounder, not a field
concern; stream resolution deliberately left at the owner's 1080×1440 for now.

Verification: `flutter analyze` clean, 99/99 tests, debug APK built + installed +
exercised live on the Xiaomi as above. Docs: SETTINGS_REFERENCE (new setting),
FIELD_GUIDE §4 (blackout now detaches preview), OVERVIEW (defaults row + interop
funnel & blackout invariants + field power invariant).

## Round 83 (2026-07-12): fix — screen stuck at minimum brightness after a timed session end in blackout

Owner field report: after using the moon (blackout) button during a recording, the
screen sometimes stayed so dim after the session ended that it was unreadable
outdoors.

Diagnosis: when the session ended via `_sessionTimer` (max session length) while
blacked out, `_toggleRecording()` stopped the recording and pushed the summary
screen without ever calling `_exitBlackout()`. The window-brightness override
(`setApplicationScreenBrightness(0.0)`) is per-Activity — and the whole Flutter
app is one Activity — so the summary rendered at minimum brightness with the
system bars still hidden. Neither safety net could fire: the tap-to-wake cover was
buried under the pushed summary route, and the `dispose()` restore never ran
because `Navigator.push` keeps the camera screen alive underneath. Manual stops
were unaffected (waking by tap runs `_exitBlackout()` first), which is why the bug
only showed up on timer-ended sessions.

Fix: `_toggleRecording()`'s stop branch now `await _exitBlackout()` before
stopping/pushing the summary (no-op when not blacked out). That single call
restores brightness + system bars, reattaches the preview, and keeps the wakelock
bookkeeping consistent (`_recording` is still true at that point), so the manual
and timed end paths converge.

Verification: `flutter analyze` clean, full `flutter test test/pollinator` pass.

## Round 84 (2026-07-12): power graph hidden for sessions with any charging

Owner question: with the field invariant that the phone runs on a power bank, is the
end-of-session "Power draw (W)" graph meaningful while charging?

Answer: no — and it cannot be corrected by computation. The source is
`BatteryManager.BATTERY_PROPERTY_CURRENT_NOW` (battery-terminal current). Plugged in,
the charger carries the load and the sensor sees the *charging* current: because the
summary takes `abs(current)` (OEM sign conventions vary), charging graphs as if it were
consumption, and a full battery on a power bank reads ≈ 0 W while the phone actually
draws several watts. The Wh integral is wrong for the same reason, and Android exposes
no charger-input-power API.

Change (all-or-nothing per owner decision; per-segment masking of charging periods was
considered and rejected — in practice a session is either fully on the power bank
(field) or fully on battery (home benchmark), and spliced averages/partial Wh would
confuse more than help):

- `_PowerSample` now parses the per-sample `is_charging` flag that `power` records have
  carried since the power logging round; `_buildEnergySeries` sets
  `_chargingDuringSession` if ANY sample was charging (previously only the start/end
  records' thermal flags were checked, so a mid-session plug-in was missed; those flags
  remain the fallback for older logs) and then builds NOTHING — no `_power` series, no
  avg/median/min/max, no Wh — so no misleading number can surface anywhere.
- Graphs tab: the power section keeps its heading but shows an orange explanatory note
  ("battery sensor measures charging current, not consumption; record on battery to see
  this graph") instead of the graph + stats.
- Overview tab: the existing ⚠ plugged-in note now also fires for mid-session charging
  and says the graph is hidden, so both tabs tell one story. "Battery used %" stays
  visible (self-explaining, with the note right under it).

Logging is unchanged — raw `power` records (current/voltage/charge counter/is_charging)
are still written every sample, so offline analysis keeps the full data either way.

Verification: `flutter analyze` clean, 99/99 tests. Manual check: a power-bank session
summary shows the note instead of the W graph; an unplugged session renders as before.

## Round 85 (2026-07-12): fake low-FPS spikes after motion-gate wake — EMA resume guard

Owner report: with the gate mostly asleep, the FPS (and seemingly inference-time)
graphs show near-vertical downward spikes around gate transitions and the averages
come out far too low; proposed masking the wake/sleep moments out of graphs + stats.

Diagnosis (session_127): the spikes are WRONG NUMBERS, not brief real slowdowns.
`Predictor.finishTiming` keeps `t4` as an EMA (α=0.05) of the interval between
inferences and reports `fps = 1/t4`. While the gate sleeps `t3` goes stale, so the
first inference after wake blends the whole sleep gap into the EMA (53 s × 0.05 →
"0.4 fps") and recovery takes ~45 inferred frames (~4.5 s at 10 fps) — longer than a
typical wake window. Proof: all 10 awake fps samples in session_127 read 0.49–5.3
while `pipeline_fps` on the same rows read 9.4–11.7 (detector truly ran ~10 fps).
Sleep-side is clean (r77 omits inference fields while idle). The `inf_ms` bumps on
the first post-wake frame (7→13 ms) are RAW per-frame truth (cold caches/clocks) —
left as is. Masking (the proposed remedy) was rejected: in gate-heavy sessions the
contamination spans the entire wake window, so masking would delete ALL awake FPS
data (127's graph would be empty). Fix the measurement instead:

- `Predictor.finishTiming` (native): a gap > max(2 s, 5×t4) is a RESUME (gate wake,
  settings-sheet pause, summary screen) — reseed `t3`, skip the blend, keep the last
  known rate. The relative bound keeps very low fps caps (≈1 s gaps) blending
  normally. Also fixes a real tracking bug for free: `_trackerParamsForFps` derives
  the occlusion buffer / min-hits from this fps every second, so each wake used to
  shrink the occlusion window ~10–20×.
- `FrameProcessor.updatePipelineFps` (Dart): same guard (its α=0.1 EMA dipped ~10%
  per wake). KEEP IN SYNC pair with the native guard. Two new unit tests (gap
  skipped; legitimate 1 fps rhythm still blends) — 101 tests total.
- Summary FPS graph (`session_summary_screen.dart`): plots `pipeline_fps ?? fps` so
  ALREADY-RECORDED sessions display honestly too (both fields estimate results/s;
  post-r85 they agree; pre-r85 pipeline_fps is far less contaminated; oldest logs
  only carry `fps`). Measured on session_127: avg 2.24 → 10.49 fps, min 0.49 → 9.39.

Verification: `flutter analyze` clean, 101/101 tests, debug APK builds (Kotlin
compiles). On-device check still advised: per-second `fps` records right after a
wake should read ≈ the inference cap, and the live readout must not crater after
waking or after closing the settings sheet.

## Round 86 (2026-07-12): Photos tab shows ALL insects detected in the trigger frame

Owner request: photos with multiple insects only showed boxes for the insect(s) that
triggered the photo; the others detected in the same frame were missing.

Cause: `RoiCaptureScheduler.evaluate` puts only the DUE track ids into
`PendingCapture.trackIds`, and `SessionRecorder.recordFrame` writes the `jpeg`
filename only into those tracks' entries. A track that was present but not due
(step not reached, or its capture window expired) has its `box_in_roi` in the very
same `detections` record — the summary's `_loadPhotos` just skipped entries without
a `jpeg` field.

Fix (display-side only, so it works retroactively on already-recorded sessions —
no logging change): when parsing a `detections` record, the first entry's `jpeg`
filename is shared with the record's other entries (`frameJpeg`), so every insect
of the trigger frame gets a box on the photo. Entries carrying their own `jpeg`
are marked `triggered` and keep the cyan box (`_BoxPainter.triggerColor`, the
pre-r86 color for everything); co-detected insects draw amber
(`coDetectedColor`); a two-swatch legend line sits under the Photos-tab explainer.
The per-photo track-id list and confidences now naturally include the co-detected
insects (they ARE in the photo). Legacy per-track `detection` records (≤ r68)
can't be regrouped into frames and keep trigger-only boxes.

Verified on session_128: 52 of 66 photos gain the previously hidden boxes
(e.g. 1 trigger + 1 co-detected), photo count unchanged, single-insect photos
identical. `flutter analyze` clean, 101/101 tests.

## Round 87 (2026-07-12): photo viewer tools — boxes on/off + pinch/slider zoom

Owner request: viewer tool buttons (top-right column) for (1) toggling the detection
boxes overlay, (2) zooming (two-finger pinch and a magnifier slider). A third button
(send crop to a citizen-science classifier, e.g. iNaturalist/Observation.org) was
discussed and is PLANNED ONLY — see the chat plan; groundwork thinking: sessions log
no GPS, which observation platforms want, so a future round may add optional
session-start location capture.

Implementation (`_PhotoViewer` in `session_summary_screen.dart`, display-only):
- Each page's photo+overlay Stack sits inside an `InteractiveViewer` (Flutter's
  built-in pinch-zoom/pan), max 8×. The box overlay is INSIDE the transformed child
  so boxes stay glued to insects while zooming. Double-tap resets to 1×.
- One `TransformationController` PER PAGE (PageView keeps neighbours alive during a
  swipe — a shared controller would zoom the incoming photo too); zoom resets when
  leaving a page (gallery convention; also keeps swiping working, since pan owns the
  horizontal drag while zoomed). Controllers disposed with the state.
- Tool column fixed at the viewer's top-right (does not swipe/zoom with the photo):
  boxes toggle (`Icons.crop_din`, cyan when active) and magnifier (`Icons.zoom_in`)
  that unfolds a vertical 1–8× slider with a live "N.N×" readout. Slider zooming
  keeps the current viewport centre fixed (so it doesn't jump off a pinch-panned
  insect) and clamps the pan to keep the photo covering the viewport —
  InteractiveViewer only enforces its boundary during gestures, not programmatic
  transforms. A controller listener mirrors pinch scale back into the slider thumb.
- Non-deprecated matrix construction (`Matrix4.diagonal3Values` +
  `setTranslationRaw`) — `..translate()..scale()` are deprecated in current
  vector_math.

Verification: `flutter analyze` clean, 101/101 tests, debug APK builds. View-state
only (no SessionConfig/logging change), so no settings/summary/data-guide rows.

## Round 88 (2026-07-12): photo viewer zoom UX — swipe/pan conflict, ‹ › nav, thin boxes

Owner field-test feedback on r87: after pinch-zooming and lifting both fingers, a
one-finger drag usually swiped to the NEXT photo instead of panning ("the pinch
evaporates"); wanted a way to move the zoomed view, explicit prev/next buttons,
a visible zoom mode, and box lines/labels that stay thin at 8×.

Root cause of the pan problem: PageView and InteractiveViewer both compete for
one-finger horizontal drags in the gesture arena, and PageView usually wins.
Fixes (all in `_PhotoViewer` / `_BoxPainter`, `session_summary_screen.dart`):

- While zoomed (`_scale > 1.01`), the PageView gets
  `NeverScrollableScrollPhysics` — a one-finger drag then always PANS the photo
  (no extra "move" button needed; the requested button became unnecessary once
  the drag conflict was removed).
- ‹ › navigation buttons, vertically centred on the viewer edges, greyed at the
  gallery ends; they reset the zoom BEFORE animating so a zoomed crop never
  slides around. While zoomed they are the only way to change photo.
- A cyan chip (top-left) makes the mode explicit: "Zoom N.N× — drag to move,
  ‹ › or double-tap to exit".
- `_BoxPainter` now takes the page's zoom factor and divides stroke width
  (2/zoom), label font (11/zoom) and label offset by it, so boxes/labels keep a
  constant ON-SCREEN thickness at any zoom (glyphs rasterize under the full
  transform, so scaled-up text stays crisp); `shouldRepaint` compares zoom too.

Verification: `flutter analyze` clean, 101/101 tests, debug APK builds. View-state
only; no SessionConfig/logging change.

## Round 89 (2026-07-12): zoomed panning still stolen — freeze ALL ancestor scrollables + pan pad

Owner re-test of r88 on the Xiaomi: panning a zoomed photo still barely worked.
Not a device quirk — r88 only froze the INNER PageView, but two more scrollables
sit above the photo in the gesture arena and win most drags: the summary's
TabBarView takes horizontal drags (tab swipe) and the Photos tab's ListView takes
vertical/diagonal drags (page scroll). A pan is rarely axis-pure, so almost every
drag was stolen by one of them.

Fixes (`session_summary_screen.dart`):
- `_PhotoViewer` now reports zoom-mode changes via `onZoomChanged` (debounced to
  actual mode flips via `_lastNotifiedZoomed`; dispose-time un-freeze is
  post-frame). While zoomed, the parent gives BOTH the TabBarView and the Photos
  ListView `NeverScrollableScrollPhysics` — with the r88 PageView freeze, the
  InteractiveViewer is then the only drag contender, so one-finger panning and
  re-pinching work. Physics only gate USER drags: tab-bar taps still switch tabs,
  and everything unfreezes at 1×.
- Pan pad (owner request): while zoomed, a 4-arrow nudge pad (bottom-right)
  moves the view by ⅓ viewport per tap with the same translation clamping as the
  slider — a button fallback so moving around never depends on winning a drag
  gesture, on any device.

Verification: `flutter analyze` clean, 101/101 tests, debug APK builds. Owner
should re-test on the Xiaomi: zoom in → one-finger drag must pan (not scroll the
page/switch tabs), vertical pans included; arrows/double-tap exit; pad nudges.

## Round 90 (2026-07-12): Overview tab — date/start/end rows + storage section + Delete session

Owner request, all on the summary's Overview tab:

- Under the headline stats: Date (yyyy-mm-dd), Start time, End time (hh:mm:ss),
  then Session duration last — same formats as the home history list. A session
  crossing midnight shows the end's own date; a crashed session shows End
  "unknown" (matches the list's "incomplete").
- After a divider, a storage section: "Session storage" (folder size — same scan
  as the home list, so the numbers match) and "Phone storage free" (same GB/1-dp
  reading + ⚠-low marker as the recording screen's readout; via
  `DeviceStorage.read()`).
- A red "Delete session" button: an AlertDialog warns that the whole folder —
  log, metadata, every photo (+ its size) — is permanently lost; confirming
  deletes `logFile.parent` recursively and pops the summary. Failures surface as
  a snackbar (`logSwallowed('session_delete')`), never a crash.

Plumbing: `_folderSizeBytes`/`_formatBytes` moved OUT of home_screen into shared
top-level `folderSizeBytes`/`formatBytes` in `logging/device_storage.dart` (one
source for list + summary). `HomeScreen._openSession` now rescans the list on
return (it previously only rescanned after recording), so a deleted session
disappears and per-session sizes stay fresh. Free-storage readouts elsewhere need
no plumbing: the home list rescans folders, and the recording screen polls StatFs
on the thermal cadence, so freed space shows up automatically.

Verification: `flutter analyze` clean (plus one pre-existing single-line `if`
braced after `dart format` reflowed it), 101/101 tests, debug APK builds.


## Round 91 (2026-07-12): crop-and-export from the summary photo viewer

Phase 1 of the "send to a classifier" idea: instead of API integration (deferred —
needs GPS in session logs + platform decisions), the Photos-tab viewer can now cut
a user-drawn rectangle out of a saved photo and hand it to the identification apps
the owner already has (Google Lens, iNaturalist/Seek). Owner decisions this round:
save destination is the **Gallery** (MediaStore Pictures — photo pickers surface it
far better than Downloads), plus a direct **Share** button.

- **Crop mode** (`_PhotoViewerState`, `session_summary_screen.dart`): new crop tool
  button. While active, a full-square gesture layer sits ABOVE the InteractiveViewer
  and wins every one-finger drag; drag points are converted to the photo's scene
  coordinates immediately (`toScene`), so the box is drawn correctly at any zoom/pan
  and stays glued to the insect (the painter re-maps scene → viewport each build;
  the transform listener also repaints on pure pans while a box exists). Page
  swiping and ancestor scrollables freeze exactly as in zoom mode (`_scrollFrozen =
  _zoomed || _cropMode` feeds the existing `onZoomChanged` plumbing). A crop bar
  under the viewer shows the box's REAL saved-pixel size (⚠ tiny under 100 px —
  honesty about deep-zoom crops), with Save / Share actions; a chip explains the
  mode. The rectangle is dropped on page change and when it would land under 16 px.
- **Export path** (`capture/crop_export.dart`, new): pure geometry helpers
  (`sceneRectForDrag` with the 1:1 lock + edge shrinking, `normalizedRect`,
  `cropExportName`) + `cropJpegRectSync` (decode → `copyCrop` → JPEG q90, never
  from the screen) run through a background isolate (`cropJpegNormRect`).
  `saveCropToGallery` calls the platform; fallback on failure/old Android writes to
  `<session>/crops/`. `shareCrop` reuses the ErrorReporter SharePlus pattern.
- **Native** (`MainActivity.kt`): `saveImageToGallery` method on the existing
  `pollinator/crop` channel — MediaStore insert with RELATIVE_PATH
  `Pictures/PollinatorMonitor` + IS_PENDING (API 29+; returns false below, both
  test phones are above). Runs on `cropExecutor`, deletes the pending row on error.
- **New tunable** (owner rule): `cropSquareLock` (default off) — SessionConfig
  (all 5 spots), Settings → Summary switch, in-viewer "1:1" chip (same setting,
  re-loads the config before saving so it can't stomp other fields), summary
  Settings-tab row, round-trip test.
- Tests: `crop_export_test.dart` (drag geometry incl. square lock + edge clamp,
  name format, pixel-verified JPEG crop, clamping, tiny/garbage rejection).

Verification: `flutter analyze` clean, 114/114 tests, debug APK builds. Field check
still pending: save a crop on the Xiaomi, find it in the Gallery, feed it to
Seek/Lens (also answers whether ~300–1000 px crops identify well).

## Round 92 (2026-07-12): movable crop box in the summary viewer

Field feedback after round 91 (owner tested crop-export successfully with Google
Lens and Seek): framing the insect needs the drawn box to be MOVABLE, not only
redrawable. Also re-confirmed on request: the export has always cropped the
ORIGINAL saved JPEG (`cropJpegNormRect(p.file, …)` decodes the `roi_frames/` file;
the screen only supplies normalized coordinates), so small crops are purely a
saved-resolution matter — raising `targetRoiSavedPx` / using stills is the fix.

- A pan starting INSIDE the existing box (inflated by 12 on-screen px for finger
  tolerance, converted to scene px via the zoom) now MOVES it; starting outside
  redraws as before. Moving shifts the rectangle as it was at drag start
  (`_cropMoveOriginRect`) by the drag delta via the new pure helper
  `moveSceneRect` (`capture/crop_export.dart`): translation clamped so the box
  stays fully on the photo, size untouched — an enforced 1:1 therefore stays 1:1
  through any move, as does a free-aspect shape.
- Visual cue: `_CropRectPainter` draws a four-arrow "move" glyph
  (`Icons.open_with`) just inside the box's top-right corner, clamped to the
  canvas so it stays visible when that corner is panned off-screen. The crop-mode
  chip now reads "drag inside the box to move it, outside to redraw".
- `_finishCropDrag` clears the drag/move state on every pan end; the tiny-box
  drop only ever triggers for freshly drawn boxes (a moved box kept its
  already-validated size).
- Tests: `moveSceneRect` (shift, edge clamping, size/aspect preservation for
  square and non-square boxes) in `crop_export_test.dart`.

Verification: `flutter analyze` clean, 118/118 tests, debug APK builds.

## Round 93 (2026-07-13): export a session's photos to the Gallery as an album

Why: session photos live in app-private storage (`Android/data/.../files/sessions/`),
which Android's media index (MediaStore) deliberately never scans — so the phone's
own Gallery app can't show them, and end-users only had the in-app viewer or a
USB cable. Owner decision: a MANUAL button (no auto-export, capture path is
heat/perf-critical and untouched), PHOTOS ONLY (session.jsonl stays private).

What was built:
- **Kotlin (`MainActivity.kt`)**: new `saveImagesToGallery` method on the existing
  `pollinator/crop` channel. Args: `paths` (≤25 absolute JPEG paths) + `album`
  (Kotlin prepends `Pictures/PollinatorMonitor/` itself so Dart can never redirect
  the insert). Returns `{supported, exported, skipped, failed}` (counts sum to
  paths.length when supported). Only PATH STRINGS cross the channel — Kotlin
  streams each file from disk into MediaStore. The r91 single-crop insert body was
  refactored into a shared `insertJpegIntoMediaStore(displayName, relativePath,
  write)` (IS_PENDING row, orphan cleanup on failure); `saveImageToGallery` is now
  a one-line wrapper, behavior unchanged. Runs on the existing `cropExecutor`
  (safe: capture and the summary screen never run concurrently).
- **Idempotent re-export**: `existingDisplayNames(relativePath)` queries MediaStore
  for DISPLAY_NAMEs already under that RELATIVE_PATH and skips them. GOTCHA worth
  remembering: MediaStore stores RELATIVE_PATH with a TRAILING SLASH — the
  selection arg must be `"$relativePath/"` or the query matches nothing. Photo
  filenames are globally unique (`roi_<sessionId>_<ms>.jpg`), so no false
  cross-session skips. Query failure → empty set (worst case MediaStore renames
  to "name (1).jpg", never crashes).
- **Dart (`capture/crop_export.dart`)**: `exportPhotosToGallery(photos, album,
  onProgress)` sends chunks of `kGalleryExportChunk = 25` and accumulates counts;
  first `supported:false` reply aborts remaining chunks; a chunk that throws is
  logged (`logSwallowed('gallery_batch_export')`), counted failed, and the NEXT
  chunk still goes out — the function never throws. Chunking chosen over one big
  native call + EventChannel: negligible overhead (short strings), plain
  request/response handler, free progress ticks. `galleryAlbumName()` re-sanitizes
  the session folder name as a safety net (strip leading dots BEFORE the character
  sweep — a swept leading dot becomes `_` and the strip then misses it; caught by
  the unit test).
- **UI (`session_summary_screen.dart`, Overview → Storage & cleanup)**:
  `FilledButton.tonalIcon` "Export photos to Gallery" above Delete; confirm dialog
  shows photo count + extra storage (`formatBytes`) and explains copies/skips;
  determinate `LinearProgressIndicator` + "Exporting photo N of M…" while busy;
  completion SnackBar with exported/skipped/failed or a plain-language
  "needs Android 10+" note. Photo list comes from the real `roi_frames/` dir (not
  the log), so crash-ended sessions export fully. Delete session is DISABLED while
  exporting (closes the delete-mid-copy race).
- **SDK < 29**: native replies `supported:false` before touching MediaStore; no
  legacy WRITE_EXTERNAL_STORAGE path. No new SessionConfig tunable (user action,
  not a session parameter). Docs: FIELD_GUIDE §6 paragraph; overview bullet
  extended.
- **Tests**: new `test/pollinator/gallery_export_test.dart` — album-name
  sanitizing; mocked-channel chunking (60 → 25/25/10), count accumulation,
  unsupported early-stop, failed-chunk survival, progress ticks.

Verification: `flutter analyze` clean, 126/126 tests, debug APK builds.
Manual on-phone steps still pending (owner): export a real session, check the
Gallery album, re-press for the skip path, zero-photo session message.


## Round 94 (2026-07-13): scheduled recording — daily windows × N days with sleep between

Owner request: leave the phone mounted and have it record on a schedule (e.g.
06:00–10:00 and 15:00–20:00 every day for 2 days), sleeping between windows to
save power. Design decisions (owner-confirmed): between windows the app stays
FOREGROUND with the screen blacked out and the camera fully unbound (true OS
deep sleep via AlarmManager was rejected — MIUI kills backgrounded apps and a
silent overnight death would cost the morning window); each window is its own
session (existing JSONL format, summary and R/Python parsers untouched); the
schedule shape is "same 1–3 windows every day × N days".

**New files**
- `models/schedule_window.dart` — `ScheduleWindow(startMinute, endMinute)`
  (minutes since midnight; start < end, no crossing midnight — split in two),
  JSON round-trip with malformed-entry drop, `label`/`startLabel`/`endLabel`,
  `overlaps()`, static `hhmm()`.
- `session/schedule_plan.dart` — pure-Dart planner (clock injected, no timers/
  I/O): `phaseAt/activeSlotAt/nextSlotAt/nextTransitionAt/startOf/endOf` over
  `SchedulePhase {sleeping, recording, finished}` + `ScheduleSlot(day, window)`.
  Everything recomputed from `now` each call, so timer drift / doze / clock
  jumps self-heal. Day indices via UTC-rebuilt calendar dates (DST-safe).
  Windows already past at start are skipped; a mid-window start records the
  partial window.
- `test/pollinator/schedule_plan_test.dart` — 12 tests (phases, mid-window
  start, skip-past, day/month rollover, 3 windows, finished detection).

**Config (owner rule: tunable = Settings + JSON + summary row + test, same round)**
- `SessionConfig`: `scheduleEnabled` (off), `scheduleWindows` (default one
  06:00–10:00 window; load sorts, drops malformed, caps at 3), `scheduleDays`
  (1, clamped ≥1 on load), `isScheduleValid` (1–3 valid, pairwise
  non-overlapping; touching ends OK). Round-trip + legacy-fallback tests.
- Settings → Setup: "Scheduled recording" switch; per-window rows with
  `showTimePicker` buttons + delete; "Add window" (max 3); orange warning on
  invalid combos (lenient, like the time-lapse check); "Days to run" (1–14).
- Summary → Settings tab: Scheduled recording / Schedule windows / Schedule
  days rows + "Schedule slot: day 1/2, window 2 (06:00–10:00)" from the start
  record's `schedule` block. Null-safe; old sessions omit them.

**Driver (camera_session_screen.dart)**
- REC button with scheduling enabled = "start scheduled run" (clock glyph in
  the button, confirm dialog spelling out windows/days/dark-screen); while a
  run is active it means "stop the whole run" (confirm-guarded).
- `_scheduleTick()` reconciles actual state vs `plan.phaseAt(now)`; re-arms
  `_scheduleTimer` for the next boundary, capped at 60 s (self-check absorbs
  doze gaps and retries failed wakes). Also ticked from
  `didChangeAppLifecycleState(resumed)`.
- Window end (`_endWindow`): `_stopRecording(normal: true, retainKeepAlive:
  true)` — NEW `retainKeepAlive` param on `SessionRecorder.stop` keeps the
  foreground service + wakelock across the sleep — then `_controller.pause()`
  (FULL unbind: analysis + capture + preview; the r82 blackout alone only
  detaches preview) + blackout with the sleep-status cover variant. No summary
  push (user asleep/away).
- Window start (`_wakeForWindow`): `resume()` under the cover, poll
  `_lastStreamEventMs` for real frames (20 s timeout; on failure park + retry
  on next tick), `_startRecording(scheduleSlot:)` → folder
  `<name>_d<day>w<win>`, start record gains a `schedule` block, and the
  `_sessionTimer` auto-end is NOT armed (window end governs — the 60-min
  default must not truncate a 4-h window). Then `_applyBlackoutSteadyState()`
  (split out of `_enterBlackout`'s hint timer) re-detaches the preview the
  resume brought back.
- Sleep cover: tap shows status ("day 1/2 · next recording 15:00 · N sessions
  recorded") at readable brightness for 8 s + "Stop scheduled run" button, then
  re-dims. Never a full wake (camera is off — a dead preview would mislead).
  Status also shown once on sleep entry. Abort-dialog freezes the auto-dim.
- Run end (`_finishSchedule`): release keep-alive + wakelock, exit blackout,
  resume preview, "Scheduled run complete — N sessions recorded" dialog; the
  per-window sessions are on the home list.
- Blackout guards for the paused-camera state: `setPreviewEnabled(true/false)`
  skipped while `_paused` (whole camera unbound — dead channel call), and
  `_exitBlackout` keeps the wakelock while `_schedule != null` (not just while
  recording). Settings gear locked during a run.
- dispose() while sleeping releases the keep-alive service (recording path
  already did via `_stopRecording`).

Verification: `flutter analyze` clean; 145/145 tests. On-phone bench + field
tests pending (owner): two short windows minutes apart → dark sleep with
tappable status, auto-wake/re-dim, two `_d1w1`/`_d1w2` folders ending
`ended_normally: true`, completion dialog, notification present throughout;
manual-mode regression with the switch off; overnight 2×2 field run.

## Round 95 (2026-07-13): motion-only capture mode — photos on motion, detector never runs

Owner request: an option that captures ROI photos on motion alone, WITHOUT running
the AI — but only if it genuinely consumes less energy. It does, strictly: idle cost
is identical to the gated detector mode (same pre-conversion frame drop at
`motionGateIdleFps`), and when motion wakes it only the MotionGate thumbnail diff
(<1 ms) runs — `predict()` never executes, the GPU stays cold. Documented trade-off:
wind/shadow false wakes now produce junk PHOTOS (storage + review burden) instead of
wasted inference, and there is no detector to reject them.

Design decisions:
- **Model still loads, predict is never called.** Camera startup is coupled to
  `setModel`; a model-less YOLOView would be a structural rewrite for zero
  runtime-energy gain (load is one-time). A native `motionOnlyMode` flag routes
  frames into a self-contained branch in `YOLOView.onFrame` placed AFTER bitmap
  conversion + frame-cache and BEFORE `predictor?.let` — the detector path is
  byte-identical while the flag is off. The branch runs `gateMotionFromFrame` on
  every converted frame (background EMA must keep learning; never
  `motionDetectedFromModelInput` — no raster exists), extends `gateAwakeUntilNs`
  on motion, and emits awake stream maps at ≤10 Hz (fixed 100 ms interval, NOT
  `shouldRunInference()` — that cap is tied to the auto-throttle, which never
  updates without inference timings; a wake TRANSITION emits immediately). Idle:
  the existing ~1 Hz `gateIdle:true` heartbeat, now via a shared helper
  `maybeEmitGateIdleHeartbeat` so the two paths can't drift.
- **Stream contract additions:** awake maps `{gateIdle:false, motionOnly:true,
  motionScore, cameraFps, imageWidth, imageHeight, roiActive, timestamp}` — the
  dims are mandatory (the Dart capture-probe/ROI-push bootstrap needs a map with
  `imageWidth > 0`; heartbeats don't carry dims, and the gate starts awake after
  `setMotionGate`, so the first events do). Heartbeats gained a harmless
  `motionOnly` key.
- **Config: `bool motionOnlyCapture` (default false)**, not an enum. Requires the
  gate: the Settings switch forces `motionGateEnabled: true` and locks the gate
  toggle while on; `_pushMotionGate` sends `enabled: gate || motionOnly` and the
  Kotlin side guards the same way (belt and braces). Gate tunables double as the
  motion-only sensitivity controls; time-lapse step/duration + photo-source mode
  apply unchanged.
- **Scheduler:** `RoiCaptureScheduler.evaluateMotion(nowMs)` — ONE shared
  `_motionWindow` (no track ids): first photo on motion onset, one per step while
  motion persists, stop after durationMs; a NEW window only after motion has been
  absent > durationMs (same hysteresis as track windows). `capture()` unchanged
  (already track-agnostic).
- **Logging:** new `motion_capture` record `{jpeg, motion_score}` per photo
  trigger (key named `jpeg` to match the detections-record photo link);
  `SessionRecorder.recordMotionFrame(ts, motionScore)` drives it. The per-second
  `fps` record omits ALL inference-derived fields in this mode even while awake
  (r77 rule: absent = detector off, never a logged 0) and carries
  `motion_only: true`. Guard: the detector-path `recordFrame` is skipped when
  `motionOnlyCapture` so the startup race (detector-style frames before the first
  `setMotionGate` lands) can't write `detections` records into a motion-only log.
- **Summary:** `_loadPhotos` parses `motion_capture` records into the photo list;
  general backstop — `capture` records now also seed unseen files into the list
  (any session's saved JPEGs stay browsable even if their discovery line is
  missing; `containsKey`-guarded so detector photos never double-count). Empty
  visit timeline shows a "motion-only capture session" note instead of "No visits
  recorded"; Overview's unique-insects row reads "n/a (motion-only capture)";
  Settings tab gained the row.
- **UI:** gate chip reads "CAPTURING"/"WAITING FOR MOTION" in this mode; Engine
  line replaced by "Mode: motion-only capture (detector off)"; detector/pipeline
  FPS + pre/inf/post lines hidden; Model line kept (the model really loads).
  ROI-border grey + motion-% stat line now show for gate-or-motion-only.

Files: `YOLOView.kt` (flag, setMotionGate param, onFrame branch, heartbeat
helper), `YOLOPlatformView.kt` + `yolo_controller.dart` (motionOnly arg),
`session_config.dart`, `roi_capture.dart` (evaluateMotion), `session_logger.dart`
(logMotionCapture), `session_recorder.dart` (recordMotionFrame),
`camera_session_screen.dart` (stream branch, gate push, chip/stats, fps record),
`settings_sheet.dart`, `session_summary_screen.dart`; tests in
`session_config_test.dart`, `roi_capture_scheduler_test.dart`,
`session_logger_test.dart`.

Verification: `flutter analyze` clean; 154/154 tests; `flutter build apk --debug`
succeeds. On-device pending (owner): chip WAITING FOR MOTION ↔ CAPTURING on a
hand-wave; first photo immediately on motion then per step, stopping after the
capture duration; no watchdog banner during long idle; logcat FRAMEPERF
`inferredFps=0.0` throughout; session.jsonl has `motion_capture` + `capture`
records and zero `detections` records; motion-only summary shows photos + note;
an OLD session summary parses unchanged; a detector session after toggling the
mode off behaves exactly as before.

## Round 96 (2026-07-13): motion-only capture — second-burst bug fix, burst rate, setting texts

Field test (Xiaomi, owner): motion-only capture worked — first hand-wave produced
the expected burst (Photo step 1 s × Photo duration 5 s = 5 photos) — but a SECOND
wave "a few moments" later captured nothing.

**Root cause.** `evaluateMotion` re-armed only after a quiet gap > `durationMs`,
measured from `lastSeenMs` — which every awake stream emission refreshed. The
native side keeps emitting awake maps every 100 ms for the whole `wakeSeconds`
window after motion stops (`motion || wasAwake` in the onFrame branch), so a
second burst effectively required ~`wakeSeconds + durationMs` (≈8 s at defaults)
of TOTAL stillness. Any wave inside that window refreshed the clock and stayed
silent.

**Fix.** A new motion event = a gate sleep→wake cycle. `_setGateIdle` (camera
screen) on the awake→idle TRANSITION (motion-only mode) calls
`SessionRecorder.onMotionGateIdle()` → `RoiCaptureScheduler.resetMotionWindow()`.
The next wake starts a fresh window (immediate first photo). This is visible on
screen: chip shows WAITING FOR MOTION ⇒ the next motion will photograph. The old
gap>durationMs rule survives only as a backstop for paused streams (settings
sheet, blackout) — while awake, emissions never pause, so it can't fire.
Regression tests: exhausted window + reset → immediate burst; reset mid-window
restarts.

**Burst rate for offline detection/tracking (owner wants ~5–10 fps on the saved
photos).** Decision: no ROI video — CameraX `VideoCapture` records the full frame
only, ROI-cropped video would need an OpenGL surface pipeline, and a 4th use case
alongside Preview+Analysis+ImageCapture hits device use-case combination limits.
Fast-path photos already deliver: `captureRoiFromFrame` crops the cached analysis
frame in tens of ms and the native motion emissions arrive at up to 10 Hz — so
"Photo step" min was lowered 0.5 → **0.1 s**. Caveats in the helper text:
sub-second steps need the "fast" photo source (stills take 0.5–1.5 s each; in
auto mode with a small stream every burst photo would go still-path and stall),
and fast crops are capped at the STREAM short side (÷32) — 1024 px at 5 fps needs
a delivered stream short side ≥ 1056; otherwise photos save at the
stream-limited size (fine for offline detection, which downscales anyway).

**Setting texts (owner request).** "Photo step" helper now says it drives both
per-track photos and motion-only bursts + the fast-source caveat. "Photo duration
per track" renamed to "Photo duration"; helper: per track id with the AI pipeline,
per motion event in motion-only mode (new event once the gate has slept and
motion returns). Summary rows were already mode-neutral — unchanged.

Files: `roi_capture.dart` (resetMotionWindow + evaluateMotion doc),
`session_recorder.dart` (onMotionGateIdle), `camera_session_screen.dart`
(_setGateIdle hook), `settings_sheet.dart` (texts + step min),
`roi_capture_scheduler_test.dart` (2 new tests). No native changes.

Verification: `flutter analyze` clean; 156/156 tests. On-device pending (owner):
wave → burst; wait for WAITING FOR MOTION (~wakeSeconds); wave again → NEW burst
immediately, repeatable. Burst rate: photo source "fast", step 0.2 s → ~5
photos/s during a wave; `capture` records' `total_ms` confirm the fast path
keeps up.

## Round 97 (2026-07-14): time-lapse capture mode + CaptureTrigger enum + unit-aware durations

Owner request: a third session mode — pure time-lapse photo bursts, no AI and no
motion check (cheapest possible; wind-proof; meant for OFFLINE detection/tracking
on the saved photos afterwards, possibly on-phone with tiled inference — future
work, but filenames/records already carry ms timestamps so nothing blocks it).

**CaptureTrigger enum.** `motionOnlyCapture` (r95 bool) became
`CaptureTrigger { detector, motion, timelapse }` with compatibility getters
(`motionOnlyCapture` / `timeLapseCapture` / `detectorEnabled`) so most call
sites read unchanged. Migration mirrors captureMode/fullResPhotos:
`_captureTriggerFromJson` reads the new `captureTrigger` string, falls back to
legacy `motionOnlyCapture:true` → motion; toJson writes BOTH keys for one
generation. The mode selector is a dropdown at the top of the SETUP tab (moved
from the Camera tab's motion-only switch, which is gone); the Camera tab keeps
the motion GATE switch + tuning (locked ON for the motion trigger, locked OUT
in time-lapse where it does nothing).

**Time-lapse semantics.** Each burst = the same capture window motion mode
uses: first photo at burst start, then every "Photo step", stopping after
"Photo duration". Bursts repeat every `timeLapseIntervalSeconds` — the new
**"Repeat burst every"** setting (START-TO-START, so "every 30 min" stays every
30 min regardless of burst length; default 1800 s). Interval ≤ duration ⇒
CONTINUOUS time-lapse. Session length / scheduled windows compose unchanged
(each window anchors its own plan). Both "Photo duration" and "Repeat burst
every" use the new `DurationSettingField` (NumericSettingField + s/min/h unit
dropdown; value stored in seconds; duration max raised 60 s → 24 h).

**Implementation.**
- Pure planner `capture/time_lapse_plan.dart` (`TimeLapsePlan`): stepMs/
  burstMs/intervalMs; `inBurstAt`/`cycleIndexAt`/`nextBurstStartAt`/
  `nextTickDelayMs`; clock-injected like SchedulePlan; unit-tested.
- Camera screen: `_timeLapseTick` self-rescheduling one-shot timer (armed in
  `_startRecording`, capped 60 s, min 100 ms — doze/clock jumps self-heal),
  drives `SessionRecorder.recordTimeLapseFrame(ts, burstIndex)` (→ scheduler
  `evaluateMotion` window → `capture()`) and `beginTimeLapseBurst()`
  (`resetMotionWindow`) at each cycle start. Photos only while recording.
- Native `YOLOView.setTimeLapse(enabled, sampleFps)`: pre-conversion frame drop
  at sampleFps (the gate-idle trick, rate-controlled by Dart: `ceil(2/step)`
  clamped 1–30 during a burst so fast crops stay fresher than half a step,
  1 fps between bursts) + a branch BEFORE `predictor?.let` that heartbeats
  ~1 Hz `{timeLapse:true, cameraFps, imageWidth/Height, roiActive, timestamp}`
  (dims feed the Dart bootstrap) and returns — predict() never runs. Channel
  plumbing in YOLOPlatformView.kt + yolo_controller.dart.
- Dart stream branch on `timeLapse:true` maps: zero inference numbers, dims/
  bootstrap, return BEFORE the 0-FPS watchdog (same guard as motion mode).
  `recordFrame` now gated on `detectorEnabled` (startup race). `fps` records
  omit inference fields in any detector-off mode + carry `time_lapse:true`.
- Logging: new `timelapse_capture` record `{jpeg, burst}` per photo trigger.
- UI: `_timeLapseChip` — green "TIME-LAPSE: CAPTURING" during a burst, grey
  "NEXT BURST in mm:ss" countdown between (ticks off `_recordElapsedVN`),
  "starts with REC" before recording. Engine line reads "Mode: time-lapse
  (detector off)"; detector fps/perf/gate lines hidden appropriately.
- Summary: `timelapse_capture` seeds the Photos list (plus the r95 capture-
  record backstop); timeline/unique-insects show a time-lapse note; Settings
  tab gains "Capture trigger" + "Burst repeat interval" rows; motion-only
  detection accepts both the enum and the legacy bool.

NOT done (deliberate): ROI-cropped video (full-frame-only VideoCapture, GPU
pipeline needed, use-case combo limits — fast photos serve the same purpose);
camera full-unbind between long bursts (r94's pause machinery could halve the
standing cost for 30-min intervals — a follow-up if field heat demands it);
the on-device post-processing detector/tracker (owner: future round).

Verification: `flutter analyze` clean; 171/171 tests; debug APK builds.
On-device pending (owner): time-lapse session → chip counts down, bursts fire
on schedule (first photo at burst start, step cadence, duration cutoff), zero
`detections` records, `timelapse_capture` + `capture` records present, photos
in summary + time-lapse note; motion + detector modes regress unchanged (r95
sessions' summaries still show their motion-only rows).

## Round 98 (2026-07-14): human-readable, cross-device-unique ROI photo filenames

Photos used to be named `roi_<sessionStartEpochMs>_<captureEpochMs>.jpg` —
machine-sortable but unreadable in a file browser, and two phones recording
side by side could in principle produce the same name in the same millisecond.
New format (new sessions only; old sessions keep their old names):

`roi_2026-07-14_153045_123_k7x2.jpg`
= `roi_<yyyy-MM-dd>_<HHmmss>_<SSS>_<token>.jpg`, parse with
`^roi_(\d{4}-\d{2}-\d{2})_(\d{6})_(\d{3})_([a-z0-9]+)\.jpg$`

- Timestamp is the capture moment in LOCAL device time, zero-padded fixed
  width, so alphabetical filename order == capture order (the gallery export's
  path sort relies on this — `session_summary_screen.dart`).
- Token = 4 random base-36 chars drawn once per session with `Random.secure()`
  (`session_recorder.dart`), reused on every photo and logged as `file_token`
  in the start record. Two phones collide only on same millisecond AND same
  token (~1 in 1.7 M), and the log ties any photo back to its session/phone
  even after folders from several phones are merged for analysis.
- Implementation: public `roiPhotoFileName(epochMs, token)` in
  `capture/roi_capture.dart`; the scheduler's `sessionId` field (only ever
  used for filenames) became `sessionToken`; `SessionRecorder.start`'s
  `captureBuilder` callback now passes the token instead of the session id
  (the epoch-ms `session_id` is still logged unchanged in the start record).
- Track ids stay OUT of the filename (unchanged): one photo can serve several
  concurrent tracks; ids live in the JSONL `capture` records.
- Cost: a handful of string ops once per saved photo — nothing on the frame path.
- Tests: the two exact-name assertions in `roi_capture_scheduler_test.dart`
  now compare against `roiPhotoFileName(...)` (timezone-independent) and one
  locks the format with the regex above. Full suite green (172 tests).

## Round 99 (2026-07-14): token-first photo names + trigger-time "Captured" stamp

Field follow-up on round 98 after the first live session (session_132).

- **Token moved to the front**: `roi_<token>_<yyyy-MM-dd>_<HHmmss>_<SSS>.jpg`
  (e.g. `roi_elhp_2026-07-14_155813_119.jpg`), parse with
  `^roi_([a-z0-9]+)_(\d{4}-\d{2}-\d{2})_(\d{6})_(\d{3})\.jpg$`. Rationale:
  photos from many sessions/phones pooled into one folder (post-processing,
  model training) now sort grouped by session automatically; within a session
  the token is constant, so alphabetical order is still capture order and the
  gallery export's path sort keeps working.
- **The three timestamps of one photo, documented** (they looked inconsistent
  on the Photos tab but all were correct): the FILENAME stamp is the trigger
  moment (frame time when the scheduler declared a photo due,
  `PendingCapture.capturedAtMs`); the `detections` record's `time_ms` is
  ~tens of ms later (stamped when the record is enqueued, after tracking);
  the `capture` record's `time_ms` is when the JPEG finished writing
  (~0.8 s later for a full-res still). The Photos tab used to show the
  detections-record time, hence the near-miss vs the filename.
- **Fix — trigger time logged explicitly**: `CaptureStat.capturedAtMs` (new)
  is logged as `captured_at_ms` in `capture` records, and
  `motion_capture`/`timelapse_capture` records carry it too. The summary's
  photo browser prefers `captured_at_ms` for the "Captured" row, so it now
  matches the filename stamp exactly. Old logs lack the field and fall back
  to the previous behavior.
- **EXIF finding (no change, user opted to skip)**: saved crops carry NO EXIF
  at all — every save path re-encodes raw pixels (native still crop uses
  BitmapRegionDecoder which ignores EXIF; fast path encodes the RGB analysis
  frame; Dart fallback uses package:image). Filename + JSONL are the ground
  truth for capture time.
- **session.jsonl stays strict JSON Lines** (one object per line): decided
  against pretty-printing — it would break the app's own line-oriented
  readers and standard tooling (`jq`, pandas `lines=True`). For human
  reading: `jq . session.jsonl | less`.
- Tests: format-locking regex updated (token-first); full suite green (172).
## Round 100 (2026-07-14): REC banner countdown + scheduled-run session position

- The red REC pill (top of the live screen) now has a second, smaller line
  under "REC mm:ss": the time LEFT until the recording auto-stops, e.g.
  "54:48 left". Works in every capture mode (detector / motion-only /
  time-lapse) because the pill is mode-independent — it renders whenever
  `_recording` is true.
- The end moment lives in a new `_recordEndAt` field, set in
  `_startRecording`: manual session → now + `sessionMinutes` (same Duration
  used to arm `_sessionTimer`); scheduled window → `SchedulePlan.endOf(slot)`
  (session length is deliberately ignored in scheduled runs — unchanged r94
  rule, the countdown just mirrors it honestly). Cleared in `_stopRecording`.
  Countdown clamps at 0 (a scheduled stop can lag the window end by ≤1 tick).
- Scheduled runs additionally show which session of the planned bundle is
  recording: "· session k/N" on the same line, where k = the slot's position
  in the whole plan (day × windowsPerDay + windowIndex + 1 — same ordering as
  the folder `d<day>w<win>` suffix) and N = days × windowsPerDay. Bundle
  POSITION, not sessions-recorded count: a run started mid-day that skips the
  morning window still labels the afternoon window by its plan position.
- Elapsed and remaining are shown as two separate values (never merged into
  one number) per the one-scale UI rule; both use `_formatElapsed`
  (mm:ss → hh:mm:ss → dd:hh:mm:ss).
- No new tunables, no log-format change. `flutter analyze` clean; full test
  suite green (171).

## Round 101 (2026-07-14): app renamed Pollinator Monitor → FaunaPulse

- Rationale: with swappable detectors + the AI-free capture modes (motion,
  time-lapse) the app monitors any organism, not just pollinators. Name vetted
  2026-07-14 (no existing app/software/company "FaunaPulse"; first pick
  "FieldPulse" dropped — existing field-service SaaS).
- Full rebrand INCLUDING the Android applicationId:
  `com.pollinatormonitor.app` → `com.faunapulse.app` (new app identity on the
  phone: old install's sessions must be adb-pulled before uninstalling; prefs
  start fresh). Dart package `pollinator_monitor` → `fauna_pulse`;
  `lib/pollinator/` → `lib/fauna_pulse/`; `test/pollinator/` →
  `test/fauna_pulse/`; method channels `pollinator/*` → `faunapulse/*`
  (Kotlin+Dart in lockstep); notification channel `faunapulse_recording`;
  wakelock tag `FaunaPulse::RecordingWakeLock`; gallery album
  `Pictures/FaunaPulse` (old exports stay in Pictures/PollinatorMonitor);
  prefs keys `faunapulse_*`; android:label + UI titles "FaunaPulse";
  `PollinatorApp` → `FaunaPulseApp`; rootProject.name "FaunaPulse".
- Deliberately NOT renamed: Kotlin namespace/packages `com.ultralytics.yolo`
  (vendored-plugin heritage), plugin package `ultralytics_yolo`, this
  changelog's historical entries, existing session folders on disk,
  `session.jsonl` format (the brand never appears in it — parsers unaffected).
- README: title + one added sentence on organism-generic use; biological
  "pollinator" wording and the three literature citations kept.
- Repo renamed `valentinitnelav/pollinator-monitor` → `valentinitnelav/fauna-pulse`
  (GitHub redirects old URLs); local folder `pollinator-monitor/` → `fauna-pulse/`.

## Round 102 (2026-07-14): new FaunaPulse app icon

- Owner-provided artwork (bee inside blue camera-focus brackets on a white
  rounded card, 1254 px) replaces the Ultralytics template icon. Master kept
  at `android/app/src/main/ic_launcher-playstore.png` (Android Studio
  convention); all shipped sizes are generated from it — regeneration script
  pattern: PIL card-bounds detect → square crop → per-density resize.
- Adaptive icon (API 26+, what the test phones show): foreground PNGs
  (`drawable-*/ic_launcher_foreground.png`, central 78% of the card) with the
  XML inset raised 16% → 27% so the bracket corners stay inside the 66 dp
  safe circle (round masks never clip them); `ic_launcher_background`
  changed #2E7D32 → #F9F9F9 = the card's own fill, so the foreground's
  square edge is invisible under any mask shape.
- Legacy mipmaps (`mipmap-*/ic_launcher.png`, API < 26): the card itself with
  transparent rounded corners (radius 21%, 4× supersampled mask).
- No code changes; debug APK builds clean.

## Round 103 (2026-07-14): delete-all-sessions via home-screen overflow menu

Owner request: a way to free phone storage after many recordings without
deleting sessions one by one from their summaries — but hard to trigger by
accident.

- **New ⋮ overflow menu, top-right of the home screen** (`home_screen.dart`).
  A `PopupMenuButton<_HomeMenuAction>` floats over the corner via a `Stack`
  (the centered title block is untouched). Deliberately a menu, not a bare
  button: the owner wants a future home for other all-session actions
  (filtering by name/date, bulk export, …) — add new `_HomeMenuAction` values.
- **"Delete all sessions…"** item (red `delete_sweep` icon), disabled while the
  list is empty.
- **Type-to-confirm guard** (`_confirmDeleteAllSessions`): the dialog shows the
  session count + total size (sum of the already-scanned `sizeBytes`, via
  `formatBytes`) and the red "Delete all" button stays disabled until the user
  types `delete`. Chosen over a plain confirm dialog: bulk-deleting field data
  is the app's most destructive action, one stray tap must never suffice.
- **Deletion is per recognized session folder** (`s.logFile.parent.delete(
  recursive: true)`), NEVER the `sessions/` root — stray owner files placed
  there over USB survive. Failures go through `logSwallowed('sessions_delete_all')`
  + a "Could not delete N session(s)" SnackBar. A non-dismissible progress
  dialog covers the UI while deleting (thousands of JPEGs take seconds), then
  `_loadSessions()` rescans.
- `flutter analyze` clean; all 171 tests pass (no new pure logic to unit-test —
  the flow is dialog UI + file I/O).

## Round 104 (2026-07-14): fix delete-all-dialog teardown crash from first field test

Field test of r103 (a ~30 min pollinator session, then "Delete all sessions…")
ended in a red assertion screen: `framework.dart:6268 '_dependents.isEmpty':
is not true`. The deletions themselves completed (sessions gone after
restart) — only the widget teardown crashed.

- **Root cause:** that assertion is `InheritedElement.debugDeactivated` — an
  inherited widget was deactivated while widgets still depended on it. The
  r103 confirm dialog used a `StatefulBuilder` with a caller-owned
  `TextEditingController`; on confirm the caller disposed the controller AND
  pushed the progress dialog in the same synchronous turn, while the confirm
  dialog (auto-focused text field, keyboard up) was still animating out —
  its subtree was torn down in the wrong order.
- **Fix:** the dialog is now its own widget, `DeleteAllSessionsDialog`
  (public, so tests can drive it), whose State owns and disposes the
  controller — the framework controls the teardown order. Both close paths
  also `unfocus()` the keyboard before popping.
- **Regression tests** (`test/fauna_pulse/home_delete_all_dialog_test.dart`,
  3 new, 174 total passing): button disabled until `delete` typed
  (case/whitespace tolerant), Cancel path, and the exact crash sequence —
  confirm with focus held + progress dialog pushed in the same turn, then
  `pumpAndSettle` through the exit animation (the r103 code trips the same
  debug-mode assertion under `flutter test`).
- Note: the crash never reached the session log or an error report because it
  was a Flutter framework assertion on the home screen (no recording active),
  and the logcat capture ended at USB disconnect before the exception printed.

## Round 105 (2026-07-14): selectable tracker — C-BIoU alternative + offline replay harness

Follow-up to a documentation-based tracker review (ByteTrack / BoxMOT /
Roboflow-trackers READMEs). Conclusion there: keep ByteTrack as the default;
the one algorithm worth having as an on-device alternative is C-BIoU
(Yang et al., WACV 2023) — buffered-IoU matching designed for exactly this
app's hard case (small boxes, abrupt motion, 2–20 irregular FPS), needing
only geometry + confidence (no ReID model, no Kalman). Owner asked for it as
a selectable option with ByteTrack staying the default.

- **`tracking/tracker.dart` (new):** `InsectTracker` interface (update/reset/
  expireLostTracks/confirmedTracks/totalConfirmed/setFrameBudgets/
  effectiveParamsJson/algorithmName) + `TrackerAlgorithm {bytetrack, cbiou}`
  enum. `ByteTracker` implements it (no behavior change); `FrameProcessor`
  and the camera screen now only know the interface. `FrameProcessor.tracker`
  is mutable: settings-close (locked while recording) rebuilds the tracker via
  `_buildTracker` and swaps it in, so an algorithm change never restarts ids
  mid-log and the processor's gate state survives the settings visit.
- **`tracking/c_biou_track.dart` (new):** C-BIoU-style tracker. Cascaded
  greedy matching on buffered IoU (boxes enlarged by `bufferScale1` = 0.30,
  then leftovers by `bufferScale2` = 0.50; pass 2 auto-clamped ≥ pass 1);
  fixed small `_minBiou` 0.05 floor and fixed velocity-EMA 0.5 (deliberate
  constants — buffering absorbs prediction error, that's the algorithm's
  point). Shares ByteTrack's visit semantics: high-score spawn rule (faint
  band only revives ids), tentative/confirmed/lost lifecycle, frame budgets
  re-derived live from the user's seconds.
- **Config:** `trackerAlgorithm` (default bytetrack; pre-r105 configs and
  unknown names fall back to it), `cbiouParams`, `logRawDetections` — all in
  copyWith/toJson/fromJson with round-trip tests. Start record logs
  `tracker_params: {algorithm, ...}` via `effectiveParamsJson()`.
- **Settings AI tab — "Visit tracking" section (Icons.polyline):** algorithm
  dropdown (one-sentence plain-language contrast), the two shared seconds
  controls stay visible ("Min hits to confirm" relabeled **"Minimum visit
  length"**, matching SETTINGS_REFERENCE), everything else moved into a
  collapsed **Advanced** ExpansionTile that shows ONLY the selected
  algorithm's knobs (ByteTrack: match overlap / low-score / high-score /
  velocity smoothing; C-BIoU: search margins pass 1+2 / high-score), plus
  "Reset tracking to defaults" (keeps the algorithm choice; respects the
  Confidence-coupled high-score floor, which now applies to BOTH trackers'
  highThresh) and the raw-detections toggle. Summary Settings tab shows the
  algorithm in the sub-header and only that algorithm's params (old sessions
  = ByteTrack).
- **Evaluation pipeline (the "compare on real data" plan):**
  `logRawDetections` writes one `raw_detections` record per processed frame
  (detector-mode only; empty frames included — frame-count aging needs them):
  `{frame_ms, boxes: [[l,t,r,b,conf,cls], ...]}` frame-normalized, ~1–2 MB/h.
  `FrameResult` now exposes the pre-tracking `detections` (already built).
  `tracking/tracker_replay.dart` (new) parses those records and replays them
  through any tracker, reproducing the live seconds→frames behavior (FPS EMA
  with the r85 pause guard; budget re-derive ~1/s; long gap ⇒ one empty
  update + expireLostTracks, mirroring the gate-wake rule). Reports visits +
  per-visit durations + max concurrent — deliberately NOT MOTA/HOTA; judge
  against a hand count from the session's photos. Run:
  `flutter test test/fauna_pulse/tracker_replay_test.dart
  --dart-define=REPLAY_SESSION=/abs/path/session.jsonl` (prints one summary
  line per tracker; reads the session's own occlusion/min-visit seconds from
  its start record).
- **Tests:** `c_biou_track_test.dart` (buffered match holds an id across a
  jump plain IoU loses + the knob's failure direction, cascade pass-2 rescue,
  shared visit semantics, mis-ordered scales clamp), `tracker_replay_test.dart`
  (parser vs the real on-disk envelope, visit counting/durations, gap-expiry),
  config round-trips, FrameResult.detections exposure. 196 tests green,
  analyzer clean.
- Docs: SETTINGS_REFERENCE "Visit tracking" section rewritten (both
  algorithms + Advanced table), DATA_GUIDE `raw_detections` record type.
- Not done (deliberate): no benchmark-number-driven default change — MOT17/
  SportsMOT/etc. numbers in the reviewed READMEs are pedestrians/sports at
  ~30 FPS and don't transfer to insects-in-ROI; the replay harness on owner
  field sessions is the decision tool. C-BIoU stays "experimental" in the UI
  until it wins there.

## Round 106 (2026-07-15): neutral tracker names + first replay evaluation (screen tests)

- **UI (owner request):** tracker dropdown shows plain names only — "ByteTrack"
  / "C-BIoU", no "field-tested default"/"experimental, for fast/erratic
  movers" qualifiers — while the comparison is still open; the helper text
  below was neutralized the same way (mechanics only, no recommendation).
  SETTINGS_REFERENCE row matched. Default stays bytetrack.
- **First real evaluation** (owner screen test: phone at a laptop playing a
  looping bee-pollination video; one session per tracker, raw logging on;
  sessions/Xiaomi/sessions/session{,_2}):
  - Pipeline verified end-to-end: `raw_detections` written for every frame
    (966/919, incl. empty ones), no corrupt lines, no `app_error`s, and the
    replay harness reproduced each live run EXACTLY (cbiou session: live 3
    ids ↔ replayed cbiou 3 visits; bytetrack session: live 2 ↔ replayed 2).
  - Cross-comparison on identical input: bytetrack 2 visits (long durations)
    vs cbiou 3 (session 1); bytetrack 2 vs cbiou 5 (session 2). C-BIoU
    fragments here. Mechanism measured from the raw boxes: detections are
    tiny (median ~0.056×0.04 normalized) and the bee repeatedly jumps
    ~0.14 frame-widths between consecutive frames; C-BIoU's buffers scale
    with BOX SIZE, so even pass 2 (0.5) reaches only ~0.11 — short of the
    jumps — while ByteTrack bridges them via velocity prediction + the
    distance fallback's ABSOLUTE 0.05 floor. A buffer sweep (throwaway test,
    deleted) was non-monotonic — b2 1.0 made it worse (noise matches), b2
    ≥1.5 partial recovery, never reaching bytetrack's 2 — so this is not
    fixable by one knob on tiny boxes.
  - Caveats: no ground truth (unknown loop count), screen artifacts, and the
    video-restart teleport SHOULD split ids (a new continuous appearance is
    a new event by app semantics — "one id across restarts" is not the goal).
    Early evidence still favors bytetrack as default; retest on real-field
    sessions with a hand count.
- No config/format changes; analyzer + 196 tests green.

## Round 107 (2026-07-15): ChatGPT-critique follow-ups — variant A/B flags + ground-truth frame dump

Owner had ChatGPT review the r105 tracker analysis. Point-by-point verdict:
its two best catches were (1) motion should be normalized by REAL elapsed
time (our velocity was per-frame while field frame gaps swing 130→950 ms) and
(2) my "the distance fallback already gives you C-BIoU's benefit" was too
strong — the hybrid (buffered-IoU fallback INSIDE ByteTrack) deserved a test.
Its ground-truth-circularity critique was half right: raw_detections records
already ARE the pre-tracker cache it demanded, but the photo record used for
hand counts WAS tracker-triggered. Its "don't ship a selectable tracker"
recommendation was overtaken (owner explicitly wanted it, r105); the license/
benchmark-scoping/ReID-phrasing corrections were fair but prose-only.

- **Internal variant flags (constructor-only, NEVER SessionConfig/UI;
  adoption rule: default only changes after winning on gt-frame hand counts):**
  - `timeAwareMotion` on BOTH trackers: velocity in normalized units/second
    measured from the last true observation (`lastObservedCenter`) over real
    dt; association + coasting use `Track.predictedBoxAfter(dt)` with the
    frame's actual gap (capped 2 s). Legacy per-frame path untouched and
    still the default.
  - `FallbackMode {distance, bufferedIou}` on ByteTracker: the third pass
    can score by buffered IoU anchored at the last observed position, box
    reach = max(0.5 × size, 0.05 absolute floor) per side, accept ≥ 0.05.
- **Replay harness:** frame-stream degraders (`keepEveryNth`, `injectGaps`,
  `staircaseFps` — timestamps always original), report now carries tracker
  ms/frame (mean/p95), `peakActiveTracks` (new `InsectTracker.activeTrackCount`),
  and the optional REPLAY_SESSION test prints a permanent 6-variant × 2-stream
  matrix (no more throwaway sweep files).
- **Variant matrix on the r106 screen sessions** (no ground truth — loop
  count unknown — so NO defaults changed): `byte` 2/2 visits; `byte dtAware`
  identical 2/2 (no regression); `cbiou` 3/5 → `cbiou dtAware` 2/4 and under
  the 15/3/10 staircase 4→3 — time-aware motion consistently reduced C-BIoU
  fragmentation and never hurt. `byte bIoU-fb` collapsed both sessions to
  ONE ~2-minute visit — the 0.05 absolute reach floor on 0.06 boxes bridges
  the ~0.15 video-restart teleports, i.e. it over-merges; evidence AGAINST
  adopting it as-is (the distance gate's 1.5×diag scaling is what keeps
  ByteTrack from doing the same).
- **Ground-truth frame dump (user-facing, owner-specified):**
  `gtFramesEnabled` (off) + `gtFrameSeconds` (5 s; 1 s–1 h via
  DurationSettingField) in tracking Advanced; a SECOND RoiCaptureScheduler
  writes into `gt_frames/` on its own clock (`evaluateMotion` with a 1<<50
  duration = pure periodic window; scheduler-window test added), driven by a
  1 s screen timer through `SessionRecorder.recordGtFrame` so dumps continue
  while the motion gate sleeps. Same photo pipeline ⇒ size follows
  `targetRoiSavedPx` (deliberately no new resolution setting). One
  `gt_capture` JSONL record per save (jpeg, captured_at_ms, timing/size),
  logged from onStat AFTER the write. Not in the summary Photos tab yet
  (future work). Reset-tracking-defaults covers the new fields.
- Docs: SETTINGS_REFERENCE Advanced table + DATA_GUIDE `gt_capture` record.
- 206 tests green (new: time-aware + buffered-fallback knob tests, degrader
  tests, gt scheduler window, gt config round-trip), analyzer clean.

## Round 108 (2026-07-15): still-photo sync — content-lag instrumentation + companion live crop; tracker verdict on bumblebee sessions

**Tracker verdict (sessions/Xiaomi/sessions/session_3..5 — looping bumblebee
video, occlusion 4 s, owner expectation ~1 visit, raw logging on; replay
matrix run on all three):** plain ByteTrack hit ground truth — 1 visit in
session_4 and session_5, 2 in session_3 (max-concurrent 2 there ⇒ a brief
second SIMULTANEOUS detection, not fragmentation). C-BIoU fragmented 3–6
visits on identical input in every session. The r107 variants added nothing:
byte was already at truth; dtAware didn't reliably help cbiou on this data
(and its r106 promise didn't replicate); bIoU-fb changed nothing here after
over-merging in r106. ByteTrack stays default; variants remain unadopted.
Docs updated; no tracker code changed.

**Still-photo lag (the owner's "insect gone from the photo" bug — e.g.
session_3 roi_c7bk_2026-07-15_010515_968.jpg):** all s3/s4 photos took the
still path (small ROI → fast crop < 1024 target) with median **760 ms**
trigger→file; session_5 (big ROI → fast path) is ~100 ms and in sync. The
plugin requests ZERO_SHUTTER_LAG and the Xiaomi GRANTS it (logcat), yet the
content is late ⇒ ZSL requested but not effective — prime suspect: the r82
Camera2 interop options (AE fps range / manual focus). Two fixes:

- **Content-lag instrumentation:** `takeRawStill` (YOLOView.kt) stamps
  `t0 = elapsedRealtimeNanos()` before takePicture and computes
  `contentLagMs = (imageInfo.timestamp − t0)/1e6` (sensor timestamp;
  NEGATIVE = ZSL really served a pre-request frame) + `callbackLagMs`;
  threaded through `capturePhotoRaw` (named record fields — `.$1..$3` call
  sites untouched) → `RawStill` → `CaptureStat` → `capture`/`gt_capture`
  records (`content_lag_ms`, `callback_lag_ms`), plus a `grab_ms` split of
  `total_ms` measured in the scheduler for both paths.
- **Sync companion (`stillSyncCompanion`, default ON; Camera-tab switch under
  the photo-source dropdown):** when a photo takes the still path, the
  scheduler FIRST saves the trigger-moment live-frame crop as
  `<name>_live.jpg` (cheap memory grab; `.jpg` sorts before `_live.jpg` so
  pairs stay adjacent — filename invariant intact), then the still. Written
  even when the still fails, and then reported as the capture (path `fast`),
  so every trigger yields at least one in-sync image. `capture` records carry
  `live_jpeg`/`live_bytes`/`live_saved_px`. Photos tab intentionally shows
  only primary photos for now (companions reachable via capture records —
  future work); gallery export naturally includes companions.
- **Owner experiment queued:** one session with Camera frame rate cap = 0 —
  if `content_lag_ms` goes negative, the r82 interop cap is what defeats ZSL
  (then decide: still-aware cap vs living with the companion).
- 210 tests green (new: companion two-file write + still-fails + disabled
  cases, config round-trip), analyzer clean, `flutter build apk --debug` OK
  (Kotlin change compiles).


## Round 109 (2026-07-15): ROI in the user's scale, ROI history, auto stream default

Owner field test session_6 (first run of the r108 companions) + follow-up review.

**Session_6 findings**
- The `_live.jpg` sync companions work: every still had its trigger-moment live
  crop beside it (480 px — the ROI's size in the 1440×1080 stream).
- `content_lag_ms` ≈ 380–450 ms on all 11 stills — positive, so ZSL is still
  not effective (session ran with cameraFpsCap 15; the fps-cap=0 experiment is
  STILL PENDING). Owner also observed motion-ghosting on stills vs sharp live
  crops — consistent with the still pipeline's longer effective capture
  (multi-frame processing), another reason the companion matters.
- "Initial ROI 1333×1333" mystery SOLVED: the start record's `roi` block is
  logged against `_roiLogDims` = the full-res still (3000×4000) on the still
  path; 480/1080 × 3000 = 1333. Not a bug in the box — a wrong-scale display.

**Changes**
- `roi_side_stream_px` now logged in the start record and every `roi_update`:
  the ÷32 stream-grid side the user saw (same `savedSidePx` math as the live
  readout). The `roi` block stays as-was (append-only back-compat). Summary
  "Initial ROI" shows it (pre-109 logs: recomputed via new pure
  `roiStreamSideFromLog` — fraction re-projected onto the analysis frame);
  new "Initial ROI saves" row = `saves_px via still|fast crop`.
- `roi_update` writes are DEBOUNCED (new `logging/roi_update_debouncer.dart`,
  2 s stability, seeded with the start ROI, skip-if-unchanged, flushed in
  `_stopRecording` before the logger closes, cancelled on dispose). One record
  per settled adjustment instead of one per drag tick. Box + inference ROI
  still follow the finger immediately — only logging waits.
- Summary Settings tab: lazy `_loadRoiHistory()` scan renders "ROI changes
  during the session" (+offset, size, saves) from `roi_update` records.
- Auto stream-resolution default (owner request: bias away from laggy stills):
  new `SessionConfig.streamResolutionExplicit` (pre-109 configs migrate:
  stored size ≠ 640×480 ⇒ explicit, never stomped). While non-explicit, the
  camera screen once-per-lifetime applies `autoStreamResolution` (new pure fn:
  smallest probed size with short side ≥ 1024, honouring the r56 analysis
  ceiling via new `analysisCeilingProbed` flag) — on the Xiaomi that yields
  1440×1080. Settings dropdown gains an "Auto — smallest with short side
  ≥ 1024 (this phone: …)" first item; a manual pick sets explicit. Heat
  trade-off sentence added to the note under the dropdown; summary shows
  "(auto)" on the stream row. NOTE: what decides fast-vs-still is
  ROI-fraction × stream short side, so auto helps but a small box on a big
  frame can still need stills — the capture decision logic is unchanged.
- Docs: DATA_GUIDE (`roi_side_stream_px`, roi-block scale warning, debounce
  semantics), SETTINGS_REFERENCE (Auto option + heat), OVERVIEW refreshed.
- 225 tests green (new: debouncer fake_async suite, autoStreamResolution +
  roiStreamSideFromLog tables, explicit-flag round-trip/migration; fake_async
  added to dev_dependencies), analyzer clean, debug APK builds.

## Round 110 (2026-07-16): ZSL verdict from session_14 + fps-cap help-text fix

Owner ran the requested experiments; analysis + one wording fix, no behavior change.

**Findings (sessions 12 & 14; both: 1440×1080 stream, manual focus, still path,
minHitsSeconds 0.5)**
- session_12 (cameraFpsCap 15): still `content_lag_ms` median ~408 ms — matches
  session_6. session_14 (cap 0): median ~172 ms, callback lag ~470 ms. So the
  r82 camera fps cap WAS throttling the still pipeline (every capture stage
  waits on sensor frames), and manual focus is exonerated (active in both).
- But content lag never goes negative even uncapped: CameraX grants
  ZERO_SHUTTER_LAG and the HAL still serves a post-trigger frame. ~0.17 s is
  this phone's floor — not worth chasing further in software; the r108
  `_live.jpg` companion IS the zero-lag capture of the trigger moment.
- Extra latency knob identified while answering the owner's trigger question:
  photos are scheduled from TRACKER-CONFIRMED tracks
  (`session_recorder.dart` → `RoiCaptureScheduler.evaluate`), so "Minimum
  visit length" (0.5 s in these sessions) also delays the FIRST photo of a
  visit by that much. Trade-off (earlier first photo vs photos of false
  positives) documented for the owner; no change.
- Owner confirmed the r109 summary fix: "Initial ROI 480 × 480 px" shown.

**Change**
- Camera frame rate cap helper text (settings_sheet.dart) reworded: the old
  text used "default" for two different things back-to-back ("0 = device
  default" then "Default 15"). Now: 0 = removes the cap (camera's own full
  rate, ~30/s on most phones), the app *ships set to* 15/s, and the measured
  still-lag trade-off (~0.4 s at 15/s vs ~0.17 s uncapped) is stated.
  SETTINGS_REFERENCE row updated to match; OVERVIEW sync-companion note
  updated with the ZSL verdict.
## Round 111 (2026-07-16): view `_live` companions in the summary photo browser

Owner request: the r108 sync companions (`<name>_live.jpg`, the trigger-moment
live-stream crop saved beside every still-path photo) were on disk and in the
log but invisible in the app — the summary Photos tab only showed the stills.
Seeing both matters: the companion shows where the insect really was at the
trigger moment, so flipping between the two makes the still's content lag
directly visible (the owner's main use: eyeballing how far stills lag).

- `_loadPhotos` (summary screen) now also reads `live_jpeg`, `live_saved_px`
  and `content_lag_ms` from `capture` records; `_PhotoSample` carries
  `liveFile`/`liveName`/`livePx`/`contentLagMs` (companion only offered when
  the file really exists — it is saved best-effort).
- New ⚡ tool button in the photo viewer (only rendered when the loaded photos
  have any companion) toggles still ↔ companion, viewer-wide like the boxes
  toggle. Photos without a companion (fast-path photos ARE live crops) keep
  showing their own file; an amber bottom-left chip says which image is on
  screen, including the still's measured lag ("still lags N ms").
- Detection boxes need no remap: they are ROI-normalized from the trigger
  frame, so they overlay the companion directly (and align better there).
- Crop & export follows the toggle: the box size readout uses the shown
  image's real saved px (`_shownSidePx`), and Save/Share cut from the file on
  screen with its own export name.
- Info panel follows too (Resolution "(live companion)", File shows the
  `_live` name) and gains two rows: "Still lag" (`content_lag_ms`, shown in
  both views) and "Companion" (name + pointer to the ⚡ button when the still
  is shown).
- Photos tab shows a short explainer paragraph when companions exist: still =
  sharper but a fraction of a second late; companion = lower-res but the exact
  trigger moment.
- No new SessionConfig field: this is a viewer-only toggle like the box
  overlay, not a capture tunable. `flutter analyze` clean, 225 tests pass.

## Round 112 (2026-07-16): photo-viewer field feedback — no buttons over the photo, live view default, per-view lag

Owner feedback on r111: (1) with four tool buttons the in-photo top-right
column overlapped the › nav arrow and covered the image; (2) "Still lag"
under the live view read as if the LIVE image were late; (3) the live
companion should be the default view since its boxes match the insect's
real position.

- **No button may overlap the photo.** The four tool buttons (boxes, ⚡,
  crop, zoom) moved out of the photo into a right-aligned ROW above the
  preview; the zoom slider is now horizontal under that row; the ‹ ›
  arrows moved into a row UNDER the preview flanking the "Photo X / Y"
  caption; the zoomed pan pad became a horizontal strip under that. Only
  the text-only mode chips (crop/zoom hints) still overlay the image.
- **Live companion is the default view** (`_showLive = true`): the ⚡
  button now switches TO the high-res photo; tooltip + Photos-tab
  explainer reworded. The r111 amber overlay chip was dropped — a
  "Showing" info row (only rendered when the photo has two files) states
  which file is on screen instead.
- **Per-view lag.** The info panel shows one "Lag" row describing only
  the image on screen: the still's measured `content_lag_ms`, or the
  companion's NEW `live_lag_ms` ("≤ N ms", an upper bound measured at
  fast-grab return in roi_capture.dart — grab completion minus trigger
  moment, before the file write). Plumbed CaptureStat.liveLagMs →
  `live_lag_ms` in `capture` records; documented in DATA_GUIDE.md.
  Pre-r112 logs simply lack the row in live view.
- Crop/export continues to follow the shown file (both variants
  croppable — the high-res one still carries more px per insect).
- Rename of the "still"/"live" terminology discussed but NOT executed
  this round (needs an owner decision — touches JSON keys, filenames,
  settings and docs; options proposed in chat).
- `flutter analyze` clean, 225 tests pass.

## Round 113 (2026-07-16): "still" → "high-res" rename (live / high-res pair), wire format frozen

Owner decision (follow-up to the r112 naming discussion): the high-resolution
photo path is no longer called "still" anywhere a person reads — the old name
wrongly suggested crisp images, when these are the slower, motion-blur-prone
ones. The photo pair is now **live** (trigger-moment stream crop) /
**high-res** (full-resolution capture).

**WIRE FORMAT IS FROZEN — nothing on disk changed.** Every recorded session,
saved config and R/Python script keeps working:
- `capture.path` and `roi_source` still log `"still"`/`"fast"` — via the new
  `CapturePath.wireName` getter (`.name` is no longer logged anywhere).
- config JSON `captureMode` still saves `"still"` — via `_captureModeWireName`
  in session_config.dart; `_captureModeFromJson` accepts `still`, `highRes`
  (defensive) and the legacy `fullResPhotos` bool.
- JSON key `stillSyncCompanion` and the `_live.jpg` suffix are unchanged.
- New tests pin the freeze: `session_config_test.dart` ("r112 wire freeze")
  asserts toJson writes `still`; `roi_capture_test.dart` asserts
  `CapturePath.highRes.wireName == 'still'`.
- Diagnostic tags `native_still_crop` / `still_size_probe` kept (log grep
  continuity).

**Dart identifiers renamed:** `RoiCaptureMode.still` → `.highRes`,
`CapturePath.still` → `.highRes` (+ `wireName`/`uiName` getters),
`stillSyncCompanion` → `highResSyncCompanion`, `RawStill` → `RawHighRes`,
`stillCaptureFn` → `highResCaptureFn`, `stillDims` → `highResDims`,
`uprightStillDims` → `uprightHighResDims`, `stillW/H` → `highResW/H`, plus
comment sweeps in roi_capture, camera_session_screen, settings_sheet,
session_summary_screen, camera_diagnostics_controller, session_logger,
crop_export, tracker_replay. On-screen "(still)" readout now says
"(high-res)" via `CapturePath.uiName`; the summary translates logged wire
values for display ("Photo source mode: high-res", "via high-res photo").

**UI strings:** Settings photo-source label/dropdown ("Auto — high-res only
when needed", "High-res photos always"), companion switch "Sync companion
photo (high-res)", camera-fps help text; summary Settings rows.

**Docs:** SETTINGS_REFERENCE, DATA_GUIDE, HOW_PHOTO_RESOLUTION_WORKS,
ARCHITECTURE, OVERVIEW rewritten to the new vocabulary, each noting that
`"still"` remains the frozen wire value. AGENT_CHANGELOG history untouched
(append-only record).

**Deliberately NOT renamed:** plugin/native Kotlin internals (`stillExecutor`,
CameraX ImageCapture is officially "still capture" — renaming would fight the
platform vocabulary), and all on-disk formats above. Reinstall not strictly
required, but the owner plans one anyway; old saved prefs load fine either way.

`flutter analyze` clean, 227 tests pass.

## Round 114 (2026-07-16): time-matched detection boxes for high-res photos

Owner question: since high-res photos lag their trigger, can the logged
detections be matched to each photo by timestamp instead of showing the
trigger frame's boxes? Answer: yes — and entirely OFF the live pipeline
(new log fields + display-time/offline matching; on-device re-inference on
stills rejected: heat). Owner picked: replace boxes on the high-res view
(not overlay), include the native precision change.

**Tier 1 — logging (additive wire fields only):**
- YOLOView.kt: `sensorNanosToEpochMs()` maps CameraX sensor timestamps
  (elapsedRealtime nanos) to epoch ms at callback/emit time, with a 10 s
  plausibility clamp for SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN HALs.
  `takeRawStill` now also returns `contentAtEpochMs` (the still content's
  sensor-exposure moment as epoch — unlike `content_lag_ms`, which is
  measured from takePicture() and misses the trigger→dispatch gap); the
  detector stream emit adds `frameSensorMs` per frame. `"timestamp"`
  (emit time) deliberately untouched — frozen semantics (scheduler windows,
  tracker dt, filename stamps).
- Dart: plumbed `contentAtEpochMs` through yolo_controller → RawHighRes →
  CaptureStat → `content_at_ms` in `capture` + `gt_capture` records.
  `detections` records now carry `frame_ms` (= the emit-time frame stamp,
  SAME clock basis as the frozen `raw_detections.frame_ms` — one key name,
  one meaning) and `frame_sensor_ms` (precise, when the HAL allows).
  ~45 bytes per insect-bearing frame.

**Tier 2 — summary viewer:** new pure module
`logging/photo_box_matcher.dart` (`contentMomentOf` — measured
`content_at_ms`, else the r108–113 approximation `captured_at_ms +
content_lag_ms + live_lag_ms` flagged approx; `toleranceMs` = max(250 ms,
1.5× median frame interval), a display heuristic deliberately NOT a
Setting; `roiMovedInWindow` with +2.5 s for the debouncer's stamp lag;
`NearestFrameAccumulator` — O(photos) memory, binary search).
`_loadPhotos` runs a second pass over the already-in-memory lines (skipped
for pre-r114 logs → behavior unchanged); the HIGH-RES view draws the
matched frame's boxes (matched entries rarely carry the photo's `jpeg`, so
they render in the co-detected amber — honest), the live view keeps
trigger boxes, and a new "Boxes" info row states the source and the signed
match delta (or the fallback reason). Caption detection count follows the
displayed boxes.

**Tier 3 — docs:** DATA_GUIDE §5b with the exact R (data.table
roll="nearest") and Python (merge_asof) join recipes + per-generation error
bounds, and the explicit recommendation that pixel-accurate boxes come from
re-running the detector offline on the saved crops. OVERVIEW updated
(logging invariant + photo-viewer bullet).

Tests: 14 new (matcher rules, logger field round-trip, frame-processor
parse, CaptureStat plumbing) — 241 pass, analyze clean, debug APK builds.
Not yet field-verified: needs one high-res session on the Xiaomi to confirm
`content_at_ms` ≈ `captured_at_ms + live_lag_ms + content_lag_ms` and an
eyeball of a fast-insect photo.

## Round 115 (2026-07-16): interpolated box placement for high-res photos (session_16 follow-up)

Owner field-tested r114 (session_16, owner-provided at
sessions/Xiaomi/sessions/session_16/) and reported misaligned boxes plus a
confusing "no detector frame within 250 ms of this photo's content" under a
photo whose Lag read 450 ms. Investigation findings (log + photos verified):

- r114's timestamps WORK: `content_at_ms` = trigger + 424–504 ms on all 16
  photos, consistent with live_lag + dispatch + content_lag.
- **KEY DISCOVERY: capturing a high-res photo pauses the analysis stream**
  (ImageCapture vs ImageAnalysis contention) — frame holes of 133–1532 ms
  bracket every capture, exactly across the content moment. The frames the
  matcher needs often don't exist BY CONSTRUCTION.
- **r114 flaw:** the hard tolerance rejection fell back to TRIGGER boxes
  (~500 ms from the content) — strictly farther than the frames it
  rejected (−323/−390/−589 ms).
- "N ms AFTER the content" labels are correct (first post-pause frame =
  nearest observation); the UI just never explained the pause.
- 13/16 photos had the SAME track on both sides of the hole.

**Fix (display-time only, no wire changes):**
- `photo_box_matcher.dart`: `NearestFrameAccumulator` →
  `FrameBracketAccumulator` keeping the nearest frame on EACH side
  (±`kBracketWindowMs` 1500 ms); the feed now walks OUTWARD from the
  binary-search point instead of touching two neighbours — r114 could
  starve the second of two photos sharing one pause of its post-hole frame.
  New `buildPhotoBoxes`: per-track linear interpolation of `box_in_roi` at
  the content moment when the track exists on both sides (span cap
  `kMaxBracketGapMs` 2 s; confidence/class from the nearer frame — never
  interpolated); one-side tracks emitted verbatim; both-null → null.
- Summary pass 2: ROI-move rejection now FIRST; the tolerance no longer
  rejects boxes — it only picks the "Boxes" row tone. Label matrix:
  interpolated → "estimated at this photo's moment — from detector frames
  X ms before and Y ms after"; both-sides-no-shared-track → both deltas +
  "no shared track to merge across the capture pause"; distant single side
  → "nearest available frame … the detector pauses while a high-res photo
  is taken"; fallback notes only "ROI was moved…" / "no detector frame
  within 1500 ms — the insect had likely left". Mixed photos mark
  uninterpolated boxes with a trailing ≈. Photos-tab explainer mentions
  the pause. `_PhotoSample`: `stillMatchDeltaMs` → `stillMatch`
  (PhotoBoxResult) + `stillWithinTol`.
- Replayed the REAL matcher over session_16 (throwaway test, deleted):
  14/16 photos now interpolate at the exact content moment (incl. the
  previously rejected −390/−589 cases); photo 132119_855 (track id 5→4
  switch across the pause) degrades to both single-side candidates;
  ZERO bare trigger-box fallbacks.
- DATA_GUIDE §5b: interpolation recipe + pause explanation + revised error
  bounds; tolerance documented as a labelling gate, not a discard.

Follow-up idea (not built): reduce the pause itself is not possible —
ImageCapture inherently contends; the sync companion + interpolation are
the mitigations. 250 tests pass, analyze clean.


## Round 116 (2026-07-17): explicit track lifecycle in session.jsonl (track_event lines)

Owner priority shift: reliable downstream analysis from session.jsonl over
the image-preview overlay. Review of the r114/115 work surfaced the real
logging gap — and corrected a wrong assumption along the way.

**Key verified fact (invariant, now documented in code):** the logged
`detections[].tracks[]` boxes are ALWAYS detector-observed. Both trackers
demote an unmatched confirmed track to `lost` in the same frame, and
`update()` only returns `confirmed` tracks — so velocity-coasted (predicted)
boxes never reach the log at all. (An earlier code-exploration report claimed
coasted boxes were logged unflagged; that was false.) Consequence: a track
temporarily vanishing from `detections` records was AMBIGUOUS — occluded?
gone for good? or simply no frames analyzed (r115: a high-res photo grab
pauses the analysis stream 0.13–1.5 s)? Nothing in the log said which.

**Change — additive, backward compatible:**

* New `track_event` record type (`SessionLogger.logTrackEvent`, flush:false
  like the other hot-path lines): one line per lifecycle transition.
  Fields: `event` (`created` = confirmed as a visit / `lost` = first
  unmatched frame / `recovered` = matched again, same id / `removed` =
  dropped for good), `track_id`, `frame_ms` (the transition's frame stamp),
  `box_in_roi` (for `lost`: the last OBSERVED box, captured before coasting
  starts), `hits`, `first_seen_ms` (tentative start = real visit start),
  `last_seen_ms` (for `recovered`: the pre-gap observation, so
  `frame_ms − last_seen_ms` IS the survived gap), `frames_missed` (when >0),
  `reason` (`aged_out` | `gate_expired`, removals only). Gate-expiry
  removals are stamped with the last processed frame (no frames arrive while
  the gate sleeps); the line's own `time_ms` carries the wake moment.
* Emission lives in a shared `TrackEventBuffer` mixin (`tracking/tracker.dart`)
  + `drainEvents()` on the `InsectTracker` interface, so a `track_event`
  line means one thing regardless of algorithm. Both trackers emit at the
  same four transitions (byte_track.dart / c_biou_track.dart); tentative
  tracks that die unconfirmed emit nothing (they were never a visit).
* Wiring: `FrameProcessor.process` drains the tracker into
  `FrameResult.events` (gate-wake expiry events ride with the NEXT processed
  frame) → `camera_session_screen` passes them to
  `SessionRecorder.recordFrame` → one `track_event` line each; the ~0.5 s
  fsync cadence now also triggers on event-only frames. The replay harness
  (`tracker_replay.dart`) drains-and-discards per frame so events can't pile
  up over thousands of frames.
* Defensive `coasted:true` key on `detections[].tracks[]` entries, emitted
  only when `timeSinceUpdate > 0` — never fires with the current trackers
  (see invariant above); it exists so a future tracker that returns
  predicted boxes can't silently pass them off as observations.

**Why it matters downstream:** visit stitching (merging fragmented ids into
one ROI event) and loss-vs-pause classification become deterministic joins
on `track_event` lines instead of heuristics over gaps in `detections`
timestamps. Cost: a handful of lines per visit, zero per-frame overhead.

Not built this round (agreed follow-ups): `analysis_gap` records (pause
detection without the raw-detections toggle), `trigger_frame_ms` on
`capture` records (exact photo↔frame join), live-crop-by-default capture
path decision, offline stitching helper script in `helper_scripts/`.

Tests: lifecycle sequences for both trackers (created→lost→recovered→
removed incl. `aged_out`/`gate_expired` + gap bookkeeping), FrameProcessor
drain wiring, logger schema line. 257 tests pass, analyze clean. Summary
screen ignores unknown record types, so old parsers are unaffected.

## Round 117 (2026-07-17): fast crops default + track_event in DATA_GUIDE + companion clarity

Owner decisions after r116: document the new record type for practitioners,
and stop treating high-res photos as the recommended baseline.

* **Capture-mode default: `auto` → `fast`** (`SessionConfig` constructor +
  the no-key `fromJson` fallback; configs with an explicit `captureMode`
  are untouched, legacy `fullResPhotos` migrations unchanged). Rationale
  (owner + r115/session_16 measurements): each high-res photo pauses the
  AI pipeline 0.13–1.5 s (worse on older phones), shows the scene after
  the trigger, and often carries motion blur — blur destroys exactly the
  detail the extra pixels were meant to add, so a smaller crisp live crop
  is usually MORE informative for downstream classification. High-res
  stays available (auto / always) as a deliberate opt-in.
* **"(recommended)" removed everywhere** for the capture mode: Camera-tab
  dropdown (fast now listed first) + info text (rewritten around the
  pause/lag/blur trade-off), SETTINGS_REFERENCE.md row,
  HOW_PHOTO_RESOLUTION_WORKS.md section (retitled from "auto mode" to the
  photo-source setting, with a "why fast is the default" paragraph).
* **Sync companion wording clarified** (owner found it ambiguous): the
  companion is ALWAYS the fast live-frame crop saved beside a HIGH-RES
  photo — never a second high-res photo — and the toggle does nothing on
  the fast path (a fast photo IS the live crop). Settings subtitle +
  SETTINGS_REFERENCE row now say so explicitly.
* **DATA_GUIDE.md §3: new `track_event` section** (r116 record): event
  meanings table (created/lost/recovered/removed + reasons), field table,
  and three usage recipes — visit boundaries without per-frame grouping,
  telling temporary track loss apart from analysis pauses (no `lost` line
  inside a frame-timestamp hole = pause, not a lost insect), and spotting
  id fragmentation for stitching (removed+created close in time/space).
  Also added the `tracks[].coasted` guard-flag row to the `detections`
  table (normally absent; every logged box is detector-observed).

Tests: default assertion updated + empty-config fallback covered. 257 pass,
analyze clean.
## Round 118 (2026-07-17): report sending (email), log sampling, persistent crash files

- **Report log sampling**: the error report now embeds a HEAD + TAIL sample of the latest
  `session.jsonl` (first 30 + last 200 lines, `… N lines omitted …` marker) instead of the
  last 300 — the first lines carry the start-record metadata, the last the failure-time
  context. Single lines are capped at 2000 chars (`raw_detections` can be huge). Live logcat
  embed reduced 3000 → 2000 lines. Pure helper `headTailSample` in `error_reporter.dart`
  (unit-tested in `error_reporter_test.dart`).
- **Email send option**: the "Report saved" dialog (home screen) gained an email text field
  (EMPTY by default — the developer's address is handed to testers privately, never shipped)
  plus an "Email…" button; the address persists in shared_preferences
  (`report_recipient_email`) — deliberately NOT SessionConfig, so it can never land in a
  shared session.jsonl. Mechanism: `sendEmail` on the `faunapulse/diagnostics` channel →
  Kotlin `sendFileByEmail` (`ACTION_SEND`, `message/rfc822`, `EXTRA_EMAIL`, FileProvider) —
  share_plus can't pre-fill a recipient and `mailto:` can't attach files. New FileProvider
  (`<applicationId>.reports.fileprovider`) in the manifest serves ONLY `error_reports/`
  (`res/xml/report_file_paths.xml`). "Share…" (OS share sheet — WhatsApp etc.) unchanged.
  Report footer prints the configured address when set; `githubIssuesUrl` stays the empty
  placeholder to fill at public-release time.
- **Persistent crash files**: uncaught errors now also land as timestamped files
  `crashes/crash_<yyyy-MM-dd>_<HHmmss>.txt` (first line ISO-8601 with ms) under the external
  files dir, surviving restarts. Dart side: `logging/crash_store.dart` (rate limit 1/10 s,
  prune to newest 20) called from both global hooks in `app_error_hooks.dart` (session-JSONL
  routing unchanged). Kotlin side: `Thread.setDefaultUncaughtExceptionHandler` in
  `MainActivity` writes the SAME format/folder (keep `writeCrashFile` ↔ `crashFileBody` in
  sync) before chaining to the previous handler, so Java/Kotlin crashes that kill the process
  are captured too. KNOWN LIMIT: native C++ signal crashes (GPU delegate segfaults) bypass
  JVM handlers — not captured (the GPU blocklist covers the known case). The report embeds
  up to the 3 newest crash files from the last 7 days (each capped 200 lines) automatically —
  the user never attaches anything by hand.
- **Versioning note (owner Q)**: pubspec `version: 0.6.4+10` is the single source of truth
  (Gradle `versionName`/`versionCode` and the report's package_info_plus readout all derive
  from it). Convention adopted: bump the build number for every APK handed to a tester; at
  the eventual public release, tag GitHub `v<version>` matching pubspec. No code change.

## Round 119 (2026-07-17): model dropdown cleanup + download model from URL

- **Dropdown trimmed**: `ModelCatalog.officialModels` now lists ONLY the bundled `yolo26n`.
  The yolo26 s/m/l/x "(add file)" placeholder entries are gone — picking one only produced a
  long warning while detection silently kept running nano. Pre-r119 configs that saved a
  placeholder id migrate to `yolo26n` in `SessionConfig.fromJson` (`_migrateModelPath`,
  frozen set — never extend; round-trip tested). Larger/custom models are added via the new
  Download… or the existing Import… instead.
- **Unused bundled assets deleted**: `assets/models/yolo26n-{cls,obb,pose,seg,sem}_int8.tflite`
  (13.6 MB) were referenced nowhere (app or plugin Dart) and never appeared in the picker —
  removed; APK shrinks accordingly. Kept: `yolo26n_int8.tflite` + `assets/models/custom/`.
- **Warning shortened + generalized** (`settings_sheet.dart`): the old official-id-specific
  banner is replaced by a one-liner shown whenever the SELECTED model isn't in the scanned
  list — which now also covers an imported model whose file was deleted (previously silent:
  just the 'Custom / other' hint). Text points at Download…/Import….
- **Download model from URL**: new `Download…` button beside `Import…` (AI tab) opens
  `_DownloadModelDialog`: paste a direct link to a `.tflite` (helper text points to
  github.com/valentinitnelav/fauna-pulse/releases), progress bar (MB counts;
  indeterminate when the server sends no length), inline error, cancellable (checked
  between chunks; 30 s between-chunk stall timeout). Engine:
  `ModelCatalog.downloadModel` — dart:io HttpClient (no new dependency; the INTERNET
  permission finally earns its manifest comment), streams to `<name>.part` in the
  imported-models folder, renames on success, deletes the partial on ANY failure. URL
  validation via pure `modelFileNameFromUrl` (http/https + `.tflite`, query ignored;
  unit-tested in `model_catalog_test.dart`). On success the model is auto-selected like a
  dropdown pick (modelPath + task from its scanned entry).
- **GitHub asset guidance (owner Q)**: release-asset URLs are stable per tag
  (`…/releases/download/<tag>/<file>`); recommend publishing models in a DEDICATED release
  (e.g. tag `models-v1`) decoupled from app releases so model links never move;
  `releases/latest/download/…` shifts with each release — avoid for models. Future idea
  (not built): a `models.json` manifest in the repo for a one-tap in-app catalog.

## Round 120 (2026-07-17): opaque settings sheet + one calibration cycle

- **Opaque session-settings sheet.** The sheet opened with `backgroundColor:
  Colors.black87` (~87% opaque), so the paused camera preview bled through and made
  the settings hard to read over bright/whitish scenes. Now a fully opaque near-black
  (`Color(0xFF141414)`) in `_openSettings` (`camera_session_screen.dart`).
- **One `_calibrating` flag for the whole start-up cycle.** Previously two sequential
  indicators ran on two different probes: the big `CalibratingBanner` cleared on the
  first analysis frame (`_imageWidth > 0`), then the bottom pill kept saying
  "Calibrating — please wait…" until the slow full-res photo probe landed
  (`_captureWidth > 0`). Meanwhile the settings gear was tappable, and opening the
  Camera tab mid-probe showed only the 3-item fallback "Live stream resolution" list
  (the probed list was still empty). New getter
  `_calibrating = _imageWidth <= 0 || _captureWidth <= 0 || !_probes.analysisCeilingProbed`
  — every term terminates (photo probe falls back to the analysis frame; ceiling probe
  sets its flag in a `finally`), so it can never hang.
- **Gated on it:** big banner now shows for the WHOLE cycle (banner + bottom pill clear
  at the same instant — one visible calibration phase, not two), settings gear, blackout
  (would hide the banner), lens switch (a lens change rebinds the camera and would
  invalidate the in-flight probe), manual-focus button, REC button ready-state, and the
  `_toggleRecording` guard (was `_captureWidth <= 0`). ROI dragging stays enabled —
  harmless and useful while waiting.
- Banner subtitle now sets expectations: "Measuring camera & photo resolution — this
  takes a few moments".
- **UI-placement decision (owner):** session settings STAY on the camera screen (the
  sheet needs the live camera: stream-resolution ground truth, engine benchmark, gate
  tuning); they are already locked during recording, so "fixed per session" holds.
  Future app-level settings go behind the home screen's ⋮ overflow menu — camera gear
  = session settings, home ⋮ = app/data actions.
- `flutter analyze` clean; all 275 tests pass.

## Round 121 (2026-07-17): persistent calibration cache (fast New-session start)

- **Why:** every "New session" press re-ran the full calibration; almost all of the wait
  was the full-res photo-size probe (up to 6 attempts × 4 s timeout). The photo size is
  a hardware fact of the phone — re-measuring it each time was pure friction.
- **New `session/capture_calibration_cache.dart`:** stores the last measured upright
  photo size in shared_preferences (NOT SessionConfig — it's a measurement, not a user
  setting). Key = device manufacturer+model + app version + lens zoom
  (`buildKey` is pure for tests; `key()` degrades to "unknown" parts if platform
  lookups fail). `save()` drops entries from other device/version stems (app updates
  don't accumulate stale keys) but keeps sibling-lens entries.
- **Stale-while-revalidate in `_probeCaptureResolution`** (controller now also takes
  `preferredLensZoom`): cached dims apply instantly (`captureDimsFromCache = true`,
  controls unlock ~1 s after the first frame), the real test photo still runs and
  confirms/corrects + re-saves the cache. Loop condition changed from
  `captureWidth == 0` to a local `confirmed` flag so revalidation runs even on a cache
  hit. The analysis-frame FALLBACK is never cached, and with a cache hit the fallback
  never overwrites the cached value (only fires when nothing landed).
- **Science-log honesty:** start record gains `capture_dims_from_cache: true` when a
  recording starts before the live probe confirmed the cached dims (near-certainly
  identical; the flag says where `camera_full_width/height_px` came from). If the probe
  never succeeds in a session, the flag simply stays true. (DATA_GUIDE.md not yet
  updated with this key — add on next docs pass.)
- Tests: `capture_calibration_cache_test.dart` (keying, round-trip, malformed-value
  rejection, stale-stem cleanup preserving sibling lenses + unrelated prefs).
  `flutter analyze` clean; all 279 tests pass.

## Round 122 (2026-07-17): Auto stream follows Saved photo side + Camera tab cleanup

- **Auto stream resolution now follows the user's "Saved photo side" target** instead of
  a hard-coded 1024: `autoStreamResolution` gets `minShortSide: targetRoiSavedPx` from
  both callers (`_maybeApplyAutoStreamDefault` in the camera screen and the settings
  dropdown). The two settings were already conceptually coupled (the 1024 literal WAS
  the target's default) — now changing the target moves the Auto pick with it.
- **Weak-phone fallback in `autoStreamResolution`:** when NO probed size reaches the
  target (under the analysis ceiling), the pick is now the LARGEST size under the
  ceiling — the best fast crops that phone can produce — instead of returning null and
  silently keeping a small preset. Slight heat cost on weak phones, accepted by owner
  (better photos win). Tests updated + new cases (target-follows, largest-fallback).
- **Dropdown Auto label is self-explaining:** "Auto — matches Saved photo side
  (N px): W × H" or, on a phone that can't reach it, "Auto — largest this phone
  streams (W × H, below N px)". Editing Saved photo side while on Auto re-picks and
  re-stores the stream size in the sheet (WYSIWYG).
- **Camera tab layout (owner request):** "Saved photo side (px)" moved directly under
  the stream-resolution dropdown + ceiling note (they're coupled); the ROI photo source
  label now says "meets the 'Saved photo side' set above" (was "below").
- **Helper text rewritten in plain language** (the old one cited "round 63" and the
  min/max-pair history — meaningless to app users): what the number means, how fast
  crops vs Auto vs high-res reach it, never-upscaled rule, ⚠ readout, snap to 32,
  and that the Auto stream size follows this number.
- `flutter analyze` clean; all 280 tests pass.

## Round 123 (2026-07-17): hide above-ceiling stream resolutions

- Samsung field test: the dropdown listed "1080 × 1440 (may cap to 720×960)" while the
  note below said the phone streams at most ~720×960 — offering a size the phone will
  shrink anyway just annoys (owner). Above-ceiling sizes are now FILTERED OUT of the
  "Live stream resolution" dropdown.
- Exceptions/safety: the user's already-saved explicit choice stays listed even if
  above the ceiling (annotated "phone will shrink it to LO×HI") so an old config stays
  visible and re-selectable; if filtering would empty the list, the unfiltered list is
  kept. The ceiling note now ends "…so they are not listed" instead of explaining why
  they were offered.
- Softens the r56 "dropdown can over-promise" stance: the dropdown no longer lists
  what the ceiling says can't be delivered; the live "Stream: W×H" readout stays the
  ground truth (the ceiling is still an estimate).
- `flutter analyze` clean; all 280 tests pass.

## Round 124 (2026-07-17): portrait lock + collapsible info panel

- **Portrait-only, locked twice.** Owner unlocked their phone's rotation and found the
  preview overlay truncated with Flutter's yellow/black overflow stripes. Deeper issue:
  NOTHING ever locked orientation, yet the capture/rotation math explicitly assumes an
  upright phone (`uprightHighResDims` — "The phone is held portrait in this app";
  `rawRectForUprightRect` Dart + Kotlin mirror), so landscape risked silently wrong
  crops/geometry, not just bad layout. Locked in the manifest
  (`android:screenOrientation="portrait"`) AND `main()`
  (`SystemChrome.setPreferredOrientations([portraitUp])`). Lift BOTH together if
  landscape support is ever built (it would need an orientation-aware audit of the
  keep-in-sync crop pair + preview mapping).
- **Collapsible on-screen stats (owner request: too much text over the ROI).** The
  top-left list now defaults to ONE tappable line "▸ <camera fps> · <battery temp>"
  (the two field essentials; parts respect `showFps`/thermal availability). Tapping
  expands the full list ("▾ hide info" collapses); the choice persists in
  shared_preferences `stats_panel_expanded` (viewing preference — deliberately NOT
  SessionConfig). The gate/time-lapse state chip stays visible in both states; the
  existing Settings toggle (`showOverlayInfo`) still removes the strip entirely. Note:
  the ROI size line (✎ → exact-size sheet) is inside the expanded section.
- `flutter analyze` clean; all 280 tests pass. Field-verify: rotate phone (app must
  stay portrait), tap the ▸/▾ line, kill + reopen app (state remembered).

## Round 125 (2026-07-17): landscape-held photo verdict + detector fps in collapsed line

- **VERDICT — landscape-held recording is data-safe (no code change).** Owner recorded
  session_22 (Xiaomi) holding the phone sideways at a YouTube pollinator video and asked
  whether the "rotated" photos endanger annotation/YOLO training. Verified on the files:
  the saved crops carry **NO EXIF at all** (r98/99 invariant — every path re-encodes raw
  pixels), so the classic annotator-honors-EXIF / trainer-ignores-EXIF box-offset bug
  CANNOT occur; `box_in_roi` is normalized to the same pixels stored in the JPEG, so
  boxes align regardless of hold. The only effect is that the scene CONTENT is rotated
  90° inside the pixels — for training that is plain rotation augmentation. Advice
  recorded: YOLO isn't rotation-invariant, so keep holding-orientation roughly
  consistent per dataset (or use rotation augmentation); nothing in the log records how
  the phone was physically held (future idea, not built: log device tilt in the start
  record).
- **Collapsed info line: detector fps instead of camera fps** ("det 9.8 fps"; reads 0
  while the gate sleeps — honest per r77, the chip beside it says SLEEPING). In the
  no-AI modes (motion-only / time-lapse) it falls back to "cam 15 fps" — the label
  changes with the unit, never silently (r62 one-scale rule).
- **REC-banner overlap fixed structurally:** the state chip and the ▸/▾ toggle now share
  ONE Row as the strip's first child. The REC banner's `top: 52` padding was sized to
  clear the chip, so keeping the whole header at chip height guarantees no overlap in
  any mode; the expanded list still flows below the banner as the full panel always has.
- `flutter analyze` clean; all 280 tests pass.

## Round 126 (2026-07-17): one GPS fix per session + EXIF where-and-when on exported crops

- **Why:** ObsIdentify/iNaturalist-style apps read location+time from a photo's EXIF;
  the owner wants that on the crops they export after a session — WITHOUT touching the
  capture pipeline (r98 invariant: session photos stay EXIF-free; that is what keeps
  training data orientation-safe) and without continuous GPS (battery; tripod phone).
- **`session/location_fix.dart`:** `SessionLocation` (lat/lon/accuracy_m/fix_time_ms/
  `source`: gps|manual|previous, JSON round-trip), pure `LocationFixTracker` (keeps the
  most accurate fix; done at ≤15 m accuracy or 60 s with any fix) and `SessionLocator`
  (geolocator stream wrapper; silent start only proceeds when permission pre-granted —
  no surprise prompts; hard timeout backstop; `stop()` releases the app's entire GPS
  load — Android apps cannot toggle the system GPS itself). New dep `geolocator`,
  manifest gains ACCESS_FINE/COARSE_LOCATION (no FOREGROUND_SERVICE_LOCATION — the
  read is foreground-only, once).
- **Camera screen:** location pin button in the controls row (green = set, amber =
  searching, dim = none; locked while recording). Tap → `widgets/location_dialog.dart`
  — deliberately MAP-FREE (offline/flight-mode friendly): live fix readout, "Search
  GPS" (prompting path), one-tap "use last session's" (prefs `last_session_location`,
  persisted at REC), manual decimal-degree entry, Remove. Start record gains
  `location` (only when set); summary Overview shows a Location row.
- **EXIF stamping (`capture/crop_export.dart`):** `CropExifInfo` + `applyCropExif` set
  DateTimeOriginal/DateTime (photo's `captured_at_ms`, local time) and the GPS IFD
  (DMS rationals via public `IfdValueRational.data` — the image package doesn't export
  its Rational type; explicit IfdValue objects because GPS tags carry no type in the
  package tables). Stamped inside the existing isolate encode in `cropJpegRectSync` —
  zero native code, works identically for Gallery save, share sheet, and the crops/
  fallback. NO orientation tag is ever written. `_exportCrop` passes `p.captureMs` +
  the start record's location through a new `_PhotoViewer.location` param.
- **Privacy:** `redactLocation` in error_reporter.dart replaces the start record's
  `location` with `"[redacted]"` in problem-report log samples — field-site
  coordinates (possibly protected species) never ride along in shared reports.
- Tests: `location_fix_test.dart` (tracker stability/accuracy rules, JSON round-trip,
  and an EXIF encode→decode round-trip proving the tags land in the real JPEG) +
  redaction tests. All 290 pass; `flutter analyze` clean; debug APK builds.
- Docs: DATA_GUIDE start-record table gains `location` + the pending r121
  `capture_dims_from_cache` row; FIELD_GUIDE gains the get-fix-before-flight-mode
  recipe. Phase 2 (not built): EXIF on batch gallery export, map picker.

## Round 127 (2026-07-17): ObsIdentify "no location" investigated — not our file; GPS block hardened

- Owner fed a session_23 crop to ObsIdentify → "location cannot be determined".
  Investigated: session_23's start record HAS a gps fix (51.3182, 12.3962, ±11.5 m),
  and a crop reproduced with the exact same stamping code was read correctly by TWO
  independent parsers (exiftool: full GPSPosition composite; PIL: linked GPS IFD via
  the GPSInfo pointer, exact DMS values, DateTimeOriginal). Our EXIF is
  standards-compliant — the stamping is NOT the bug.
- **Root-cause hypothesis (Android, not us):** since Android 10 the OS REDACTS
  location EXIF when another app reads an image from MediaStore without
  ACCESS_MEDIA_LOCATION, and images obtained via the system photo picker have
  location stripped BY DESIGN. A gallery-picked copy of our crop can therefore lose
  its GPS in transit. Workaround for the owner: use FaunaPulse's SHARE button and pick
  ObsIdentify directly in the share sheet — share_plus serves our own cache file
  verbatim (no MediaStore redaction path). Verify the Gallery file itself with Google
  Photos → details (Photos holds the media-location permission and shows a map).
- **Hardening anyway:** `applyCropExif` now writes `GPSVersionID` (2.3.0.0) and
  `GPSMapDatum` ("WGS-84") — exiftool/PIL don't need them, but stricter mobile
  parsers expect GPSVersionID to head the GPS IFD. Unit test asserts both.
- `flutter analyze` clean; all 290 tests pass.
- **Field verification (owner, same day) — hypothesis CORRECTED:** Google Photos
  shows the crop's map (file good), gallery-pick INTO ObsIdentify reads the location
  (so no OS redaction for that app — it holds the media-location permission), but
  Share → ObsIdentify loses it. Conclusion: ObsIdentify's share-receive handler
  doesn't read EXIF location from shared-in files (their side; identical bytes work
  via the picker). RESOLVED WORKFLOW, not a code fix: for ObsIdentify use
  "Save crop to Gallery" then pick it inside ObsIdentify; direct Share stays for
  apps that honor EXIF on shared files. FIELD_GUIDE updated accordingly.


## Round 128 (2026-07-18): FPS-gap review vs upstream plugin v0.6.10 — docs only

- Owner question: Ultralytics demo app shows 11–12 FPS (yolo26n, Xiaomi) vs
  FaunaPulse's 7–8 — what can we port from the fresh upstream copy at
  `/InsectDetectApp/yolo-flutter-app-main`?
- Comparison verdict: **nothing big to port.** The vendored plugin is the same
  generation as upstream 0.6.10 — RGBA_8888 camera path, LiteRT 2.x
  `CompiledModel` (identical `litert:2.1.5`), GPU program cache, buffer reuse,
  flat-output decode + JNI C++ NMS, boxes-only payload. Both apps compute FPS
  identically (EMA of start-to-start detector interval), so the numbers are
  comparable.
- Root cause of the gap: **cadence beat between our own caps.** Inference cap
  10 (100 ms elapsed-time gate in `shouldRunInference`) on a 15 fps camera
  (frame every 66.7 ms) can only fire every second frame → locked 7.5 FPS =
  the observed 7–8. The demo runs uncapped at ~30 fps / 640×480 → 11–12 is
  the phone's natural loop rate. Secondary factor: our auto stream 1440×1080
  vs demo 640×480 (~5× pixels per frame conversion).
- Added **Part C** to `PERF_AND_ROBUSTNESS_REVIEW.md`: C0 parity verdict
  (+ divergent-file list for future upstream syncs), C1 phase-aligned
  deadline-scheduler cap fix (recommended; ~+33% detections/s at the same
  configured budget, ~15 lines in `YOLOView.kt`), C2 owner-run parity
  benchmark recipe (cap 0 / camera cap 0 / 640×480 / gate off / GPU →
  expect ≈11–12), C3 measure conversion cost vs stream size via existing
  FRAMEPERF, C4 optional upstream micro-ports (pad-only clear, planar-CHW —
  likely skip).
- No code changes this round.

## Round 129 (2026-07-18): phase-aligned inference cap (C1) + parity benchmark verdict (C2)

- Owner ran the C2 parity benchmark (session_25, 640×480, all caps 0, gate
  off): cool phone ~16 FPS (ABOVE the demo's 11–12), thermal governor kicked
  in at ~39 °C reported temp ~70-75 s in → abrupt drop to ~6.5 FPS sustained.
  The demo app on the same warm phone showed 4–5 FPS. Verdict: pipeline at
  parity or better; **thermal throttling is the binding constraint on both
  apps**, so the deliberate caps + auto-throttle remain the right field
  strategy. C2 ticked with results + verdict in PERF_AND_ROBUSTNESS_REVIEW.md.
- **C1 implemented** (plugin `YOLOView.kt` only): the inference-rate cap gate
  in `shouldRunInference()` is now a deadline scheduler.
  `lastInferenceGateTime` → `nextAllowedInferenceNs`; an allowed start
  advances the deadline by exactly one interval (average rate = configured
  cap regardless of camera cadence — kills the beat that locked cap 10 on a
  15 fps camera to 7.5 FPS); a stall > 1 interval re-anchors at now+interval
  (no catch-up burst; composes with the r85 EMA resume guards, which key off
  real gaps, untouched); reset to 0 in `setupThrottlingFromConfig()` so a new
  cap takes effect on the next frame. A1 invariant kept: check still precedes
  bitmap conversion on the gate-off path; gate-on path shares the same
  function.
- Verified: `flutter build apk --debug` builds clean. Field check pending:
  det FPS should read ~10.0 at cap 10 + camera 15 (was ~7.5); uncapped
  behaviour unchanged.

## Round 130 (2026-07-18): C1 field-verified, C3 measured, C5 opened (docs only)

- Owner ran sessions 26 (640×480) and 27 (1440×1080). IMPORTANT for reading
  the numbers: the LOGGED config in both was the DEFAULTS (inference cap 10,
  camera cap 15, auto-throttle on, gate on) — not the parity settings the
  owner intended to set. That accident made session_26 the exact C1
  verification run.
- **C1 verified:** detector FPS 9.9–10.2 for 230 s straight at cap 10 +
  camera 15 (mean 9.97, median 10.01) — pre-fix this config was locked at
  7.5. Ticked with numbers in the review doc.
- **C3 measured + ticked:** toBitmapMs 0.2–0.3 ms @640×480 vs 4.3–4.5 ms
  @1440×1080 (under the 10 ms action rule → guidance only, no mechanism).
  Real cost of the big stream is camera/ISP heat: session_27's collapse at
  41 °C was the CAMERA delivery (1.6–3.0 fps) while inf_ms stayed 21–25 ms
  (brief 45–154 ms spikes); auto-throttle stepped the cap 10→6→7→8 and the
  system recovered by t≈200 s — the owner's observed "sharp rise back to 8"
  is the designed recovery. Session_26 only dipped once at the very end
  (camera 7.4 at 40 °C). Caveat noted: 27 started 2 °C warmer.
- **C5 opened (small, not yet implemented):** on-screen pipeline FPS reads
  ~11 next to an honest detector 10 — Dart `updatePipelineFps` EMAs
  instantaneous rates (1000/dt), which over-weights the short gap of C1's
  alternating 66.7/133.3 ms cadence (Jensen bias: (15+7.5)/2 = 11.25). Fix =
  EMA the interval and invert, mirroring native `finishTiming` t4; few lines
  in `frame_processor.dart` + test.
- No code changes this round.
## Round 131 (2026-07-19): pipeline-FPS readout fixed to interval EMA (review C5)

- **What:** `FrameProcessor.updatePipelineFps` (`lib/fauna_pulse/session/frame_processor.dart`)
  now smooths the *interval between frame callbacks* and inverts it once for
  display, instead of smoothing the instantaneous rate `1000/dt`.
- **Why:** the r129 deadline-scheduler cap legitimately alternates 66.7/133.3 ms
  frame gaps (cap 10 on the 15 fps camera). Averaging the two instantaneous
  rates gives (15 + 7.5)/2 ≈ 11.25 even though true throughput is exactly 10
  (short gaps get over-weighted — Jensen's inequality), so the screen showed
  "pipeline ~11" beside an honest detector 10.0 (seen in session_26, r130) —
  violating the owner rule that on-screen numbers must not mislead. The native
  detector FPS (`Predictor.finishTiming` `t4`) already EMAs the interval; both
  numbers now use the same math.
- **How:** field renamed `_pipelineFpsEma` → `_pipelineIntervalEmaMs`; getter
  `pipelineFpsEma` returns `1000/interval` (0 while unset). EMA weights
  unchanged (0.1 new / 0.9 old). The r85 resume-gap guard behaves identically —
  "skip gaps > max(2 s, 5× smoothed interval)" is now expressed directly on the
  interval instead of `5000/fps`. Gate-idle reset (r77) clears the interval
  field. No native change, no log-schema change; historical logs unaffected
  (per-second records store what was shown; summary graph reads
  `pipeline_fps ?? fps`).
- **Tests:** `frame_processor_test.dart` expectations moved to interval
  semantics; new test: 100 alternating 67/133 ms gaps settle at ~10.0 fps
  (old math: ~11.2). Full suite 291 passing, analyzer clean.

## Round 132 (2026-07-19): heat findings documented + session-comparability logging gaps closed

**Data analysis (owner-pointed sessions; drove everything below):**
- Samsung SM-M127F, five 1-h sessions, never charging: battery temp never
  exceeded 31.5 °C, `thermal_status` "none", headroom ≤0.78 — heat is a
  non-issue on this device; compute is the limit (yolo26n ~260 ms/inference →
  auto-throttle cap 3, flat ~2.8 fps; arthropod int8 65 ms → steady ~7 fps;
  model choice ≈2.5× fps). Battery 7–12 %/h unplugged. Its
  `battery_current_ua` reporting is broken (µA-scale values → power_w ~0);
  use battery-% drop instead.
- Xiaomi session_28 (12 min, charging, 1440×1080 explicit, started 39 °C):
  39→46 °C; camera-first throttle confirmed again at ~41–42 °C (camera_fps
  min 1.4 while inf_ms stayed ~24); auto-throttle stabilized ~6 fps mean at
  43–46 °C. MIUI `thermal_status` read "none" even at 46 °C.
- Verdict passed to owner: skip a factorial test matrix; do ONE realistic
  field-config session (Xiaomi, 1 h, power bank + blackout + gate + auto
  stream — no existing session matches the real end-user config); defer
  cooler hardware until that shows whether the wall is even hit.

**Docs:**
- `FIELD_GUIDE.md` §8 "Heat: what to expect and what helps": plain-language
  throttling explanation, the two measured device narratives, mitigation
  ladder (shade → blackout → gate → smaller photo target → charging costs
  headroom → faster model), honest untested-gadget note on Peltier clip-on
  coolers; cross-links from §4 and a new §7 troubleshooting entry.

**Code (comparability gaps found during the analysis — all logging-only, no
new tunables):**
- `blackout` JSONL records (`{on: true/false}`) from `_enterBlackout` /
  `_exitBlackout` via `SessionLogger.logBlackout`; start record gains
  `blackout_at_start: true` when a scheduled wake starts under the cover.
  (The five Samsung sessions could not be told apart by screen state — this
  was the gap.)
- Start record gains `app_version`, `app_build` (package_info_plus, already a
  dep) and `build_mode` (release/profile/debug) — debug `flutter run`
  sessions perform measurably worse (C2 note) and behaviour changes between
  versions (e.g. r129), so perf comparisons must not mix binaries.
- `focus_change` records: the manual-focus slider is usable WHILE recording
  but only the start record carried focus — mid-session changes were
  invisible. `RoiUpdateDebouncer` generalized to `SettledUpdateDebouncer<T>`
  (same file; Roi subclass keeps the old name/API, default equality = `==`
  so Dart records work); the screen debounces focus like ROI (seed at start,
  notify on slider/reset, flush at stop, cancel in dispose).
- `DATA_GUIDE.md`: new start fields + `blackout` + `focus_change` sections.
- Tests: logger round-trip for both new records; generic-debouncer test with
  a record type. Suite 293 passing, analyzer clean.

## Round 133 (2026-07-20): no debug-key fallback for release builds

- `android/app/build.gradle`: release builds now always use `signingConfigs.release`;
  the silent fallback to the debug key is removed. A guard on `preReleaseBuild`
  (release-only, runs before any compilation) throws a GradleException with setup
  instructions when signing is unconfigured. Debug/profile builds unaffected
  (verified: `:app:preDebugBuild` passes, `:app:preReleaseBuild` fails with the
  clear message).
- Keystore path can now also come from the `ANDROID_STORE_FILE` env var, matching
  the existing `ANDROID_KEY_ALIAS`/`ANDROID_KEY_PASSWORD`/`ANDROID_STORE_PASSWORD`
  fallbacks; `android/key.properties` remains the primary (git-ignored) config.
- Root `.gitignore` now also ignores `key.properties`, `*.jks`, `*.keystore`
  (android/.gitignore already did, this covers the rest of the tree).
- No keystore was generated or committed; create one with `keytool` per the
  error message before shipping a release APK.

## Round 134 (2026-07-20): public-release scaffolding

Prep for the first public alpha (no version bump yet; still 0.6.4+10 per user).

- `lib/fauna_pulse/logging/error_reporter.dart`: `githubIssuesUrl` now points to
  `https://github.com/valentinitnelav/fauna-pulse/issues` (was empty placeholder).
  The report footer's "Or open a GitHub issue" line activates via the existing
  `.isNotEmpty` guard; no test touched it.
- New `CITATION.cff` at repo root (GitHub "Cite this repository" + Zenodo pickup).
  Authors/affiliation/ORCID and the Zenodo DOI are TODO placeholders; `version`
  and `date-released` must track each tag.
- New `.github/ISSUE_TEMPLATE/`: `bug_report.yml` (asks for phone+Android/MIUI,
  app version, capture mode, model, and to attach the in-app "Report a problem"
  file), `feature_request.yml`, `config.yml` (blank issues still allowed).
- `README.md`: added a `## Getting started` numbered quick-path (install → perms →
  model → ROI → test session → inspect session.jsonl → known limitations),
  expanded `## Project status` into an explicit alpha disclaimer (missed/duplicate/
  split tracks, per-device variance, heat/throttle/battery, review outputs before
  conclusions), and added a `## Citation` section before `## License`.
- `docs/AGENT_CHANGELOG_OVERVIEW.md`: updated the stale "empty placeholder" note.
- Deliberately skipped: root CONTRIBUTING.md (GitHub surfaces docs/CONTRIBUTING.md),
  new AI-disclosure (README already has one), CODE_OF_CONDUCT.md (optional for a
  small preview). Keystore creation + release build/install handled by the owner.

## Round 135 (2026-07-22): post-hoc batch detection over saved session photos

First slice of the approved post-hoc analysis plan (Round A of: batch images → visits → video source → background comfort → SAHI). Lets the user re-run a (typically higher-resolution) detector over a finished session's `roi_frames/` JPEGs — no camera, no real-time limit; groundwork for offline visit detection and, later, user-supplied video analysis.

- **New `lib/fauna_pulse/postprocess/post_detector.dart`**: batch driver around the plugin's camera-free `YOLO.predict(jpegBytes)` (single-image channel; letterboxes to the model's own input size, so 1024px models work). Appends to `<session>/post_detections.jsonl` (strict JSONL like session.jsonl): one `post_start` header (model, thresholds, use_gpu, counts, app_version), one `post_detection` per photo (`jpeg`, `captured_at_ms` parsed from the filename's trigger stamp, `infer_ms`, `boxes[]` with `class_name`/`conf`/`box` [l,t,r,b] normalized), one `post_end` (`ended_normally`, `reason: cancelled`). **Resumable**: already-recorded photos are skipped on the next run. `_live.jpg` companions are skipped when their main photo exists (double-count guard); orphan companions are kept. Per-photo failures are recorded (`error` key) and the run continues. The predictor is injected (`PredictFn`) so all of this is unit-tested without the native channel.
- **New `lib/fauna_pulse/screens/analysis_screen.dart`**: session picker (photo + already-analyzed counts), model dropdown from the existing `ModelCatalog` (input size shown; models added via the AI tab's Import/Download), confidence + IoU sliders, progress (n/total, ms/photo, ETA), Stop (cancels between photos; resumable). Wakelock held during a run; `useGpu` follows the app's existing engine preference. Last-used model/thresholds persist in shared_preferences (`analysis_*` keys — app-level job settings, deliberately NOT SessionConfig).
- **Home screen**: new secondary button "Analyze saved photos" under New session; session rows show a small blue ✨ badge when `post_detections.jsonl` exists; long-press a row = analyze that session directly.
- **Tests**: `test/fauna_pulse/post_detector_test.dart` (12) — filename stamp parsing, companion/orphan selection, resume bookkeeping, cancel + failure paths, record shapes. Full suite 305 passing; `flutter analyze` clean; debug APK builds.
- Next (Round B of the plan): feed `post_detections.jsonl` through the tracker / a gap-tolerant visit grouper and surface visits in the summary.

## Round 136 (2026-07-22): analysis refocused on AI-free sessions + photo cleanup

Owner clarified the point of "Analyze saved photos": storage triage for AI-FREE sessions (motion / time-lapse capture) — keep on the phone only photos that probably contain an insect. Re-analyzing detector-mode sessions is a computer job (copy photos over USB). Tracker deliberately NOT used for triage: at ~1 photo/s a simple time-gap rule covers the "detector missed the next photo of the same individual" case without tracker complexity.

- **New `lib/fauna_pulse/postprocess/photo_keep.dart`**: `keepNames(outcomes, gapMs)` — keep = photos with ≥1 detection, plus photos within `gap` seconds (before OR after) of any detected photo (bridges single-photo detector misses), plus failed analyses ("no result" ≠ "no insect"); photos without a filename timestamp keep only on their own detection. `photoOutcomesFromJsonl` (last record per photo wins re-runs), `planCleanup` (delete candidates incl. `_live.jpg` siblings + freed bytes), `runCleanup` (deletes + appends a `post_cleanup` audit record: gap_seconds/deleted/kept/freed_bytes). `liveSessionInfoFromLogHead` parses a session.jsonl head for the start record's `captureTrigger` (same legacy `motionOnlyCapture` mapping as SessionConfig) + `modelPath`.
- **Analysis screen**: session dropdown now tags each session `[AI live]` / `[motion]` / `[time-lapse]` (start-record head read, 8 KB). Selecting an AI-live session shows a notice (AI already ran; this screen mainly helps AI-free sessions; heavier models → computer). **Re-analysis with the SAME model the session ran live is disabled** (button explains). New "Photo cleanup" section once results exist: keep-gap slider (0–10 s, default 2 s, persisted `analysis_keep_gap`), live kept/deleted counts + freed MB, red delete button behind a count-explicit confirm dialog. Outcomes are filtered to photos still on disk so a second cleanup shows honest numbers.
- **Summary photo viewer**: `Image.file` got an errorBuilder — a cleaned-up (deleted) photo shows "Photo deleted (analysis cleanup)" instead of an error box; log records are never touched by cleanup.
- **Tests**: `test/fauna_pulse/photo_keep_test.dart` (12) — bridge/before/after/gap-0 keep rules, error-kept, re-run last-wins, cleanup deletion + `_live` sibling + audit record, head parsing incl. legacy configs. Suite 317 passing; analyze clean; debug APK builds.

## Round 137 (2026-07-22): pair analysis, in-summary review of cleanup, scroll fix

Owner feedback on r136: pairs should be analyzed on both members ("_live" companions can be sharper than the lagged high-res photo), the cleanup wants a visual review step in the summary's Photos tab before anything is deleted, and the analysis screen's bottom text was unreachable (scroll bug).

- **Pairs (postprocess)**: `selectPhotoNames` now analyzes BOTH members of a high-res/`_live` pair (r135 skipped the companion). `keepNames` gained the pair rule: a detection on EITHER member keeps both (`pairBase` helper); `planCleanup` dedupes (main + sibling can enter twice) and still sweeps never-analyzed companions of unkept mains (pre-r137 results). `PhotoOutcome` now carries the parsed `boxes` (class/conf/edges) so screens can draw them. Old r135 result files stay valid; re-running analysis picks up the now-pending companions.
- **Summary Photos tab review (round 137 UI)**: `SessionSummaryScreen` gained `initialTabIndex`; the analysis screen's new "Review photos before deleting" button opens it straight on Photos. The summary loads `post_detections.jsonl` on init (`_loadPostHoc`, keep set at the saved `analysis_keep_gap`): viewer draws **green** post-hoc boxes (new `_DetBox.postHoc` flag + `_BoxPainter.postHocColor`, keyed by the SHOWN file's name so each pair member shows its own boxes), photos the cleanup would delete get a translucent red ✕ (`_DeleteMarkPainter`, IgnorePointer) + a "no detection — cleanup will delete" chip (r112 invariant respected: passive marks/text chips only). A post-hoc panel above the viewer states counts + gap and hosts the same confirm-guarded "Delete N marked photos (MB)" action; after deleting it reloads post-hoc state, the photo list and the storage numbers.
- **Analysis screen**: body wrapped in SafeArea + bottom padding 32 — the closing hint text sat under the system gesture bar and could never scroll into view (owner-reported on the Xiaomi).
- **Tests**: pair-selection expectations updated; new pair-keep, boxes-parse, `pairBase` tests. Suite 320 passing; analyze clean; debug APK builds.

## Round 138 (2026-07-22): typed keep-window input + keep-reason marks in the review

- **Keep window is now a typed input**, not a slider: the analysis screen reuses `DurationSettingField` (r97 unit-aware number field) — type the number, pick s/min (h also available), stored as seconds in `analysis_keep_gap`, validated 0 s–60 min. Rationale: users may need windows far beyond the old 10 s slider max.
- **Live kept/deleted percentages**: analysis screen + summary post-hoc panel now show "$kept kept (P%), $deleted deleted (Q%)" recomputed on every input change. P is rounded, Q = 100 − P (complement, never two independent roundings), so they always sum to 100 without misrepresenting.
- **Keep reasons surfaced (photo_keep.dart)**: new `keepDecisions(outcomes, gapMs)` → `Map<name, KeepDecision{reason: detected|failed|bridged|pair, decisiveName, deltaMs}>` is now THE single source of the keep rule (`keepNames` wraps it). Bridged photos name the NEAREST decisive detection with a signed delta; pair-kept photos name the decisive sibling. New `formatKeepWindow`/`formatKeepDelta` helpers ("2 s", "5 min", "3 s later").
- **Photos tab clarity (r138 UI)**: a kept photo WITHOUT an own detection now shows an amber chip on the image — "kept — detection 3 s later" / "kept — pair photo has the detection" / "kept — analysis failed" — and the info panel gains a "Kept" row naming the decisive photo file (e.g. "decisive detection 3 s later in roi_xxxx_….jpg"). Delete-marked photos get a "Cleanup: marked for deletion" info row. Red-✕ and amber chips are mutually exclusive by construction.
- Tests: keepDecisions (nearest/signed delta, closer-side preference, pair decisive name, absence = delete) + format helpers. Suite 325 passing; analyze clean; debug APK builds.

## Round 139 (2026-07-22): SAHI-style tiled analysis (small-insect triage recall)

Goal (owner): flag photos with/without pollinators as accurately as possible in motion/time-lapse sessions — tiling recovers small insects that letterboxing shrinks below detectability. Boxes need not be tight; recall matters.

- **New `lib/fauna_pulse/postprocess/sahi.dart`** (pure Dart, `image` package): `SahiOptions` (enabled off; tile 0=auto→model input; overlap 25%; full-photo pass on; merge IoU 0.5 — all exposed, all persisted `analysis_sahi_*`); `planTiles` (stride = tile·(1−overlap), last tile flush with the edge; image ≤ tile ⇒ 1 tile = no-op); `mergePostBoxes` (greedy class-aware NMS); `tileWorker` (decode+crop+encode in a `compute()` isolate); `sahiPredictFn` — wraps the plain predictor and RETURNS THE SAME RESULT SHAPE as `YOLO.predict`, so the batch driver, keep logic, cleanup and review UI are untouched. Decode-failure/no-op paths always fall back to the plain full pass.
- **Driver**: `PostRunConfig.sahi` map echoed into `post_start`; new `force` flag on `run()` processes ALL photos (re-analysis with another model or tiling — `photoOutcomesFromJsonl` already takes the last record per photo, so the newest run wins downstream); `skipped_done` reads 0 on forced runs.
- **Analysis screen**: "Small-insect tiling (SAHI) — advanced" ExpansionTile with master switch + every parameter (`NumericSettingField`s), a live **cost/fit preview** ("1024×1024 px photos, 640 px tiles, 25% overlap → 2×2 tiles + whole photo = 5 passes ≈ 5× time") computed from the session's first photo size (`probeJpegSize`, cached per folder) and the selected model's input size; guidance text (worth it when model input ≪ photo; expect a few extra kept photos). New "Re-analyze photos already done" checkbox (per-run, not persisted) wiring `force` — also unlocks trying a different model on a done session; button reads "Re-analyze N photos".
- **Auto grid** directly implements the owner's example: 320 px model on 1024 px crops → 4×4 tiles; 640 px model → 2×2; photos ≤ tile → tiling no-op, stated in the preview.
- **Tests** (`sahi_test.dart`, 11): grids (2×2/4×4/no-op/non-square, flush edges), NMS (same-class merge/cross-class keep/distance), pass counts, tile→photo coordinate mapping, one-insect-in-all-passes merges to exactly one, smaller-than-tile fallback. Suite 336 passing; analyze clean; debug APK builds.

## Round 140 (2026-07-23): user-facing SAHI docs (docs-only)

Owner asked whether r139's SAHI used a library and how to document it for users. Answer: no library — `postprocess/sahi.dart` is a self-contained pure-Dart implementation (only dep: the `image` package); neither obss/sahi (Python-only) nor Ultralytics ships anything usable on Android/Flutter. External docs (obss/sahi repo, Ultralytics SAHI guide) are cited as CONCEPT references only, since our merge differs: IoU-based greedy NMS vs obss/sahi's IoS (intersection-over-smaller) NMM default.

- **SETTINGS_REFERENCE.md**: new "Photo analysis (Analysis screen)" section — first coverage of any Analysis-screen setting; table for the five SAHI tunables + the per-run "Re-analyze photos already done" checkbox; concept links; explicit "expect extra small boxes" note explaining WHY (small box inside big box has low IoU ⇒ IoU-NMS keeps both; tiles surface fine background detail at native scale).
- **DATA_GUIDE.md**: new §6 documenting `post_detections.jsonl` (previously undocumented, r135+): `post_start` (incl. the `sahi` map — `tile_px` already auto-resolved, `overlap`, `full_pass`, `merge_iou`; `reanalyzed_all` on forced runs), `post_detection` (`jpeg`, `captured_at_ms`, `infer_ms`, `boxes` with `class_name`/`conf`/`box` [l,t,r,b] photo-normalized), `post_end`, `post_cleanup`; last-record-per-jpeg rule; SAHI-run interpretation caveats. Softened §5b's stale "on-phone re-run rejected" note: rejected DURING the session; after-session is §6.
- **Not done (deliberate)**: the small-box artifact fix itself. Owner observed many small boxes on tiled runs — diagnosis: IoU merge keeps contained partial-insect boxes at tile borders; obss/sahi solves this with IoS matching. If wanted later: switch/augment `mergePostBoxes` to IoS (containment ≈ 1) and/or add a min-box-size filter — small change, tests exist.
- No code touched; suite/build state unchanged from r139.

## Round 141 (2026-07-23): SAHI small-box artifact fix (IoS merge + speck filter)

Owner approved the r140 follow-up: fewer spurious small boxes on tiled runs.

- **`sahi.dart` merge switched IoU → IoS** (intersection over the SMALLER box's area — obss/sahi's criterion). Rationale: a partial insect at a tile border yields a small box INSIDE the full-insect box; IoU ≈ area ratio (~0.06 in the test case) never reached the 0.5 threshold so both survived — IoS scores containment ≈ 1 and merges them. `boxIos` added, `boxIou` kept (shared `_intersection`/`_area` helpers); `mergePostBoxes` signature unchanged (param renamed `overlapThresh`). Same-class-only merging unchanged, so a genuinely different-class insect inside another's box still survives. Threshold setting, pref key `analysis_sahi_merge_iou` and JSONL key `merge_iou` all keep their names/values; UI label is now "Duplicate-merge overlap".
- **New speck filter** `SahiOptions.minBoxFrac` (default 0 = off; UI "Ignore tiny tile boxes", 0–20% of photo side, pref `analysis_sahi_min_box_pct`): drops TILE-derived boxes smaller than the floor in BOTH dimensions, applied pre-merge and NEVER to whole-photo-pass boxes — invariant: the filter can only trim tiling's additions, a SAHI run never returns less than the plain run would. Default off because SAHI's whole point is small insects; helper text suggests ~1–2%.
- **Provenance in JSONL**: `sahi` map gains `merge_metric: "ios"` (absent ⇒ r139–140 IoU run) and `min_box_frac` — old runs stay interpretable.
- **Docs synced** (they were r140-fresh and described IoU): SETTINGS_REFERENCE merge row + new filter row + "extra small boxes — mostly fixed in r141" note; DATA_GUIDE §6 `sahi`-map keys + reading-SAHI-runs caveat now split by log generation.
- **Tests** (+4 → suite 341 passing, analyze clean): contained same-class box merges under IoS (asserts IoU < 0.1 AND IoS ≈ 1 for the same pair), contained different-class box survives, end-to-end speck filter (4 tile specks dropped, full-pass box kept, 5 passes still run), `toJson` records `merge_metric`/`min_box_frac`.
- Field expectation: re-analyze an affected session with "Re-analyze photos already done" — the newest records win; compare small-box counts before/after.

## Round 142 (2026-07-23): analysis-screen label fixes (owner-reported)

- **"Ignore tiny tile boxes" number was invisible**: the r141 `unitSuffix: '% of photo'` was long enough to push the typed value out of the `NumericSettingField` box. Suffix is now just `'%'`; "of the photo side" moved into the helper text. Lesson for future fields: keep `unitSuffix` to a few characters — it renders INSIDE the input box next to the number.
- **"Keep window around a detection" → "Keep time-window around a detection"** (analysis screen) and the matching summary-Photos-tab info line ("Keep time-window Xs …") — "window" alone reads as a spatial window next to SAHI's tiling on the same page.
- UI strings only; suite 341 passing, analyze clean.

## Round 143 (2026-07-23): speck filter tests the NARROWER box side (owner-reported bug)

Owner set the r141 filter to 10% on session 31 and a tile-pass false positive survived. Diagnosis from `sessions/Xiaomi/sessions/session_31/post_detections.jsonl`:

- The photo (`roi_z2yq_2026-07-22_185816_662.jpg`, 608×608) has ZERO detections in the plain no-SAHI run → BOTH boxes (bumblebee 113×90 px conf 0.48, false positive 82×30 px conf 0.59) are tile-derived; the full-pass exemption was not the cause. Notably the plain pass misses the bumblebee entirely — SAHI is earning its keep on recall here.
- The r141 rule dropped a box only when `max(w,h) < floor` ("small in BOTH dims"). The FP is a SLIVER — 13.4% × 4.9% — so its width cleared the 10% floor. Border/partial artifacts are characteristically thin-one-way, not tiny-both-ways; the r141 criterion only ever caught compact specks.
- **Fix**: filter now tests `min(w,h) < floor` (narrower side, either direction). On session 31 at 10% (60.8 px): FP min side 30 px → dropped; bumblebee min side 90 px → kept. Helper text + SETTINGS_REFERENCE + DATA_GUIDE updated ("narrower than this in either direction"); DATA_GUIDE notes that `min_box_frac` in runs from the r141 build (2026-07-23 morning only) meant the both-dims rule.
- Trade-off documented: a slender insect side-on also has a narrow side — keep the floor low (~1–2%) unless reviewing.
- **Test** added reproducing the session-31 geometry through the tile mapping (sliver 0.134×0.049 dropped at 10%, insect-shaped 0.186×0.148 kept). Suite 342 passing; analyze clean.

## Round 144 (2026-07-23): frozen AI-mode box after switching to motion capture (owner-reported)

- **Bug**: with AI mode running and boxes on screen, switching the capture trigger to motion (or time-lapse) in Settings left the last predicted box frozen on the preview. It only vanished on leaving the screen, because the box overlay listens to `_tracksVN` and in the no-AI modes the streaming handler takes the `motionOnly`/`timeLapse` branch, which never touches that notifier — nothing ever repainted (or cleared) the stale tracks.
- **Fix** (all in `screens/camera_session_screen.dart`):
  - `_openSettings` now sets `_tracksVN.value = const []` right after rebuilding the tracker — the rebuilt tracker starts empty, so on-screen boxes are orphans in any mode; in the no-AI modes they were permanent.
  - The `TrackBoxPainter` overlay is additionally gated on `_config.detectorEnabled` — the no-AI modes can never paint detector boxes, whatever path led there (belt-and-braces).
  - The expanded stats "Current tracks / Total tracks" lines are now hidden in the no-AI modes, matching the existing detector/pipeline-fps lines (they read the same stale tracker state).
- No settings, log format, or native code touched. Analyze clean; suite 341 passing (+1 skipped).

## Round 145 (2026-07-23): always-on mode chip, header overflow fix, info panel above REC banner (owner-reported)

Three related camera-screen header bugs, all in `screens/camera_session_screen.dart` (pure view layer — no SessionConfig/log/native changes):

- **Right overflow**: long chip labels (worst: "TIME-LAPSE (starts with REC)") shared one unconstrained Row with the collapsed "▸ det fps · temp" toggle → Flutter's yellow/black "RIGHT OVERFLOWED" stripes. Fix: the chip sits in a `Flexible` and its label Text is also `Flexible` + `maxLines: 1` + ellipsis (BOTH are needed — the outer one alone squeezes the chip but its inner Row still overflows). The header stays ONE row, so the REC banner's hand-tuned `top: 52` invariant (r124/125) holds.
- **Mode chip is now ALWAYS shown** (previously plain AI mode had no chip): `_gateStateChip()` + `_timeLapseChip()` (duplicated styling) merged into `_modeChipShell()` + `_modeChip()`, dispatching on the exclusive CaptureTrigger getters. Labels now all name the mode: "DETECTOR ON" / "DETECTOR SLEEPING" (was bare "SLEEPING"), "MOTION: CAPTURING" / "MOTION: WAITING" (was "CAPTURING"/"WAITING FOR MOTION"), "TIME-LAPSE: press REC" (was "TIME-LAPSE (starts with REC)"), "TIME-LAPSE: CAPTURING" / "NEXT BURST in mm:ss" unchanged. Colors hoisted to `_chipActiveColor`/`_chipWaitingColor`.
- **REC banner covered the expanded info panel** (banner painted after the strip in the Stack, so z-above it). Fix per owner's request: the banner is built once into a `recBanner` local (ValueKey'd so Flutter MOVES the live countdown between slots) and slotted at one of two mutually exclusive Stack depths — collapsed keeps today's banner-on-top look; expanded puts the banner BELOW the strip so the panel reads on top. The expanded spread also gained one shared ~75%-black rounded backdrop (`Color(0xC0000000)`), so lines stay readable over the banner/preview. The panel stays below the calibrating/error banners and blackout (those must always outrank stats). Recording state remains visible while the panel is open via the red ROI border.
- Docs: FIELD_GUIDE §3 chip bullet rewritten (three modes + info-panel-over-REC note); overview chip labels updated in place. Two `if` one-liners in the panel gained braces (lint, after the re-indent).
- Analyze clean; suite 341 passing (+1 skipped). Owner to verify on-device: no stripes in time-lapse pre-REC, panel readable while recording, chip present in plain-AI mode.

## Round 146 (2026-07-23): no-AI panel honesty — hide Model line, explain time-lapse "Camera: 1 fps" (owner-reported)

- **Model line hidden in motion + time-lapse modes** (`if (_config.detectorEnabled) _statLine(modelLabel)`): the model file is loaded in those modes but `predict()` is never called, so naming it (and its input size) in the expanded panel misled. The "Mode: … (detector off)" line already replaces the Engine line there.
- **"Camera: 1 fps (sensor→app)" in time-lapse explained, kept, relabelled.** Root cause verified in `YOLOView.kt`: the time-lapse pre-conversion sampler (drop at ~:2284) sits ABOVE `perfFramesIn++` (~:2293), so `lastDeliveredFps` counts frames the app KEEPS — ~1/s between bursts (Dart pushes 1 fps between, ceil(2/step) during a burst), while the camera hardware keeps running at the cap (hence motion mode showing 15). This mirrors the deliberate r63 gate-idle semantics ("readout shows ~idle rate while sleeping = the heat fix working"), so the number stays — the panel line in time-lapse mode now reads "Camera: N fps (frames kept for time-lapse — the camera itself runs at full rate)". Native untouched.
- Docs: FIELD_GUIDE troubleshooting gains a '"Camera: 1 fps" in time-lapse mode' entry; overview r63 invariant bullet extended with the time-lapse case.
- Analyze clean; suite 341 passing (+1 skipped).

## Round 147 (2026-07-23): mode-aware session settings + summary/log applicability (owner-reported)

Owner: with motion/time-lapse capture selected, AI-only controls stayed active and AI-only settings were printed in the summary as if meaningful; also (mid-round follow-up) every setting must stay REGISTERED in session.jsonl with applicability indicated Python-safely.

- **Settings sheet (`settings_sheet.dart`) is now capture-mode-aware**, reusing the two established idioms (gate-switch disable pattern with appended white54 reason; `if (...) ...[` hide pattern):
  - Setup: "Show detection boxes & track IDs" locked off (value forced false, reason appended) in the no-AI modes; saved preference untouched.
  - AI tab: tab icon/label dims (white24) in no-AI modes; tab body becomes a notice ("apply only to the AI detector mode…") over the full control list wrapped in `IgnorePointer` + `Opacity(0.4)` — visible but read-only.
  - Camera: auto-throttle switch locked off with reason in no-AI modes and the whole inference-rate block (rate cap + min rate + duty + explanations) hidden; gate switch now DISPLAYS off in time-lapse (was showing the stored value although the gate is natively forced off there); gate sensitivity block hidden in time-lapse (`motionGateEnabled && !timeLapseCapture`).
  - "Wake duration after motion" STAYS editable in motion mode (owner decision after code check: the native gate idles after `wakeSeconds` of stillness and photos stop then — it directly governs how long motion-mode capture persists); its helperText now branches per mode.
- **Summary Settings tab (`session_summary_screen.dart`)**: for no-AI sessions the "Model & detection" and "Visit tracking" sections each collapse to ONE muted "Not applicable — … (<mode> mode)" note (algorithm name dropped from the header then); auto-throttle rows likewise; gate rows kept for motion sessions (they ARE the sensitivity) but replaced with a note for time-lapse. "Ground-truth frames" stays outside the branch (detection-independent, runs in every mode). Old/AI sessions render unchanged (`_motionOnlySession` handles the legacy bool).
- **Log format (additive)**: start record gains `config_not_applicable` — the list of `config` keys inert under the session's trigger, from the new pure `notApplicableConfigKeys(CaptureTrigger)` in `session_config.dart`. Values are NEVER replaced with "n/a"/null (would flip pandas dtypes); the config block still always carries every field. Two new tests: every listed key exists in `toJson()` (drift guard) + per-mode expectations. DATA_GUIDE start-record table documents it; SETTINGS_REFERENCE gains the mode-aware note + motion-mode wake meaning.
- Analyze clean; suite 343 passing (+1 skipped). Manual on-device check: switch trigger with the sheet open → all gating reacts live; values survive mode round-trips.


## Round 148 (2026-07-23): diagnostics opt-in + collapsible extra graphs

Owner-requested UX split of the summary graphs: the visit timeline is the promised
deliverable for a general (citizen-science) user; FPS/temperature/power are advanced
diagnostics and now opt-in — both for sampling and for display.

- **`SessionConfig` (`session_config.dart`)**: new `diagnosticsEnabled` (default OFF) —
  master switch for logging `fps`/`thermal`/`power` records. `autoComputeGraphs` REMOVED
  (fields absent from old saved configs are simply ignored on load; the timeline is now
  always computed, see below). Flows into the start record's `config` block automatically.
- **Settings sheet, Graphs tab (`settings_sheet.dart`)**: "Compute graphs automatically"
  switch removed; new "Record diagnostics (FPS, temperature, power)" switch. The three
  sample-interval fields (Frame-rate/Temperature/Power sample) are only rendered while
  the switch is on (progressive disclosure — same direction as r125/r147).
- **Camera screen (`camera_session_screen.dart`)**: timer setup extracted into
  `_rebuildSamplingTimers()`, called at init AND after the settings sheet closes (so a
  toggle or interval change now applies without leaving the screen — previously intervals
  only applied on re-entry). The thermal timer ALWAYS runs (it feeds the on-screen
  temp + free-storage readouts); only its `logThermal` write is gated on
  `diagnosticsEnabled`. The FPS and power timers are log-only, so with diagnostics off
  they are not created at all (plus belt-and-braces guards in `_sampleFps`/`_samplePower`).
  Auto-throttle is per-frame and untouched.
- **Summary Graphs tab (`session_summary_screen.dart`)**: always parses the log on open
  ("Generate graphs" button removed; `_graphsRequested` is now just the re-entry guard).
  Visit timeline renders at top as before (its own show/hide + floating button untouched).
  Temperature/headroom/FPS/inference/power moved behind a tappable
  "▸/▾ Extra graphs — temperature, FPS, power" header (`_extraGraphsExpanded`, persisted
  as SharedPreferences `extra_graphs_expanded`, collapsed by default — the r125
  stats-panel pattern; a viewing preference, deliberately NOT SessionConfig). Sessions
  with `diagnosticsEnabled:false` in their config block show a pointer note
  ("turn on Record diagnostics in Session settings → Graphs") instead of empty charts
  (`_diagnosticsOffSession`; pre-r148 sessions lack the key → graphs render as always).
- **Summary Settings tab**: new "Record diagnostics" row; the three sample-interval rows
  are skipped for diagnostics-off sessions (r105 "never list knobs that had no effect").
- Analyze clean; suite 344 passing. Old sessions, gate-idle/no-AI sparse fps records, and
  the charging-invalidates-power guard all unaffected (graph code already tolerates
  missing series — "Not enough samples." / conditional sections).

## Round 149 (2026-07-23): always log diagnostics; keep only the display opt-in

Owner decision after on-device testing of r148: the diagnostic *sampling* costs
essentially nothing — the thermal reading is taken anyway for the on-screen
temperature/storage readouts, fps is maintained every frame, and power is one cheap
platform call per interval (~2–3 MB of log per 8 h in total). So the r148 logging
gate is reverted: `fps`/`thermal`/`power` records are ALWAYS written while recording,
and only the *display* stays opt-in via the summary's collapsed "Extra graphs" section.

- **`SessionConfig`**: `diagnosticsEnabled` REMOVED (lived exactly one round; the stale
  JSON key in saved configs is ignored on load).
- **Settings sheet, Graphs tab**: "Record diagnostics" switch removed; the three
  sample-interval fields are always visible again (pre-r148 layout, label now mentions
  they feed the summary's "Extra graphs").
- **Camera screen**: all `diagnosticsEnabled` guards removed — `_rebuildSamplingTimers()`
  always creates the fps + power timers and `_sampleThermal` always logs while recording.
  The r148 improvement stays: the helper is re-called after the settings sheet closes,
  so interval changes apply live.
- **Summary**: unchanged structurally (timeline always computed, Extra graphs collapse
  persisted as `extra_graphs_expanded`). The `_diagnosticsOffSession` branch is KEPT as
  backward compat for sessions recorded with the r148 build (`diagnosticsEnabled:false`
  in their config block, no diagnostic records): its note now explains the app-version
  history instead of pointing to the (removed) setting; their interval rows stay hidden
  in the Settings tab. All other sessions render normally.
- Docs (SETTINGS_REFERENCE, DATA_GUIDE, FIELD_GUIDE, overview) updated to "always
  logged, display opt-in". Analyze clean; suite 344 passing.

## Round 150 (2026-07-24): accept *_qnn.onnx NPU models in the picker + MODEL_CONVERSION.md

Owner investigated ONNX support because collaborators want to share `.pt`/`.onnx`
models. Findings: the vendored plugin ALREADY contains an ONNX Runtime path — but
only for Ultralytics QNN context-binary exports (`*_qnn.onnx`) running on the
Snapdragon Hexagon NPU via `OrtQnnModel.kt` (upstream yolo-flutter-app PR #526,
merged 2026-06-11; `onnxruntime-android-qnn:1.26.0` was already an `implementation`
dep in the app's build.gradle, plus the `qnn_*_test.dart` integration tests). Generic
`.onnx` is deliberately rejected natively (`Predictor.kt`: "convert to TFLite") and we
decided NOT to add a general ONNX runtime: no FPS to gain (CPU = same XNNPACK; LiteRT's
GPU delegate beats ORT's weak Android GPU story; per-frame NHWC→NCHW transpose cost),
big maintenance/APK cost for a solo maintainer. The only ONNX case that IS faster
(Snapdragon NPU) was already implemented — this round exposes it in the UI.

- **Gap closed**: the Dart `ModelCatalog` filtered `.tflite` everywhere, so even a
  `*_qnn.onnx` could not be imported despite full native support. New top-level helpers
  in `model_catalog.dart`: `isSupportedModelFileName()` (`.tflite` OR `_qnn.onnx`,
  case-insensitive — plain `.onnx` stays rejected so broken entries never reach the
  picker) and `isQnnModelPath()`. Applied at all four filter sites (bundled-custom asset
  scan, imported-dir scan, Import… file picker, `modelFileNameFromUrl` for Download…);
  download error + dialog label + import snackbar now say ".tflite or *_qnn.onnx".
- **Benchmark guard** (settings AI tab): the engine benchmark builds `LiteRtModel`
  variants only, so for a selected `*_qnn.onnx` the "Benchmark engines (GPU vs CPU)"
  button + helper text are replaced by a note ("always runs on the Snapdragon NPU —
  benchmark and CPU-thread setting don't apply"). Native `inspectModel` already reads
  ONNX `metadata_props` (`loadMetadataFromOnnx`), so input-size labels work unchanged.
- **New `docs/MODEL_CONVERSION.md`** (collaborator-facing, plain language): what formats
  the app accepts and why generic ONNX is not one of them; `.pt` → `.tflite` export
  one-liners (fp32/fp16 need NO dataset; INT8 needs calibration images — collaborators
  run `int8=True data=…` on THEIR machine, data never shared); why INT8 matters on
  CPU-bound phones (Samsung M12: 65 ms int8 vs 260 ms float nano) while GPU-vs-CPU is
  decided by op-graph compatibility, not precision (r77 invariant); `onnx2tf` as the
  fallback when only an `.onnx` exists (no embedded class names — prefer `.pt`); QNN
  export caveats (Snapdragon-only, no CPU fallback, arch-specific).
- Tests: `model_catalog_test.dart` gains `_qnn.onnx` accept + plain-`.onnx` reject cases
  for `modelFileNameFromUrl`, plus unit tests for both new helpers. Analyze clean;
  suite 347 passing.

## Round 151 (2026-07-24): surface model-load failures (QNN test fallout), never hang calibration

Owner field-tested r150 by downloading `yolo26n_v73_qnn.onnx` / `yolo26n_v81_qnn.onnx`
from the yolo-flutter-app v0.3.5 release assets. Root cause of everything seen: QNN
context binaries are precompiled per Hexagon NPU generation (`strings` shows
`min_arch=73`); the Xiaomi 11T Pro (Snapdragon 888) is a v68 HTP, so ONNX Runtime
fails with `ORT_INVALID_GRAPH ... LoadCachedQnnContextFromBuffer ... Error code: 5005`.
Those two files can never run on this phone (they need 8 Gen 2 / newer). The app bugs
were in how that failure was (not) handled:

- **Bug 1, stale detections**: on a failed in-place switch the native side deliberately
  keeps the previous predictor (YOLOView.kt) and the plugin fires `onModelError`, but
  the camera screen only wired `onModelLoad`, so the config/dropdown claimed the QNN
  model while the old model kept detecting, with zero user feedback.
- **Bug 2, infinite "Calibrating..."**: on cold start the model loads fire-and-forget
  from creationParams (`YOLOPlatformView` init); on failure `predictor` stays null,
  `onFrame` never emits streaming data, `_imageWidth` stays 0 and `_calibrating`
  (r120) never clears. The app was unusable until the saved model changed.

Fixes:

- **Native**: `YOLOView.lastModelLoadError` (@Volatile, exception class + message,
  cleared on both success paths) so callers can surface the real reason. The
  `"setModel"` channel error now carries that reason instead of a generic string.
  `YOLOView.isModelLoaded()` added. `YOLOPlatformView`'s existing model-load callback
  now, on failure AND only when no predictor is left running (so in-place switch
  failures are not double-reported), notifies Dart via
  `methodChannel.invokeMethod("onInitialModelLoadFailed", {modelPath, message})`.
- **Plugin Dart** (`yolo_view.dart`): new `_handleMethodCall` case
  `onInitialModelLoadFailed` routes that event into the existing `onModelError`
  callback, giving hosts ONE error path for both failure shapes.
- **App** (`camera_session_screen.dart`): `onModelError` is now wired.
  `_loadedModelPath`/`_loadedModelTask` are captured in `onModelLoad`; the handler
  calls the new pure helper `modelLoadRecovery()` (model_catalog.dart): revert the
  config to the still-loaded model on a switch failure, or fall back to the bundled
  `yolo26n` (+ task detect) when nothing is running (the hang case, now self-healing),
  persist via `SessionConfig.save()`, re-probe the input size, and show one dialog
  (spam-guarded via `_modelErrorDialogOpen`) with the file, the native reason, and a
  plain-language hint (`modelLoadHint()`) for the QNN arch-mismatch pattern.
  `sameModelFile()` compares by file name and maps official bundled ids to their
  real asset (`yolo26n` = `yolo26n_int8.tflite`) WITHOUT prefix-matching, so
  `yolo26n_v73_qnn.onnx` is never confused with the nano id (stale-failure check).
- **Cleanup**: `YOLOFileUtils.inputImageSize` early-returns null for `.onnx` paths
  (the TFLite metadata extractor logged a spurious "Input tensor shape read failed"
  warning per QNN model on every settings-sheet open).
- **Docs**: MODEL_CONVERSION.md QNN section gains the arch-generation caveat
  (v68 = SD888 gen, v69 = 8 Gen 1, v73 = 8 Gen 2, v75 = 8 Gen 3, v79+ = 8 Elite),
  the concrete v0.3.5-assets example, and the new error/fallback behaviour.
- Tests: `modelLoadRecovery` (switch revert, bundled fallback, resolved-path
  matching, stale ignore, id-vs-lookalike), `modelLoadHint`. Analyze clean;
  suite 354 passing; `flutter build apk --debug` compiles the Kotlin changes.

Owner verification steps: (1) with nano loaded, pick the v73 QNN model: expect the
error dialog naming the file + reason, dropdown reverts, detections stay honest;
(2) select the QNN model, kill + reopen the app, New session: expect the fallback
dialog and calibration completing on nano. The two downloaded QNN files can be
deleted afterwards, they can never run on this phone.
## Round 152 (2026-07-27): reference photos on by default (promote r107 gt frames)

Owner request: periodic photos at a fixed interval during AI sessions (even
while the motion gate sleeps), on by default, as unbiased evaluation samples —
users can spot pollinators the AI missed and send those photos in for model
training. Finding: r107's "Ground-truth frames" already did exactly this
(plain Dart timer, works through gate-idle and blackout), so this round
promotes it instead of building anything new. Owner decisions: UI name
"Reference photos", on/30 s default, visibility-only scope (no post-hoc
integration), active in detector + motion modes, inert in time-lapse.

- **Wire names FROZEN** (r112 precedent): folder `gt_frames/`, record
  `gt_capture`, JSON keys `gtFramesEnabled`/`gtFrameSeconds`. Dart
  identifiers kept too (rename = ~30 cosmetic sites); doc comments lead with
  the UI name.
- **Default flip** to `true`/`30.0` (constructor + fromJson fallbacks).
  Migration nuance: toJson always writes the keys, so ONLY configs missing
  them (fresh installs, never-resaved pre-r107 configs) get the new
  defaults; an explicitly saved `false` — including the owner's current
  device — survives and needs one manual flip ON. Guarded by a migration
  test in session_config_test.dart.
- **`ref_` filename prefix** (`roiPhotoFileName` gained `prefix` param;
  `RoiCaptureScheduler.filePrefix`): both schedulers share the session
  token, so a same-millisecond capture in roi_frames/ and gt_frames/ could
  collide by name and the gallery export's native same-name skip would
  silently drop one album copy. Fixed-width stamp unchanged → per-folder
  path sort still equals capture order. Old sessions' `roi_`-named gt files
  keep working (summary resolves by the `jpeg` field, scans glob `*.jpg`).
- **Fast path FORCED** for the reference scheduler (`RoiCaptureMode.fast`,
  was `_config.captureMode`): a high-res capture stalls the analysis stream
  0.13–1.5 s per photo (r115) — a detection-independent sampler must never
  tax the detection pipeline. Accepted trade-off, documented in code: no
  cross-scheduler busy guard; if a detection high-res capture has the
  stream paused, the crop is at worst ~1.5 s stale at a 30 s cadence.
- **Time-lapse inert** (whole session is already clock-driven photos):
  builder + timer conditions exclude `timeLapseCapture` (no scheduler, no
  `gt_frames/` dir), keys added to `notApplicableConfigKeys(timelapse)`,
  Setup-tab switch greyed + shown OFF with a suffix note (stored preference
  survives), summary shows a not-applicable note.
- **Settings control moved** from AI → Visit tracking → Advanced to the
  Setup tab (SwitchListTile + unit-aware DurationSettingField, r147
  mode-aware pattern); removed from `_resetTrackingDefaults` (a tracking
  reset must not flip a Setup-tab setting).
- **Capture cue wired**: `recordGtFrame`'s previously ignored bool now
  triggers `_flashCaptureCue()` (self-gates on flashOnCapture).
- **Summary visibility**: `gt_capture` records seed the Photos tab
  (chronological, empty box lists — the capture-record backstop pattern),
  `_PhotoSample.isReference` + neutral blue-grey "Reference photo — fixed
  interval" chip (slot free: post-hoc delete/kept chips scan roi_frames/
  only), "(N reference)" in the Showing-count, file resolution helper picks
  gt_frames/ vs roi_frames/ per name. Settings row moved into Photos &
  capture. Gallery export scans BOTH folders (full-path sort groups
  gt_frames first, capture-ordered within each; dialog mentions the
  reference count).
- **Out of scope (deliberate)**: post-hoc analysis / photo_keep cleanup
  stay roi_frames-only. Future ideas noted in the plan: run post_detector
  (+SAHI) over gt_frames/ and flag frames where it finds insects the live
  log missed; a gate-wake-without-detection sampler; sub-threshold
  raw_detections logging.
- Tests: config round-trip rewritten for the new defaults + explicit-false
  migration guard + notApplicable expectations; scheduler filePrefix test
  (`ref_S_…`); roiPhotoFileName prefix/sort test. `flutter analyze` clean,
  356 tests pass.

## Round 153 (2026-07-27): upstream 0.6.10 re-audit, proposals recorded (no code)

Trigger: owner re-downloaded upstream yolo-flutter-app main into
`./yolo-flutter-app-main` and asked whether the newer upstream offers pipeline
FPS or efficiency gains. Audit: 3 parallel read-only explorers (native delta,
Dart delta, fresh hot-path sweep) + adversarial verification of the top 10 of
20 candidate findings; 4 survived.

- Verdict: upstream main is **v0.6.10, the same release the r128 Part C review
  compared file-by-file**. Android deps byte-identical (litert 2.1.5, CameraX
  1.6.0, onnxruntime-android-qnn 1.26.0); Dart lib delta 0.6.4 to 0.6.10 has
  zero perf work (depth task + docstrings). No live-path FPS gains to port;
  the thermal governor stays the ceiling (C2 verdict stands).
- Recorded in PERF_AND_ROBUSTNESS_REVIEW.md as new **Part D** (open
  checkboxes, so a future round can implement without re-auditing):
  - D1: fast ROI crop (`captureRoiFromFrame`) runs synchronously on the
    platform/main thread; move to `stillExecutor` (~10 lines, removes an
    8-50 ms hitch per photo, smoothness only).
  - D2: format=litert (NCHW) model support, staged. Today such a model
    "loads" then throws every frame (0 fps, endless "Calibrating") while the
    settings sheet shows the right input size. Stage A = loud load-time guard
    (~10 lines, rides the r151 recovery dialog); Stage B = ~60 LOC detect-only
    port + MODEL_CONVERSION.md collapses to one calibration-free
    `quantize=w8a32` command (at the next model-export cycle).
  - D3: batch/SAHI predict path JPEG-encodes an annotated image FaunaPulse
    discards; opt-out flag (~30 lines, roughly 10-20% batch wall time).
  - D4: skipped-leads inventory (re-sync hazards incl. fork-only
    normalizationLut, micro items, Dispatchers.IO correctness risk).
- C4 record corrected in place: re-entry is three pieces (NCHW auto-detect
  prerequisite + CHW packing + doc update together), and the failure mode is
  a loud per-frame buffer-mismatch throw, not silent garbage.
- Owner decision: proposals only, no code changes this round. Files touched:
  PERF_AND_ROBUSTNESS_REVIEW.md, AGENT_CHANGELOG_OVERVIEW.md (pointer line),
  this file.

## Round 154 (2026-07-27): D1, fast ROI photo crop off the platform thread

Implements Part D's D1 (from the r153 audit): the `"captureRoiFromFrame"`
method-channel handler ran `ImageUtils.cropRoiFromFrame` (bitmap alloc +
rotate-draw + optional rescale + JPEG encode; ~8-15 ms at 640x480, ~20-50 ms
at 1440x1080) directly on the platform/main thread, the same thread that
drains detection results to Flutter. Every fast photo (the default capture
path, ~1 Hz during visits, plus one per high-res sync companion) stalled box
delivery and UI by that much.

- New `YOLOView.captureRoiFromFrameAsync` (beside its sync sibling): work runs
  on the round-63 `stillExecutor` (single-threaded, so crops stay serialized
  behind any in-flight still job), callback always invoked on the main thread,
  null on failure. Exceptions are caught, logged (reaches `logcat_end.txt`)
  and mapped to null, which the Dart `_invoke` wrapper already turns into the
  normal "fast path failed" fallback, so error behaviour is unchanged from the
  caller's point of view.
- `YOLOPlatformView.kt` handler now completes the MethodChannel result from
  that callback instead of blocking. No Dart changes, no new tunable, no
  behaviour change beyond the removed stall (the deferred grab reads a
  slightly newer frame, so companion freshness marginally improves).
- Deliberately NOT done (r153 verifier warning): no channel-wide background
  TaskQueue (other handlers touch camera/view state).
- Verified: `flutter analyze` clean, 356 tests pass, debug APK builds. Owner
  smoke test: photos at ~1 Hz while watching box smoothness, once at 640x480
  and once at 1440x1080.

## Round 155 (2026-07-27): D2, format=litert (NCHW) model support (detect-only)

Implements Part D's D2 at the owner's request, Stage B directly (which subsumes
the Stage A load guard: NCHW models now load and run, so there is nothing to
reject). `yolo export format=litert` (the current documented Ultralytics Android
export; official `*_w8a32.tflite` assets) produces NCHW `[1,3,H,W]` models with
input `args_0` and outputs `output_N`; the fork previously understood only the
legacy onnx2tf convention (`images`/`Identity_N`, NHWC), and such a model would
"load" then throw every frame (0 fps, endless "Calibrating").

- `LiteRtModel.kt`: input-name probe (`images`, `args_0`, `input`, `input_1`,
  `serving_default_input`); NCHW detected from the native shape AFTER the
  fork-only TFLite-graph fallback so both resolution paths pass the test (r153
  hazard 1); the graph fallback is kept over upstream's sqrt(count/3) buffer
  guess (hazard 2); `inputDims` stays NHWC-convention, new `inputUsesNchw`
  property; outputs probed as `output_$i` then `Identity`/`Identity_$i`; the
  compile log line now prints `layout=NCHW|NHWC`.
- `Predictor.kt`: `InferenceModel.inputUsesNchw` with default `false`, so
  `OrtQnnModel` keeps its internal HWC-to-CHW transpose untouched (the r153
  deliberate skip stands); only `LiteRtModel` overrides it.
- `ImageUtils.kt`: `copyRgbBitmapToFloatArray` gained `channelsFirst` (planar
  CHW branch, all R then all G then all B) using the fork's cached
  `normalizationLut`, NOT upstream's invStd multiply (hazard 3).
- `ObjectDetector.kt`: passes `channelsFirst = rtModel.inputUsesNchw`.
  Detect-only scope: Segmenter protoNchw and the other predictors deliberately
  not ported (unreachable in FaunaPulse).
- `MODEL_CONVERSION.md`: now leads with ONE export command, `format=litert
  quantize=w8a32` (dynamic-range quantization, NO calibration dataset, embedded
  Ultralytics metadata, requires `ultralytics>=8.4.83`); the legacy
  `format=tflite` exports stay documented, full INT8 kept as the low-end-CPU
  option (Galaxy M12 datapoint stands).
- No new tunable (the layout is auto-detected, nothing to configure); the model
  picker filter is unchanged (`.tflite` was already accepted, r150).
- Verified: `flutter analyze` clean, 356 tests pass, debug APK builds. Owner
  on-device test: Settings → AI → Model → Download… with
  https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.6.6/yolo26n_w8a32.tflite
  then confirm boxes appear, logcat shows "layout=NCHW", and run the engine
  benchmark (GPU vs CPU) on it.
- 2026-07-28 field confirmation (owner): the official yolo26n_w8a32.tflite
  downloads, loads and detects on the Xiaomi — r155 verified on-device.

## Round 156 (2026-07-28): D3, skip the discarded annotated JPEG on batch/SAHI predicts

Implements Part D's D3, the last open Part D item (D4 is a record of skipped
leads, not work). Every single-image predict (post-hoc photo analysis + each
SAHI tile) made the native side draw all boxes onto a full
bitmap.copy(ARGB_8888) and JPEG-q90-encode it into response["annotatedImage"];
FaunaPulse reads only the box list and discarded the bytes.

- New optional `includeAnnotatedImage` (default `true`) on `YOLO.predict` /
  `YOLOInference.predict`; the wire key crosses the channel ONLY when false and
  the native default stays true, so the plugin demo screen and any older caller
  behave byte-identically.
- Kotlin: `YOLOPlugin.predictSingleImage` reads the flag →
  `YOLOInstanceManager.predict` gains `generateAnnotatedImage` →
  `YOLO.predict(bitmap)` skips `drawAnnotations` when false (the plugin's
  JPEG-encode block is null-guarded and skips itself).
- `analysis_screen.dart` base PredictFn passes `false` — applies to plain AND
  SAHI analysis (PostDetector / sahi.dart unchanged, they see only the
  PredictFn).
- Deliberately NOT bundled (D4 record): the Dispatchers.IO hop for
  predictSingleImage (`YOLOInstanceManager.predict` mutates and restores
  per-instance thresholds around the call; concurrency there is a correctness
  risk).
- Expected gain (r153 verified estimate): ~3-6 ms per 640 tile (~10-20% of
  batch wall time), ~15-25 ms on a 1440x1080 full-image pass, ~100 KB less per
  tile over the method channel; offline path only, no live-camera or heat
  interaction.
- Tests: `test/fauna_pulse/predict_annotated_image_test.dart` (wire contract:
  key only when false; default and explicit true stay off the wire). Verified:
  `flutter analyze` clean, 359 tests pass, debug APK builds. Owner measurement:
  re-run "Analyze saved photos" on a large session and compare wall time with a
  pre-r156 run of the same session and settings.


## Round 157 (2026-07-28): first-public-release plan (docs/RELEASE_PLAN.md)

- Added docs/RELEASE_PLAN.md: phased, checkbox-tracked plan for the first public release. Phases: 0 repo hygiene (release keystore, SDK pinning to targetSdk 36, privacy policy, CITATION.cff cleanup, fetchBundledModels path fix), 1 v0.7.0 GitHub release + Zenodo DOI (webhook must be enabled BEFORE the first tag), 2 citizen-scientist docs (QUICK_START, screenshots, "(round N)" cleanup, fastlane metadata), 3 settings-sheet reorganization (Graphs tab becomes Power; auto-throttle, rate caps, camera fps cap and motion gate move there; advanced folds; per-field help toggles), 4 Google Play (personal account, 12 testers x 14 days closed test, own keystore uploaded to Play App Signing so GitHub APKs cross-update), 5 optional F-Droid.
- Key research findings (sources listed in the plan): Play requires target API 36 for new apps from 2026-08-31; IzzyOnDroid's ~30 MB limit rules it out (129 MB universal APK); the free channel is GitHub Releases + Obtainium.
- Owner decisions recorded: early tag + DOI before polish; heat controls go to a Power tab, not the AI tab (the AI tab is whole-greyed in no-AI modes while the motion gate must stay editable in motion mode).
- Docs only, no code changes this round.

## Round 158 (2026-07-28): Phase 0 release prerequisites (signing, SDK pinning, bundled model, privacy policy)

Implements Phase 0 of docs/RELEASE_PLAN.md. No app-code changes (Dart untouched); build config, scripts and docs only. `flutter analyze` clean, 359 tests pass, debug APK builds, release build correctly refuses to run without a keystore.

- **Release signing made a one-command step.** New `scripts/create_release_keystore.sh` (prompts for a hidden password, runs keytool with PKCS12/RSA-2048/validity 10000, writes `android/key.properties` with mode 600, prints the SHA-256 fingerprint and a backup reminder; refuses to overwrite an existing keystore). New committed template `android/key.properties.example`. New INSTALL.md section B4 explaining in plain language what a keystore is, why losing it is permanent, and why the SAME key must later go to Play App Signing (otherwise Play installs and GitHub-APK installs cannot update each other). Old B4 renumbered to B5; stale "Track A4" reference fixed to A3. The build.gradle failure message now points at the script instead of a raw keytool command.
- **SDK levels pinned** in `android/app/build.gradle`: `compileSdk 36`, `minSdk 24`, `targetSdk 36`, replacing `flutter.*SdkVersion`. These matched the installed Flutter 3.44 defaults, so nothing changed behaviourally, but the API level the app targets is now a deliberate choice rather than a side effect of the installed Flutter SDK. Verified in the built APK via aapt2: `minSdkVersion:'24' targetSdkVersion:'36' compileSdkVersion='36'`. Google Play's API-36 requirement for new apps (2026-08-31) is therefore already satisfied.
- **Bundled model actually gets bundled.** The `fetchBundledModels` preBuild task pointed at `${rootProject.projectDir}/../../scripts/` (i.e. outside this repo, at `InsectDetectApp/scripts/`, which does not exist) and, even if found, the plugin's script writes into `packages/ultralytics_yolo/example/assets/models/` and pulls six task variants that round 119 deliberately deleted (13.6 MB). `ignoreExitValue = true` hid the failure, so a clean clone built an APK with no model. New `scripts/fetch_bundled_models.sh` (ours) downloads ONLY `yolo26n_int8.tflite` into `assets/models/`, skips when present, always exits 0. Build output now shows `fetch_bundled_models: have yolo26n_int8.tflite`.
- **Release builds refuse to ship without the model** (new guard in the existing `preReleaseBuild` doFirst, alongside the signing guard), escape hatch `-PallowMissingBundledModels`. ORDERING NOTE for future work: `fetchBundledModels` (preBuild) runs before `preReleaseBuild`, so on an online machine the model is downloaded and the guard never fires; it is an offline / failed-download backstop, not a routine gate.
- **PRIVACY_POLICY.md** at the repo root (Google Play requires a publicly reachable privacy-policy URL even for apps that collect nothing). Claims verified against the code: detection is fully on-device; the ONLY network paths are the user-triggered `ModelCatalog.downloadModel` and the plugin's `YOLOModelResolver` fallback fetch of an unbundled official model; problem reports are built locally and only sent if the user shares them, with `redactLocation` stripping coordinates; crash files stay local; no analytics/tracking dependency exists. Includes a permission-by-permission table and a responsible-use note on protected-species coordinates and crop EXIF.
- **CITATION.cff**: the three stale TODO comments removed (the real ORCID'd author list was already in place); the DOI line stays commented with a note to use the Zenodo CONCEPT DOI.
- **README §Models rewritten around the honest answer to "does a fresh install detect insects?"**: no. The bundled yolo26n is a general-purpose COCO detector, so the AI pipeline runs immediately but recognises no insects; insect work needs a purpose-trained model via Download…/Import…/MODEL_CONVERSION.md; motion and time-lapse need none. Getting-started step 3 and INSTALL.md A3 aligned. An OWNER TODO comment asks whether an insect model may be published as a release asset (this is the single biggest citizen-scientist adoption question, also recorded in RELEASE_PLAN.md).
- **docs/FIELD_GUIDE.md**: title typo fixed ("Running a FaunaPulseing Session"), and the public `> TODO (owner knowledge)` block replaced by a real "Physical setup" section written only from what the code guarantees (mounted phone required because camera shake reads as motion, portrait-only, distance set by the on-screen px readout rather than a fixed number, power bank), plus an HTML comment (invisible to readers) listing the four things the owner still needs to add from field experience.
- **CHANGELOG.md** (new, human-facing) with an Unreleased section for 0.7.0; AGENT_CHANGELOG.md remains the development journal.
- RELEASE_PLAN.md updated in place: Phase 0 boxes ticked, build-config section split into fixed vs still-open, and the insect-model question recorded as an explicit open decision.

## Round 159 (2026-07-28): settings sheet reorganized by user intent (Phase 3 of RELEASE_PLAN)

Implements all four sub-rounds (A-D) of RELEASE_PLAN.md Phase 3 in one round. UI placement, folds and wording only — ZERO SessionConfig JSON key changes (wire stays frozen), zero behaviour changes to detection/capture. `flutter analyze` clean; 363 tests pass (4 new). Owner still owes the on-device pass across all 3 capture modes.

- **Tabs are now user-intent groups**: Setup (what am I recording?), AI (how does detection behave?), **Photos** (was Camera), **Power** (was Graphs; `Icons.bolt`). A citizen scientist can run a session touching only folder, trigger and session length.
- **Power tab (the core fix)**: auto-throttle + max inference rate (per-control greying kept verbatim), NEW "Advanced (throttle tuning)" fold (min rate, duty target), camera fps cap (moved from Camera — it is heat territory; its comment now cross-references the inference cap "above"), motion gate switch (tri-mode logic verbatim), NEW "Gate sensitivity" fold with the 5 tuning fields — `initiallyExpanded: _c.motionOnlyCapture` + `ValueKey(_c.motionOnlyCapture)` so it arrives OPEN in motion mode (there the fields ARE the capture sensitivity) and collapsed in AI mode, NEW "Diagnostic graph sampling (advanced)" fold (the old Graphs tab's three sample intervals). Intro sentence points at the live-screen power-save button. Deliberately NOT the AI tab (owner's first guess): the AI tab is whole-greyed (r147) in the no-AI modes, exactly where the gate must stay editable.
- **Photos tab**: "Saved photo side" leads (helper reworded — stream references now say "Advanced below"); ROI photo source + sync companion unchanged; "Square (1:1) export crops" arrives from Graphs under a "Photo viewer" label; stream resolution dropdown + ceiling note moved into NEW "Advanced (camera stream)" fold (round-122 Auto coupling unchanged, placement flipped); lens-info fold unchanged. The tab now has NO mode-aware greying at all (everything on it applies in all 3 modes).
- **AI tab**: model + Confidence stay visible; NEW "Advanced (engine & thresholds)" fold (IoU, GPU switch, CPU threads, engine benchmark + NPU note); tracker-algorithm dropdown moved INSIDE the existing advanced tracker fold (research-comparison feature; fold title still names the active algorithm); "Show FPS" left for Setup. The r147 whole-tab greying is untouched — everything remaining on the tab is detector-only.
- **Setup tab**: session length moved up directly after the capture trigger (extracted `_sessionLengthFields()`); display toggles (show boxes, info panel, Show FPS from AI, ROI flash) now in a collapsed "On-screen display" fold; "Show setup tips" REMOVED from the sheet →
- **Home screen ⋮ menu** gains a `CheckedPopupMenuItem` "Show setup tips at session start" (`kHideSessionInfoPrefKey` unchanged; sheet's SharedPreferences import dropped). Enum grew to `{toggleSetupTips, deleteAllSessions}`.
- **Collapsed help (`NumericSettingField`)**: helper paragraphs now hide behind a per-field ⓘ (tap the label row to toggle; ephemeral state, no API change for ~40 call sites; `DurationSettingField` inherits). This was the main density driver — several helpers run 8+ lines. New widget test `numeric_setting_field_test.dart` (help toggle, no-icon-without-helper, clamped commit, duration passthrough).
- **New shared helper `_foldSection`** (settings_sheet.dart): the tracker-fold ExpansionTile recipe (zero tile padding, muted chevron, `shape: Border()`), reused by all 6 folds incl. the refactored tracker fold.
- Cross-references updated: Setup trigger explainer ("motion gate on the Power tab"), reference-photos subtitle ("Photos tab"), sheet header comment, session_config.dart L463 comment, camera_session_screen.dart L1550 comment. `docs/SETTINGS_REFERENCE.md` restructured to mirror the new tabs (its "(AI tab)" headings for throttle/gate were stale even before this round) + a migration note for pre-r159 screenshots + fold locations marked per setting + previously-undocumented "Square export crops" and "Show setup tips" locations added.
- Files: settings_sheet.dart (large diff, mostly moves), home_screen.dart, numeric_setting_field.dart, session_config.dart (1 comment), camera_session_screen.dart (1 comment), test/fauna_pulse/numeric_setting_field_test.dart (new), docs/SETTINGS_REFERENCE.md, docs/RELEASE_PLAN.md, this file, AGENT_CHANGELOG_OVERVIEW.md.

## Round 160 (2026-07-31): Part E recorded (codex re-audit, adversarially verified)

The owner had codex (OpenAI) audit the repo against the re-downloaded upstream plugin copy
(now v0.6.11) and propose a Part E for PERF_AND_ROBUSTNESS_REVIEW.md; Claude then verified
every checkable claim (3 parallel read-only exploration agents + firsthand spot-checks)
before recording anything. Docs + two comment lines only; no behavior changes.

- **Verification verdict:** the codex plan is nearly hallucination-free. Of ~40 verifiable
  claims essentially all matched the code at exact file:line, including the QNN packaging
  size (claimed ~76/226 MB; measured 75.7 MB in-APK / 224.3 MB uncompressed in the actual
  release APK). One proposal rested on a false premise and was reworded (E7
  thermal-headroom caching: headroom is read ~2x per 10 s, nowhere near Android's ~1/s NaN
  throttle; only the thermal+power read coalescing survives). Smaller amendments: E0 must
  not rewrite Part D's historical "0.6.10" statements; E1 gains the RUN_SOAK twin bug, the
  v81-vs-v73 asset inconsistency and the debug-Xiaomi/release-Samsung device caveat; E9
  gains the fact that PreviewView COMPATIBLE is a deliberate fork override.
- **Top verified finding (E2):** vendored `YOLOInstanceManager.dispose()` has an EMPTY try
  block ("YOLO class doesn't have a close() method") so every dispose leaks the native
  interpreter; upstream 0.6.11 contains the complete fix to port (idempotent YOLO.close(),
  remove-then-close on Dispatchers.IO, synchronized predict with finally-restored
  thresholds, plugin-owned scope instead of GlobalScope). Highest-value open item.
- **Part E appended** to PERF_AND_ROBUSTNESS_REVIEW.md: E0 verdict (upstream v0.6.11,
  iOS-only change, rejected leads) + E1-E10 proposals, ALL unchecked until implemented,
  tested and measured, with interfaces/acceptance/order recorded. New settings proposed
  there (timeLapseCameraSleep, reduceCameraFpsWhileMotionGateIdle) both default false and
  only ship if their experiments pass.
- **Small fix landed:** `integration_test/qnn_benchmark_test.dart` header comments said
  `--dart-define=RUN_BENCH=1`, but `bool.fromEnvironment` only accepts the literal `true`,
  so the bench silently never ran; comments now say `=true` and document `RUN_SOAK=true`.
  Code unchanged.
- Review artifacts: the codex source plan sits at `/InsectDetectApp/codex-proposed-plan.md`
  (repo-root sibling, not part of the app tree).

## Round 161 (2026-07-31): E2 native predictor lifecycle port (close/scope/executors)

Implements Part E item E2 of PERF_AND_ROBUSTNESS_REVIEW.md, both phases: the upstream-0.6.11
predictor-close port and the executor-ownership cleanup. Native Kotlin only (plugin + app shell),
zero Dart changes, zero behavior changes to detection/capture. Robustness work, not frame time:
before this round every disposed batch-analysis instance leaked its native LiteRT interpreter
(the r135+ analyze/re-analyze flows dispose one per run) and every model switch parked one
non-daemon thread forever.

- **YOLO.kt**: explicit lazy `predictorDelegate` + `closed` flag; `@Synchronized`
  `predictorInstance()` / `predict(bitmap)` / new idempotent `close()` (releases the
  BasePredictor's LiteRT interpreter or ORT session). Any predictor access after close fails fast
  with IllegalStateException; the existing channel catches turn that into a clean
  `prediction_error` reply instead of silently rebuilding an interpreter on a disposed instance.
- **YOLOInstanceManager.kt**: maps are ConcurrentHashMaps (close happens on IO while predict/load
  run on the platform thread); `predict()` is `synchronized(yolo)` with the temporary thresholds
  restored in `finally` (the old try/catch pair missed non-Exception Throwables); `dispose()` is
  suspend, removes the instance from the maps FIRST, then closes on Dispatchers.IO (the close can
  briefly wait for an in-flight predict and must not do that on the platform thread) - pre-r161 it
  held an empty try block ("YOLO class doesn't have a close() method") and leaked the model;
  `disposeAll()` hands all closes to the IO dispatcher; `removeInstance` alias deleted.
- **YOLOPlugin.kt**: plugin-owned `pluginScope` (SupervisorJob + Dispatchers.Main.immediate)
  replaces GlobalScope; created in onAttachedToEngine, cancelled in onDetachedFromEngine, which now
  also clears every instance-channel handler and calls `disposeAll()` (the old detach comment
  "YOLO class doesn't need explicit release" was wrong). `disposeInstance` replies after the real
  close; `predictorInstance` warm-up runs in the scope.
- **YOLOView.kt (executor ownership)**: one owned `modelLoadExecutor` replaces
  `Executors.newSingleThreadExecutor()` per `setModel()` call (one leaked thread per model switch,
  e.g. every engine-benchmark run). A generation token (AtomicInteger) resolves overlapping loads:
  a superseded load's finished predictor goes into the bounded LRU cache but is NOT installed over
  the newer model; a load finishing after permanent view disposal closes itself. KEY DETAIL:
  completions run on a main-looper Handler, deliberately NOT `View.post` - a detached (disposed)
  view parks View.post runnables until a re-attach that never comes, which would strand the fresh
  predictor unclosed. New terminal `release()` (shuts down `modelLoadExecutor` + `stillExecutor`)
  is called from `YOLOPlatformView.dispose()` AFTER `stop()`; `stop()` itself stays restartable
  (a later `setModel()` rebinds the camera), which is why the executors were never shut down there.
  CameraX `takePicture` now receives a rejection-tolerant wrapper executor: a capture-error
  callback delivered from the camera thread just after `release()` is dropped with a log line
  instead of crashing CameraX internals with RejectedExecutionException.
- **MainActivity.kt**: `onDestroy()` shuts down `cropExecutor` (queued crop/Gallery writes still
  finish; the executor is per-Activity so a recreated Activity gets a fresh one).
- **Preserved invariants**: `includeAnnotatedImage` behavior (D3), the r151 model-load recovery +
  `onInitialModelLoadFailed` flow (the failure path's stale/disposed guard fires BEFORE any UI
  state is touched, so a superseded failure can no longer overwrite the newer load's state), the
  3-entry predictor LRU cache semantics, and the round-63 still-capture threading.
- Verified: `flutter analyze` clean, 363 tests pass, debug APK builds. Owner's on-device step:
  repeated "Analyze saved photos" run/cancel/re-run cycles and a few model switches while watching
  `dumpsys meminfo <pkg>` (native heap should plateau, pre-r161 it climbed per analysis run) and
  `ps -T -p <pid> | wc -l` (thread count should plateau, pre-r161 it grew per model switch).

## Round 162 (2026-07-31): E1 benchmark protocol + perf_summary tool; E5 bounded error sampling

Implements Part E item E1 (both deliverables) and the small half of E5 from
PERF_AND_ROBUSTNESS_REVIEW.md. `flutter analyze` clean, 380 tests pass (17 new). No behavior
changes to detection/capture; the only app-code change is the error-report sampler.

- **docs/PERFORMANCE_BENCHMARKING.md (new):** how to measure honestly. Four golden rules (never
  quote debug-build numbers as device speed; never compare mixed binaries, the r132 start-record
  fields make that auditable; power/energy only unplugged, the r84 rule; 10 min cool-down between
  runs, the D3 lesson). Device/build matrix: Xiaomi = debug/dev + thermal-behaviour phone,
  Samsung = release-test + absolute-speed phone (its `battery_current_ua` is broken, battery-%
  only). Fixed-variables checklist, 3 paired runs in alternating order, cold (first ~2 min) vs
  sustained (last ~10 min) separation, and the acceptance criteria (all three pairs agree AND the
  gain exceeds run-to-run variation; capped modes need equal delivered FPS + >=5% lower power or a
  materially delayed thermal collapse). Cross-links to the r76 in-app engine benchmark, C2, C3,
  D3 and the QNN harness instead of restating them.
- **tool/perf_summary.dart (new):** pure-Dart session-log summarizer, no Flutter dependency
  (`dart tool/perf_summary.dart <session.jsonl|session-folder>... [--csv] [--cold=S]
  [--sustained=S]`). STREAMS each log via openRead + LineSplitter (never a file-sized
  `List<String>`; only the periodic samples are buffered, a few thousand numbers even for 8 h).
  Output: one comparison row per session (build/model/trigger, sustained camera+pipeline FPS,
  inference med/p95, temp start->max, gate-idle %, cap changes, power/energy, errors, end status)
  plus per-session overall/cold/sustained detail tables; `--csv` gives one stable row per session
  for R/pandas. Honours the diagnostics semantics so humans don't have to: `pipeline_fps ?? fps`
  (r85 legacy), inference fields absent while the gate sleeps = missing data not zeros (r77),
  power withheld whenever any sample was charging (r84), malformed/truncated lines counted and
  skipped. Debug-build and no-end-record sessions are flagged in the output. 10 unit tests
  (test/fauna_pulse/perf_summary_test.dart) on synthetic fixtures. Note: sustained columns read
  n/a for sessions shorter than cold+sustained windows, deliberately (no steady state exists).
- **E5, bounded error sampling:** `ErrorReporter._sampledLog` no longer `readAsLines()`s the
  whole session log at report time (the worst possible moment for a memory spike, right after
  something failed, possibly hours into a recording). New `boundedHeadTailSample` reads a 128 KB
  head + 512 KB tail chunk via RandomAccessFile (the `_loadStats()` pattern), drops the partial
  line at each chunk boundary, redacts ONLY retained lines (`redactLocation` unchanged), and is
  byte-identical to the old output for small files. Large-file marker reports file size instead
  of exact omitted-line count. 7 new tests in error_reporter_test.dart. The summary-screen
  `SessionLogIndex` (E5's main body) remains open.
- **QNN bench consistency:** the RUN_BENCH benchmark downloaded `_v81_qnn.onnx` while validation
  and soak use `_v73` (silently different context binaries per row). Aligned to v73 with an r151
  reminder that neither arch runs on the SD888 Xiaomi.
- Owner workflow note: from now on, perf/thermal claims in review rounds should come with a
  perf_summary table and follow PERFORMANCE_BENCHMARKING.md; the E3/E4/E6/E9 gates depend on it.

## Round 163 (2026-08-03): E3 time-lapse camera parking + E5 streaming session-log index

Perf review Part E, second batch (recommended order step 2: "E3 parking + E5 index").

- **E3, camera parking between time-lapse bursts (opt-in `timeLapseCameraSleep`, default off):**
  new `session/time_lapse_camera_coordinator.dart` — a pure, clock-injected state machine
  (running / parked / warming / fallbackBound; minIdleGap 30 s, prewake lead 10 s, wake
  allowance 20 s, minPark 10 s) in the TimeLapsePlan/SchedulePlan style, 15 unit tests. The
  camera screen owns the async platform calls: park = the r94 `_controller.pause()` full
  unbind after a burst ends, wake = `resume()` ~10 s before the next wall-clock burst, then a
  bounded wait for a FRESH stream event before photos may flow (`_waitForFrames` generalized
  with an `active` predicate; the native frame cache holds the pre-park frame, so capturing
  earlier could save a half-hour-old "photo"). A late (dozed) wake starts that burst's photos
  late but never shifts the burst grid. Failure policy is reliability-first: a failed park or
  a wake timeout logs the failure, leaves the camera bound, and disables parking for the rest
  of the session (fallbackBound); the camera-delivery watchdog is suppressed ONLY while
  parked/warming, so after a failed wake it deliberately fires on the genuinely dead camera.
  New `camera_sleep` JSONL records ({state, reason, next_burst_at_ms, wake_ms on success};
  DATA_GUIDE section added) make intentional camera-off gaps auditable. Owner rule honoured in
  the same round: Settings switch (Setup tab, under "Repeat burst every", with a
  current-timing hint), SessionConfig JSON + round-trip test, summary Settings row,
  `config_not_applicable` in detector/motion modes. Chip shows "NEXT BURST in mm:ss · camera
  off" while parked; blackout steady state is re-asserted after the wake rebind (same as the
  scheduled-window wake); SETTINGS_REFERENCE + FIELD_GUIDE warn that the frozen preview is
  intentional. Expected effect at the 10 s / 30 min defaults: camera-bound duty ~100% → ~1.1%.
  OPEN: paired one-hour field runs on both phones per PERFORMANCE_BENCHMARKING.md (the r162
  protocol exists precisely to measure this).
- **E5, streaming `SessionLogIndex` (the remaining half; E5 now fully done):** new
  `logging/session_log_index.dart` replaces the summary screen's three full `readAsLines()`
  parses on the UI isolate (graphs+spans, photos, ROI history) with ONE streaming pass —
  `File.openRead()` → UTF-8 decode → `LineSplitter`, built inside `Isolate.run`, no file-sized
  `List<String>` and no UI-isolate JSON decoding. The index carries track spans, the
  temperature/headroom/FPS/inference series, raw power samples, per-photo aggregates (trigger
  boxes with the r86 co-detection filename sharing, r64 capture-record size/time overrides,
  r108 live-companion fields, motion/timelapse/gt discovery, carried-forward ROI size) and the
  ROI history (r109 stream-side recompute for pre-109 logs now happens in-index). The r114/115
  high-res frame-bracket matching runs as a second bounded streaming pass only when needed
  (memory O(photos), never O(frames)). The screen caches ONE future; `_loadGraphs` /
  `_loadPhotos` / `_loadRoiHistory` consume it and keep only display concerns (label text,
  `_DetBox` mapping, file-existence checks); `_loadPostHoc`'s post_detections.jsonl read+parse
  moved off the UI isolate too. Legacy per-track `detection` (≤ r68) vs batched `detections`
  semantics preserved; crash-truncated lines tolerated; the cheap `_loadStats` head/tail path
  untouched (headline numbers still appear before the full parse). 15 tests in
  session_log_index_test.dart: mixed-record fixture covering every record shape, pre-109 ROI
  recompute, bracket interpolation/no-frame/ROI-move cases, a worker-isolate round-trip, and a
  100k-line fixture.
- Review doc: E3 and E5 ticked with done-notes; full suite 411 tests green, analyzer clean.
- Next per Part E order: E4 step 1 (log the supported AE FPS ranges — cheap, no UI) gating the
  gate-idle hardware cap experiment; E8/E9/E10 remain.

## Round 164 (2026-08-03): configurable wake lead, blackout+parking verified, always-manual focus

Owner follow-up to the round-163 camera parking, three parts.

- **Configurable camera wake lead (`timeLapseWakeLeadSeconds`, default 10 s, 1-60 s):** the r163
  10 s prewake came from the review spec (headroom for the CameraX rebind + auto-exposure
  settling). It is now a user setting per the owner rule (Setup tab field under the camera-sleep
  switch, SessionConfig JSON + round-trip test, summary row, `config_not_applicable` in
  detector/motion modes); the screen passes the configured value to the coordinator. The default
  was briefly 5 s in this round, then reverted to 10 s after the owner's same-day field test:
  the first burst photo came out DARK AND BLURRY at 5 s. Root cause is physics, not an app focus
  bug - a full camera power-off parks the lens actuator and discards auto-exposure state; on
  wake the locked manual focus VALUE is re-asserted instantly (r82 funnel), but the lens motor
  still has to physically travel back to it and AE has to ramp from scratch, which LOOKS like an
  autofocus hunt on the preview. Only full unbind/rebind paths pay this cost (time-lapse
  parking, scheduled-window wakes); blackout never unbinds the camera and the detector/motion
  modes never power it off, so no other mode is affected. Coordinator tests updated + one test
  proving an explicit lead moves the prewake moment.
- **Blackout (moon) + camera parking compose — verified, no code change:** both
  `_applyBlackoutSteadyState` and `_exitBlackout` guard their `setPreviewEnabled` call on
  `!_paused`, and the r163 park path sets `_paused = true`, so a moon tap while parked never
  touches the unbound camera (the native `setPreviewEnabled(true)` WOULD partially rebind a
  parked camera - the Dart guard is what prevents it); the r163 wake already re-asserts the
  blackout steady state after `resume()`, and the native `previewEnabled` flag is honored on
  every full rebind (r82). Energy-wise they are complementary (screen+preview vs whole camera):
  use both for unattended time-lapse. FIELD_GUIDE + SETTINGS_REFERENCE now say so.
- **Always-manual focus with close-up preset + reminder badge (owner decision):** autofocus is
  no longer selectable anywhere - on a mounted phone it drifts onto the background and silently
  changes what "sharp" means mid-session. Every camera-screen open now locks a manual preset at
  `kFocusPresetDioptres` 7.5 dpt (~13 cm; the DIOPTRE midpoint of the owner's 10-20 cm band, so
  depth of field covers the band most evenly; owner-confirmed over the 15 cm arithmetic middle),
  computed by the pure `focusPresetNormalized` (camera_diagnostics_controller.dart, clamped to
  the lens's own closest focus; 6 unit tests in focus_preset_test.dart). Applied via the new
  `onFocusRangeKnown` hook when the focus-range probe lands; on every LENS SWITCH the range is
  re-probed and the preset re-applied against the new lens (the native zoom event emitted inside
  the bind-success callback is the "rebind settled" signal - already surfaced as
  `YOLOViewController.zoomEvents`, previously unused; 3 s fallback for bind paths that never
  emit; this also fixed a startup race where the initial probe could read the default lens
  before the persisted lens applied). The focus button carries an amber Badge dot until the user
  drags the Far-Near slider themselves (the preset does not count; the badge re-arms per lens
  switch); the "Auto" reset button and `_resetAutoFocus` are gone. Mid-recording slider
  adjustments stay allowed and logged (`focus_change`, owner-confirmed). Wire values unchanged:
  `focus_mode` is now always `manual`/`fixed`; `auto` only appears in pre-r164 logs (DATA_GUIDE
  notes it). Focus stays SCREEN state by design (the preset must reset every session), not
  SessionConfig. SessionInfoDialog bullet rewritten (also fixed its stale button-position text).
- Docs: SETTINGS_REFERENCE (wake-lead row, camera-sleep row, Focus row rewrite), FIELD_GUIDE
  (new "Check the focus" setup step 4, time-lapse paragraph), DATA_GUIDE (camera_sleep intro,
  focus_mode notes), review E3 done-note amended, OVERVIEW defaults + invariants.
- flutter analyze clean; full suite green.

## Round 165 (2026-08-03): summary bottom-inset fix + scroll-to-end regression guard

Owner field bug: on the session summary's Graphs tab the bottom-most element could not be
seen/reached. Recurring bug CLASS, not a one-off - the app renders edge-to-edge (forced by
targetSdk 36 on Android 15+), and two traps keep reproducing it:

- A ListView with an EXPLICIT `padding:` silently loses Flutter's automatic MediaQuery
  bottom-inset padding. The summary's four tabs shared `_tabPadding` (fixed bottom 64) - now an
  instance getter adding `MediaQuery.paddingOf(context).bottom`.
- A `Positioned(bottom: 16)` inside the Graphs tab's full-body Stack anchored the floating
  "Hide/Show timeline" button to the SCREEN bottom - i.e. behind the navigation/gesture bar
  (the invisible "last button" the owner hit). Now `16 + MediaQuery.paddingOf(context).bottom`.

Audit of the other screens: home, analysis (fixed the same way in r137) and problem-report wrap
their bodies in SafeArea; the settings sheet SafeArea-guards its bottom bar; the camera screen's
controls row sits in SafeArea - only the summary screen was exposed.

Same round, same button (owner follow-up): the floating "Hide/Show timeline" toggle used to
render for EVERY session — including no-AI (motion/time-lapse) ones where the timeline area is
just an explanatory note (the empty state carries the same GlobalKey, so the visibility check
saw it "in view"). It now only exists when a real, tall timeline is there:
`_timelineCollapsible` = more than 10 track lanes (`_timelineCollapseMinLanes`); below that
there is no scrolling problem for the button to solve. Two widget tests encode it (no-AI
session and a 3-lane AI session both show no toggle; the inset test's fixture grew to 12 lanes
so the button still exists there).

Regression guard (the owner-requested "reminder"): new widget test
`test/fauna_pulse/summary_bottom_inset_test.dart` simulates a 48 px bottom system bar
(FakeViewPadding), opens the summary straight on the Graphs tab over a real temp session.jsonl,
and asserts BOTH the floating button and the last scrolled row stay fully above the bar via the
reusable `expectAboveBottomInset` helper (verified to FAIL against the unfixed code: "bottom
edge 770.0, safe bottom 752"). New OVERVIEW invariant records the rule: any new screen with
bottom-anchored content or an explicitly-padded scrollable gets a test reusing this pattern.
Widget-test traps documented in the file for future rounds: fixture IO must be SYNC (awaiting
real IO outside runAsync hangs the fake-async clock - even the test timeout can't fire), and
frames are pumped OUTSIDE short `tester.runAsync` waits (pump inside runAsync deadlocks).

flutter analyze clean; suite 420 tests green.
## Round 166 (2026-08-04): E4 step 1, log the HAL's AE fps-range menu

Perf review E4 ("hardware camera cap while the motion gate sleeps") step 1, the
cheap decision-data collector. Kotlin-only, no UI/config/Dart change.

- `YOLOView.kt`: new `supportedAeFpsRanges()` helper is now the single reader of
  Camera2 `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES` (`chooseAeFpsRange` consumes
  it instead of reading + discarding the list).
- New `logSupportedAeFpsRangesOnce(applied)`, called from the r82 interop funnel
  `applyInteropOptions()`: logs ONE logcat line per lens with the full advertised
  menu + requested cap + applied range, e.g. "Supported AE fps ranges (camera 0):
  [15, 15], [15, 30], [30, 30]; requested=15 applied=[15, 15]". Keyed on the
  Camera2 camera id (field `aeRangesLoggedCameraId`), so a lens switch re-logs
  (each physical camera has its own menu) but repeated funnel calls do not.
  Fires even at camera fps cap 0 (applied reads "device default").
- Why: the whole E4 experiment hangs on whether the Xiaomi/Samsung advertise ANY
  range below the known-good fixed [15,15]. If the menu holds nothing lower,
  E4 gets rejected without building the gate-idle cap machinery.
- Where the data lands: the line fires at camera-screen open (camera bind), so
  `logcat_start.txt` (2000-line snapshot at REC start) captures it; live check
  via `adb logcat -d -s YOLOView`. Owner to-do: one screen-open + lens-cycle on
  each test phone, ideally during the paired one-hour E3 parking benchmark runs
  (PERFORMANCE_BENCHMARKING.md protocol, `dart tool/perf_summary.dart`) that are
  still owed, then decide E4 per its reject criteria.
- flutter analyze clean; suite 421 tests green; debug APK builds.

## Round 167 (2026-08-04): E4 verdict, rejected on hardware evidence

Owner collected the r166 AE fps-range log lines on both phones (flutter-run logcats
plus pulled sessions: Xiaomi session_41, Samsung session_2). Doc-only round, no code.

- Measured menus: Xiaomi 2107113SG camera 0: [12, 12], [15, 15], [12, 30], [30, 30].
  Samsung SM-M127F cameras 0 and 2 (identical): [15, 15], [15, 20], [20, 20],
  [24, 24], [8, 30], [10, 30], [15, 30], [30, 30].
- Reading: [8, 30]-style entries are AE-variable ranges (may drop toward 8 in low
  light, run ~30 in daylight), NOT caps. The lowest forced rate is the smallest
  upper bound: Samsung 15 (equals the current default cap, zero headroom),
  Xiaomi 12.
- Verdict: E4 REJECTED per its own criteria. A gate-idle cap could never go below
  [12,12], and the existing Camera FPS cap setting reaches [12,12] statically
  (chooseAeFpsRange(12)) for the whole session, with zero new machinery and none
  of E4's wake-transition risks. Gate-idle switching adds nothing on either phone.
- Replacement follow-up (no new code): paired E1-protocol Xiaomi run at camera
  cap 12 vs 15. Code check done this round: the r129 deadline scheduler keeps
  inference cap 10 a true ~10 on a 12 fps camera (per-frame deadline overshoot
  <= 83 ms, under the 100 ms interval, so it never re-anchors). Expected costs:
  ~17 ms worse worst-case fast-capture latency, less AE shutter headroom in dim
  light. Default stays 15 unless the paired run says otherwise; on the Samsung a
  requested 12 harmlessly resolves to [15,15].
- Side observation from the same logs: applied [15,15] delivers a true 15.0
  deliveredFps on both phones (FRAMEPERF lines), funnel working as designed.
- Docs: E4 marked [x] REJECTED with the full verdict note in
  PERF_AND_ROBUSTNESS_REVIEW.md; OVERVIEW Part E status line updated and both
  device-quirk entries now record their AE menus (durable hardware facts).

## Round 168 (2026-08-04): E6 step 1, SAHI phase profiling + run wall time

Perf review E6 ("native tiled-image API only if profiling justifies it") step 1:
instrument where a SAHI batch run's time actually goes, so the 15%-of-wall-time
gate can be evaluated on real runs. Plus the owner request: show and log every
analysis run's total duration.

- New `postprocess/sahi_profile.dart`: `SahiPhaseProfile`, a per-run accumulator.
  Internally microseconds (many sub-ms events, e.g. merge, must not round away),
  JSON in whole ms. Counts: `photos`, `tiled_photos`, `tiles`, `full_passes`.
  Times: `source_decode_ms` + `tile_prep_ms` (measured INSIDE the tileWorker
  isolate and returned in its record, the isolate boundary hides them otherwise),
  `tile_transfer_ms` (compute() wall minus in-isolate work = isolate spawn + byte
  copies), `tile_predict_ms` / `full_predict_ms` (stopwatch around each predict
  channel call; one lump on purpose, the native predictSingleImage response has
  NO timing fields so channel/native-decode/inference cannot be split from Dart),
  `merge_ms`, and the `tile_overhead_ms` convenience sum (the E6 gate's
  Dart-visible numerator).
- `sahi.dart`: `tileWorker` returns two extra ints (decode/prep µs);
  `sahiPredictFn` gains optional `profile:`; behavior identical when null.
- `post_detector.dart`: `run(phaseProfile:)`; `post_end` gains `elapsed_ms`
  (EVERY run, plain and SAHI) and `phases` (SAHI runs).
- `analysis_screen.dart`: builds the profile when SAHI is on, passes it to both;
  completion snackbar now reports the total wall time ("Done: N photos analyzed
  in 18 min 05 s", also on the Stopped branch), `_fmtElapsed` helper. No new
  user setting: instrumentation is free and always on (r149 precedent).
- Tests: +4 (phase counts and lower-bound times via a 5 ms fake predictor,
  no-tile fallback accounting, null-profile parity, post_end embedding +
  elapsed_ms presence and plain runs carrying no phases block).
- Docs: DATA_GUIDE §6 post_end fields; review E6 step-1 done note.
- Gate evaluation owed (owner): cooled paired SAHI runs, then compare
  tile_overhead_ms (+ the native decode share hidden in tile_predict_ms)
  against elapsed_ms; under 15% closes E6 as a skipped lead.
- flutter analyze clean; suite 425 tests green.

## Round 169 (2026-08-04): E10 documentation truth pass

Perf review E10, docs only (no code, no behavior change). Every stale claim was
verified against the code/tests before editing.

- NEW `packages/ultralytics_yolo/FAUNAPULSE_FORK.md`: fork provenance (base
  `22b2e5d`, upstream label 0.6.4; iOS untouched and unmaintained), upstream
  audit table (0.6.10 Parts C/D, 0.6.11 glance r160, OrtQnn adopted early from
  upstream PR #526), headline change list with rounds (ROI-crop inference, fast
  crop, MotionGate, interop funnel + AE logging, preview detach, deadline
  scheduler, GPU blocklist, NCHW, includeAnnotatedImage, r161 lifecycle, r151
  load-failure signal, FRAMEPERF/sensor timestamps), fork-only invariants, and
  a 5-step re-audit checklist. Plugin README gains a fork banner at the top;
  the rest stays upstream-verbatim deliberately (diffability).
- `lib/fauna_pulse/README.md` REPLACED: was the Phase-1 snapshot ("plugin
  untouched", pre-r69 per-track `detection` schema, 12-file code map). Now:
  what the app does, a one-line-per-directory map of all ten module folders,
  current session-folder layout (gt_frames, post_detections.jsonl, logcats,
  filename format), DATA_GUIDE pointer instead of a duplicate dictionary.
- `test/README.md` REPLACED: was upstream boilerplate ("cd example"). Now: the
  unit suite, the tracker replay harness (REPLAY_SESSION define), the three
  integration tests incl. the exact-spelling `=true` dart-defines (r160), and
  the PERFORMANCE_BENCHMARKING pointer.
- CONTRIBUTING: "app deploys as debug" corrected (Samsung = release-test phone
  since r158, benchmarking points at the E1 protocol); the "known coverage
  gaps" paragraph removed (scheduler cadence, logger write-failure and the
  screen orchestration all have tests: roi_capture_scheduler_test,
  session_logger_test onWriteError cases, frame_processor_test since r73);
  model bullet now points at MODEL_CONVERSION.md (python_scripts/ no longer
  exists) and states accepted formats; device quirks refreshed; doc index
  fixed (dup AGENT_CHANGELOG row -> AGENT_CHANGELOG_OVERVIEW; rows added:
  MODEL_CONVERSION, PERFORMANCE_BENCHMARKING, FAUNAPULSE_FORK, RELEASE_PLAN).
- ARCHITECTURE: §5 now defers to FAUNAPULSE_FORK.md and names the missing
  headline changes; §6 "god class slated for extraction" replaced with the
  real r73 `session/` split + the "new logic goes in session/" rule;
  `rawRectForUprightRect` name fixed.
- FIELD_GUIDE: calibrating banner text no longer claims an automatic engine
  benchmark (it is user-triggered only, r76); notes probe caching (r121).
- DATA_GUIDE: `fps` record now documents the r77 gate-idle omission semantics
  (fields absent + `gate_idle: true`, never zero readings; graphs break).
- RELEASE_PLAN: both "detects insects out of the box" verification lines
  aligned with the honest r158 wording (AI pipeline runs, COCO model knows no
  insects); APK size figures updated to the r160 116.5 MB (IzzyOnDroid line +
  a remeasured note on the 2026-07-28 122.1 MB record).
- flutter analyze clean; suite green (no code touched).

## Round 170 (2026-08-04): E7 three small cleanups

Perf review E7, all three bullets. No behavior change visible to the user apart
from smoother fast analysis batches; no new tunables (internal constants only).

- Thermal/power sample coalescing (`logging/device_thermal.dart`):
  `DeviceThermal.read()` now serves a cached reading for 900 ms (stamped with a
  monotonic Stopwatch clock, immune to wall-clock jumps) AND shares one
  in-flight channel call among concurrent callers. The in-flight sharing is the
  part that actually coalesces the default case: the thermal and power timers
  are armed together with the same interval, so their ticks land in the same
  event-loop turn and the second read() arrives BEFORE the first channel call
  returns (a plain TTL cache would fetch twice). One native sample per tick;
  the user-minimum 1 s cadence stays under Android's ~1/s getThermalHeadroom
  NaN limit. Errors cache as an empty reading (no re-hammering a failing
  channel inside the window). Session start/end reads can be up to 0.9 s
  stale, harmless for battery-%/temp records. New
  test/fauna_pulse/device_thermal_test.dart: 4 tests (shared in-flight call,
  cache hit, expiry via injectable clock, error caching + recovery).
- C++ NMS early break (`packages/.../cpp/native-lib.cpp`): `nms_sorted_bboxes`
  gains a `max_picked` parameter and breaks once that many survivors are
  collected; caller passes `num_items_threshold` (default 30); the post-loop
  min() stays as a guard. Proposals are pre-sorted and survivors append in
  order, so the first N survivors are exactly what the old truncate kept.
  PARITY EVIDENCE (the review's requirement; repo has no C++ test infra): a
  standalone host harness (scratchpad, g++ -O2) replicating the file's exact
  code compared old vs new over 48,000 randomized cases (0-299 proposals,
  score ties, degenerate zero-width boxes, IoU 0/0.3/0.7/1.0, thresholds
  0/1/5/30/300/10000): outputs exactly identical (indices and order). Only
  helps noisy frames with > 30 survivors, as the review predicted.
- Batch-progress throttle (`postprocess/post_detector.dart`): progress
  callbacks now fire at most once per 200 ms (static `progressMinInterval`,
  @visibleForTesting so tests can pin it); the FIRST and the FINAL/cancel
  updates always fire (the UI's last state must show true totals);
  cancellation stays per-photo and unthrottled. The analysis screen needed no
  change. 3 deterministic tests (interval huge -> first+final only, interval
  zero -> old per-photo cadence, cancelled run ends on true totals).
- flutter analyze clean; suite 432 tests green; debug APK builds (NDK
  recompiled native-lib.cpp).

## Round 171 (2026-08-04): E8, lean QNN packaging documented (not built)

Perf review E8, document-only by its own scope. Nothing in the build or the app
changed; the accepted single QNN-inclusive release stands.

- New docs/LEAN_QNN_PACKAGING.md: plain-language explainer of what QNN is and
  its r160 measured cost (21 arm64 libs, 75.7 MB in-APK / 224.3 MB uncompressed,
  ~62% of the 116.5 MB APK; useLegacyPackaging doubles the on-device footprint
  because Hexagon loads Skel libs via real file paths); where the single opt-in
  point lives (the app's two implementation lines, onnxruntime-android-qnn
  1.26.0 + qnn-runtime 2.46.0 override; the plugin declares compileOnly).
- The lean design on record: default build without the QNN deps and with
  useLegacyPackaging=false (estimated ~41 MB arm64 APK, to be re-measured if
  built); a -Pqnn Gradle property gating both the deps and the packaging flag;
  stable -qnn- artifact names for Obtainium; native isQnnRuntimeAvailable via
  safe Class.forName("ai.onnxruntime.OrtEnvironment") (NOT via OrtQnnModel,
  whose constructor references OrtEnvironment and would throw the very
  NoClassDefFoundError the query prevents); selection-time "needs the QNN
  edition" dialog with the r151 modelLoadRecovery net as backstop; Play = lean
  App Bundle only, GitHub = both artifacts.
- Why not built: the permanent two-artifact release matrix vs a capability no
  current test device can exercise (SD888 = Hexagon v68, assets need v73+).
  Three explicit reopen triggers recorded (size limits bite; a v73+ device AND
  a QNN insect model arrive; Play flags the payload).
- Cross-refs: RELEASE_PLAN Play-phase bullet (where the accepted decision
  lives) now points at the doc; CONTRIBUTING doc index gains the row; review
  E8 marked done.
- Docs-only round; analyze/tests untouched (last verified green in r170).

## Round 172 (2026-08-04): photo-count consistency fix (owner-reported, session_18)

Owner bug report: session_18's summary Photos tab says "63 of 63 saved photos"
while the analysis screen's session dropdown said "126 photos". Root cause: the
session is from the r108 high-res era, every photo has a `_live.jpg`
trigger-moment companion (63 pairs = 126 files). The SUMMARY counts photo
ENTRIES (a pair is one entry, the r111/112 viewer design with the lightning-bolt toggle); the
ANALYSIS screen counted raw jpg FILES and labeled them "photos" (its
_AnalyzableSession doc comment even claimed companions were excluded, stale
since r137 made both pair members analyzable). Fix follows the ui-numbers-one-
scale rule: one meaning per label, derived counts labeled separately.

- New single-source helpers next to `pairBase` in postprocess/photo_keep.dart:
  `photoUnitCount` (capture moments: a pair counts once, an orphan `_live`
  counts as its own photo) and `analyzedPhotoUnitCount` (a photo counts as
  analyzed only when EVERY pair member has a record; half-analyzed pairs stay
  pending). 3 unit tests.
- `_AnalyzableSession` now carries BOTH units (photoCount/donePhotoCount in
  photos, fileCount/doneFileCount in files) with a doc comment naming the rule.
- Labels: dropdown shows "63 photos (+63 live copies, N analyzed)" (photo
  units, matching the summary; the surplus disclosed); start button "Analyze
  63 photos (126 files)" (file suffix only when they differ); progress panel,
  completion snackbar, cleanup section, delete-confirm dialog and
  deleted-toast all say "files" (that is the unit the driver/cleanup actually
  walks and deletes). Internal `_total` seeding switched to file units (it
  must match the driver's onProgress).
- No wire/log change; sessions without companions read exactly as before
  (photos == files, suffix suppressed).
- flutter analyze clean; suite 435 tests green; debug APK builds.

## Round 173 (2026-08-04): continuous time-lapse starvation fix (owner field bug)

Owner report: time-lapse with Photo step 1 s, Photo duration 100 s, "Repeat
burst every" 5 s took exactly the first 100 photos and then NOTHING for the
rest of the 1 h session. Expected (and documented r97) behavior for interval <=
duration is CONTINUOUS capture (bursts touch/overlap, photos never stop).

Root cause (three pieces, each individually correct):
- `TimeLapsePlan.continuous` mode defined `cycleIndexAt` as ALWAYS 0.
- `_timeLapseTick` re-arms the shared capture window (`beginTimeLapseBurst` ->
  `resetMotionWindow`) only when the cycle index CHANGES -> re-armed exactly
  once, at recording start.
- The scheduler window hard-stops `> durationMs` after its start
  (roi_capture.dart `evaluateMotion` "window exhausted"), and its
  forget-backstop (`lastSeenMs` gap > durationMs) can never fire while ticks
  keep arriving every step. Net: photos for exactly one photo-duration, then
  starvation. Non-continuous mode was always fine (cycle advances per
  interval).

Fix in `capture/time_lapse_plan.dart` only: new private `_cycleMs` =
`continuous ? burstMs : intervalMs`; `cycleIndexAt` and `nextBurstStartAt` use
it. Continuous cycles now advance every photo duration, so the existing tick
contract re-arms the window the moment the old one is exhausted: seamless one
photo per step across the seam (the reset fires BEFORE the same tick's
evaluateMotion, so no duplicate and no gap). Non-continuous behavior is
byte-identical (`_cycleMs` = intervalMs).

Consequences audited:
- `timelapse_capture.burst` now increments per photo-duration block in
  continuous mode (was always 0). DATA_GUIDE gains a `timelapse_capture`
  record note (the record was previously undocumented) incl. the r97-r172
  data caveat: continuous sessions from old builds contain only the first
  burst's photos.
- "NEXT BURST in mm:ss" chip and camera parking are unreachable in continuous
  mode (always in burst; idle gap < 30 s), unchanged.

Tests (time_lapse_plan_test.dart): the old test asserting "always cycle 0" in
continuous mode ENCODED the bug and was replaced; new cycle-advance test plus
an end-to-end regression reproducing the owner's exact config against the REAL
scheduler window via the screen's tick contract (305 s simulated, expect 306
photos). Verified to fail on the unfixed code with exactly the field numbers
(101 photos, then starvation), pass with the fix.

flutter analyze clean; suite 437 tests green; debug APK builds.

## Round 174 (2026-08-04): "Time between bursts" (gap semantics, owner decision)

Owner follow-up to r173: "Repeat burst every" should be the BREAK between
bursts, not start-to-start spacing (session_2: duration 10 s + "repeat every"
10 s was expected to pause 10 s between bursts; under start-to-start semantics
it legally meant continuous). The break framing also matches camera parking,
which happens exactly in that break.

- SessionConfig: new key `timeLapseGapSeconds` (default 1800 = 30 min break;
  0 = continuous) replaces `timeLapseIntervalSeconds`. Migration in fromJson
  (`_timeLapseGapFromJson`): new key wins; else gap = legacy interval −
  duration clamped ≥ 0 (old interval ≤ duration meant continuous → gap 0), so
  a migrated config's effective timing is unchanged. notApplicableConfigKeys
  updated (detector/motion modes list the new key).
- TimeLapsePlan rewritten gap-based: `gapMs` (≥ 0), `cycleMs` = burst + gap
  (public; the camera_sleep wake record's burst-anchor math uses it),
  `continuous` ⇔ gap 0. This ABSORBS the r173 special case: cycles always
  advance every cycleMs, so the tick's re-arm-on-cycle-change contract keeps
  the capture window alive in every configuration. Coordinator:
  `parkingPossible` is now simply `plan.gapMs >= minIdleGapMs`.
- Settings sheet: label "Time between bursts", min 0, helper explains the
  break + camera-off connection + 0 = continuous; mode help text updated;
  the camera-off "leaves less than 30 s" hint now reads the gap directly.
- Summary Settings tab: "Time between bursts" row (new key) + a
  clearly-labelled "Burst repeat interval (start-to-start, pre-r174)" row for
  old sessions (add() skips whichever key is absent) — old data is never
  relabelled with the new meaning.
- Tests: config round-trip incl. 0, three-case migration test (1800/10 →
  1790; 10/10 → 0; new key wins), plan tests converted to gap values
  (numerically identical phases), a new 10 s-on/10 s-off test encoding the
  owner's session_2 expectation, coordinator plans converted
  semantics-preserving. Suite 439 tests green; analyze clean; APK builds.
- Docs: SETTINGS_REFERENCE gains the (previously missing) setting row incl.
  the migration note; DATA_GUIDE timelapse_capture note updated with the
  config-key change and cross-version conversion; OVERVIEW defaults row
  rewritten.

## Round 175 (2026-08-04): post-hoc box overlay fix (silently broken since r163)

Owner report: "Review photos before deleting" after a SAHI run showed NO green
prediction boxes, while post_detections.jsonl carried boxes for 179/180 photos.

Root cause (reproduced in a widget test before fixing): `_loadPostHoc`'s
r163 `Isolate.run(() => photoOutcomesFromJsonl(...))` was inlined in the async
State method, so the closure's context chain included the Zone the async
machinery keeps — and the app runs inside runZonedGuarded (r67
app_error_hooks), a CUSTOM Zone, which is unsendable. Every call threw
"Illegal argument in isolate message: object is unsendable - _CustomZone",
the catch logSwallowed it (logcat only), and the post-hoc maps stayed empty:
no green boxes, no red deletion marks, no kept-chips, for EVERY session type
since round 163. The SessionLogIndex never had the problem because its
`build` wraps Isolate.run in a SYNC static helper whose closure captures only
the path string.

Fix: `_outcomesOffUi(String path)`, a top-level-style static sync wrapper in
session_summary_screen.dart (same shape as SessionLogIndex.build);
_loadPostHoc awaits it. Audit of all other worker calls: sahi.dart,
roi_capture.dart, crop_export.dart use compute(topLevelFn, message) (nothing
captured) and session_log_index.dart already uses the safe shape — only this
one site was broken.

Regression test: new summary_posthoc_boxes_test.dart — synthetic time-lapse
session + post_detections.jsonl with one box, pumps the real summary on the
Photos tab (bottom-inset test's async recipe), taps "All", then digs the
_BoxPainter out of the tree and asserts a postHoc box reached it. Verified
failing before the fix with the exact production error, passing after.

flutter analyze clean; suite 440 tests green; debug APK builds.

## Round 176 (2026-08-04): E6 step 2 verdict — gate PASSED overwhelmingly

Owner ran the r168-instrumented analysis on the Xiaomi, RELEASE build, on a
180-photo 1024 px time-lapse session with the 320 px arthropod model (16 tiles
per photo + optional full pass). post_end phases:

- SAHI + full pass: elapsed 199.0 s; source_decode 18.9 s, tile_prep 145.7 s,
  tile_transfer 0.3 s, tile_predict 29.6 s, full_predict 3.6 s, merge ~0.
  tile_overhead_ms = 164.9 s = 82.8% of wall.
- SAHI, no full pass (same photos, force): elapsed 201.6 s; overhead 173.3 s
  = 85.9%. The full pass costs only ~3.6 s (~2%) — keep it on, its recall win
  is nearly free; run-to-run variance/thermal outweighs it.

Verdict: the 15% gate is passed by more than 5x. The r160 bounding guess
("Xiaomi heat dominates, gate may fail") is REFUTED on the release build:
pure-Dart tile prep (`image` package crop + encodeJpg, 2880 tiles) alone is
73% of wall time; inference is ~17%. A native `predictTiledImage` (decode the
source once natively, crop + infer tile by tile, no JPEG round trips —
design already specified in review E6) is justified and projected to cut SAHI
wall time roughly 3-5x (~1.1 s/photo -> ~0.3 s/photo). E6 step 3 (the native
API) is now the next implementation item; review doc updated.

## Round 177 (2026-08-04): E6 step 3, native tiled inference (predictTiledImage)

The r176 measurement justified it (Dart tile pipeline = 83-86% of SAHI wall
time); this round builds the native API per the review E6 design.

- Native (YOLOPlugin.kt) `predictTiledImage`: decode the source JPEG ONCE,
  crop each Dart-supplied [left, top, width, height] rectangle (clamped to
  the decoded bitmap so a stale probe can never crash createBitmap), run the
  detector SEQUENTIALLY per tile via YOLOInstanceManager with
  generateAnnotatedImage=false, optionally run the whole photo in the same
  call, recycle every temporary bitmap (createBitmap may return the source
  itself for a full-bitmap rect — identity-checked), reply with per-tile box
  lists in the exact predictSingleImage box shape (normalized to the tile)
  plus the echoed decoded dims. Work on a background thread with a
  main-looper reply (benchmarkAccelerators' pattern): one photo's tiles
  would otherwise block the platform thread for hundreds of ms. The Dart
  driver awaits each call, so two tiled predictions are never in flight
  (the predictor is mutable — never parallelize it).
- Plugin Dart: YOLO.predictTiled / YOLOInference.predictTiled (detect task
  only; shares _processDetectResults so the detection shape is identical).
- App (sahi.dart): sahiPredictFn gains tiledPredict. Tile PLANNING stays in
  Dart: new `jpegDimensions` reads width/height from the JPEG HEADER only
  (img.JpegDecoder().startDecode, no pixel decode — microseconds vs the
  ~100 ms full decode that was 18.9 s of the r176 run), then the existing
  planTiles. Mapping, the r141/r143 speck filter and the IoS merge now run
  through helpers SHARED by both paths (_tileBoxToPhoto, _underMinBox,
  _detectionsResult) so native and Dart results cannot drift.
- Reliability: the reply's echoed dims must equal the planned dims and the
  tile-list count must equal the request, else throw; any native failure
  logs (logSwallowed 'sahi_native_tiled'), counts `nativeFallbacks`, and
  disables the native path for the REST of the run (r163 fallback
  philosophy) — the pure-Dart pipeline is the always-correct baseline.
  Profile accounting happens only after native success, so a failed attempt
  never half-counts a photo. One-tile photos and unreadable headers take
  the plain path as before.
- Profile/records: SahiPhaseProfile gains nativeTiledPhotos/nativeFallbacks
  (post_end.phases keys native_tiled_photos/native_fallbacks; DATA_GUIDE §6
  updated: on the native path tile_predict_ms is one lump, source_decode_ms
  is only the header probe, tile_prep/transfer are 0). FAUNAPULSE_FORK.md
  gains the new-API bullet. Correction for the record: r168's claim that
  the native predict response carries no timing fields was wrong (speed/
  preMs/inferenceMs/postMs exist on the wire); the lump measurement stands.
- analysis_screen wires tiledPredict: (bytes, tiles, fullPass) =>
  yolo.predictTiled(...) with the run's thresholds.
- Tests: +7 (header probe; grid planning + tile-box mapping parity with
  base never called; full-pass ride-along + profile accounting incl.
  tilePrepUs 0; speck filter on the native path never trimming full-pass
  boxes; dims-mismatch fallback that never half-counts and stays on Dart
  for the run; one-tile no-op skipping the native call). Suite 446 green;
  analyze clean; debug APK builds (new Kotlin compiled).
- Owner validation owed: re-run the same 180-photo session (force,
  release build) and compare elapsed_ms + keep counts vs the r176 baseline
  (199.0 s, 83% overhead; projected ~3-5x faster).

## Round 178 (2026-08-04): E6 validated (6.5x) + photo-caption/info-row fixes

E6 VALIDATION (owner, release build, same 180-photo session re-run with the
r177 native tiled path): elapsed_ms 30761 vs the r176 baseline 199010 =
6.5x faster. post_end.phases: native_tiled_photos 180, native_fallbacks 0,
tile_prep_ms 0, tile_transfer_ms 0, source_decode_ms 795 (header probes
only), tile_predict_ms 28685 — essentially pure inference; tile_overhead_ms
collapsed 82.8% -> 0.26% (796 ms). E6 closed end to end (instrumented r168,
gate measured r176, built r177, validated r178). Review doc + OVERVIEW note
the numbers.

Owner-reported viewer bugs, same review session (both fixed + widget-tested
in summary_posthoc_boxes_test.dart):

- Pager caption said "0 detections" under five green analysis boxes: it
  counted only the live trigger-frame boxes. New `_detectionCountLabel`
  counts what the overlay actually DRAWS for the current view: live-only ->
  "N detections" (unchanged AI behavior), post-hoc-only -> "N analysis
  detections", both -> "N live + M analysis detections". Keyed on the SHOWN
  file, so the count follows the high-res/live toggle like the boxes do.
- "Track IDs: none" / "Confidence: n/a" rows on no-AI photos: the two rows
  now render only when the photo has live track data (p.trackIds non-empty)
  — hidden for motion/time-lapse/reference photos, kept for AI sessions
  (one entry per visible track id, as before; regression test with a
  detector-session fixture asserts they stay).

flutter analyze clean; suite 447 tests green; debug APK builds.

## Round 179 (2026-08-04): tiny-box threshold as a live review-time sensitivity filter

Owner idea: after a SAHI run, changing "Ignore tiny tile boxes" should update
the cleanup statistics instantly from the RECORDED boxes instead of requiring
a re-analysis — a sensitivity analysis over one run (analyze once at the 0%
default so every box stays recorded, then tune the threshold and watch how
many photos would be kept/deleted).

- photo_keep.dart: `applyMinBoxFrac(outcomes, minFrac)` — drops recorded
  boxes whose NARROWER side is under the fraction, recomputes hasBoxes,
  leaves failed (null) photos and the on-disk records untouched; 0 = no-op
  (same list instance). Semantics note (documented in code + docs): the
  analysis-time filter is pre-merge and tile-only (r141/143); recorded boxes
  are post-merge with no origin, so the review-time filter is size-only and
  can also drop a tiny full-pass box (a box that small is a dot either way).
  `lastSahiMinBoxFrac(jsonl)` — the last post_start's sahi.min_box_frac
  (plain runs reset it to null): the live filter can't go BELOW what the
  analysis itself removed, those boxes were never recorded.
- analysis screen: `_cleanupSection` applies the current % live (the field's
  setState already rebuilds it); the stats sentence names the active filter;
  an amber hint appears when the slider sits below the run's own recorded
  filter ("re-analyze at 0% to go lower"); field helper text rewritten
  (tip: analyze at 0%). `_loadOutcomes` also parses the last run's filter.
- summary screen: `_loadPostHoc` applies the same pref, so the review's
  green boxes, kept-chips, deletion marks and counts always match the
  analysis screen's numbers (the two screens share the decision).
- Audit: `runCleanup` gains `minBoxFrac` (written as `min_box_frac` in the
  `post_cleanup` record when > 0; both call sites pass it) — an executed
  deletion stays explainable after the pref changes. DATA_GUIDE +
  SETTINGS_REFERENCE updated.
- Tests: photo_keep_test +4 (0 = untouched instance; dots and slivers
  dropped by the narrower side with hasBoxes recomputed and an exact-
  boundary survivor; failed photos pass through; lastSahiMinBoxFrac last-run
  semantics incl. plain-run reset). Float-dust lesson kept in the test
  comments: 0.4+0.05-0.4 is NOT the double 0.05, boundary fixtures must be
  anchored at 0.
- flutter analyze clean; suite 451 tests green; debug APK builds.


## Round 180 (2026-08-04): nocturnal time-lapse, torch lights each burst

- Owner request: unattended overnight time-lapse (e.g. 10 s burst / 10 min
  gap for 8 h) needs light — the LED torch now comes on a lead before each
  burst so auto-exposure settles under the final lighting, stays on through
  the burst, and goes off in the break.
- KEY FINDING: no native work was needed. The vendored plugin already ships
  a complete, unused torch path (Dart `YOLOViewController.setTorchMode` →
  channel `setTorchMode` → `YOLOView.setTorchMode` with `hasFlashUnit()` +
  `cameraControl.enableTorch()`; platform reply cached in `isTorchEnabled`,
  `resetTorchState()` for platform-side drops). CameraX's TorchControl owns
  FLASH_MODE, disjoint from the r82 interop funnel keys (AF mode, focus
  distance, AE fps range), so no conflict with manual focus / fps cap. The
  one gap: `pauseCamera()` unbinds all (`camera = null`), physically killing
  the LED, and nothing native re-asserts it — handled app-side.
- New settings (owner rule: control + config + summary row + tests, same
  round): `timeLapseTorch` (default off) + `timeLapseTorchLeadSeconds`
  (default 5 s, range 1–60). Lead rationale: AE runs in the camera HAL's
  repeating request (the app-level 1 fps between-burst sampling does not
  slow it) and re-converges within ~1–2 s of a large illumination step at
  15 fps; 5 s leaves margin. Both keys in `notApplicableConfigKeys` for
  detector + motion modes.
- Pure schedule `TimeLapseTorchPlan` (time_lapse_plan.dart, beside the burst
  plan): `shouldBeOnAt(t)` = in burst OR within lead of the next burst start;
  `alwaysOn` when continuous or lead ≥ gap; `nextEventDelayMs(t)` hands the
  tick timer the flip edges (OFF edge is burstMs+1 — `inBurstAt` is
  inclusive — otherwise a long photo step would leave the torch burning up
  to a step into the break; in-lead-window returns null, the plan's own
  next-burst delay already lands there). Unit-tested.
- Screen wiring (camera_session_screen.dart): `_tlTorchPlan`/`_tlTorchOn`
  (last CONFIRMED state)/`_tlTorchBusy`/one-time warn+log flags.
  `_timeLapseTick` applies the schedule on mismatch, BEFORE the park/wake
  dispatch, and only while `framesUsable` (parked/warming calls could only
  fail, and a transient rebind failure would be indistinguishable from
  "no flash unit"); the wake path's existing fresh-frame re-tick re-lights
  the torch with most of the wake lead still ahead. Mismatch-retry is the
  single re-assert mechanism (a failed call leaves `_tlTorchOn` on the
  confirmed state). Park resets the Dart caches (`resetTorchState`), stop
  forces the LED off. With parking + torch both on, the coordinator's
  prewake lead = max(wake lead, torch lead) so a raised torch lead still
  finds a bound camera. Chip appends "· torch" while lit (lead + burst).
- Logging: new sparse `torch` records (SessionLogger.logTorch) with
  `on`/`success`/`reason` (burst_lead / burst_end / camera_parked /
  session_stop), written on outcome transitions only — a torch-less phone
  logs ONE failure line per recording (plus a one-time snackbar), never a
  flood. DATA_GUIDE section added (incl. the methods note: light attracts /
  repels some taxa; first burst of every recording/window has no lead).
- Docs: SETTINGS_REFERENCE rows for both settings; summary Settings tab
  shows "Torch during bursts" + conditional "Torch lead" row.
- flutter analyze clean; suite 461 tests green.
## Round 181 (2026-08-05): every setting's explanation behind an ⓘ icon

Owner request: too much always-visible text per control; extend the round-159
NumericSettingField pattern (explanation collapsed behind a small ⓘ) to every
user input, and double-check the plain English of each helper.

- New `lib/fauna_pulse/widgets/setting_help.dart`:
  - `HelpLabel` — a label (over a dropdown, a section header, a screen intro)
    whose explanation toggles on a label-row tap; optional `leading` icon and
    `labelStyle` (used for the "Visit tracking" header with its polyline icon).
  - `HelpRow` — wraps a control that has no label (benchmark button, reset
    tracking button) with a trailing ⓘ and the explanation below.
  - `HelpSwitchTile` — SwitchListTile replacement (plus `checkbox: true`
    variant used by the analysis screen's re-analyze checkbox). ONLY the ⓘ
    opens the help; tapping the rest of the row still flips the switch (the
    Android habit). `statusText`/`statusColor` carry live, value-dependent
    notes that must never hide behind the ⓘ: warnings in amber ("Time between
    bursts" under 30 s so the camera stays on; torch lead >= gap so the torch
    never turns off) and mode notes in grey ("Not used in time-lapse mode",
    "AI detector mode only…").
  - `FoldSection` — public replacement of the sheet-private `_foldSection`
    (same zero-padding/no-divider recipe) with an optional header ⓘ; fold
    subtitles are now trimmed to one short "what's inside" line and the
    why/when explanation sits behind the header ⓘ.
- Settings sheet: all remaining always-visible paragraphs moved behind ⓘ —
  every SwitchListTile subtitle, the capture-trigger per-mode paragraph (the
  helper follows the dropdown selection), the ROI-photo-source paragraph, the
  stream-ceiling note (merged into the stream label's ⓘ, `_streamHelpText()`
  replaces `_streamCeilingNote()`), the benchmark and reset-tracking
  explanations, the tracker intro, the Power-tab intro, and the "ceiling, not
  a guarantee" paragraph (merged into the Max-inference-rate helper). The
  algorithm dropdown finally got a label ("Tracking algorithm"). "Use GPU
  when faster" and "Show FPS" gained explanations they never had. The model
  input-resolution readout stays visible but lost its parenthetical (now in
  the Detection-model ⓘ). Session length: hint behind ⓘ; the live "= N min
  total" conversion is shown only in Hours mode (in Minutes it just repeated
  the typed number).
- Analysis screen: screen intro, both threshold-slider helps, the SAHI fold
  (subtitle trimmed, mechanism explained behind the header ⓘ), the
  whole-photo-pass switch and the re-analyze checkbox all use the same
  widgets now.
- Wording pass while moving (owner asked to double-check plain English):
  several em-dash chains split into plain sentences; "Wind/shadows produce
  junk photos instead of wasted computation" clarified to "A false alarm
  (wind, moving shadows) costs only a junk photo, not computation"; the
  sync-companion text restructured so the "insect is in it" point lands last.
- Flutter gotcha (regression-tested): toggling a ListTile `subtitle` between
  null and non-null while the title row contains the padded ⓘ trips a
  RenderShiftedBox `!debugNeedsLayout` baseline assertion. HelpSwitchTile
  therefore renders status/help BELOW the tile in a Column, never as
  `subtitle`.
- Tests: new `test/fauna_pulse/setting_help_test.dart` (6 widget tests: help
  hidden until tap, ⓘ vs row-tap separation on switches, status always
  visible + ⓘ works on disabled tiles, checkbox variant, HelpRow, FoldSection
  header ⓘ without expansion). Full suite green (468 passed).
- Docs: SETTINGS_REFERENCE.md intro now says every setting (not just numeric)
  keeps its explanation behind the ⓘ and that live warnings stay visible;
  AGENT_CHANGELOG_OVERVIEW.md r159 invariant updated with the r181 rules.

## Round 182 (2026-08-05): session rename, per-session gear menu, summary tab reorder

Owner requests: (1) an option to rename a session, with the new name updated
everywhere it appears, especially in the session's text outputs; (2) a home
for it — the per-row gear popup idea won over an Overview-tab button (the
histogram row icon was decorative anyway); (3) the summary's "Settings" tab
renamed to avoid confusion with the live settings sheet and moved last
(Overview, Photos, Graphs, Setup).

- **Where the name lives (checked exhaustively):** the folder under
  `sessions/`, `config.folderName` in the start record, and nowhere else —
  capture records log `jpeg` file NAMES, post_detections.jsonl stores bare
  photo names resolved against the session dir (rename never breaks
  resumability or review), the gallery album name derives from the folder at
  export time, and photos carry no EXIF. `session_id`/`file_token` are
  name-independent.
- New `logging/session_rename.dart`: `sanitizeSessionName` (mirrors
  `_resolveSessionDir`'s `[^A-Za-z0-9_\- ]` → `_` rule so a renamed folder is
  never something a fresh recording would refuse) + `renameSession`:
  validates (non-empty, no existing target), renames the folder, then
  rewrites session.jsonl line-streamed to a `.rename_tmp` file — only the
  first `start_of_session` line is re-encoded (config.folderName updated;
  a truncated start line stays byte-identical) — appends a `session_renamed`
  audit record ({old_name, new_name} + the standard type/time_ms/time_iso
  envelope) and atomically replaces the log. Crash mid-rewrite leaves the
  original log intact; a failure after the folder rename says so and a
  re-rename retries the log update. This is the ONE sanctioned post-recording
  edit of the otherwise append-only log; the audit record keeps the edit
  honest (documented in DATA_GUIDE §3, incl. the "end_of_session is last
  line" caveat).
- **Home screen gear menu** (leading icon of each Previous-sessions row,
  replacing the decorative amber histogram): Rename session (dialog with
  inline validation errors, sanitisation hint, busy guard), Export photos to
  Gallery (same confirm text as the summary; progress in a modal dialog;
  shared scan via new `scanSessionPhotos` in crop_export.dart — the summary's
  `_confirmExportPhotosToGallery` now uses it too), Analyze photos (the
  long-press action, now discoverable; long-press kept), Delete session
  (same confirmation language as the summary's round-90 red button). Row tap
  still opens the summary. Summary Overview buttons unchanged.
- **Summary tabs:** Overview | Photos | Graphs | Setup (was Overview |
  Settings | Photos | Graphs). "Setup" = the read-only record of what the
  session ran with; last because it is consulted least. `_settingsTab` →
  `_setupTab`; `initialTabIndex` docs + callers updated (analysis screen
  Photos jump 2→1; tests: posthoc-boxes 2→1, bottom-inset Graphs 3→2).
- Tests: new `session_rename_test.dart` (7 cases: full rename incl. photo
  move + record-level assertions, unicode/unsafe-char sanitisation, empty
  name, name collision, no-op same name, missing log, truncated start
  record). Full suite green (475 passed).
- Docs: DATA_GUIDE `session_renamed` section + Setup-tab mention; overview
  doc new r182 bullet + tab-order update; FIELD_GUIDE gear-menu mention.

## Round 183 (2026-08-05): home-screen visual polish + About dialog

Owner's aesthetic pass over the landing screen (5 requests; #2, renaming
"Analyze saved photos", is PENDING — naming suggestions were offered, the
owner picks, then the term changes on the home button, the gear-menu entry,
the analysis screen title and in the docs).

- Top block: the `Icons.local_see` camera icon is gone (it read as a
  "take a photo" button); only the amber `emoji_nature` icon remains above
  the app name. The tagline under the name is gone too.
- NEW "About FaunaPulse" in the home ⋮ menu (top entry): `showAboutDialog`
  with a condensed version of the README's Overview paragraph, the live app
  version + build number (package_info_plus), a tappable GitHub repo link
  (new `ErrorReporter.githubRepoUrl`) and the framework's "View licenses"
  page (worth exposing for an AGPL app).
- New dependency `url_launcher` for that link (LaunchMode.externalApplication)
  + an `https` VIEW intent added to the manifest's existing `<queries>` block
  (Android 11+ package-visibility rule).
- "Report a problem" upgraded from a bare TextButton to an OutlinedButton,
  matching "Analyze saved photos" (a bare text label did not read as
  tappable).
- A `Divider` (white24) now separates the action block from the "Previous
  sessions" list header.
- Suite green (475 passed); analyzer clean.

## Round 184 (2026-08-05): About-dialog license fix, clear setup-tips check, "Run AI on photos"

Owner feedback on round 183 + the pending rename decision.

- **About dialog rebuilt as a custom AlertDialog** (was `showAboutDialog`,
  whose mandatory "View licenses" button led to hundreds of framework/package
  entries — "truly overwhelming"). Now: icon + name + version in the title,
  the description, the GitHub link, and a plain statement of the app's OWN
  license ("Open source under the AGPL-3.0 license, full text in the
  repository"). Best-practice compromise: the auto-generated third-party
  list is NOT deleted — bundled BSD/MIT packages require their attribution
  to ship with the app — but demoted to one muted "Third-party licenses"
  action that pushes the standard LicensePage only when deliberately opened.
- **⋮ "Show setup tips at session start"**: replaced CheckedPopupMenuItem
  with an explicit checkbox glyph (filled blue check_box when on, outlined
  blank box when off) — the unchecked CheckedPopupMenuItem rendered as blank
  space, so the current state was unreadable.
- **"Analyze saved photos" → "Run AI on photos"** (owner's pick from the
  r183 suggestions), applied at every entry point: home-screen button, the
  session gear menu (was "Analyze photos"), the analysis screen's AppBar
  title, FIELD_GUIDE and the overview doc. Wording INSIDE the analysis
  screen (e.g. "Analyze 42 photos", "analyzed" badges/counts) deliberately
  stays — it reads naturally in context and matches the log/doc term
  "post-hoc analysis". The ✨ badge semantics are unchanged.
- Suite green (475 passed); analyzer clean.

## Round 185 (2026-08-05): equal-width home action buttons

- The three home actions (New session / Run AI on photos / Report a problem)
  now render inside Center > IntrinsicWidth > Column(stretch): the column
  sizes itself to the widest button and stretches the others to match, so
  the block reads as one unit regardless of label lengths (no hard-coded
  width). Suite green (475), analyzer clean.

## Round 186 (2026-08-05): cross-session Dashboard (visits, activity by hour/day)

Owner idea: a "Dashboard" summarizing across saved sessions — total track ids
over a period, activity across the time of day, "anything entertaining for
the citizen scientist". Only AI-mode sessions count (track ids exist only
where the tracker ran); motion/time-lapse sessions appear as a "not counted"
note with a pointer to "Run AI on photos".

- Entry point: a "Dashboard" TextButton (insights icon) in the home screen's
  "Previous sessions" header row (a pushed screen, not a literal tab — the
  home has no tab bar; can become one later if the owner prefers).
- `logging/dashboard_stats.dart`:
  - `SessionDashboardStats` per session: start/end ms, aiMode (from
    `config.captureTrigger`, legacy `motionOnlyCapture`, pre-r95 = AI), and
    per-track (first, last) ms spans, derived via `SessionLogIndex.build`
    (the summary's parser — legacy `detection` format parity for free) plus
    the cheap tail read for `end_of_session`; crashed sessions fall back to
    the last track activity.
  - `DashboardStatsCache.forSession`: caches the stats as
    `<session>/dashboard_stats.json` keyed by log size+mtime — first
    Dashboard visit scans each log once (progress bar), afterwards opening
    is instant. The r182 rename rewrite changes size/mtime → one recompute.
    Never throws; unreadable sessions yield an inert non-AI object.
  - Pure `aggregateDashboard(sessions, sinceMs)`: visit totals, watch time,
    visits/hour rate, mean + longest visit, visit-start histogram per LOCAL
    hour of day (the biological question is local time), contiguous per-day
    activity (zero-filled; switches to 7-day buckets past a ~2-month span),
    busiest hour + record day, AI vs other session counts.
- `screens/dashboard_screen.dart`: period SegmentedButton (7 days / 30 days
  / all time — instant, aggregation is pure), 2×3 stat-tile grid (visit
  total is the amber hero; watch time, visits/hour, AI sessions, average +
  longest visit), 🏆 busiest-hour / 📅 record-day lines, and two single-series
  bar charts ("Visits by time of day", "Visits by day/week") drawn by one
  `_BarChartPainter`: amber bars, recessive white24 baseline, sparse white38
  x-labels (0/6/12/18 h; first/middle/last date), value label on the peak
  bar only, legend-free (single series; per-dataviz-skill guidance). Body in
  SafeArea (r165 inset rule). Empty state explains WHY a period may be empty.
- DATA_GUIDE §7 "Derived cache files": dashboard_stats.json is app cache,
  safe to delete, not part of the scientific record.
- Tests: `dashboard_stats_test.dart` (12 cases — aggregation: hour buckets,
  busiest hour, rates, period filter, non-AI exclusion, zero-filled days,
  weekly switch, empty input; cache: compute-from-log, cache hit proven by
  doctored cache, invalidation on log growth, aiMode false for time-lapse,
  crashed-session end fallback, missing log). Full suite green (487).

## Round 187 (2026-08-05): summary Overview tab retired; richer Graphs, random Photos sample

Owner request: the summary's Overview tab was largely redundant with Setup and
added visual complexity. Reorganized the session summary to three tabs
(Photos | Graphs | Setup) and enriched Graphs and Photos.

- Overview tab removed (`session_summary_screen.dart`); its content moved:
  - Date / Start / End / Location / Duration / Model / Engine / Ended
    normally / Battery used (+ charging warning) / Saved to / Session
    storage / Phone storage free now LEAD the Setup tab as an "Overview"
    block.
  - "Unique insects (track ids)" renamed "Insect visits (track IDs)" and
    moved to the Graphs tab, directly above the visit timeline (same n/a
    wording in no-AI modes).
  - Gallery export moved to the Photos tab as "Copy photos to gallery"
    (HelpLabel ⓘ explains: extra storage, some gallery apps index new albums
    slowly, copies carry no detection boxes / in-app metadata) with a "Copy
    photos" button. All user-facing wording switched Export→Copy, including
    the home gear menu ("Copy photos to Gallery") and both confirm dialogs.
  - The red "Delete session" button dropped without replacement — the home
    list's per-session gear menu (r182) is the only delete entry point now.
  - `initialTabIndex` mapping is now Photos 0, Graphs 1, Setup 2 (analysis
    screen's review jump updated; default landing = Photos).
- Setup tab: below the Overview block, the full settings record sits behind a
  "▸ All session settings (tap to show)" reveal. Owner decision reversing the
  r147 display collapse: EVERY recorded setting is listed in every mode; the
  ones the capture mode made inert render dimmed (`_stat(dim:)`) under short
  "not applicable — recorded values:" notes. Concretely: detector + tracking
  blocks dimmed in motion/time-lapse sessions, time-lapse block shown (dimmed)
  in non-time-lapse sessions, motion-gate rows dimmed in time-lapse, gate
  tunables also dimmed when the gate itself was off, reference photos row now
  also shows "off". Log content unchanged (config_not_applicable etc. as
  before) — display only.
- Graphs tab additions (below the timeline, above "Extra graphs"; only when
  the session has visits): a visit-length histogram with a bin-width dropdown
  (1 s…1 h presets, persisted as pref `summary_duration_bin_s`; ≤60 bars,
  tail collapses into a "≥" overflow bar; count/mean/median/min/max line
  underneath) and a per-session "Visits by time of day" chart (visit starts
  per local hour — same definition as the r186 Dashboard, so numbers agree).
  Pure math in new `logging/visit_stats.dart` (unit tests
  `visit_stats_test.dart`); the Dashboard's private bar chart extracted to
  shared `widgets/mini_bar_chart.dart` (`MiniBarChart`) and reused for both.
- Photos tab: the sample-count slider + Show/All buttons are gone. Up to 10
  RANDOM photos auto-load when the summary opens (shown in capture order;
  status line says "picked at random"); "Show all N photos" loads everything,
  with a confirm dialog above 300 photos warning it can be slow and pointing
  to USB copy on a computer. A post-hoc cleanup reload keeps the user's
  sample/all choice.
- Tests: summary_tabs_test.dart NEW (random-10 + Show all; Setup reveal with
  n/a marking for both a time-lapse and an AI session), visit_stats_test.dart
  NEW; summary_posthoc_boxes_test + summary_bottom_inset_test updated to the
  new indices/auto-load (the inset test's readiness marker is now the
  timeline header — 'Extra graphs' can start below the lazy ListView's fold
  since the tab grew). FIELD_GUIDE §5/§6 updated. Full suite green (496).

## Round 188 (2026-08-05): inference-time + power graphs verified; wording honesty + is_plugged guard

Owner asked whether the summary's "Inference time (ms)" graph is real (and what
it measures) and how accurate the "Power draw (W)" graph is. Both were traced
end-to-end (plugin Kotlin → streaming map → fps/power records → SessionLogIndex
→ graphs) before touching any wording.

Verified facts:
- `inf_ms` (the inference graph) is the native timer around `rtModel.run()`
  ONLY: input-tensor copy, LiteRT/QNN interpreter run, output read-back
  (ObjectDetector.kt). ROI crop/resize/tensor packing = `pre_ms`; decode +
  C++ NMS + box mapping = `post_ms`; camera-to-bitmap conversion is before all
  of them. Raw per-frame value at each fps-sampler tick, never smoothed
  (`throttle_inf_ms_ema` is the smoothed one).
- The W graph = |battery current| × voltage from the phone's own sensors with
  summary-side corrections (median-magnitude mA-vs-µA ×1000; >4.6 V halved to
  a single cell; 3.85 V fallback; charge-counter delta fallback; 3-point
  smoothing; trapezoid Wh). Corrections were documented only in developer
  docs; raw logged `power_w` is uncorrected.

Changes:
- Graphs tab wording: title "Detector inference time (ms) — throttle signal";
  explanation states it is the neural-network run only, that pre_ms/post_ms
  exist in the log, and that points are raw single-frame values. Power text
  names the sensor source, the silent corrections, and frames the battery-%
  drop as the independent cross-check; caption now says "power curve summed
  over the session" (the code integrates, it never multiplied avg × duration).
- NEW `is_plugged` (additive wire key): MainActivity.readThermal() reads
  EXTRA_PLUGGED; ThermalReading/DeviceThermal, power records, and
  IndexedPowerSample carry it; the summary invalidates the energy series on
  `is_charging OR is_plugged` (start/end thermal blocks too). Closes the real
  field hole: a full battery on a power bank reports NOT_CHARGING while
  plugged, so the old flag missed it and a bogus graph could render. Old logs
  (no key) behave exactly as before.
- All-zero W series (no current + stuck charge counter) is no longer rendered
  as a confident flat 0 W / "0.00 Wh" — the "Not enough samples." placeholder
  shows instead.
- Docs: DATA_GUIDE defines pre/inf/post/track_ms and gains a "Power & energy:
  how to read them" caveat block (raw power_w is uncorrected: ~1000× low on
  mA-reporting phones, ~2× high on 2-cell-voltage phones; correction recipe;
  prefer battery-% drop cross-device; plugged sessions have no valid power
  data). FIELD_GUIDE §5 notes the W graph needs a battery-only session and
  that inference time is model-run-only. PERFORMANCE_BENCHMARKING warns that
  perf_summary.dart's W/Wh columns are RAW (fine for paired same-device runs,
  not for absolute numbers). Overview doc: Xiaomi 2-cell quirk recorded.
- Tests: session_log_index_test parses `is_plugged`; summary_tabs_test proves
  a plugged-but-not-charging session hides the W graph and computes no
  average-power caption. Full suite green (497).

RECORDED FOLLOW-UP (deliberately not done): align `tool/perf_summary.dart`'s
power math with the app's corrections — its columns feed benchmarking records
and must not change silently; do it as its own round with a flag or a note in
the output.

## Round 189 (2026-08-05): About without third-party license list; GitHub issues linked in report flow

- About dialog (home ⋮ menu): the muted "Third-party licenses" action is
  removed entirely (owner decision, overriding the r184 keep-it-reachable
  note). The license line now reads "Open source under the AGPL-3.0 license
  (full text, and the licenses of the third-party packages used, in the
  repository)". FACTS RECORDED for the future: the removed page was Flutter's
  auto-generated LicensePage (built from the bundled packages at compile
  time, zero maintenance — the "hard to maintain" premise did not apply),
  and several bundled BSD/MIT/Apache packages expect their attribution to
  ship WITH distributed binaries, so a store release needs an answer;
  RELEASE_PLAN.md carries the checklist item (cheapest fix: restore the one
  muted button).
- Report-a-problem flow now surfaces the public issue tracker
  (`ErrorReporter.githubIssuesUrl`, already printed in the .txt footer since
  r134) in the UI too: a tappable link line on the "Describe the problem"
  screen ("Problems can also be reported as a GitHub issue: …") and in the
  "Report saved" dialog ("You can also open a GitHub issue and paste the
  report's text there: …"). Both open externally via url_launcher (manifest
  https VIEW query exists since r183).
- Files: home_screen.dart (_showAbout, ReportSavedDialog),
  problem_description_screen.dart (new url_launcher/error_reporter imports).
  No wire/log changes. Full suite green (497).

## Round 190 (2026-08-05): report flow rework — contrast fix, screenshots, no email, ⋮ menu entry

Owner requests, all on the problem-report flow:

- CONTRAST BUG (owner report): the describe-the-problem screen's helper texts
  (and the r189 GitHub line) used black54/black45/black26 — near-invisible on
  the app's dark theme (`ThemeData.dark`, main.dart). All switched to the
  white70/white54/white24 palette the rest of the app uses; the GitHub link
  is lightBlueAccent like other links.
- SCREENSHOT ATTACHMENTS: "Attach screenshots…" on the describe screen
  (image_picker `pickMultiImage` — system photo picker, no storage
  permission; chips with per-file remove). `showProblemDescriptionEditor`
  now returns `ProblemDescriptionResult` {description, screenshotPaths};
  both callers (home + in-session camera flow) pass them to
  `ErrorReporter.build(attachmentPaths:)`, which copies each into
  `error_reports/` next to the .txt (`report_<stamp>_screenshotN.<ext>`,
  numbering keeps input positions; missing/failed files logged + skipped),
  lists them in a "-- Attached screenshots (N) --" section and returns them
  on `ErrorReport.attachments`; `share` sends .txt + screenshots together
  (share_plus multi-file). Picker copies are temp-cache files, so the copy
  happens at build time, before they can expire.
- EMAIL REMOVED FROM UI (owner decision: don't encourage mailed reports,
  mail-server load): ReportSavedDialog lost the developer-email field and
  "Email…" action (now a plain StatelessWidget popping true=Share;
  `ReportSendChoice` deleted); the .txt footer leads with the GitHub issue
  link and never prints "Send this file to:". DORMANT, kept for a possible
  revival: `ErrorReporter.emailTo`, `saveRecipientEmail`/`loadRecipientEmail`
  (+ the `report_recipient_email` pref) and native `sendFileByEmail` — note
  a revival must extend the native intent to carry the new attachments.
- MENU MOVE: "Report a problem" left the landing screen's action block for
  the ⋮ menu, directly above "Delete all sessions…" (`_HomeMenuAction.
  reportProblem`); the action stack is New session / Run AI on photos now.
- Testability: `ErrorReporter.debugDirOverride` (CrashStore's pattern) makes
  `build()` unit-testable; error_reporter_test gains the attachment group
  (copy + naming + skip-missing + footer wording; no-attachment case).
  Full suite green (499).

## Round 191 (2026-08-05): report bundle zip + user-chosen session data (owner field test)

Owner tested r190 via WhatsApp: sharing the .txt ALONE worked, but with
screenshots attached WhatsApp delivered only the caption text — every file
dropped. Mixed MIME types in one multi-file share (text/plain + image/*) is
the suspect. Owner also flagged that the report silently sampled the NEWEST
session's log, though a problem may concern an older session or none.

- ONE shareable file: `logging/report_bundle.dart` `writeReportZip` bundles
  report.txt + screenshot copies + sampled session files into
  `report_<stamp>.zip` (NEW direct dep `archive` ^4.0.7 — already in the
  tree via `image`). `ErrorReport` gains `bundleZip`/`bundledNames`/
  `shareFile`; `ErrorReporter.share` now always sends exactly one file
  (zip when it exists, else the bare .txt — which keeps the plain
  txt-only report as readable as before). Zip failure degrades to
  txt-only sharing, never blocks the report.
- Session choice: the describe screen gains an "Include session data"
  dropdown (newest preselected, "No session data" option; home passes its
  session list as `ReportSessionOption`s; the in-session camera flow keeps
  the live session automatically). The .txt's embedded 30+200 session.jsonl
  sample follows the user's choice.
- Sampled session files (bundle members), designed from the owner's two
  example sessions (session_3: 18.7k-line/6.8 MB session.jsonl, 96%
  detections/track_event; logcats 71–93% one repeated CameraX
  `updateAcquireFence` line + per-second PERF/FRAMEPERF telemetry that
  duplicates the fps records; post_detections.jsonl 99% per-photo lines):
  - `session_events_sample.jsonl.txt` — drops flood types (detections,
    detection, track_event, raw_detections, capture, gt_capture,
    motion_capture, timelapse_capture), KEEPS unknown/future types,
    redactLocation applied, head 100 + tail 300 (session_3: 546 kept → 400);
  - `logcat_start_sample.txt` / `logcat_end_sample.txt` — noise filter +
    head/tail 150 each;
  - `post_detections_runs.jsonl.txt` — post_start/post_end/post_cleanup
    only, head/tail 40.
  `sampleFilteredFile` streams with bounded memory (head list + tail ring),
  caps 2000-char lines, returns '' for missing files, never throws.
- "Report saved" dialog names the bundle and its contents count.
- Tests: report_bundle_test.dart NEW (filters incl. keep-unknown-types rule,
  head/tail marker, redaction, zip round-trip via ZipDecoder);
  error_reporter_test extended (zip built with screenshots, bare-txt case,
  chosen-session samples land in zip + are listed in the .txt). Suite green
  (509).

## Round 192 (2026-08-05): report polish after owner's zip test (.jsonl names, no duplicate excerpt)

Owner whatsapped himself a real bundle (report_2026-08-05T14-18-03-479627,
kept under sessions/error_reports/Xiaomi/): the zip worked as designed. Two
review points, both deliberate r191 choices rather than bugs, both changed:

- `.jsonl` members are named `.jsonl` again: `session_events_sample.jsonl`,
  `post_detections_runs.jsonl` (the r191 `.jsonl.txt` suffix marked them as
  not-strictly-valid JSONL because of the plain-text omission marker). To
  make the name honest, the marker inside them is now itself a JSON record:
  `{"type":"sample_omitted","omitted_lines":N}` (`jsonlOmissionMarker`,
  optional param on `sampleFilteredFile`) — the samples parse as JSON Lines
  end to end (pandas-friendly). Logcat samples stay `.txt`.
- The .txt's embedded "-- Session log: … (first 30 + last 200 lines) --"
  excerpt was redundant next to the zip's event sample (owner was right).
  Now: extras are collected BEFORE the body is composed; when they exist the
  .txt carries only a "-- Session data: <folder> --" pointer to the zip
  members; the classic excerpt is APPENDED only when zip creation fails
  (the shared .txt must stay self-sufficient in that fallback).
- Same redundancy class, same round: the .txt's LIVE logcat capture now
  drops the `updateAcquireFence` noise line (`keepLiveLogcatLine`) — it was
  the bulk of the 2000 captured lines on the test device. PERF/FRAMEPERF
  deliberately STAY in the live capture: with "No session data" chosen they
  are the report's only performance record.
- Tests updated (member names, valid-JSONL marker round-trip via jsonDecode,
  .txt points-at-zip assertion). Suite green (510).


## Round 193 (2026-08-05): release-plan build-config items + Zenodo/Pages recipes

Owner directive: work through what is left in RELEASE_PLAN.md, most important first.
Code/asset changes land now; Phase 1 (Zenodo) and the Pages site got step-by-step
recipes the owner executes later (the repo goes public at a time of their choosing).

- Third-party licenses page RESTORED (owner decision reversing r189, for the store
  release: bundled BSD/MIT/Apache packages require their license text to accompany
  the distributed binary). The About dialog gains a muted "Third-party licenses"
  TextButton that PUSHES Flutter's auto-generated LicensePage on top of the dialog
  (no pop, backing out returns to the About; `applicationLegalese` warns the list
  is long). Nothing is listed in the About itself, so it stays discreet for end
  users. The dialog is now the extracted public `AboutFaunaPulseDialog` widget
  (version string param), same pattern as `DeleteAllSessionsDialog`, with 3 new
  widget tests (`home_about_dialog_test.dart`; the LicensePage assertions avoid
  pumpAndSettle because its license-loading spinner may never settle, and the
  root-navigator pop uses `find.byType(Navigator).first` because LicensePage
  nests its own Navigator).
- Manifest camera features decided (Play device eligibility): `android.hardware.camera`
  stays `required="true"` (camera-trap app, useless without one);
  `android.hardware.camera.autofocus` is `required="false"` (manual focus only
  since r164, preset clamps to the lens range, fixed-focus devices work).
- Play listing icon: `ic_launcher-playstore.png` resized 1254x1254/1.17 MB to the
  Play-required 512x512 32-bit PNG (~218 KB); original recoverable from git.
- New `scripts/build_release_apks.sh`: `flutter build apk --release --split-per-abi`
  and stages `dist/faunapulse-v<version>-<abi>.apk` (arm64-v8a + armeabi-v7a) under
  stable Obtainium-friendly names; `dist/` git-ignored.
- RELEASE_PLAN.md: Phase 1 rewritten as a numbered 10-step recipe (make-repo-public
  pre-flight, Zenodo toggle BEFORE tagging, publish-release fires the webhook,
  concept DOI into CITATION.cff); Phase 2 reworked per owner decisions of
  2026-08-05 (QUICK_START.md dropped, FIELD_GUIDE.md is the quick start; new
  GitHub Pages recipe: MkDocs Material deployed via LOCAL `mkdocs gh-deploy`, so
  no CI runs on the owner's several-pushes-a-day workflow; CI itself deferred to
  near v1.0, tag-triggered if revived); Build-config "Still open" items all ticked.


## Round 194 (2026-08-07): tester MDV6 bundle replaces release YOLO26

Owner decision: the general-purpose `yolo26n_int8.tflite` remains available
locally for project-owner testing but must not be downloaded, required, or
included in release APKs. Tester releases currently ship only the 256 px MDV6
INT8 and float16 MegaDetector models (3 categories: animal, person, vehicle).

- Removed the Android `fetchBundledModels` task and its `preBuild` dependency.
  `scripts/fetch_bundled_models.sh` remains as a clearly marked, manually run
  historical example.
- Added a release-only asset allowlist in `android/app/build.gradle`. Flutter
  still sees all ignored local model files for debug development, but
  `copyFlutterAssetsRelease` copies only
  `MDV6-yolov10-c_int8_256.tflite` and
  `MDV6-yolov10-c_float16_256.tflite` into the release asset tree. Local
  source weights are never deleted or modified.
- The release preflight now checks for those two tester weights, never YOLO26.
  The existing `-PallowMissingBundledModels` escape hatch remains for an
  intentionally model-free build.
- The new default is the MDV6 INT8 256 px asset. Release builds hide local test
  weights from the picker and migrate saved `yolo26n` selections to the new
  default, preventing an upgraded installation from attempting a runtime YOLO
  download. Debug builds retain the YOLO entry and all custom test models.
- Centralized the Dart release/default paths in
  `lib/fauna_pulse/models/bundled_models.dart`; its allowlist must stay in
  sync with Gradle's matching list.
- Verification: `flutter analyze` clean; focused model/config tests 74/74;
  full `flutter test test/fauna_pulse` 517 passed, 1 replay test skipped;
  signed `flutter build apk --release` succeeded (124.2 MB) with no fetch
  script output. Direct APK inspection found exactly the two intended MDV6
  weight files and no YOLO26 or other local test weights.


## Round 195 (2026-08-07): explicit linked camera and inference FPS caps

Owner report: Power tab called inference value `0` "Max" but auto-throttle
actually interpreted it as a fixed 15 FPS ceiling, while the same input
accepted explicit higher rates. The two rate controls also allowed an
impossible inference ceiling above the positive camera hardware cap.

- Confirmed the distinction in the pipeline: inference FPS is the number of
  delivered camera frames per second that the AI model may analyze. The camera
  cap limits the frames the hardware supplies, so a positive camera cap is a
  real upper bound on inference FPS.
- Both defaults are now 15 FPS. Max inference rate is an explicit 5 to 120 FPS
  value with no `0 = Max` shortcut; legacy saved inference `0` migrates to 15.
  Camera `0` keeps its existing meaning, remove the hardware cap.
- Power-tab fields now show `FPS`. Their info text explains inference FPS and
  the dependency. Inference input is limited by a positive camera cap; lowering
  the camera cap automatically lowers inference FPS and, if necessary, the
  auto-throttle minimum. With camera cap `0`, inference can be raised to 120.
- Centralized the linked-cap normalization in `SessionConfig`, including saved
  config migration and live-screen initialization. Added regression tests for
  defaults, legacy `0`, positive-cap limiting, uncapped camera behavior, and
  lowering both the inference ceiling and throttle floor.
- Updated SETTINGS_REFERENCE, PERF_AND_ROBUSTNESS_REVIEW, and the current-state
  overview. Verification: `flutter analyze` clean; focused config tests 59/59;
  full `flutter test test/fauna_pulse` 521 passed, 1 replay test skipped.


## Round 196 (2026-08-07): align camera and inference maxima at 30 FPS

Owner follow-up after Round 195 was committed: a 120 FPS inference choice was
misleading beside the camera control's 30 FPS maximum and could encourage an
unnecessarily high live-analysis setting.

- Kept both factory defaults at 15 FPS, which remains the intended balance for
  pollinator and wildlife monitoring.
- Reduced `SessionConfig.maximumInferenceFps` from 120 to 30, matching
  `maximumCameraFpsCap`. Camera `0` still removes the hardware cap, but the
  inference input remains limited to 30 FPS.
- Preserved the Round 195 dependency: a positive camera cap below 30 is the
  tighter inference maximum, and lowering it also lowers the auto-throttle
  minimum when necessary.
- Updated the Power-tab help through the shared maximum, user documentation,
  performance benchmark guidance, overview, and regression tests.
- Verification: `flutter analyze` clean; focused config tests 59/59; full
  `flutter test test/fauna_pulse` 521 passed, 1 replay test skipped.

## Round 197 (2026-08-10): make session-summary mode and model use explicit

The Setup tab's short Overview could show a configured model path for motion
and time-lapse sessions even though neither mode ran the AI detector. It also
did not state the session's operating mode near the headline details.

- Added Capture mode as the first Overview row, using plain-language values
  consistent with Setup: AI detector, Motion-triggered photos (no AI), or
  Time-lapse photo bursts (no AI).
- AI sessions continue to show the model and inference engine actually loaded.
  Motion and time-lapse sessions now show Model as "Not applicable (no AI
  detector used)" and omit the inapplicable Inference engine row.
- Kept the complete recorded configuration unchanged in "All session settings",
  where model and detector values remain visible but dimmed for no-AI sessions.
- Added a widget regression test covering row order and all three capture
  modes. Verification: `flutter test test/fauna_pulse/summary_tabs_test.dart`
  passed (5 tests).

## Round 198 (2026-08-10): make summary applicability and photo legend explicit

Owner review found two remaining sources of ambiguity in the Session summary:
the Photos legend was compressed into one line, and muted Setup values could
still look like settings that had affected the recorded session.

- Clarified the Photos introduction for sessions without live AI. Added the
  heading "Bounding box colors (if AI was used)" and placed the trigger-insect
  and co-detected-insect explanations on separate wrapping lines.
- Changed every existing `na:` settings row to display the literal value "Not
  applicable" in the muted style instead of its stored default. The underlying
  JSON remains unchanged, so scientific provenance and reproducibility are
  preserved without exposing inactive defaults as if they were used.
- Kept deliberate off states meaningful: Reference photos = off remains "off".
  The high-res sync companion is now not applicable in fast-photo mode.
- Made scheduling dependencies explicit. Scheduled recording = No now makes
  Schedule windows and Schedule days not applicable, hiding the unused
  06:00-10:00 default. When scheduling is enabled, Max session length is not
  applicable because each schedule window controls the session.
- Renamed "Camera resolution" to "Maximum camera resolution this phone can
  deliver".
- Expanded `summary_tabs_test.dart` to verify both legend lines and their
  vertical order, explicit mode-dependent values, active time-lapse values,
  the camera label, and disabled-schedule values. Verification:
  `flutter test test/fauna_pulse/summary_tabs_test.dart` passed (5 tests);
  `flutter analyze` found no issues.

## Round 199 (2026-08-10): manifest-controlled release model bundle

Release APK model selection is no longer duplicated as a hard-coded Gradle and
Dart allowlist. The maintainer can now change the tester model set by editing
`assets/models/bundled_models.txt` and running the normal release command.

- Gradle reads one path per nonblank, non-comment line. It accepts both
  `assets/models/...` and `/fauna-pulse/assets/models/...` forms.
- `copyFlutterAssetsRelease` keeps the manifest and only its listed model
  weights. Source weights remain untouched. Missing listed files print a clear
  warning and the release build continues with the remaining models.
- `ModelCatalog` reads the bundled manifest in release mode, so supported
  listed weights directly under `assets/models/` and in `custom/` are
  selectable in the app. Debug builds still expose all supported local weights,
  with YOLO26 retaining its special debug entry.
- Added unit coverage for path normalization, comment handling, top-level model
  support and manifest-based release visibility. Updated INSTALL.md,
  RELEASE_PLAN.md and AGENT_CHANGELOG_OVERVIEW.md.
- Verification: Gradle preflight found 3 of 3 listed files. A temporary missing
  entry printed the intended warning and the task still ended with
  `BUILD SUCCESSFUL`. The 20 focused model-catalog tests passed and
  `flutter analyze` found no issues. `flutter build apk --release` built a
  127.1 MB APK. Archive inspection found exactly the manifest, YOLO26 INT8,
  MDV6 INT8 256 and MDV6 float16 256. Unlisted ArthroNat and 320 px weights
  were absent.

## Round 200 (2026-08-10): Google Play security hardening

Implemented the seven release-security areas from the pre-Play review while
keeping all new runtime checks outside the live camera and inference paths.

- Hardened the Android manifest and storage boundary. Cleartext networking is
  disabled; backup is explicitly settings-only; session photos/logs, models,
  crash files and reports are excluded. Reports and crashes now live in private
  internal storage, and the report FileProvider exposes only report folders.
- Hardened user model intake. Imported models now use private storage, strict
  safe base names, path-containment checks, temporary-file promotion, available
  storage checks, non-empty checks and TFLite `TFL3` validation. TFLite is capped
  at 30 MiB at `kMaxTfliteModelBytes` in
  `lib/fauna_pulse/models/model_file_security.dart`; QNN remains separately
  capped at 256 MiB. Valid legacy external models migrate once without deleting
  the originals.
- Hardened model downloads in both FaunaPulse and the vendored resolver. Only
  HTTPS is accepted, redirect downgrades are rejected, connection/stall timeouts
  are bounded, declared and streamed sizes are capped, partial files are cleaned
  up, TFLite headers are checked and trusted callers may supply SHA-256.
- Bounded native model metadata parsing before allocation: 2 MiB metadata/text
  ceilings, 128 ONNX properties, safe long-to-int handling and bounded ZIP/YAML
  reads. Added native regression tests for exact-limit, over-limit and hostile
  ONNX length cases.
- Reduced permission and battery risk. Removed the direct battery-optimization
  exemption and unused data-sync foreground-service permissions; the UI opens
  Android's general settings instead. The recording wake lock now has a
  30-minute fail-safe renewed every 25 minutes during an active service, and the
  service no longer restarts alone after its camera Activity is killed.
- Enabled failing release lint and fixed release compilation so
  IntegrationTestPlugin remains debug-only. Added explicit API-29 style
  resources, a signed local AAB release gate, GitHub security checks and weekly
  Dependabot checks for Pub and Gradle.
- Updated the privacy policy, install/field/test guides, release plan and
  current-state overview. The policy discloses that Android backup may include
  settings and the last optional GPS coordinates while field data and
  diagnostics remain excluded.

Verification: `flutter analyze` clean; app suite 532 passed with one intentional
tracker-replay skip; vendored plugin suite 173 passed; native security tests
3 passed; `:app:lintRelease` passed with 0 errors (7 unrelated warnings);
signed `flutter build appbundle --release` built a 163.8 MB AAB and
`jarsigner -verify` reported `jar verified`. Final AAB SHA-256:
`eee5ec668ecfecaaf9610f62e491d61975bb35fcf237e43e90a7445d3e4b128a`.

## Round 201 (2026-08-11): repair security-check CI bootstrap

The first Round 200 GitHub Actions run stopped before executing any native
security assertion because the workflow called `android/gradlew`, but the app
Gradle wrapper launcher and JAR were excluded by `android/.gitignore` and were
therefore absent from a fresh checkout.

- Restored the Gradle wrapper as tracked build infrastructure so both the direct
  native test/lint command and Flutter's later Android bundle command work from
  a clean clone.
- Updated GitHub's checkout and Java setup actions from v4 to their Node.js
  24-based v5 releases, removing the runner's Node.js 20 deprecation warnings.
- Added the GitHub Actions ecosystem to weekly Dependabot checks alongside the
  existing Pub and Gradle checks.
- Verified the previously blocked command locally: all 3 native metadata
  security tests passed and `:app:lintDebug` completed successfully (`BUILD
  SUCCESSFUL`, 689 tasks). The original CI error was bootstrap-only, not a
  failed security test. The workflow's later `flutter build appbundle --debug`
  gate also built `app-debug.aab` successfully.
