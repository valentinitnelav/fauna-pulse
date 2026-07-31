# Performance & Robustness Review 

Opened with round 66, 2026-07-04.

**Who this is for:** the code agent + project owner deciding what to improve next, 
and any collaborator implementing one of these items.

This is a code review, not a change log. 
Each item is a checkbox so finished work can be ticked off in later rounds.
Items are ordered by expected payoff within each section. 
File references were verified against the code on the review date; line numbers will
drift as files change, so treat them as "near here".

Plain-language glossary for terms used throughout:

- **Analyzer / camera thread** — the single background thread the camera
  library (CameraX) uses to hand us each video frame. If this thread is busy,
  frames pile up and get dropped, so everything it runs must be fast.
- **Allocation** — creating a new object in memory. Doing this for every video
  frame (10–30× per second) forces the garbage collector to run often, which
  causes periodic stutter.
- **Platform channel** — the messaging pipe between the native Android (Kotlin)
  side and the Flutter (Dart) side of the app.
- **Delegate / accelerator** — which chip runs the AI model: CPU or GPU.

---

## Part A — Inference speed (native Kotlin, `packages/ultralytics_yolo/android/...`)

### A1. Move the FPS-cap frame drop *before* the bitmap conversion

- [x] `YOLOView.kt` — `shouldRunInference()` (~line 2131) runs **after**
  `ImageUtils.toBitmap` (~line 2038).

Every frame the inference-FPS cap discards has already paid the full
RGBA→Bitmap conversion (a per-frame image copy). With the default cap of 10
inferences/s on a 30 fps camera, roughly **two thirds of all conversions are
wasted work** — pure heat with no benefit, and heat is this project's binding
field constraint.

The right pattern already exists in the same function: the motion gate's idle
sampler drops frames with `imageProxy.close(); return` *before* any conversion
(~lines 2023–2030). The cap check can be hoisted the same way.

**Caveat:** when the motion gate is enabled, its background model needs to keep
seeing frames (the gate check deliberately runs before the cap, comment at
~2090). So the hoisted cap must still let gate-check frames through while the
gate is enabled — the win is largest when the gate is off or awake.

*Expected gain:* large reduction in per-frame CPU/heat at capped rates.
*Effort:* small–medium (one reordering + gate interaction test).
**Done (round 68):** cap check hoisted before conversion when the gate is
*off* (the verdict is remembered so the stateful check runs once per frame);
with the gate *on* every frame is still converted for the background model
and the cap applies at its original spot. The FRAMEPERF stats block moved
above the drop so `deliveredFps`/`cameraFps` keeps meaning "frames CameraX
delivered" (watchdog + FPS graphs unchanged); a new `convertedFps` shows the
savings, and `toBitmapMs` now averages over converted frames only. Side
effect, accepted: `lastFrameBitmap` (fast ROI-photo source) refreshes at the
capped rate, so a photo crop can be up to one cap interval older.

### A2. Stop blocking the camera thread on every result send

- [x] `YOLOPlatformView.kt` — `sendStreamData` posts the result map to the main
  thread and then **waits** on it: `latch.await(100, MILLISECONDS)`
  (~lines 245–260).

Every emitted frame, the camera thread stalls until Flutter's main thread
drains the message — up to 100 ms if the UI is busy (e.g. during a photo save
or a settings rebuild). A stalled camera thread means dropped frames and a
lower effective detector FPS that has nothing to do with model speed.

Fix: make the send fire-and-forget, or keep a single "latest result" slot that
the main thread picks up when ready (new result overwrites unsent old one —
dropping a stale detection frame is harmless here).

*Expected gain:* removes intermittent stalls; steadier detector FPS under UI load.
*Effort:* small, but test the existing retry/`recreateEventChannel` error path.
**Done (round 68):** replaced with a latest-result slot (`AtomicReference`)
drained by a single posted runnable — the camera thread never waits, and a
result arriving while the UI is busy overwrites the unsent one. (The old
latch's result was in fact *discarded* — the 100 ms wait bought nothing.)
If the sink is gone at drain time the existing `scheduleRetry`/
`recreateEventChannel` path takes over; `stopStreaming` clears the slot.

### A3. Reuse per-frame buffers instead of allocating

- [x] `ImageUtils.kt` — `toBitmap` creates a new `Bitmap` **every frame**
  (~line 68), and a second one when the camera pads its rows (~line 74).
  Reuse one (or two) pre-allocated bitmaps of the stream size.
- [x] `LiteRtModel.kt` — `readAsFloats` allocates a fresh `FloatArray` per
  model output **every inference** (~lines 244–255). The NPU path already does
  this right: `OrtQnnModel.kt` reuses its output buffers (~line 80). Mirror
  that.

*Expected gain:* less garbage-collector churn → fewer periodic stutters over a
multi-hour session.
*Effort:* small each; watch out for the row-stride crop case in `toBitmap`.
**Done (round 72):** new `ImageUtils.BitmapFrameBuffer` (one instance owned by
`YOLOView`) reuses a single published bitmap, plus a private staging bitmap for
row-padded frames, across all frames; the YUV_420_888 fallback still allocates
(inherent JPEG round-trip, rare legacy path). Because the reused bitmap doubles
as `lastFrameBitmap` — the fast ROI-photo source read from the platform-channel
thread — the writer and `cropRoiFromFrame`'s source draw both `synchronized` on
the bitmap instance, so a photo can never capture a torn half-old/half-new
frame; the camera thread can only block for the few ms of a crop draw, at most
once per photo. `LiteRtModel` now reuses per-output widening targets for
*integer* outputs (valid until the next `run()`, same contract as
`OrtQnnModel`). **Caveat:** the float path cannot mirror `OrtQnnModel` — LiteRT
2.x `TensorBuffer` exposes only `readFloat(): FloatArray`, which allocates a
fresh array inside the runtime on every call (verified with `javap` against
litert 2.1.5; there is no read-into-existing-buffer variant). All shipped
models have float outputs, so that one per-inference allocation remains until
the LiteRT API grows a destination-buffer read.

### A4. Implement the startup CPU-vs-GPU benchmark (spec says it exists; it doesn't)

- [x] `LiteRtModel.kt` (~lines 100–123) — engine choice is a fixed ladder: try
  GPU, and on any error fall back to CPU. The "benchmark" mentioned in
  CLAUDE.md and in the file's own header comment (~lines 15–18) is only a
  doc comment with numbers profiled on other hardware. *(Done, round 76, with
  an owner-decided design change: the benchmark is **user-triggered from
  Settings → AI**, not automatic at model load — compiling the model several
  times costs seconds and heat, so the user runs it when it matters (e.g.
  after switching models). Native `benchmarkAccelerators` in `YOLOPlugin.kt`
  times GPU and CPU at several thread counts through `LiteRtModel` (inheriting
  the crash guard / blocklist / program cache); a results dialog offers
  "Use <fastest>", which sets the existing `useGpu` switch and the new
  `cpuThreads` setting. No per-model persisted auto-choice — the chosen engine
  lives in `SessionConfig` like every other tunable.)*

GPU is *usually* faster, but not always (small nano models on some SoCs run
faster on CPU, and GPU keeps the device warmer). Proposal: at model load, run
N timed warm-up inferences on each backend that compiles, pick the faster one,
and persist the choice per model key — sitting alongside the existing 2-strike
GPU-crash blocklist (~lines 58–119) and the GPU program cache, so the cost is
paid once per model, not per session.

*Expected gain:* correct engine choice per device/model pair; matches the
documented behaviour.
*Effort:* medium (timing harness, persistence, interaction with the blocklist).

### A5. Rasterize the ROI once per frame, not twice

- [x] `MotionGate.kt` (~line 124) draws the ROI into its small thumbnail, and
  `ObjectDetector.kt` `predict` (~line 102) draws the same ROI again into the
  model-input bitmap. Derive the gate thumbnail by downscaling the model-input
  bitmap (or vice versa) so the ROI region is copied once.
  *(Done, round 74: on frames that run inference the gate thumbnail is now
  derived from the detector's model-input bitmap
  (`MotionGate.motionDetectedFromModelInput`, fed via
  `BasePredictor.lastRoiModelInput()`); idle and FPS-capped frames keep the
  direct tiny draw, since no model raster exists there and forcing one would
  cost far more than it saves.)*

*Expected gain:* modest; only matters while the gate is awake.
*Effort:* small–medium (the two consumers want different sizes/filters).

### A6. Smaller cleanups (batch these opportunistically)

- [x] `YOLOView.kt` reads `context.resources.configuration.orientation` three
  times per frame (~2052, ~2094, ~2140) — read once per frame (or cache and
  update on configuration change). *(Done, round 75: one `frameIsLandscape`
  read at the top of `onFrame` now feeds the frame cache, both
  `gateMotionFromFrame` call sites — which take it as a parameter — and the
  inference block.)*
- [x] `YOLOView.kt` `convertResultToStreamData` (~2787–2806) builds several
  nested `HashMap`s per detection on the camera thread, then copies the whole
  map again (`HashMap(streamData)`, ~2196). Pre-size maps, drop the copy.
  *(Done, round 75: converter returns `HashMap` and `onFrame` enriches it in
  place — copy gone; top-level map, `detections` list, and the per-box maps of
  the detect path are pre-sized. Pose/OBB/classification branches left as-is —
  this app never streams them.)*
- [x] `ImageUtils.kt` `copyRgbBitmapToFloatArray` (~362–376) normalizes pixels
  in a scalar per-pixel loop. Fine at 640×640, but a good candidate for a
  lookup table or vectorized loop if input sizes grow. *(Done, round 75: a
  cached 256-entry LUT replaces the per-channel subtract+divide in both
  `copyRgbBitmapToFloatArray` and the `copyRgbBitmapToFloatBuffer` sibling;
  rebuilt only if mean/std change, which no current caller does.)*
- [x] Document the `includeOriginalImage` stream option as a footgun: when
  enabled it JPEG-encodes the **full camera frame at quality 90 on every
  frame** on the camera thread (`YOLOView.kt` ~2991–2997). The app never
  enables it; make sure nothing ever does casually. *(Done, round 75: ⚠️
  warning comments at the flag definition in `YOLOStreamConfig.kt` and at the
  encode site in `convertResultToStreamData`.)*

### A7. Noted for the roadmap (no action this round)

- a. ~~There is **no CPU thread-count or XNNPACK tuning surface** in the current
  LiteRT 2.x `CompiledModel` API path — CPU behaviour is whatever the runtime
  defaults to. If CPU sessions matter more after A4, revisit.~~ *(Corrected in
  round 76: litert 2.1.5 does expose `CompiledModel.CpuOptions(numThreads,
  xnnPackFlags, xnnPackWeightCachePath)` — verified with javap against the
  AAR. XNNPACK itself is already LiteRT's default CPU backend, so there was
  nothing to "add"; `numThreads` is now plumbed through (`cpuThreads` setting,
  0 = runtime default) and measured by the A4 benchmark. `xnnPackFlags` left
  alone (exotic), and the weight cache deliberately skipped: a cache file
  corrupted by a mid-write kill would be re-read by native code at next launch
  with no crash-guard around it, for only a small load-time win.)*
- b. Larger speed/accuracy items (full-res stills strategy, alternative runtimes
  such as ncnn, model retraining) are tracked in the owner's performance
  roadmap and are out of scope for this review.

---

## Part B — Robustness for field deployment (Dart, `lib/fauna_pulse/`)

### B1. The per-frame log write can crash a session (highest priority)

- [x] `camera_session_screen.dart` `_recordFrame` (~868–896) →
  `session_logger.dart` `_append` → `raf.writeStringSync(...)` (~line 67),
  with **no try/catch anywhere on that path**.

`writeStringSync` is synchronous file I/O running inside the per-frame
detection callback. If the phone's storage fills up mid-session (hours of
JPEGs), or storage permission is revoked, it throws right in the frame
callback — the one failure mode an unattended field session cannot recover
from, on exactly the sessions long enough to fill storage.

