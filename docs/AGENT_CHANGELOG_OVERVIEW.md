# FaunaPulse: current-state overview (for coding agents)

Read at the start of every session. It holds only what an agent needs before working on the app
and would not easily find in the code it edits: where things live, the rules that keep the app
working, and pointers. Details of a feature are in its code comments and its doc in `docs/`;
defaults in `SessionConfig` and `docs/SETTINGS_REFERENCE.md`; history in git and
`AGENT_CHANGELOG.md`. Rules for editing this file: `AGENTS.md`.

## What the app is

Android field app (Flutter + Kotlin). A phone on a tripod watches a square Region of Interest
(ROI, "the yellow square" in the UI) over flowers or another fixed spot.
- **Live detection:** a YOLO detector (LiteRT, on the phone) finds animals inside the ROI, a
  tracker gives each one a **track ID**, every detection is logged and ROI photos are saved. The
  scientific output is the visitation rate (how often and how long animals visit).
- **No-AI capture:** motion-triggered photos, time-lapse photo bursts or ROI video clips.
- **AI later:** detection, track IDs and identification (BioCLIP image tower with name lists, or
  fixed-class classifiers) run afterwards on saved photos and videos, also on imported videos.
- Everything runs on the phone. No model ships in the APK: users download or import them.
- UI text is plain English for citizen scientists; expert settings sit in closed folds.

## Where things live

- **App = repository root:** `lib/main.dart` → `lib/fauna_pulse/` (all app code);
  `test/fauna_pulse/`; `integration_test/` (device checks); `assets/` (`model_downloads.json`,
  `images/`, `models/` = local weights for debug device checks only); `docs/`; `tool/` (PC
  scripts); `scripts/` (release builds).
- **Plugin:** `packages/ultralytics_yolo/`, a modified copy (fork) of the Ultralytics YOLO Flutter
  plugin, used as a path dependency: Dart `YOLOView`/`YOLO`/`YOLOViewController` + Kotlin
  (`YOLOView.kt` camera and ROI, `MotionGate.kt`, `RoiVideoWriter.kt`, `Embedder.kt`,
  `LiteRtModel.kt`, `YOLOPlugin.kt`). Changes vs upstream and the re-audit checklist:
  `FAUNAPULSE_FORK.md`. Call it "the Ultralytics plugin" (never "vendored").
- **Native app shell:** `android/app/src/main/kotlin/com/ultralytics/yolo/MainActivity.kt`
  (full-res `cropRoiJpeg`, gallery saves, crash files).
- **Off-limits:** `ios/` (git-ignored). `~/InsectDetectApp/sessions/` and the other folders
  beside the repository in `~/InsectDetectApp/` are owner data: read only a path the owner names.

## Module map (`lib/fauna_pulse/`)

- `models/`: settings and data types. `session_config.dart`: `SessionConfig`, every recording
  setting (source of truth for defaults; migrations in `fromJson`; `buildTracker(fps)`, the one
  tracker builder for camera and videos). Model files: `model_catalog.dart`,
  `model_file_kind.dart` (kind from the tensor shapes), `model_file_security.dart`
  (`isSupportedModelFileName`, the one format filter; intake checks), `model_import.dart`, `file_download.dart`,
  `model_downloads.dart` (reader of the download list), `models_on_phone.dart`.
  `field_notes.dart` and `phone_state.dart` use FaunaLapse's keys; `deviceNameOf` must give the
  same name as fauna-pulse-export (shared cases in `test/fauna_pulse/fixtures/device_name_cases.json`).
- `session/`: live recording (`frame_processor.dart` per-frame mapping and tracking,
  `session_recorder.dart` folder, logger, photos, keep-alive, stop order, `schedule_plan.dart`).
- `tracking/`: `InsectTracker`; ByteTrack (default), C-BIoU; `replayTracker` (offline replay).
- `capture/`: ROI photos (`roi_capture.dart`), time-lapse plan, ROI video clips, crop export,
  `photo_header.dart`.
