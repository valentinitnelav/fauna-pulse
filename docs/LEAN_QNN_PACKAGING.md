# Lean QNN packaging (implemented in round 299)

**Status:** built. The normal build leaves the QNN runtime out. `-P qnn=true`
(`QNN=1 bash scripts/build_release_apks.sh`) builds the NPU edition, with "-npu" in the APK
names. Differences from the design below:

- `useLegacyPackaging` stays `true` in both editions, because compressed libraries keep the
  download smallest: the lean arm64 APK is about 22 MB instead of about 94 MB (estimated: the
  round-226 APK minus its 72 MB of QNN and ONNX Runtime); with uncompressed libraries it would
  be about 39 MB.
- There is no `isQnnRuntimeAvailable` query yet. A `*_qnn.onnx` model in the normal build fails
  to load, the normal recovery runs, and a plain hint says it "needs the Snapdragon NPU edition"
  (`modelLoadHint` in `models/model_catalog.dart`).

Whether the NPU edition is published at all is a release decision of the maintainer.
Sections 1 to 3 are the original design (round 171), written when the plan was ONE build with
the QNN runtime, so that a lean variant could later be built from a worked-out plan.

**Who this is for:** the maintainer weighing APK size against release work, and whoever
changes the split later.

## 1. What QNN is, and what it costs today (measured round 160)

QNN is Qualcomm's runtime for the Snapdragon NPU (the phone's dedicated AI chip, called
Hexagon). Through the ONNX Runtime QNN execution provider, FaunaPulse uses it to run
`*_qnn.onnx` "context binary" models. Two facts limit its use:

- A context binary is compiled for one Hexagon GENERATION (`min_arch`). Round 151 found that
  the pinned v0.3.5 release files (v73/v81) can never run on the Snapdragon 888 Xiaomi test
  phone (v68). So no current test phone gains from shipping QNN.
- All other models (detectors and identification models in `.tflite`, downloaded or imported)
  run on LiteRT and do not touch QNN. QNN is an extra that users choose.

Measured cost (release APK 116.5 MB):

- The ONNX Runtime and QNN stack is **21 arm64-v8a libraries, 75.7 MB in the APK
  (compressed), 224.3 MB uncompressed: about 62% of the APK**. `libQnnHtpPrepare.so` alone is
  90.4 MB uncompressed.
- `useLegacyPackaging = true` (app `build.gradle`, `packagingOptions`) unpacks the libraries
  to `nativeLibraryDir` at install, because the Hexagon DSP loads its Skel libraries by real
  file paths (`ADSP_LIBRARY_PATH`), not from inside the APK. The phone then stores the APK plus
  the unpacked copies.

Where the opt-in lives (this is what makes a lean variant easy):

- The plugin declares the dependency `compileOnly`
  (`packages/ultralytics_yolo/android/build.gradle`:
  `compileOnly("com.microsoft.onnxruntime:onnxruntime-android-qnn:1.26.0")`), so the plugin
  itself adds no QNN bytes.
- The app's two `implementation` lines in `android/app/build.gradle` are the ONLY opt-in
  point: `com.microsoft.onnxruntime:onnxruntime-android-qnn:1.26.0` plus the
  `com.qualcomm.qti:qnn-runtime:2.46.0` override (2.46, because the device table of QAIRT 2.42,
  which the AAR brings in, is older than the Snapdragon 8 Elite Gen 5). Both lines now sit
  inside `if (project.findProperty('qnn') == 'true')`.

## 2. The lean design (if ever adopted)

### 2.1 Build variants

- **Default (lean):** leave out the two QNN `implementation` lines and set
  `useLegacyPackaging = false`. Expected arm64 release APK: 116.5 − 75.7 ≈ **41 MB**, with no
  second unpacked copy on the phone. (An estimate; measure the real number when building it,
  because ABI splits and compression interact.)
- **QNN artifact:** a Gradle project property (`-Pqnn`, maybe also read from an `ENABLE_QNN=1`
  environment variable for CI) switches BOTH the two dependency lines and
  `useLegacyPackaging = true` in one place. The artifact gets its own stable name (e.g.
  `faunapulse-v0.7.0-qnn-arm64-v8a.apk`) so Obtainium filters keep working, and the same
  versionCode as the lean build (a user changes edition by uninstall and install, not by
  update).

### 2.2 Runtime capability query

A new native method `isQnnRuntimeAvailable` on the plugin channel: a safe class check, e.g.
`Class.forName("ai.onnxruntime.OrtEnvironment")` in a try/catch. Do NOT check by touching
`OrtQnnModel`: it uses `OrtEnvironment` when it is created (`OrtQnnModel.kt:28`), so loading it
in a lean build causes the very `NoClassDefFoundError` the query must prevent.

### 2.3 App behaviour in a lean build

Choosing or importing a `*_qnn.onnx` model must EXPLAIN, not fail:

- `isSupportedModelFileName` (`models/model_file_security.dart`) stays as it is: the app
  family supports the file type, only this edition does not.
- When a model is CHOSEN, check `isQnnRuntimeAvailable` first and show a clear dialog ("this
  model needs the QNN edition of the app, from GitHub releases") instead of a load that must
  fail.
- The failed-load safety net (`modelLoadRecovery()`, called from the camera screen's
  `_onModelLoadError`: go back to the last model and show an error dialog) stays as the last
  guard. In a lean build its dialog should name the real cause (no QNN runtime), not a general
  load failure.
- The settings side is already done: on the Detection tab, a note says that the benchmark and
  "CPU threads" do not apply to an NPU model.

### 2.4 Distribution matrix

- **Google Play:** the lean build only, as an App Bundle (`flutter build appbundle`); Play
  makes the APKs for each phone. QNN users are advanced users and get it from GitHub.
- **GitHub releases:** both artifacts, with stable names and release notes that say which
  edition to choose (default: lean).

### 2.5 What must not change

`OrtQnnModel` behaviour in QNN builds; the refusal of plain `.onnx`; the wire formats of the
model catalogue; the release gates (keystore, and which model files a release may pack).

## 3. Why it is NOT implemented, and what would reopen it

This is the reasoning of the original design, before the split was built.

The real cost was not the 1-2 days of build work but the **lasting two-artifact release
matrix**: every release built, tested, published and supported twice, and users confused about
editions. On the other side stood a feature that no test phone could use. One build with QNN
kept the matrix simple and the feature ready for the day a capable phone and a QNN insect model
appear.

The design named these reasons to reopen the decision:

1. A store or repository size limit really matters (e.g. IzzyOnDroid's ~30 MB limit would still
   be missed at ~41 MB, but pressure from Play's install size or user complaints about the
   ~116 MB download are likely).
2. A test phone that can run QNN (Hexagon v73+) joins the project AND a QNN insect model
   becomes part of the normal work (then both editions can be tested properly, which is a
   condition, not only a reason).
3. Play's pre-launch report or review flags the large native payload.