Fix: wrap the append path; on failure, surface once via the existing
`logAppError` + red banner mechanism (round 65) and degrade gracefully (e.g.
stop logging detections but keep the session alive, or stop the session
cleanly so `end_of_session` gets written while the disk still has room).

While in there, two related wins:

- [x] **Batch to one JSONL line per frame** instead of one per track — several
  concurrent tracks currently mean several `jsonEncode` + `writeStringSync`
  calls per frame on the UI thread.
- [x] Consider moving writes to a small queue drained off the UI thread.

*Effort:* small for the guard; medium for batching/queueing.
**Guard done (round 67):** `SessionLogger._append`/`flushNow`/`close` never
throw on I/O failure; failed lines are counted, `onWriteError` fires once →
persistent red banner + best-effort `app_error` line; writes keep being
attempted so logging resumes if space is freed. Failure-path tests added.
**Batching + queue done (round 69):** one `detections` record per frame with
a `tracks` array (replaces per-track `detection` lines; summary screen and
DATA_GUIDE snippets read both). Records are queued and drained by a single
async writer loop — `RandomAccessFile.writeString`/`flush` run on the Dart
VM's background I/O thread pool, so disk latency no longer touches the frame
callback; fsync stays on the ~0.5 s cadence and `close()` drains the queue
before releasing the handle.

### B2. No global error trap

- [x] `main.dart` is a bare `runApp` (lines 10–12) — add
  `FlutterError.onError` + `PlatformDispatcher.instance.onError` (or
  `runZonedGuarded`) that route uncaught errors to `logAppError` when a
  session is active, so a field crash always leaves a trace in the JSONL.
- [x] `camera_session_screen.dart` — fire-and-forget futures with no error
  handler: `_capture?.capture(pending)` (~893), `_pushInferenceRoi` (~1616),
  `_pushMotionGate` (~1627). A failed JPEG write currently becomes an
  unhandled async error nobody sees. Add `.catchError` → `logAppError`.
- [x] `roi_capture.dart` `capture()` (~359–446): the native-crop call is
  guarded, but the Dart-fallback `compute()` isolate and the final
  `outFile.writeAsBytes` are only inside `try { } finally { }` — add the
  `catch`.

*Effort:* small. **Done (round 67):** new `logging/app_error_hooks.dart`
installs both traps from `main()` (rate-limited to 1 record / 2 s; uncaught
async errors are logged and *handled*, so they no longer kill a session);
the camera screen points `appErrorSink` at the live logger for the duration
of a recording. `RoiCaptureScheduler.capture()` gained a `catch` + `onError`
sink; the ROI/motion-gate pushes got `.catchError` → `_logAsyncError`.

### B3. App lifecycle gaps

- [x] `didChangeAppLifecycleState` (~437–444) handles only `resumed`
  (re-assert wakelock). Add `paused`/`detached` → `_logger?.flushNow()`, so
  if the OS kills the backgrounded app (aggressive OEM battery managers —
  the Xiaomi test device is one) the loss window shrinks from ≤0.5 s of
  detections to ~zero.
- [x] `dispose()` (~406–434) calls `_stopRecording(normal: false)` (~421)
  **unawaited**, then immediately `_controller.dispose()` (~423). The stop
  sequence does several `await`s (battery read, thermal read, logcat save)
  before closing the logger and stopping the keep-alive foreground service —
  all racing camera teardown. Make the stop sequence resilient to being
  torn down mid-way (or reorder: close logger + stop service first,
  best-effort extras after).

*Effort:* small–medium. **Done (round 70):** background/detach (and `hidden`)
now flush the log queue; `_stopRecording` reordered critical-path-first —
`_recording` false immediately, battery/thermal reads time-bounded (2 s),
`logEnd` + `close()` + error-sink teardown + keep-alive stop before the
best-effort logcat/wakelock extras, every remaining step guarded. A
`_stopping` flag keeps a second tap (or a re-entrant call) out of the stop
sequence, and `SessionLogger` drops post-close appends silently instead of
throwing on late platform events.

### B4. Camera-delivery watchdog

- [x] The existing watchdog (~490–516) catches "camera delivers but detector
  silent" (`fps == 0` while `cameraFps > 1`). The opposite failure —
  **the camera itself stops delivering** (`cameraFps` → 0: camera HAL crash,
  another app grabbing the camera, OS resource reclaim) — raises nothing.
  An unattended session would sit recording nothing for hours. Add the
  symmetric check: recording + `cameraFps` ≈ 0 for N seconds → `logAppError`
  + banner (and optionally attempt a camera rebind).

*Effort:* small. **Done (round 70):** the check rides the 1 s recording
ticker (it *must* be timer-driven — a dead camera produces no stream
callbacks to check from). Any stream event stamps `_lastStreamEventMs`,
gate-idle heartbeats included, so a sleeping detector can't false-alarm;
10 s of silence while recording → flushed `app_error` + red banner, both
auto-clearing (with a "delivery resumed" log line) if frames return. The
camera rebind was left out — no safe rebind API is exposed today; revisit
if field sessions actually hit this.

### B5. Config bug: `occlusionSeconds` default mismatch — fix first, it's one line

- [x] `session_config.dart`: constructor default is `3.0` (~line 287) but the
  `fromJson` fallback when the key is absent is `1.0` (~line 478). A config
  saved by a build that predates this setting silently loads a 1 s occlusion
  buffer instead of the bee-tuned 3 s — exactly the parameter whose tuning
  fixed track-id fragmentation. Fix the fallback to `3.0` and add the
  absent-key case to `session_config_test.dart`.

*Effort:* trivial. **Done (round 66):** fallback set to `3.0`; regression test
"legacy config missing occlusionSeconds falls back to 3 s" added (22/22 pass).

### B6. Split the god-class (incremental, behaviour-preserving)

`camera_session_screen.dart` is ~2,590 lines, one `State` object with ~45
fields and a ~480-line `build()`. It works, but every change risks touching
unrelated behaviour, and none of its orchestration is unit-testable. Suggested
extraction order (each step compiles, passes tests, and changes no behaviour):

- [x] (a) **Frame processing** — pull `_onStreamingData`'s mapping/tracking
  (~448–656) into a plain class (`FrameProcessor`) that takes a stream event
  and returns tracks + stats. This makes the core per-frame logic unit-testable
  (see B8).
- [x] (b) **Session recording** — start/stop sequence, logger wiring, capture
  scheduler wiring (~1038–1219) into a `SessionRecorder`.
- [x] (c) **Camera diagnostics** — the `_fetch*` / `_probe*` cluster
  (~689–863) into a `CameraDiagnosticsController`.
- [x] (d) Move the embedded overlay/dialog widget classes (~2245–2591) into
  `widgets/`.

