# Lean QNN packaging (documented alternative, NOT implemented)

**Status:** design on record, deliberately not built (perf review E8, round 171).
The accepted distribution policy remains ONE build that includes the QNN runtime
(RELEASE_PLAN, Play phase: "keep `useLegacyPackaging` ... and accept the size
cost"). This document exists so that, if the owner ever reopens that policy,
the lean variant can be implemented from a thought-through plan instead of from
scratch. Nothing in the build or the app changes with this round.

**Who this is for:** the maintainer weighing APK size against release
complexity, and whoever implements the split later.

## 1. What QNN is, and what it costs today (measured round 160)

QNN is Qualcomm's runtime for the Snapdragon NPU (the phone's dedicated AI
chip, called Hexagon). FaunaPulse uses it, via the ONNX Runtime QNN execution
provider, to run `*_qnn.onnx` "context binary" models. Two facts bound its
usefulness today:

- A context binary is compiled per Hexagon GENERATION (`min_arch`); the
  round-151 finding is that the pinned v0.3.5 release assets (v73/v81) can
  never run on the SD888 Xiaomi test phone (v68). So no current test device
  benefits from shipping QNN.
- Everything else (the bundled yolo26n, imported `.tflite` models) runs on
  LiteRT and does not touch QNN at all. QNN is pure opt-in capability.

Measured cost (round 160, release APK 116.5 MB):

- The ORT/QNN stack is **21 arm64-v8a libraries, 75.7 MB in-APK (deflated),
  224.3 MB uncompressed — about 62% of the APK**. `libQnnHtpPrepare.so` alone
  is 90.4 MB uncompressed.
- `useLegacyPackaging = true` (app `build.gradle`, packagingOptions) extracts
  the libraries to `nativeLibraryDir` at install, because the Hexagon DSP
  loads its Skel libraries via real file paths (`ADSP_LIBRARY_PATH`), not out
  of the APK. On-device cost is therefore roughly **APK + extracted copies**.

Where the opt-in lives (this is what makes a lean variant genuinely easy):

- The plugin declares the dependency `compileOnly`
  (`packages/ultralytics_yolo/android/build.gradle`:
  `compileOnly("com.microsoft.onnxruntime:onnxruntime-android-qnn:1.26.0")`),
  so the plugin itself adds no QNN bytes.
- The app's two `implementation` lines in `android/app/build.gradle` are the
  SINGLE opt-in point:
  `com.microsoft.onnxruntime:onnxruntime-android-qnn:1.26.0` plus the
  `com.qualcomm.qti:qnn-runtime:2.46.0` override (2.46 because the AAR's
  transitive QAIRT 2.42 device table predates the Snapdragon 8 Elite Gen 5).

## 2. The lean design (if ever adopted)

### 2.1 Build variants

- **Default (lean):** omit the two QNN `implementation` lines and set
  `useLegacyPackaging = false`. Expected arm64 release APK ≈ 116.5 − 75.7 ≈
  **~41 MB**, with no doubled on-device extraction. (Estimate; measure the
  real number when implementing — ABI splits and compression interact.)
- **QNN artifact:** a Gradle project property (`-Pqnn`, optionally also read
  from an `ENABLE_QNN=1` environment variable for CI) gates BOTH the two
  dependency lines and `useLegacyPackaging = true` in one place. The artifact
  gets its own stable name (e.g. `faunapulse-v0.7.0-qnn-arm64-v8a.apk`) so
  Obtainium filters keep working; same versionCode as the lean build (a user
  switches edition by uninstall+install, not by update).

### 2.2 Runtime capability query

New native method `isQnnRuntimeAvailable` on the plugin channel, implemented
by safe class detection, e.g. `Class.forName("ai.onnxruntime.OrtEnvironment")`
in a try/catch. Important: do NOT probe by touching `OrtQnnModel` — it
references `OrtEnvironment` at construction (`OrtQnnModel.kt:28`), so loading
that class in a lean build is exactly the `NoClassDefFoundError` the query
must prevent.

### 2.3 App behaviour in a lean build

Selecting or importing a `*_qnn.onnx` model must EXPLAIN, not fail:

- `isSupportedModelFileName` (model_catalog.dart) stays unchanged — the file
  type is still supported by the app family, just not by this edition.
- At model SELECTION time, check `isQnnRuntimeAvailable` first and show a
  clear dialog ("this model needs the QNN edition of the app, available from
  GitHub releases") instead of attempting a doomed load.
- The round-151 failed-load safety net (`modelLoadRecovery()` +
  `onInitialModelLoadFailed` → revert + error dialog) stays as the backstop
  for anything that slips through; in a lean build its dialog text should
  name the real cause (missing QNN runtime), not a generic load failure.
- The AI-tab "NPU — doesn't apply" benchmark note (round 150) already handles
  the settings side.

### 2.4 Distribution matrix

- **Google Play:** the lean build only, as an App Bundle (`flutter build
  appbundle`); Play generates per-device APKs. QNN users are advanced users
  by definition and are served from GitHub.
- **GitHub releases:** both artifacts, stable names, release notes stating
  which edition to pick (default: lean).

### 2.5 What must not change

`OrtQnnModel` behaviour in QNN builds; the plain-`.onnx` rejection; model
catalog wire formats; the round-158 release keystore/bundled-model gates.

## 3. Why it is NOT implemented, and what would reopen it

The real cost is not the ~1-2 days of build work but the **permanent
two-artifact release matrix**: every release built, smoke-tested, published
and supported twice, plus user confusion about editions. Against that stands
a capability that no current test device can even exercise. The single
QNN-inclusive build keeps the matrix trivial and the capability present the
day a capable device plus a QNN insect model appear.

Reopen this decision when any of these becomes true:

1. A store or repository size limit actually bites (e.g. IzzyOnDroid's ~30 MB
   cap would still be missed at ~41 MB, but Play install-size pressure or
   user complaints about the ~116 MB download are plausible).
2. A QNN-capable test device (Hexagon v73+) joins the project AND a QNN
   insect model becomes part of the normal workflow (then the editions can be
   properly tested, which is a precondition, not just a trigger).
3. Play's pre-launch report or review flags the oversized native payload.
