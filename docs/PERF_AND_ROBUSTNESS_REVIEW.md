# Performance & Robustness Review 

Opened with round 66, 2026-07-04.

**Who this is for:** the project owner deciding what to improve next, and any
collaborator implementing one of these items.

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
against our vendored plugin.

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

### C1. [ ] Phase-aligned inference FPS cap (the real fix — recommended)

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

### C2. [ ] Parity benchmark against the Ultralytics demo (no code — owner-run)

To compare our app to the demo apples-to-apples, reproduce its conditions in
FaunaPulse settings: **inference cap 0** (uncapped benchmark mode), **camera
cap 0** (device default ~30 fps), **stream 640×480** (explicit pick),
**motion gate off**, engine **GPU**. Expected: ≈11–12 FPS, same as the demo.
Record the measured number here afterwards. If it matches, the "gap" is fully
explained by C1 + C3 and no pipeline work is owed. If it falls clearly short
(say ≤9), reopen this part — that residue would point at our divergent frame
path (frame cache, gate plumbing) and would justify per-stage timing.

- Result (fill in): ____ FPS at parity settings, date ____.

### C3. [ ] Measure per-frame conversion cost vs stream size (measure first, then decide)

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