*Effort:* medium per step; do them in separate rounds.
**Done (round 73), all four steps in one behaviour-preserving pass:** new
`lib/fauna_pulse/session/` holds `FrameProcessor` (detection mapping + tracker
update + motion-gate idle/expire state, injectable clock), `SessionRecorder`
(session folder, JSONL logger lifecycle + appErrorSink routing, capture
scheduler wiring, wakelock/keep-alive, the ordered stop sequence, per-frame
`recordFrame`), and `CameraDiagnosticsController` (the six one-time probes +
lens cycling). The three embedded widgets moved to `widgets/`
(`CalibratingBanner`, `SessionInfoDialog`, `RoiSizeSheet`). The screen keeps
its original vocabulary via thin getters (`_recording`, `_logger`,
`_captureWidth`, `_lenses`, `_gateIdle`, …), so `build()` and all read sites
are textually unchanged; it shrank ~2,870 → ~2,180 lines. Known intentional
micro-deviations: the session/REC timers now start right after
`SessionRecorder.start()` returns (a few ms later than before), and the
once-a-second PERF debug line still reports the previous frame's tracker cost
(as before).

### B7. Silent `catch (_) {}` sites — make failures leave a trace

- [x] ~36 empty catches across the app (probes, platform calls, best-effort
  cleanup — e.g. `camera_session_screen.dart` ~697, ~711, ~749, ~770, ~803,
  ~847; `home_screen.dart` ~105, ~156; `model_catalog.dart` ~116, ~220).
  Most are legitimately best-effort, but when one fails in the field there is
  no evidence anywhere. Route them through `logAppError` (rate-limited) or at
  least `debugPrint`, so "the lens button did nothing all day" is diagnosable
  from the session folder afterwards.
  *Done round 79:* new `logSwallowed(site, error)` in `app_error_hooks.dart`
  (debugPrint at most once per 10 s per site — lands in logcat and therefore
  in `logcat_end.txt` — plus the existing 2 s rate-limited `app_error` JSONL
  line while recording, with the site as `source`). All ~30 legitimate
  best-effort catches now route through it; the three deliberate silents
  remain (the hook's own recursion guard and the two per-line JSONL parse
  guards, now commented "B7-reviewed"). `SessionLogger.close()` uses a plain
  debugPrint (it cannot log to itself). Tests in `app_error_hooks_test.dart`.

*Effort:* small, mechanical.

### B8. Test gaps (in priority order)

- [x] **`RoiCaptureScheduler.evaluate()`** (`roi_capture.dart` ~313–351) — the
  stateful photo cadence (first photo immediately, step/duration windows per
  track, shared photos across concurrent tracks, window cleanup that guards
  against id-reuse double-capture) decides *how many photos land on disk* and
  has zero tests. The pure helpers around it are tested; the scheduler is not.
  *Done round 73:* `test/fauna_pulse/roi_capture_scheduler_test.dart` covers
  first-sight photo + deterministic filename, step interval, duration window,
  shared photo across concurrent tracks, per-track windows for late arrivals,
  blip-survival vs. cleanup boundary, and the in-flight busy skip.
- [x] `SessionLogger` failure path — what happens when the write throws
  (pairs with B1). *Done round 67 (extended round 69 for the async queue).*
- [x] `SessionConfig.fromJson` with the `occlusionSeconds` key absent
  (pairs with B5). *Done round 66.*
- [x] Motion-gate Dart side: `_setGateIdle`'s `expireLostTracks` trigger when
  idle exceeds `occlusionSeconds` (~665–687) — becomes testable after B6(a).
  *Done round 73:* `test/fauna_pulse/frame_processor_test.dart` proves a wake
  after a sleep longer than the tolerance expires lost tracks (returning
  insect gets a fresh id) and a shorter sleep keeps the id revivable; plus
  detection-mapping/clamping and pipeline-FPS tests for the extracted core.

### B9. Minor per-frame hygiene (low priority)

- [x] `_onStreamingData` assigns `_fpsTrioVN.value` on both the gated and
  normal paths (~456 and ~488) and rebuilds two closures per frame
  (~568, ~579). Harmless individually; tidy while doing B6(a). The
  `ValueNotifier`-based UI updates are already the right pattern — keep them.
  *Resolved round 79 without a code change:* the double `_fpsTrioVN`
  assignment became intentional in round 77 (the gate-idle path must zero
  every inference-derived number), and the two closures (`roiToFrame` /
  `clampToRoi`) moved into `FrameProcessor.process` in round 73, where they
  are part of a unit-tested pure function. Two tiny closure allocations per
  processed frame at ≤10 fps are negligible — hoisting them would only hurt
  readability.

---

## Suggested sequencing

1. **B5** (one line) + **B1 guard** + **B2** — a session should never die
   silently. Small, high value, low risk. ✔ **Done** (B5 round 66; B1 guard
   + B2 round 67; B1 batching/queueing round 69 — B1 fully closed).
2. **A1** + **A2** — the two big heat/latency wins in the native path.
   ✔ **Done** (round 68).
3. **B3 + B4** — lifecycle + camera watchdog. ✔ **Done** (round 70).
4. **A3**, then **B6(a)** + **B8** tests. ✔ **A3 done** (round 72; float
   model outputs excluded — LiteRT API limitation, see A3 note).
   ✔ **B6 done in full (a–d) + both open B8 tests** (round 73).
5. **A4** (benchmark) as its own round; ✔ **Done** (rounds 76-78, double checked A7(a) too)
6. **A5/A6/B7/B9** opportunistically.
    - A5/A6 ✔ **Done** (rounds 74-75)
    - B7/B9 ✔ **Done** (round 77, 79)

---

## Part C — Round 128 review against upstream Ultralytics plugin v0.6.10 (2026-07-18)

Trigger: the owner measured the new Ultralytics demo app at **11–12 FPS**
(yolo26n, Xiaomi 2107113SG) while FaunaPulse shows **7–8 FPS** (detector and
pipeline) on the same phone. A fresh upstream copy sits at
`/InsectDetectApp/yolo-flutter-app-main` and was compared file-by-file
against the vendored Ultralytics plugin (`./fauna-pulse/packages/ultralytics_yolo`).

### C0. Verdict of the comparison — nothing big to port (recorded so we never redo this)

Our vendored plugin is the **same generation** as upstream v0.6.10. Every
load-bearing upstream performance feature is already present in our fork:

| Feature | Upstream v0.6.10 | Our vendored plugin |
|---|---|---|
| RGBA_8888 camera output (no YUV→JPEG round-trip) | `YOLOView.kt:786` | `YOLOView.kt:987-992` |
| LiteRT 2.x `CompiledModel`, GPU-first + CPU fallback | `LiteRtModel.kt` | same (plus our crash-guard blocklist) |
| LiteRT artifact version | `litert:2.1.5` | `litert:2.1.5` (identical) |
| GPU program disk cache (skip OpenCL recompile) | 0.6.3 feature | present (`LiteRtModel.kt:186-194`) |
| Reused bitmaps / int / float buffers per frame | `ObjectDetector.kt:74-78` | present (+ our `BitmapFrameBuffer`, A3) |
| Flat-output decode + native C++ NMS via JNI | `native-lib.cpp` | identical |
| Small boxes-only event payload, no annotated bitmaps | default | identical (+ our fire-and-forget slot, A2) |

Both apps also compute the on-screen FPS **the same way**
(`BasePredictor.finishTiming`: exponentially smoothed start-to-start interval
between consecutive detector runs), so 7–8 vs 11–12 is a real difference in
detector cadence, not a bookkeeping difference. Our extra per-frame work
(motion-gate thumbnail <1 ms, frame-cache pointer swap, one orientation read)
does not explain it either.

**The gap is caused by FaunaPulse's own deliberate heat caps interacting
badly — see C1.** Files that diverge from upstream (checked here so a future
upstream sync knows where to look): `YOLOView.kt`, `MotionGate.kt`,
`ImageUtils.kt`, `LiteRtModel.kt`, `Predictor.kt`, `ObjectDetector.kt`.

### C1. [x] Phase-aligned inference FPS cap (the real fix — recommended)

**Problem (plain language).** Two of our defaults collide: the camera
hardware cap (r82) delivers a frame every 66.7 ms (15 fps), and the inference
FPS cap (r58) demands ≥100 ms between detector starts (10 fps). The cap gate
(`shouldRunInference()`, plugin `YOLOView.kt` ~:3058) uses an *elapsed-time*
rule: "skip unless ≥100 ms passed since the last allowed start". After a run
at t=0 the frame at 66.7 ms is skipped (too early) and the next chance is
133.3 ms — every time. The detector locks to one frame in two:
**exactly 7.5 FPS**, which is the 7–8 the owner sees. The Ultralytics demo
runs uncapped on a ~30 fps camera, so it shows the phone's natural yolo26n
loop rate (11–12). We are not slower than upstream — we are throttled below
our own configured budget.