- `logging/`: `session_logger.dart` (JSONL writer), `session_log_index.dart` (one pass over a
  session, feeds every summary tab), `past_sessions.dart`, `track_source.dart`, statistics,
  thermal and storage guards, error hooks, crash files, problem reports.
- `postprocess/`: AI afterwards. Photos: `post_detector.dart`, `photo_keep.dart`, `sahi.dart`,
  `photo_tracker.dart`; videos: `video_*.dart`, `clip_cleanup.dart`; FaunaLapse import
  `faunalapse_import.dart`; `csv_cell.dart`.
- `identification/`: `label_pack.dart` (`.fpack` reader), `crop_planner.dart`,
  `identification_job.dart`, `identification_run.dart`, `identification_store.dart`,
  `track_fusion.dart`.
- `screens/` (one file per screen; `camera_session_screen.dart` is the live UI, its logic sits in
  `session/`), `widgets/` (shared UI, reuse before writing new: `setting_help.dart` ⓘ help and
  folds, `numeric_setting_field.dart`, `dialog_title.dart`, `home_button.dart`,
  `model_kind_panel.dart`, `tracker_tuning_fields.dart`, `video_timeline_bar.dart`,
  `selection_app_bar.dart`), `services/` (recording and analysis keep-alive), `perf/`.

Settings outside `SessionConfig` are shared preferences: Find in photos `analysis_*` (its
tracker = the camera's), Find in videos `video_analysis_*` (own tracker values, never touching the
camera's), Identify `identify_*`, the chosen models, `home_watch_use`, `watch_choice_<id>`.

## Key invariants

### Words and screens
- **"Track ID", not "visit"**, in every text, file and record name; durations say "track
  length". "Visit" only for the ecological quantity (hand counts, visitation rate). Readers accept
  older names; saved-settings keys and Dart identifiers kept old names on purpose. **A track
  length runs from the tracker's first sighting to its last frame everywhere:** the rule exists
  three times, `TrackSpans` (`session_log_index.dart`), the Video tab (`video_box_timeline.dart`)
  and `track_ids.csv` (`track_export.dart`): change all three.
- **UI words:** screens are named by their top title ("Download & import models", "Find animals in
  photos", "Find animals in videos"; trigger "Live detection"); "name list" (Hugging Face and
  fauna-pulse-models say "label pack"), "detector rate", "yellow square" before "ROI"; errors in
  plain words; features named for any organism, not only insects.
- **Every new tunable ships user-adjustable:** Settings control + `SessionConfig` JSON + summary
  row (`_settingsSection()`, `na:` when not applicable) + round-trip test, in the same round.
- **Settings fields** (`NumericSettingField`) never clamp silently: a number outside the range is
  refused with a red "Allowed: a to b" line; a comma is a decimal point. **No control writes a
  second stored setting** (every keystroke commits): a rule between two settings is applied where
  the values are used and shown as the box's amber `warning`. Guarded by
  `settings_fields_test.dart` (every control of every settings screen; a stored camera setting
  without a control must be listed there) and `tracker_effect_test.dart`.
- **New screens** (each new screen so far shipped with these bugs): body in `SafeArea`; list
  bottom padding ≥ 32 or `+ MediaQuery.paddingOf(context).bottom` (the app is edge-to-edge; an
  explicit `padding:` loses the automatic inset); `DropdownButtonFormField(isExpanded: true)`;
  long text in `Expanded`/`Flexible` + ellipsis; `actions: const [HomeButton()]` in every title
  bar but Home and Camera (long titles: `FitTitle`); a widget test at 360 px width with
  `simulateBottomSystemBar` that checks the last row with `expectAboveBottomInset` (template:
  `summary_bottom_inset_test.dart`).
- **Settings sheet:** tabs Setup / Detection / Photos / Power. All heat controls are on Power
  (Detection is greyed in the no-AI modes while the gate must stay editable). Expert knobs in
  `FoldSection`s, explanations behind an ⓘ. `HelpSwitchTile` draws help below the tile, never as
  `ListTile.subtitle` (toggling it trips a baseline assertion). Session settings stay on the
  camera screen (they need the live camera); app-level actions go in the Home menu.
- **Windows (AlertDialog):** `title: DialogTitle(Text(...), onClose: ...)` puts an X at the top
  right that does what the bottom button does; that button says "Cancel" when the window asks to
  confirm, "Close" when it only informs (no "Not now", "OK", "Done"). Two or more buttons:
  `actionsOverflowDirection: VerticalDirection.up`. A dialog's `TextEditingController` belongs to
  the dialog's own `State`.
- **Notes the app shows on its own, again and again, get "Don't show again"**
  (`DontShowAgainBox`, or a `SnackBarAction` shown 10 s); "Show tips and notes" (Home menu)
  brings them all back, so a new note's key goes into `_toggleTipsAndNotes`
  (`home_screen.dart`). Not for confirm questions, results or errors.
- **A SnackBar with a button stays until tapped** unless `persist: false`; a bar the code keeps
  and closes later goes through `ClosableSnackBar`.
- **A screen that sends the user to another app** (web link, phone settings, file picker) is
  pushed with `restorablePush` (static builder marked `@pragma('vm:entry-point')`) or
  `RestorableRouteFuture`: low-memory phones close the app in the background, and a screen comes
  back only if every route below it is restorable.
- **One unit per sentence:** two sizes in one sentence share the larger one's unit
  (`formatBytes(unitOf:)`, `freeStorageClause`, `formatMegabytes`).
- **An empty chart keeps its card** and says why it is empty (a hidden chart looks removed).

### Camera and native view
- **Every new native camera view gets the live settings:** `YOLOView` is keyed on the stream
  size, so a stream change builds a new native view that knows only its creation params;
  `onNativeViewCreated` makes the camera screen re-send ROI, motion gate, fps cap and time-lapse
  mode and re-run the probes. Anything new sent through the controller belongs in that sequence.
  Check: `integration_test/view_recreate_check_test.dart`.
- **`applyInteropOptions()` (`YOLOView.kt`) is the only caller of `setCaptureRequestOptions`**
  (it replaces the whole option set, so manual focus and the fps cap go together).
- **Plugin lifecycle:** `YOLOView.stop()` is restartable (never shut executors there);
  `release()` is terminal. Model loads go through the one `modelLoadExecutor` + generation token.
- **No model:** the camera runs without one (`modelPath ''`, ~1 Hz `noModel` heartbeat so the
  Dart start-up still runs). Live detection without a usable model asks, never picks silently. A
  failed load reverts (`modelLoadRecovery`); the dialog never shows the raw reason
  (`modelLoadAdvice`, `kModelDamagedAdvice`).
- **Camera hold:** while recording or scheduled, Dart holds the camera (`setCameraHold`), so it
  keeps running while the app is hidden, with the preview detached. Blackout (power save) detaches
  only the Preview use case; a recording continues.
- **Photos only from a live camera:** captures return null when no frame came for 1.5 s or the
  preview is detached; time-lapse and reference photos wait while no frame came for 5 s, or
  while the app is hidden and the camera is not held (`_cameraFramesFresh`).
- **No YUV→RGB in Dart** (native does it). **Portrait only** (crop and rotation math assume it;
  lift the locks only with a full orientation audit). **Focus is always manual** (preset 7.5
  dioptres; no autofocus anywhere).
- GPU or CPU depends on whether the GPU backend compiles the model's op graph, not on int8 vs
  fp16. A 2-strike GPU-crash blocklist moves crashing models to the CPU (`LiteRtModel.kt`).
- While the motion gate sleeps the camera fps readout shows about `motionGateIdleFps`, and about 1
  fps between time-lapse bursts: that is correct.
- **Services:** swiping the app away in Recents ends a recording (`onTaskRemoved`). Long jobs on
  saved files (Find in videos or photos, saving kept frames, Identify) hold the one
  reference-counted `AnalysisService` (type `dataSync`, `mediaProcessing` on Android 15+),
  taken on the tap on Start (Android 12+ refuses a start from the background); both permissions
  are declared in Play Console. `RecordingService` stays type `camera` (dataSync's daily cap
  would end long recordings). Notifications use the one-colour `R.drawable.ic_notification`.

### ROI and photos
- **ROI is ÷32 WYSIWYG:** the box, readout, saved crop and inference ROI are the same square;
  the side snaps to a multiple of 32, capped to the frame's short side. One mutation funnel
  `_onRoiChanged`; helpers in `models/roi.dart`. The box grid is the analysis stream grid; never
  make it follow `_activePath`.
- **Crop paths already snap and cap** (plugin `ImageUtils.cropRoiFromFrame`,
  `MainActivity.cropRoiJpeg`, Dart `_cropJpeg`): downscale above the target, never upscale.
- **Photo source is chosen per photo** (`chooseCapturePath`). High-res photos are processed off
  the main thread and never full-frame rotated: `rawRectForUprightRect` has a Kotlin mirror in
  `MainActivity.kt` (keep in sync); do not reintroduce `normalizeJpegOrientation`. The ZSL buffer
  is used only when the photo source is not `fast` (it adds two full-size camera streams). True
  zero-shutter lag never engages on the Xiaomi: don't chase it in software.
- **Photo file names** `roi_<token>_<yyyy-MM-dd>_<HHmmss>_<SSS>.jpg` (trigger moment in local
  time; path sort = capture order; no track IDs in names). Session photos carry no EXIF; only
  exported crops get time and GPS (GPS while `cropExportPosition` is on).

### Logging and session data
- **`session.jsonl` is append-only JSON Lines** (one object per line): start record (config,
  versions, `file_token`, `location`, `tracker_params`), one `detections` record per frame, and
  event records. Record dictionary: `docs/DATA_GUIDE.md`; a record change updates it, and
  fauna-pulse-export reads these records (AGENTS.md, *Related repositories*).
- Boxes in `detections[].tracks[]` are always detector-observed (unmatched tracks go `lost`).
- **Frozen wire names** (never rename): `gt_frames/`, `gt_capture`,
  `gtFramesEnabled`/`gtFrameSeconds`; high-res photo source `still`; `stillSyncCompanion`.
- While the gate is idle or in no-AI modes, `fps` records leave out inference fields: never log
  stale or zero inference numbers.
- **Writes:** one async writer queue (never sync I/O in the frame callback); `close()` must be
  awaited so `end_of_session` lands.
- **A session never dies silently:** write failures show a red banner; uncaught errors become
  `app_error` lines (`app_error_hooks.dart`); no naked fire-and-forget futures; best-effort
  `catch` blocks call `logSwallowed(site, e)`.
- **Rename** (`renameSession`) is the one allowed edit of a finished log. **Derived results stay
  out of `session.jsonl`:** post-hoc files join on file names and track IDs (appended
  exceptions: `session_renamed`, `video_cleanup`).
- **One tracks file per session:** `trackSourceOf(dir)` (afterwards when `post_tracks.jsonl`
  exists and no live tracker ran, else live); every reader uses it.
- **Problem reports** are built in `error_reports/` (the only folder the report FileProvider
  serves); every session line goes through `redactReportLine`. Crash files `crashes/` come from
  Dart and Kotlin (keep `writeCrashFile` ↔ `crashFileBody` in sync). All CSV cells go through
  `csvCell`.

### Capture modes
- **Motion gate** is native (`MotionGate.kt`); never gate in Dart.
- **Motion-only and time-lapse:** `predict()` never runs (no `detections` records). Time-lapse
  photos follow a Dart clock (`TimeLapsePlan`); native drops the other frames before conversion.
- **Camera sleep between bursts:** `TimeLapseCameraCoordinator` (pure state machine); a failed
  park or wake keeps the camera on for the rest of the session.
- **ROI video clips:** `RoiVideoWriter.kt` scales on the GPU in its own EGL context. Never
  `lockHardwareCanvas` (it aborted the app on the Xiaomi).
- **Scheduled recording:** each window is its own session; between windows the camera is unbound
  but the foreground service and wake-lock stay. No AlarmManager: staying in the foreground is
  what survives MIUI.
- **Field power:** the phone is on a power bank in the field; charging heat is expected.

### Tracking
- Two pure-Dart trackers behind `InsectTracker`: ByteTrack-style (default; distance fallback
  against ID fragmentation) and C-BIoU-style. Settings are in seconds; frame counts are derived,
  at least 2 (a track starts on its first box and confirms on a later match). New-track
  confidence is the user's value, never floored or raised by the confidence. Faint boxes can
  confirm and revive tracks (unlike Ultralytics' trackers); kept until tuned on the annotated
  videos.
- `replayTracker` (videos, photos, session replay) treats a gap as a pause only when it is longer
  than the occlusion tolerance and twice the frame rhythm.
- A tracker variant becomes default only after it wins on hand-counted sessions. Replay:
  `flutter test test/fauna_pulse/tracker_replay_test.dart --dart-define=REPLAY_SESSION=…/session.jsonl`.

### AI afterwards: photos and videos (`docs/VIDEO_ANALYSIS.md`)
- **Find animals in photos:** `PostDetector` → `post_detections.jsonl` (resumable); a
  high-res/`_live` pair is one capture moment. `keepDecisions` is the one keep rule. SAHI tiles
  are our own code (no SAHI library). Re-analysis of a live-AI session with the same model is
  blocked. Track IDs from photos only for no-AI sessions with a step ≤ 0.5 s.
- **Find animals in videos:** import moves the files into `<session>/videos/` (fragmented MP4s
  rewritten by native `VideoFrameSource.remux`). One native video source at a time (`_busy`; the
  review player is left out of the tree while busy). Detections are sampled by PTS into
  `video_detections.jsonl` (boxes normalised to the whole upright frame, the live shape); track
  IDs via `replayTracker` into `post_tracks.jsonl`, `track_ids.csv`, `mot/`. Kept frames use
  `TrackKeepRule` (shared with live capture). The default area is `largestSquareSidePx` (one rule
  for camera, editor and default).
- The video player keeps its play state on a `ValueNotifier`, not the controller (10 Hz rebuilds
  made playback stutter). Video players and runs keep the screen on only through
  `ScreenOn.hold/release` (reference-counted), never WakelockPlus directly.
- "Also identify them" starts `IdentificationRun.autoStart` itself (a page could not start it in
  the background).
- Jobs end write errors with plain words (storage full), never a raw exception; a model that
  cannot load stops the run (`video_model_error`) instead of marking clips unreadable.

### Identification (`docs/IDENTIFICATION.md`)
- Pipeline: crops per photo per track ID (`planCrop`) → crop in an isolate → native embedding
  (`Embedder.kt`) → append-only `embeddings_<model>.{jsonl,bin}` (resumable) → one score per
  track ID → `tracks_<pack>.{csv,json}`, `crops_<pack>.csv`, `summary_<pack>.json`. Method and
  credits (Dussert et al. 2025; suspect flags after insect-detect-post, Sittinger 2026) are in
  IDENTIFICATION.md. The defaults are not validated on pollinators.
- A name list pairs with its model by the first part of the file name (`listBelongsTo`, else the
  header's `model_id`); a classifier pairs with the `.fpack` of the same name. A row counts only
  down to the rank above its first empty slot (`rollUp`).
- GPU: checked once per model file and phone build against the CPU, refused when memory is short
  (`Embedder.kt`). fp16 everywhere (int8 changed answers). BioCLIP 2 needs the 4-D attention
  export; BioCLIP 2.5 is CPU-only on today's phones.
- One Identify job per session; runs take the static model lock (`IdentificationRun.takeModel`).
  The run (`identification_run.dart`) lives apart from its page, so it keeps running in the
  background.
- **A chained run loading in the background checks memory first** (`identifyFitsInBackground`)
  and otherwise waits until the app is back. Strict on purpose (owner's decision: a wait costs one
  tap, a kill loses the run silently; no exception for large phones); users are told to keep the
  app on screen. `identify_waiting.json` lets a run continue or report after Android closed the
  app, and never repeats a start that got the app closed.
- Native memory is given back after the embedder closes (`NativeMemory.giveBack`: on Android 12
  `M_PURGE_ALL` answers "done" and frees nothing, hence the steps).

### Models and downloads
- **Model facts** (origin, licence, citation) live in the model cards on Hugging Face
  (`kModelsCollectionUrl`); this repository keeps only `assets/model_downloads.json` (format:
  `tool/model_downloads/README.md`; `update_catalogue.py --urls` takes fauna-pulse-models'
  `publish/published.json`). The app shows Hugging Face pages by name, never the address.
  Presence on the phone = file name only.
- **Formats:** `.tflite` and `*_qnn.onnx` are accepted (`isSupportedModelFileName`), plain
  `.onnx` is refused. A `*_qnn.onnx` model runs only in the NPU edition (`-P qnn=true`); the
  normal build fails its load with an edition hint. Only debug builds pack local weights.
- **Model and photo files are user input and must never close the app.** Intake (only there,
  never in the camera path): HTTPS only, one 2 GiB limit (`kMaxModelFileBytes`), checks in
  `model_file_security.dart` and `model_file_kind.dart`. Native parsers and model loads catch
  `Throwable` (a crafted length throws OutOfMemoryError). Photos over 120 MP are refused from the
  header before any decode (native `MAX_DECODE_PIXELS` = Dart `kMaxPhotoPixels`: keep equal); Dart
  decodes only JPEGs within the limit (`decodeJpegWithinLimit`). FaunaLapse zips are unpacked
  only by `_unpack` (never package:archive's `ZipDecoder`). `.fpack` headers are checked before
  `jsonDecode`.
- **Download & import models** (`models_screen.dart`) is the only place to import, download and
  delete model files and name lists; one list per kind, by file name (`fileNameOrder`).
- Renaming a published model file needs a line in `kFormerModelNames` (files and saved choices
  are renamed at app start).
- The "What do you want to watch?" pages (`watch_plan_screen.dart`) choose a detector and a
  naming per answer; saving is `useModels`. A model needs a catalogue entry only to be offered or
  suggested; any model on the phone can be chosen everywhere.
- **Downloads:** a file already being written is refused (`_activeDownloadTargets`); leftover
  `.part` files are deleted at app start; full storage ends a download with plain words, never a
  hang.

### Home, Sessions, Dashboard
- Donation link only with `--dart-define=DONATION_LINK=true` (GitHub APKs), never in the Play
  build (Play policy). About's licences button pushes the generated LicensePage (store
  compliance). `citationText` must match CITATION.cff (a home-screen test compares them).
- *Delete all sessions* never deletes the `sessions/` root.
- Dashboard: a track ID is not an animal count (the UI says so). Its per-session cache
  `dashboard_stats.json` is versioned.

### Build, release, repository
- **Branches:** `main` = stable, `develop` = integration (base for PRs). Dependabot keeps
  alerts only (no `dependabot.yml`, security updates off); check open alerts before a
  release, library updates are made in a round (`docs/CONTRIBUTING.md`, *Library updates*).
- **Toolchain:** Gradle, AGP, Kotlin and SDK levels are pinned in `android/`; keep
  `android.builtInKotlin=false` and `android.newDsl=false`; `file_picker` stays `^10.3.10`. App id
  `com.faunapulse.app`; native classes stay in `com.ultralytics.yolo`. Keep the tracked Gradle
  wrapper files.
- **Release:** release builds fail without a keystore (`scripts/create_release_keystore.sh`);
  `scripts/security_release_gate.sh` (analyze, tests, native security tests, release lint, signed
  AAB); `scripts/build_release_apks.sh` (per-ABI APKs with the Play versionCode; `QNN=1` = NPU
  edition). Backup = shared preferences only (as `PRIVACY_POLICY.md` says); cleartext traffic
  blocked. CI actions are pinned by commit; the Flutter version in `security_checks.yml` equals
  the local `flutter --version` (change both in the same round).
- **Versioning:** pubspec `version:` is the single source; bump the build number for every tester
  APK; tags `v<version>`. Since 0.9.0 (beta) an update keeps older sessions and saved settings
  readable. Move together: pubspec version, CITATION.cff (`version`, `date-released`, version
  DOI; the concept DOI never changes), CHANGELOG.md, the fastlane changelog, the year in
  `citationText`. Pubspec `description` = CITATION.cff `title`; never retitle an archived
  version.

## Test phones

`adb devices -l` first: the connected phones change. Rules for using them: AGENTS.md, *Phones*.
- **Xiaomi 11T Pro `2107113SG`** (Snapdragon 888, 7.4 GB, Android 14): main phone, debug builds.
  PIN lock (a person unlocks it). It reports the laptop's USB cable as AC power, so keep it awake
  with `svc power stayon true`. Runs hot (camera throttles at ~41-42 °C). Battery voltage reads
  as 2 cells (the summary halves it). It often shares its mobile internet with the laptop over
  USB: avoid big downloads while it is connected. Neither `adb shell` nor `run-as` can read the app's
  `Android/data` folders: check results in the app.
- **Samsung `SM-M127F`** (Exynos 850, 3.9 GB, Android 13): runs release-signed APKs, so no
  `run-as`, and a debug build needs an uninstall (deletes its data: ask the owner).
  `battery_current_ua` is broken. Swipe lock (adb can wake and swipe).
- **Redmi Note 9S** (Snapdragon 720G, 3.6 GB, Android 12 MIUI): debug builds. Memory-bound:
  BioCLIP 2 loaded in the background is killed. MIUI asks "Install via USB?" for a new package.

## Pointers

- **Docs:** `FIELD_GUIDE.md`, `INSTALL.md`, `SETTINGS_REFERENCE.md` (every setting and its
  default), `DATA_GUIDE.md` (record dictionary), `ARCHITECTURE.md` (data flow, channel contract,
  keep-in-sync pairs), `CONTRIBUTING.md`, `IDENTIFICATION.md`, `VIDEO_ANALYSIS.md`,
  `MODEL_CONVERSION.md`, `PERFORMANCE_BENCHMARKING.md`, `HOW_PHOTO_RESOLUTION_WORKS.md`,
  `LEAN_QNN_PACKAGING.md`. Models tried and parked: fauna-pulse-models `docs/PARKED_MODELS.md`.
- **PC tools:** `tool/model_downloads/`, `tool/video_eval/`, `tool/perf_summary.dart`; the model
  export tools are in fauna-pulse-models (`FAUNAPULSE_MODELS_REPO` lets `model_file_kind_test`
  see its files).

## Build and test

- `flutter analyze`; `flutter test test/` (about 990 tests, ~2.5 min). No whole-file `dart format`
  (the repository is not formatter-clean).
- Debug APK: `flutter build apk --debug`, then `adb -s <device-id> install -r`.
- Device checks: `flutter test integration_test/<file> -d <device-id> --no-uninstall`. First back
  up the app's settings (`adb exec-out run-as com.faunapulse.app cat
  shared_prefs/FlutterSharedPreferences.xml`) and compare after. Camera checks need the phone
  awake and unlocked at the start; checks that tap REC call `skipBeforeRecordSheet()`.
  Afterwards rebuild, then reinstall the normal debug app (the check overwrites
  `app-debug.apk`). A side-by-side `com.faunapulse.app.check` copy: `test/README.md`.
- KGP/Gradle deprecation warnings are known and unrelated.