**Fix.** Make the gate a *deadline scheduler*: keep a `nextAllowedStartNs`
that advances by `interval` on every allowed run (clamped up to `now` when
we fall behind, so missed deadlines don't accumulate). A frame arriving at or
after the deadline runs. On a 15 fps camera with a 10-cap this alternates
66.7/133.3 ms intervals and averages a true 10 FPS.

- **Files:** `packages/ultralytics_yolo/.../YOLOView.kt` only —
  `shouldRunInference()` (~:3058-3087), the `lastInferenceGateTime` field
  (~:176, becomes `nextAllowedStartNs`), reset in
  `setupThrottlingFromConfig()` (~:3050). The gate is shared by the gate-off
  (~:2333) and gate-on (~:2504) paths, so one change covers both. Keep the
  r68/A1 invariant: the check stays BEFORE bitmap conversion on the gate-off
  path. Update the comment block above the field (~:174) that documents the
  start-to-start semantics.
- **Benefit:** ~+33% detections/s (7.5 → 10) at the heat budget the user
  already configured. Better visitation-rate resolution for free.
- **Cost:** ~15 lines of Kotlin. Slightly more heat than today's accidental
  7.5 — but 10 was the *chosen* budget, and auto-throttle still rules above
  it. The beat effect exists for any cap/camera pair that isn't an integer
  divisor; the fix removes the whole class, not just 10-on-15.
- **Verify:** with cap 10 + camera 15, on-screen det FPS and per-second `fps`
  records read ~10.0 (today: ~7.5). Uncapped behaviour unchanged.

**Done (round 129):** the gate field is now `nextAllowedInferenceNs` (a
deadline, not a last-start timestamp). An allowed start advances it by exactly
one interval; a stall longer than one interval (gate sleep, settings pause,
slow inference) re-anchors it at `now + interval` so there is never a
catch-up burst. Reset to 0 ("run immediately") in
`setupThrottlingFromConfig()` whenever the cap changes. The r68/A1 invariant
holds — the check still runs BEFORE bitmap conversion on the gate-off path,
and both gate-on/off paths share the one function.

**Field-verified (round 130, session_26 2026-07-18):** at the default cap 10
+ camera 15 (640×480), detector FPS held 9.9–10.2 for 230 straight seconds —
mean 9.97, median 10.01 over the session (pre-fix this exact configuration
was locked at 7.5). Side effect worth knowing: the on-screen *pipeline* FPS
now reads ~11 next to a detector 10.0 — that is a display bias, not extra
speed; see C5.

### C2. [x] Parity benchmark against the Ultralytics demo (no code — owner-run)

To compare our app to the demo apples-to-apples, reproduce its conditions in
FaunaPulse settings: **inference cap 0** (uncapped benchmark mode), **camera
cap 0** (device default ~30 fps), **stream 640×480** (explicit pick),
**motion gate off**, engine **GPU**. Expected: ≈11–12 FPS, same as the demo.
Record the measured number here afterwards. If it matches, the "gap" is fully
explained by C1 + C3 and no pipeline work is owed. If it falls clearly short
(say ≤9), reopen this part — that residue would point at our divergent frame
path (frame cache, gate plumbing) and would justify per-stage timing.

- Test results (at parity settings), date 2026-07-18, 08:22, "session_25"
  
  I adjusted the FaunaPulse settings: "Session settings" > "Camera" tab:

    - "Live stream resolution ..." : 480 x 640
    - "Camera frame rate cap": 0
    - "Auto-adjust inference rate (prevents overheating)": off
    - "Detector rate cap": 0
    - "Motion gate ..." : off
  
  The "Detector FPS over the session" graph showed higher FPS values decreasing 
  from ~16 to ~10 FPS within the first ~70-75 seconds from the start of the recording, 
  while the reported temperature increased from 37 C to 39 C. When that 39 C temp was
  reached, FPS rate had an abrupt drop to around 6.5 FPS and stayed around that value
  until the end of the session (total recording time 2m 48s). The average FPS reported
  under the graph was 9.4 (median 7.2 fps) min 5.9 fps, max 16.1 fps.
  While the phone was still warm, I opened the Ultralytics YOLO app and I have seen
  FPS values even lower than in FaunaPulse, at around 4-5 FPS.
  It looks like **overheating** is our main challenge on both apps. 
  
  Note: I run the FaunaPulse app in debug mode via USB using `flutter run`. This
  might be running slower than the release apk.

**Verdict (round 129):** parity confirmed — better than expected. No pipeline
work is owed to upstream. The abrupt 10→6.5 drop at ~39 °C reported temp is
the Xiaomi's thermal governor (the known invisible SoC throttle), and it
binds BOTH apps — uncapped running just sprints into that wall ~70 s in.
Consequence: the deliberate caps + auto-throttle are the correct field
strategy (they spend the heat budget on purpose instead of letting MIUI
spend it), and C1 makes the capped rate honest. Field sessions add charging
heat (power-bank invariant), so expect the wall sooner than in this test.

### C3. [x] Measure per-frame conversion cost vs stream size (measure first, then decide)

Our auto stream resolution picks 1440×1080 on the Xiaomi (for 1024 px photo
sharpness, r109/r122) vs the demo's 640×480 — ~5× the pixels through the
per-frame RGBA buffer copy, frame cache and ROI raster, all on the single
camera thread. This is invisible today (the C1 cadence lock dominates) but
becomes the next ceiling once C1 lands or caps are raised.

- **How:** the instrumentation already exists — `perfToBitmapNs` /
  FRAMEPERF per-second logcat lines (plugin `YOLOView.kt` ~:2301-2320,
  ~:2340-2347). Run one short session at 1440×1080 and one at 640×480,
  compare the toBitmap ms and achieved FPS from `logcat_*.txt` in the
  session folder.
- **Decision rule:** only if conversion costs >~10 ms/frame at 1440×1080 is
  any action worth it — and the action is guidance, not mechanism: a line of
  Settings help text explaining the FPS ↔ photo-sharpness trade-off (stream
  size is already user-controllable). No new code path.

**Measured (round 130, sessions 26/27 — same defaults, only the stream size
differs; caveat: 27 started 2 °C warmer, 38 vs 36 °C battery):**

- FRAMEPERF `toBitmapMs`: **0.2–0.3 ms at 640×480 vs 4.3–4.5 ms at
  1440×1080.** Under the 10 ms action rule → no mechanism change; keep the
  guidance-only plan.
- The REAL cost of the big stream is **camera/ISP heat**, not CPU
  milliseconds. Per-second `fps` records show the collapse is the CAMERA
  delivery, not the model: in session_27 `camera_fps` already sagged to
  ~9–10 by t≈120 s and crashed to **1.6–3.0 fps** at 41 °C (t≈175–195 s)
  while `inf_ms` stayed 21–25 ms apart from brief 45–154 ms spikes; the
  auto-throttle stepped `applied_cap_fps` 10→6→7→8 and everything recovered
  by t≈200 s (the "sharp rise back to ~8" the owner saw = governor easing +
  auto-throttle recovering, both working as designed). At 640×480
  (session_26) the whole run held det 9.9–10.2 with a single end-of-session
  camera dip to 7.4 at 40 °C. MIUI's thermal governor hits the camera HAL
  hardest — consistent with the r78/r82 finding that the camera is the
  standing heat cost.
- **Practical guidance:** 1440×1080 is fine while the phone stays under
  ~40 °C; expect deeper FPS dips beyond it. If a session doesn't need
  1024 px photos, lowering "Saved photo side" lets the auto stream pick a
  smaller size — less ISP heat, later/shallower throttle.

### C4. [ ] Optional upstream micro-ports (low priority — likely skip)

Two upstream 0.6.8 tweaks we don't have, recorded so they aren't
re-discovered later:

- **Pad-only letterbox clearing** (`clearLetterboxPadding`): upstream paints
  only the padding rectangles black instead of the whole model-input bitmap.
  Our ROI inference path has **zero padding** (square ROI → square input), so
  this saves nothing where FaunaPulse actually runs. Near-zero benefit.
- **Planar-CHW float packing**: upstream writes NCHW directly during RGB
  packing for `litert`-format (torch-exported) models. Only matters if we
  ever switch to NCHW model exports; our current models are NHWC. Skip
  unless the export pipeline changes.
  *r153 correction:* re-entry is THREE pieces, not one. The fork also lacks
  the upstream 0.6.6 NCHW auto-detect prerequisite (input `args_0` /
  `output_N` handling in `LiteRtModel.kt`), so a real adoption ships
  auto-detect + CHW packing + a MODEL_CONVERSION.md update together (see D2
  in Part D). And the failure mode of loading a `format=litert` export today
  is not silent garbage: the load "succeeds" (warm-up uses the runtime's own
  correctly-sized buffers), then every frame throws on a buffer-size mismatch
  (0 fps, endless "Calibrating") while the settings sheet shows the correct
  input size, because `YOLOFileUtils.inputImageSize` has the layout heuristic
  the detector path lacks.

### C5. [x] Pipeline-FPS readout biased high next to an honest detector FPS (display fix, small)

Found while verifying C1 (session_26): the screen shows pipeline ~11.0–11.9
beside detector 10.0. The pipeline number is computed in Dart
(`updatePipelineFps`, `lib/fauna_pulse/session/frame_processor.dart`
~:133-149) as an EMA of the *instantaneous rate* `1000/dt`. C1's deadline
scheduler produces alternating frame gaps (66.7/133.3 ms on the 15 fps
camera): the average of the two instantaneous rates is (15 + 7.5)/2 ≈ 11.25
even though the true throughput is exactly 10. Averaging rates over-weights
the short gaps (Jensen's inequality); the native detector FPS avoids this by
EMA-ing the *interval* and inverting once (`Predictor.finishTiming` `t4`).

- **Fix:** make the Dart side mirror the native math — EMA the interval `dt`,
  display `1000/emaDt`. Same file/function; keep the r85 resume-gap guard
  (threshold logic unchanged — it already works on `dt`) and the
  "KEEP IN SYNC" comment pair with the native EMA. Update the
  `frame_processor` unit test expectations.
- **Why bother:** owner rule — on-screen numbers must not mislead
  (`ui-numbers-one-scale`); today "pipeline 11 > cap 10" suggests
  the pipeline outruns the cap, which is impossible. Historical logs are
  unaffected (raw per-second records store what was shown; the summary graph
  reads `pipeline_fps ?? fps`, so post-fix sessions just plot the corrected
  number).
- **Cost:** a few lines of Dart + test update. No native change, no schema
  change.

**Done (round 131):** `updatePipelineFps` now EMAs the inter-frame interval
(`_pipelineIntervalEmaMs`, same 0.1/0.9 weights as before) and
`pipelineFpsEma` inverts it once for display — the same math as the native
`t4`. The r85 resume-gap guard is unchanged in behaviour (`5×` the smoothed
interval, now expressed directly on the interval instead of `5000/fps`), and
the KEEP IN SYNC comment pair with `Predictor.finishTiming` stands. Tests
updated for interval semantics + a new test proving the alternating
67/133 ms cadence reads ~10.0 (the old rate-EMA read ~11.2).

---

## Part D: Round 153 re-audit against fresh upstream main (2026-07-27)

Trigger: the owner re-downloaded the current upstream main branch to
`/InsectDetectApp/yolo-flutter-app-main` and asked whether newer upstream code
offers pipeline FPS or efficiency gains. Method: three parallel read-only
exploration agents (native Android delta, Dart delta, fresh hot-path sweep),
20 candidate findings, the top 10 each adversarially verified against the code
and this document; 4 survived. Owner decision (r153): recorded as proposals
only, no code changed this round.

### D0. Verdict (recorded so this is never redone)

The fresh copy is **v0.6.10, the same release Part C reviewed on 2026-07-18**.
Android dependencies are byte-identical (litert 2.1.5, CameraX 1.6.0,
onnxruntime-android-qnn 1.26.0). The Dart `lib/` delta 0.6.4 to 0.6.10
contains zero performance work (the depth-estimation task and docstrings).
The C0 parity table stands unchanged: there are **no live-path FPS gains to
port**, and the FPS ceiling remains the thermal governor (C2). The items below
are the modest survivors: one smoothness fix, one capability/workflow fix, one
offline-path waste removal.

### D1. [x] Move the fast ROI photo crop off the platform/main thread

`YOLOPlatformView.kt` registers its method handler with no TaskQueue (~:85),
so the `"captureRoiFromFrame"` branch (~:654-665) runs
`ImageUtils.cropRoiFromFrame` (bitmap alloc, rotate-draw, optional rescale,
JPEG encode) on the thread that also drains detection results to Dart. Cost
per photo: ~8-15 ms at the default 640x480 stream, ~20-50 ms at 1440x1080, at
~1 Hz during visits (the fast path is the default capture mode; the high-res
sync companion adds one crop per photo). This is the one capture entry point
that stayed synchronous (the r72/A3 note described its caller as "the
platform-channel thread", which is why it was never spotted as main-thread
work).

**Fix:** run `yoloView.captureRoiFromFrame(...)` on the existing
`stillExecutor` and post `result.success`/`result.error` back on a main-thread
handler, the same pattern as `capturePhotoRaw` (`YOLOView.kt` ~:1985-2010, the
round-63 lesson at ~:348-356) and the app crop channel (`MainActivity.kt`
~:135-145).

*Expected gain:* smoothness, not throughput. Removes an 8-50 ms main-thread
hitch per photo; box delivery and preview stop stuttering during captures. No
effect on the thermal ceiling.
*Effort:* ~10 lines, ~30 min. On-device check: photos at 1 Hz while watching
box smoothness, once at 640x480 and once at 1440x1080.
*Cautions:* the `synchronized(bitmap)` guard already covers off-thread use;
the deferred grab reads a slightly newer frame (companion freshness improves);
do NOT convert the whole method channel to a background TaskQueue (other
handlers touch camera/view state).

**Done (round 154):** new `YOLOView.captureRoiFromFrameAsync` mirrors the
`capturePhotoRaw` contract: work on `stillExecutor` (single-threaded, so crops
stay serialized behind any in-flight still job), callback always on the main
thread, null on failure (exceptions caught + logged, mapped to null, which the
Dart `_invoke` wrapper already treats as the normal "fast path failed"
fallback). The `"captureRoiFromFrame"` handler completes its MethodChannel
result from that callback instead of blocking. No Dart changes, no new
tunable. Verified: `flutter analyze` clean, 356 tests pass, debug APK builds;
the on-device smoke test (photos at ~1 Hz watching box smoothness, at 640x480
and 1440x1080) is the owner's step.

### D2. [x] format=litert (NCHW) model support, staged (capability fix, zero live-path effect)

`yolo export format=litert` is now the documented Ultralytics Android export
route (0.6.6+, official w8a32 assets). Such a model in FaunaPulse today
*appears to load* (warm-up uses the runtime's own correctly-sized buffers),
then throws on every frame: 0 fps, permanent "Calibrating", while the settings
sheet correctly shows 640x640 (`YOLOFileUtils.inputImageSize` ~:213-219 has
the layout heuristic the detector path lacks). Not reachable via the shipped
defaults (bundled URLs pin the NHWC v0.3.5 assets; MODEL_CONVERSION.md says
`format=tflite`), but reachable the moment anyone imports such a model or
pastes a current official asset URL (`model_catalog.dart` ~:254 accepts any
.tflite).

- [x] **Stage A (subsumed r155, never built), loud load-time guard (~10 lines, do first):** in
  `LiteRtModel.prepareModel` after dims resolve (including the graph
  fallback, ~:207-225), detect NCHW (`dims.size >= 4 && dims[1] == 3 &&
  dims.last() != 3`) and fail the load with a plain-language message
  ("re-export with format=tflite"). A load failure flows through the existing
  r151 `onInitialModelLoadFailed` recovery (error dialog + config revert) for
  free. Highest value per line in this Part.
- [x] **Stage B, full detect-only support (~60 LOC, 4 files; do at the next
  model-export cycle):** port upstream's layout handling
  (`yolo-flutter-app-main/.../LiteRtModel.kt` ~:124-181): input-name probe
  (`images`, `args_0`, `input`, `input_1`, `serving_default_input`), NCHW
  detection with NHWC-convention `inputDims` plus `inputUsesNchw`;
  output-name probe `output_$i` then `Identity`/`Identity_$i`; `Predictor.kt`
  exposes `inputUsesNchw` (~3 lines); `ImageUtils.copyRgbBitmapToFloatArray`
  gains a `channelsFirst` branch that MUST use the fork's `normalizationLut`
  (~:458), not upstream's invStd multiply (~18 lines); `ObjectDetector.kt`
  1-line call arg. This is the C4 escape clause firing, not a re-proposal.
  Merge hazards a verbatim upstream copy gets wrong: (1) the fork-only graph
  fallback (`YOLOFileUtils.inputTensorShapeFromPath`) must ALSO pass the NCHW
  test (reuse the heuristic already in `inputImageSize` ~:213-219); (2) keep
  the fork's graph fallback, upstream's `sqrt(count/3)` buffer-size guess is
  strictly worse. Deliberately skipped: Segmenter `protoNchw`, the other
  predictors, the OrtQnn transpose cleanup (detect-only app, diff inflation
  against the readability rule). Then simplify `MODEL_CONVERSION.md` to one
  command: `yolo export format=litert quantize=w8a32` (dynamic-range
  quantization, no calibration dataset, embedded Ultralytics metadata;
  requires `ultralytics>=8.4.83`); keep full-INT8 documented for low-end CPUs
  (the Galaxy M12 datapoint stands, w8a32's FP32 activations are not the
  fastest CPU path). Verify on-device with a fresh w8a32 export.

**Done (round 155), Stage B implemented directly at the owner's request, which
subsumes Stage A** (NCHW models now load and run, so there is nothing to guard;
the one remaining failure edge, a model matching no known input name whose graph
shape also can't be read, behaves exactly as before). Port honoured all three
r153 hazards: NCHW is detected AFTER the fork-only TFLite-graph fallback so both
resolution paths pass the test; the graph fallback is kept over upstream's
sqrt(count/3) guess; the `channelsFirst` CHW branch uses the fork's cached
`normalizationLut`. `InferenceModel.inputUsesNchw` defaults false, so OrtQnnModel
keeps its internal transpose untouched (the deliberate skip stands). The LiteRT
compile log line now prints `layout=NCHW|NHWC` for field diagnosis.
MODEL_CONVERSION.md leads with the one-command `format=litert quantize=w8a32`
export; full INT8 stays documented for low-end CPUs. Verified: `flutter analyze`
clean, 356 tests pass, debug APK builds. On-device verification (owner): Settings
→ AI → Model → Download… with
`https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.6.6/yolo26n_w8a32.tflite`,
confirm boxes appear, logcat shows `layout=NCHW`, and run the engine benchmark.

### D3. [x] Skip the discarded annotated image on the batch/SAHI predict path

Every `YOLO.predict` call (post-hoc photo analysis and each SAHI tile) makes
the native side draw all boxes onto a full `bitmap.copy(ARGB_8888)`
(`YOLO.kt` ~:239; the ~:215 early-out never fires for DETECT) and
JPEG-q90-encode it (`YOLOPlugin.kt` ~:453-458); FaunaPulse reads only the box
list and throws the bytes away. Upstream 0.6.10 has the same behaviour, so
this is a parity gap, not a port.

**Fix:** optional `includeAnnotatedImage` param on `yolo_inference.dart`
`predict()` (default `true` for compatibility), threaded through
`predictSingleImage` / `YOLOInstanceManager.predict` / `YOLO.predict`;
`post_detector.dart` passes `false`; the plugin demo screen keeps the default.

*Expected gain (honest):* ~3-6 ms per 640 tile against ~30-40 ms
decode+inference (roughly 10-20% of batch wall time; the SAHI isolate's own
Dart `encodeJpg` per tile is the bigger cost), ~15-25 ms on the full-image
pass of a 1440x1080 photo, plus ~100 KB less per tile over the method channel.
Offline path only, no heat-budget interaction; saves some heat on long
unattended batch runs. Measure batch wall-clock before/after on the Xiaomi.
*Effort:* ~30 lines across 5 files, 1-2 h.
*Cautions:* do NOT bundle a `Dispatchers.IO` hop for `predictSingleImage`
(`YOLOInstanceManager.predict` mutates and restores per-instance thresholds
around the call; concurrency there is a correctness risk). Known observation,
recorded, no action: batch inference blocks the platform thread ~30-60 ms per
tile (progress-UI jank only).
*Tests:* assert the flag in the `predictSingleImage` args from
`post_detector_test.dart` / `sahi_test.dart`; assert the default stays `true`.

**Done (round 156):** `includeAnnotatedImage` param (default `true`) on
`YOLO.predict` / `YOLOInference.predict`; the wire key crosses the channel ONLY
when false, so the native default keeps the demo screen and older callers
byte-identical. Kotlin chain: `YOLOPlugin.predictSingleImage` reads the flag →
`YOLOInstanceManager.predict(generateAnnotatedImage)` → `YOLO.predict` skips
`drawAnnotations` (the JPEG-encode block is null-guarded and skips itself). The
analysis screen's base PredictFn passes `false` (applies to plain and SAHI
analysis; PostDetector and sahi.dart are unchanged, they see only the
PredictFn). The Dispatchers.IO hop stays NOT done, per the D4 record. Tests:
`test/fauna_pulse/predict_annotated_image_test.dart` pins the wire contract.
Verified: analyze clean, 359 tests pass, debug APK builds. Owner measurement:
re-run "Analyze saved photos" on a large session and compare wall time with a
pre-r156 run of the same session and settings.

- Test results (at parity settings), date 2026-07-28, 10:35, "session_29"
  
  FaunaPulse settings: "Analyze saved photos":

    - Session: session_29 [AI live] - 228 photos
    - Detection model: arthropod_yolov11_int8.tflite
    - Confidence threshold: 0.25
    - IoU threshold: 0.70
    - Small-insect tiling (SAHI): on
    - Keep time-window around a detection: 0.0 seconds (s)

  The gain before-after varied from 2-3% to 8-10%. The run before D3 implementation
  gave around 920-930 ms processing time per image. After D3, I saw ~900 ms/img
  in a first test and then 830-855 ms/img in a second test, when the phone
  was a bit cooler. Time between runs matter, as the second run can be affected by the
  overheating of the first run. Let at least 10 min between test runs on the same
  images of the tested session. It looks like overheating of the Xiaomi phone remains
  the main driver of performance.

### D4. Skipped leads (recorded so they are not rediscovered)

- **Wholesale re-sync to upstream 0.6.10:** no performance content; a
  block-copy would silently delete fork-only assets. Re-sync hazard
  inventory: `yolo_model_resolver.dart` is the most diverged Dart file; the
  fork-only 256-entry `normalizationLut` exists only in our `ImageUtils.kt`;
  upstream `YOLOTask` gained a depth entry (index shift, safe: task crosses
  the channel by name).
- **Micro items (skip unless touched incidentally):** per-frame
  `overlayView.invalidate()` although FaunaPulse permanently disables the
  native overlay; the `tracks` ValueNotifier fires every detector frame even
  when nothing is detected. Both immaterial at 10 fps.
- **`Dispatchers.IO` for `predictSingleImage`:** correctness risk, see D3.

## Part E: Round 160 codex re-audit against upstream v0.6.11 and broader efficiency review (2026-07-31)

Provenance: these proposals were authored by codex (OpenAI) on 2026-07-31 from a
read-only repo audit, then adversarially verified by Claude in round 160 (three
parallel exploration agents plus firsthand spot-checks; every file:line reference
below was re-checked against the code). The verification found the codex plan
nearly hallucination-free; E7's first bullet was reworded (false premise) and
E0/E1/E9 carry small factual amendments. Every proposal stays UNCHECKED until
implementation, tests, and measurements are complete (codex's own instruction).

### E0. Verdict: upstream v0.6.11 and rejected leads (recorded so this is never redone)

- The on-disk upstream copy at `/InsectDetectApp/yolo-flutter-app-main` is now
  **v0.6.11** (pubspec:5). Its only change after 0.6.10 is an iOS float16
  object-decoding fix (CHANGELOG top entry): no Android CameraX, LiteRT,
  ORT/QNN, or live-pipeline changes. The D0 parity conclusions are unaffected.
  Part D's "v0.6.10" statements are historical (true when written on
  2026-07-27) and are deliberately NOT rewritten.
- The vendored plugin's pubspec still says `version: 0.6.4`. That is a stale
  label, not the audit state: parity against 0.6.10 was established in Parts
  C/D (D1-D3 selectively ported r154-156). E10's FAUNAPULSE_FORK.md should
  record base version + audit dates so the label stops misleading.
- Rejected leads, do not re-investigate: wholesale plugin synchronization,
  task-specific segmentation/depth/pose changes, tracker rewrites, overlay
  micro-optimizations, direct CameraX RGBA-to-tensor conversion, speculative
  AHardwareBuffer zero-copy work.
- Output-buffer reuse stays unavailable: LiteRT's current `TensorBuffer`
  exposes array-returning reads only, no destination-buffer API
  (https://ai.google.dev/edge/api/litert/kotlin/com/google/ai/edge/litert/TensorBuffer;
  the page could not be fully re-fetched on 2026-07-31, low stakes since this
  only keeps an already-rejected idea rejected).

### E1. [ ] Establish a reproducible performance baseline

- Add `docs/PERFORMANCE_BENCHMARKING.md` + a `tool/perf_summary.dart` parser
  (neither exists yet). The parser streams one or more session JSONL files and
  emits CSV/Markdown: camera/detector/pipeline FPS; pre/inference/post/tracking
  medians and p95; temperature/headroom; cap changes; gate-idle fraction;
  power/energy only where valid (unplugged sessions, the r84 rule); error
  counts. Precedent for offline session parsing incl. the dart-define pattern:
  `tracking/tracker_replay.dart`.
- Protocol: profile or release builds, fixed model hash, scene, mount, camera
  mode, FPS settings, screen state, charging state, ambient conditions,
  starting temperature. Three paired A/B runs with alternating order; separate
  cold startup from the final sustained interval. Cross-link (do not restate)
  the existing benchmarking material in A4, C2, C3 and the D3 field notes.
- Device caveat (r160 amendment): the Xiaomi deploys as a debug build (MIUI
  quirk) while the Samsung is the release-test phone (r158 convention), so the
  protocol must state per table which device/build produced each number. The
  Samsung's `battery_current_ua` is broken (r132): battery-% drop only.
- RUN_BENCH define bug: `integration_test/qnn_benchmark_test.dart:22` uses
  `bool.fromEnvironment('RUN_BENCH')`, which is false unless the value is
  exactly `true`, while the in-file instructions said `--dart-define=RUN_BENCH=1`
  (silently skips the bench). Comment fix landed r160; `RUN_SOAK` (:23) had the
  same trap and is now documented. Still open for this item: the bench
  downloads `_v81_qnn.onnx` (:180) while validation uses `_v73` (:105), and per
  r151 neither Hexagon arch can run on the Xiaomi (SD888 = v68), so QNN rows
  are other-device only; keep QNN/network/soak tests explicitly opt-in and keep
  the pinned v0.3.5 assets for reproducibility.
- Acceptance rule: adopt an optimization only when three paired runs agree and
  the gain exceeds run-to-run variation. For capped modes: equal useful
  delivered FPS plus at least 5% lower power, or materially delayed thermal
  collapse.
- Benefit: publication-grade evidence, protection against optimizing
  debug-build noise. Cost: ~1 day, no runtime overhead.

### E2. [x] Port upstream's deterministic native predictor cleanup

- Verified defect: vendored `YOLOInstanceManager.kt:169-180` `dispose()` holds
  an EMPTY try block with the comment "YOLO class doesn't have a close()
  method, just remove from map", so every dispose leaks the native LiteRT
  interpreter/delegates/buffers until GC maybe finalizes them. Vendored
  `YOLO.kt` has no `close()` at all. Vendored `YOLOPlugin.kt:634` launches on
  `GlobalScope`. This matters most for the r135+ batch analyze/cancel/
  re-analyze flows, which dispose predictors repeatedly.
- Port from upstream 0.6.11: idempotent synchronized `YOLO.close()` closing its
  BasePredictor (upstream `YOLO.kt:730-734`); `YOLOInstanceManager.dispose()`
  removes the instance then closes it on `Dispatchers.IO` (upstream
  `YOLOInstanceManager.kt:116-119`); synchronized predict with temporary
  thresholds restored in a real `finally` (upstream `:90-104`, the vendored
  copy restores in try/catch so a non-Exception Throwable corrupts them);
  reject prediction after close. Replace GlobalScope with a plugin-owned
  SupervisorJob scope cancelled on engine detach (upstream pattern:
  `pluginScope` created at attach, `pluginScope.cancel()` on detach), and on
  detach close every instance and clear method/event channels.
- Second phase (executor ownership): `stillExecutor` (`YOLOView.kt:356`) is
  never shut down; model loading spawns throwaway
  `Executors.newSingleThreadExecutor().execute` (`YOLOView.kt:801`, needs one
  owned executor + a generation token so stale loads are closed); `cropExecutor`
  (`MainActivity.kt:47`) needs shutdown from `onDestroy()`. Do NOT touch
  `cameraExecutor`: it is already drained on rebind and stop.
- Preserve: FaunaPulse's `includeAnnotatedImage` behavior (D3), the r151
  model-load recovery path, and the fork's 3-entry predictor LRU cache
  semantics (see E9).
- Validate: 20 repeated analyze/cancel/reanalyze cycles, dispose-during-
  prediction, double-dispose, engine detach/reattach, native heap/thread
  plateau via `dumpsys meminfo` and `ps -T`.
- Benefit: long-running robustness (bounded native memory/threads), not frame
  time. Cost: 0.5-1 day predictor cleanup, 1-2 days executor ownership.

**Done (round 161), both phases in one round.** Predictor lifecycle:
`YOLO.kt` gained the explicit lazy delegate + closed flag, `@Synchronized`
`predictorInstance()`/`predict(bitmap)`/`close()`; `close()` releases the
BasePredictor (LiteRT interpreter / ORT session) once, idempotently, and any
predictor access after close fails fast (IllegalStateException, surfaced by
the existing channel catches as `prediction_error`). `YOLOInstanceManager.kt`:
maps are ConcurrentHashMaps, `predict()` is `synchronized(yolo)` with the
thresholds restored in `finally` (survives non-Exception Throwables too),
`dispose()` is suspend + remove-from-maps-FIRST then close on
`Dispatchers.IO`, `disposeAll()` hands every close to the IO dispatcher; the
`removeInstance` alias was deleted (single caller updated). `YOLOPlugin.kt`:
plugin-owned `pluginScope` (SupervisorJob + Main.immediate) created on
attach, cancelled on detach; detach also clears all instance-channel
handlers and calls `disposeAll()`; `disposeInstance`/`predictorInstance` run
in that scope (GlobalScope is gone). Executor ownership: one owned
`modelLoadExecutor` replaces the throwaway per-`setModel()`
`newSingleThreadExecutor` (which parked one non-daemon thread per model
switch); a generation token makes superseded loads step aside (finished
predictor goes into the bounded LRU cache, NOT installed) and loads that
finish after permanent disposal close themselves; completions run on a
main-looper handler DELIBERATELY instead of `View.post` (a detached view
parks View.post runnables until a re-attach that never comes, which would
strand the freshly built predictor unclosed). New terminal
`YOLOView.release()` (called from `YOLOPlatformView.dispose()` after
`stop()`) shuts down `modelLoadExecutor` + `stillExecutor`; `stop()` itself
stays restartable and was not changed. CameraX `takePicture` now gets a
rejection-tolerant wrapper executor (a capture-error callback delivered
from the camera thread just after `release()` is dropped, not crashed).
`MainActivity.onDestroy()` shuts down `cropExecutor`. Preserved:
`includeAnnotatedImage` (D3), the r151 model-load recovery /
`onInitialModelLoadFailed` flow, predictor LRU cache semantics, and the
already-correct `cameraExecutor` handling (untouched). Verified: analyze
clean, 363 tests pass, debug APK builds. The on-device validation pass
(repeated analyze/cancel/re-analyze + model-switch soak while watching
`dumpsys meminfo` native heap and `ps -T` thread count plateau) is the
owner's step.

### E3. [ ] Park CameraX between long time-lapse bursts

- New `SessionConfig.timeLapseCameraSleep`, UI "Turn camera off between
  bursts", default false. Owner rule applies: Settings control + SessionConfig
  JSON + summary row + round-trip test in the same round.
- Extract a tested `TimeLapseCameraCoordinator` from
  `screens/camera_session_screen.dart` with explicit running / parked /
  warming / fallbackBound states. The machinery exists: r94 scheduled sleep
  already fully unbinds via `_controller.pause()` and resumes via
  `_controller.resume()` (`camera_session_screen.dart:1904-1943`), and the
  post-resume frame-arrival deadline `_waitForFrames(Duration(seconds: 20))`
  (`:1933`) is the "wake allowance" to reuse. No coordinator/parking logic
  exists today; `time_lapse_plan.dart` stays pure schedule math.
- Park only when time-lapse is non-continuous and the idle gap is at least
  30 s. Unbind after a burst; resume ~10 s before the next wall-clock burst;
  invalidate cached native frames and wait for a fresh frame generation/
  timestamp before capturing (today the between-burst 1 fps sampler keeps the
  frame cache fresh for the burst's first photo, `:2624-2637`; parking removes
  that, so staleness must be handled explicitly).
- Late wake: preserve the original time grid. If no fresh frame arrives within
  the 20 s allowance: record the failure, leave the camera bound, disable
  parking for the rest of the session. Suppress the dead-camera watchdog
  (`_checkCameraDelivery`, 10 s silence threshold, `:1173-1191`) ONLY while
  explicitly parked; today the native 1 Hz heartbeat keeps it quiet between
  bursts, so parking would otherwise trip it within 10 s.
- New compact `camera_sleep` JSONL records {state, reason, scheduled burst
  time} so a scientific audit can tell intentional inactivity from camera
  failure. Existing readers ignore unknown record types.
- Update session config/settings/summary display, FIELD_GUIDE,
  SETTINGS_REFERENCE; warn that the preview freezes while parked.
- Validate: fast and high-res capture, manual and auto focus, blackout,
  scheduled windows, stop/dispose during wake, Doze lateness, stale-frame
  prevention, fallback behavior, on both test phones.
- Benefit: at the default 10 s burst / 30 min interval, camera-bound duty falls
  from 100% to ~1.1% including prewake (20 s per 1800 s). Whole-device savings
  smaller (foreground service + wakelock remain). Live detector mode unchanged.
  Cost: 3-5 days plus paired one-hour field runs.

### E4. [ ] Experiment: hardware camera cap while the motion gate sleeps

- Step 1 (cheap, do first): log every supported Camera2 AE FPS range plus the
  requested/applied range. `chooseAeFpsRange()` already reads
  `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES` (`YOLOView.kt:1865`) but discards
  the list; the existing applied-range log line only fires on change. No UI
  until a lower legal range is proven on hardware (the Xiaomi is known to
  accept a fixed [15,15]; whether anything like [5,15] or [5,5] exists is the
  open question).
- Design (r160 amendments): keep the user's configured ceiling separate from a
  new effective-cap field so the r82 single-funnel invariant holds and the
  user's value is never clobbered; when the gate goes idle, request
  min(configuredCap, 5) once on the state transition (`gateAwakeUntilNs`
  transitions exist, wake at `YOLOView.kt:2471`); restore immediately on
  motion, ROI change, gate disable, or capture preparation. The gate code runs
  on the camera executor while interop options are applied from main/bind
  paths, so post the funnel call to the main thread.
- If proven: expose `reduceCameraFpsWhileMotionGateIdle`, default false, in the
  gate-sensitivity advanced fold (Power tab). Independent from the inference
  cap controller.
- Reject on: only [15,15]-style fixed ranges, under 10% camera/power reduction
  in paired release tests, worse low-light behavior, delayed high-res capture,
  or missed events.
- Benefit: sensor/ISP heat reduction during empty-ROI periods, possibly better
  sustained active FPS later. No instantaneous FPS gain. Cost: 1-2 days plus
  Xiaomi/Samsung A/B.

### E5. [ ] One streaming session-log index + bounded error sampling

- Verified: `screens/session_summary_screen.dart` (4208 lines) does three full
  `readAsLines()` parses of session.jsonl on the UI isolate (`:374` graphs +
  track spans + diagnostics, `:600` photos, `:1001` ROI history) plus a full
  `readAsString()` of post_detections.jsonl (`:187`). The parses are lazy
  (tab-triggered), so this is jank/heap relief on long sessions, not a crash
  fix.
- Introduce an immutable internal `SessionLogIndex` built OFF the UI isolate
  from `File.openRead()` + UTF-8 decode + `LineSplitter`; cache one future per
  summary screen; graphs, photos, ROI history, diagnostics and track spans all
  consume it. Keep the existing bounded head/tail stats path (`_loadStats()`
  `:288-336`; same pattern in home_screen and analysis_screen). A second
  streaming pass only for high-res frame-bracket matching. Move parsing/
  aggregation out of the widget into a pure logging/repository component.
  Preserve legacy `detection` vs batched `detections` semantics (`:385-395`)
  and tolerate malformed/truncated final lines.
- Separately: `ErrorReporter._sampledLog()` (`logging/error_reporter.dart:273`)
  reads the WHOLE file (its docstring says so) before `headTailSample` keeps
  30+200 lines. Replace with a bounded random-access head/tail reader; redact
  only retained lines.
- Validate parity against the existing parser for detection, raw-detection,
  gate, ROI, photo, time-lapse and ground-truth records; 100k-line unit
  fixtures + a large integration fixture, with no file-sized `List<String>` and
  no UI-isolate JSON decoding.
- Benefit: bounded heap, one parse instead of three, responsive summaries,
  safer error reporting after long sessions. No live FPS change. Cost: 2-3
  days for the index, under half a day for bounded error sampling.

### E6. [ ] Native tiled-image API only if SAHI profiling justifies it

- Step 1: instrument SAHI phases (source decode, tile crop/JPEG encode, channel
  transfer, native tile decode, inference, merge). Today the only timing is the
  lumped per-photo `infer_ms` (`postprocess/post_detector.dart:281`); no
  Stopwatch exists anywhere under `postprocess/`.
- Gate: continue only if tile preparation plus JPEG round trips are at least
  15% of wall time on cooled paired runs. Bounding note (r160): tile prep
  already runs in a background isolate via `compute()` (`sahi.dart:202`), so
  the candidate win is the per-tile `encodeJpg` (`:186`), the per-tile
  `predictSingleImage` channel round trip, and the native re-decode; the D3
  field data says Xiaomi heat dominates SAHI wall time, so this gate may well
  fail, and that outcome should be recorded as a skipped lead.
- If justified: add `predictTiledImage` to the vendored plugin (decode the
  source JPEG once, sequentially crop + infer one tile at a time, recycle
  temporary bitmaps, return source dimensions + tile rectangles + per-tile
  detections; never parallelize access to the mutable predictor). Keep
  coordinate mapping, minimum-box filtering, IoS merging and all scientific
  behavior in pure Dart (r141/r143 semantics); keep the current per-tile path
  as the fallback.
- Validate: mapped-box parity, thresholds restored after failure, cancellation
  between tiles/photos, decode errors, fallback, peak heap, absence of
  annotated-image bytes (D3).
- Benefit: ~10-25% lower SAHI wall time and bounded tile memory, SUBJECT TO
  MEASUREMENT; offline only, no live-camera effect. Cost: 2-4 days plus
  increased fork-maintenance burden.

### E7. [ ] Three small cleanups (first bullet reworded after verification)

- Coalesce the thermal/power reads (REWORDED r160: codex's original premise,
  frequent headroom calls risking the Android NaN throttle, is FALSE: the
  single call site `MainActivity.kt:648-657` is driven by two Dart timers both
  defaulting to 10 s, ~2 calls per 10 s, nowhere near the ~1/s limit). What
  remains worth doing: both timers hit the same channel, so share one native
  sample per tick, stamped with a monotonic clock; this also covers the
  user-configurable 1 s minimum interval, the only case where the rate limit
  could ever matter.
- C++ NMS early break: `native-lib.cpp:79-93` collects every surviving
  proposal and truncates only afterwards (`:153`, `num_items_threshold`,
  default 30). Inputs are pre-sorted (`:147`), so breaking once the threshold
  is reached is byte-identical. C++ path only; the Kotlin
  `postprocessEndToEnd` already breaks early (`ObjectDetector.kt:252`).
  Require an exact-parity test; expect a benefit only on noisy frames with
  more than 30 surviving proposals.
- Batch-analysis progress at most ~5 Hz: today an unthrottled per-photo
  callback lands in `setState` (`post_detector.dart:299-304` →
  `analysis_screen.dart:370-377`). Keep per-photo cancellation and the
  mandatory final/cancel updates; only matters when photos process fast.
- Benefit: tidier telemetry, a crowded-frame postprocessing micro-gain,
  smoother fast batches. Cost: ~1 day total. None of these are live-FPS gains.

### E8. [ ] Document the lean QNN packaging alternative (document only)

- Measured (r160, release APK 116.5 MB): the ORT/QNN stack is 21 arm64-v8a
  libs, 75.7 MB in-APK (deflated) / 224.3 MB uncompressed, ~62% of the APK;
  `libQnnHtpPrepare.so` alone is 90.4 MB uncompressed. `useLegacyPackaging =
  true` (app build.gradle:91-97) additionally extracts these to
  `nativeLibraryDir` at install (the Hexagon DSP loads Skel libs via real file
  paths), so the on-device cost is roughly APK + extracted copies. The plugin
  declares the dep `compileOnly` (plugin build.gradle:94-97); the app's two
  `implementation` lines (app build.gradle:150,153) are the single opt-in
  point, which makes a lean variant genuinely easy.
- Preserve the accepted single-capability-build decision (RELEASE_PLAN
  "keep useLegacyPackaging ... accept the size cost") unless the owner
  explicitly reopens distribution policy. Part E documents the lean
  alternative WITHOUT implementing it:
    - Default build omits the QNN deps and uses `useLegacyPackaging = false`.
    - `-Pqnn` / `ENABLE_QNN=1` produces a separately labelled QNN artifact.
    - Native `isQnnRuntimeAvailable` capability query (safe class/provider
      detection); the model picker must explain that `*_qnn.onnx` needs the
      QNN build (extend the r151 `modelLoadRecovery` path) rather than accept
      a model that cannot load.
    - Prefer an App Bundle for Play; QNN APK for advanced users via GitHub.
- Benefit: major download/install reduction for standard users; zero runtime
  effect when QNN is unused. Cost: 1-2 days plus the REAL ongoing cost, a
  two-artifact release matrix.

### E9. [ ] Three controlled camera experiments (build-time A/B, not defaults)

- Fast-mode ImageCapture unbind: all three use cases currently bind
  unconditionally (`YOLOView.kt:1091-1097`) with the ZSL ring buffer alive,
  while fast live-frame crops are the DEFAULT photo mode that never uses
  ImageCapture. Retain only if visit/reference photos, lens switching, resume,
  CALIBRATION (the startup full-res photo probe uses ImageCapture) and the
  auto/high-res fallback all stay correct, and PSS or camera power improves
  materially.
- PreviewView PERFORMANCE mode: correction (r160), the fork EXPLICITLY sets
  `ImplementationMode.COMPATIBLE` (`YOLOView.kt:265-267`); CameraX's default
  is PERFORMANCE, so this was a deliberate opt-out, almost certainly for
  Flutter platform-view layering. First recover why, then try PERFORMANCE in
  one experimental build; retain only if every ROI control/overlay stays
  visible and GPU/power improves at least 5%.
- Predictor cache 3 → 1 (`predictorCacheLimit`, `YOLOView.kt:730-732`,
  fork-local LRU): measure native/graphics PSS after loading three models;
  reduce only if materially elevated; slower switching back is the accepted
  tradeoff.
- Cost: 0.5-2 days each.

### E10. [ ] Documentation truth pass

- Add `packages/ultralytics_yolo/FAUNAPULSE_FORK.md`: upstream base (commit
  `22b2e5d`, label 0.6.4) vs last audited version/date (0.6.10 Part C/D,
  0.6.11 glanced r160), selectively ported changes (D1-D3, E2 when done),
  fork-only invariants, safe re-audit checklist. Add a short fork banner to
  the plugin README (currently VERBATIM upstream: Ultralytics badges, zero
  fork markers).
- Replace `lib/fauna_pulse/README.md`: it is a Phase-1 snapshot ("the plugin
  itself is untouched" contradicts ARCHITECTURE §5; the code map misses
  `perf/ postprocess/ services/ session/`; the schema section predates the r69
  one-line-per-frame change). ARCHITECTURE.md's intro points readers at it, so
  the staleness propagates.
- Replace `test/README.md`: verbatim upstream boilerplate whose commands
  reference a nonexistent `example/` directory; document the real commands
  (`flutter test test/fauna_pulse`, the replay harness, integration tests with
  WORKING dart-defines, see E1).
- CONTRIBUTING.md: "the app deploys as a debug build" is stale since r158
  (Samsung = release-test phone); benchmarking guidance should point at
  E1's protocol. Fix the doc-index bugs: duplicate AGENT_CHANGELOG.md row
  (the first should be AGENT_CHANGELOG_OVERVIEW.md) and missing
  RELEASE_PLAN.md + MODEL_CONVERSION.md rows.
- FIELD_GUIDE.md / DATA_GUIDE.md: verify telemetry cadence and omission
  semantics (r77 gate-idle fps omissions, r149 always-on diagnostics) and
  actual startup behavior. Verified r160: ARCHITECTURE.md, CONTRIBUTING.md and
  test/README.md contain NO stale "Camera tab"/"Graphs tab" names; only
  SETTINGS_REFERENCE.md's deliberate migration note mentions them.
- RELEASE_PLAN.md: fix the real bundled-model contradiction (the open-question
  section says a fresh install "cannot detect insects", while two verification
  lines promise "detects insects with the bundled model out of the box";
  align on the honest r158 README wording). Update the drifted APK size
  figures (129 / 122.1 MB recorded vs 116.5 MB current). Do NOT add another
  Quick Start task; it exists in Phase 2. Add the simple mode-choice and
  heat/battery table when that existing task is done.
- Benefit: less onboarding ambiguity for users, reviewers, and future agents.
  Cost: ~1 day.

### Part E interfaces, acceptance, and order

- New user settings only if their experiments pass: `timeLapseCameraSleep`
  (default false), `reduceCameraFpsWhileMotionGateIdle` (default false); both
  ship with Settings control + SessionConfig JSON + summary row + round-trip
  test per the owner rule.
- New log record: `camera_sleep` (state, reason, scheduled burst time);
  readers must keep ignoring unknown record types.
- New optional plugin APIs: `predictTiledImage(...)` (E6, gated),
  `isQnnRuntimeAvailable()` (E8, only if split packaging is ever adopted).
- `SessionLogIndex` stays internal and must read every existing session schema
  without migration. No model, session folder, or existing JSONL is rewritten.
- Preserve: detection-only behavior, the 15 camera / 10 inference defaults,
  blackout, capture modes, scheduling, model recovery, all completed Parts
  A-D work. Measure live/thermal changes on both test phones; benchmark
  offline SAHI and lifecycle changes separately from the live pipeline.
  Default to scientific reliability over aggressive power saving: every
  wake/cap failure falls back to today's bound-camera behavior. Keep the
  QNN-inclusive release until the owner changes distribution policy.
- Recommended order: 1) E1 protocol + E2 predictor cleanup + E5 bounded error
  reports; 2) E3 parking + E5 index; 3) E4 measurement-gated cap; 4) E6 if
  profiling supports it; 5) E8 documentation, E9 experiments, E10 truth pass
  (E10 is cheap and can land any time).
