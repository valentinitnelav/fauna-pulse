# FaunaPulse: current-state overview (for coding agents)

Read at the start of every session. It says what the app is now: where code lives, the defaults,
and the rules that keep it working. When something changes, replace or delete the entry in place.
No history here (which round, why, old values, measurements behind a decision): that goes to
`AGENT_CHANGELOG.md`. Keep this file under 75,000 characters (`wc -m`).

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
  `test/fauna_pulse/` (unit + widget tests); `integration_test/` (device checks); `assets/`
  (`model_downloads.json`, `images/` setup drawings, `models/` local weights for debug device
  checks only); `docs/`; `tool/` (PC scripts; the model export tools are in the separate repository
  `fauna-pulse-models`, see *PC tools*); `scripts/` (release builds).
- **Plugin:** `packages/ultralytics_yolo/`, a modified copy (fork) of the Ultralytics YOLO Flutter
  plugin (from `ultralytics/yolo-flutter-app`), used as a path dependency. Dart `YOLOView`/`YOLO`/`YOLOViewController` + Kotlin (CameraX,
  LiteRT, ROI crops, motion gate, video decode/encode, embedder; `YOLOPlugin.kt` holds
  `benchmarkAccelerators` and `predictTiledImage`). What changed vs upstream and
  the re-audit checklist: `packages/ultralytics_yolo/FAUNAPULSE_FORK.md`. Call it "the Ultralytics
  plugin" (never "vendored"); "modified copy (fork)" where the licence matters.
- **Native app shell:** `android/app/src/main/kotlin/com/ultralytics/yolo/MainActivity.kt`
  (full-res `cropRoiJpeg`, MediaStore gallery saves, uncaught-exception crash files).
- **Off-limits:** `ios/` (git-ignored). `~/InsectDetectApp/sessions/` and other sibling folders
  of the repository are owner data: read only a path the owner names.

## Module map (`lib/fauna_pulse/`)

**models/**
- `session_config.dart`: `SessionConfig`, every recording setting (source of truth for defaults;
  JSON in each session's start record; migrations in `fromJson`; `buildTracker(fps)`, the one
  tracker builder for camera and videos; `notApplicableConfigKeys(trigger, saveAs:)`).
- `roi.dart` (`Roi`, ÷32 snapping `snapSideToGrid`/`copyClamped`, `boxInRoi`,
  `largestCentredSquare`, `largestSquareSidePx`), `track.dart`, `schedule_window.dart`.
- `phone_state.dart`: `PhoneState` (r298; FaunaLapse's `phone_state` keys, `tips` with their
  settings page). Native `MainActivity.readPhoneState`/`openPhoneSettings` on the keepalive
  channel; Dart `services/phone_settings.dart`.
- `field_notes.dart`: `FieldNotes` (r297; `kFieldNoteSpecs`, prefs `field_notes`, own fields
  `CustomField`/`CustomFieldType` with FaunaLapse's 7 types and rules (r301, `custom_fields`),
  `recordBlock` = the start record's `field` block with FaunaLapse's 17 keys, `locationBlock`).
- `model_catalog.dart`: detection models on the phone (`ModelCatalog.build`, `entryOf`,
  `modelsDir`; `isSupportedModelFileName` = the one format filter; `fileNameOrder`).
- `model_file_kind.dart`: `modelFileKind` reads a `.tflite`'s tensor shapes from its FlatBuffer
  (first output 3-D = detection, all outputs 2-D = identification, input must be a 4-D colour
  picture); `.fpack` by header; `*_qnn.onnx` = detection.
- `model_file_security.dart` (intake checks, `kMaxModelFileBytes`), `model_import.dart`
  (`ModelImport.importFiles`/`pickAndImport`/`download`/`onPhoneAs`, `ReplaceQuestion`),
  `file_download.dart` (shared HTTPS download, `downloadStatusMessage`, `directFileUri`),
  `bundled_models.dart`.
- `model_downloads.dart`: reader of `assets/model_downloads.json` (`ModelDownloads`,
  `ModelDownload`, `NameListDownload`, `NamingDownload`, `WatchUse`, `downloadCatalogueFile`,
  `modelFor`).
- `models_on_phone.dart`: `ModelsOnPhone.count` (home step 1 counts, file names only),
  `ModelFilesOnPhone.load` (files by kind), `namingPairs`, `currentModelChoice`, `useModels`,
  `saveNamingChoice`, `kNoNamingNote`. `model_choice_keys.dart`: pref keys of the chosen models.

**session/** `frame_processor.dart` (per-frame mapping + tracking, gate-idle state, pipeline
fps), `session_recorder.dart` (recording lifecycle: folder, logger, photos, keep-alive, stop
order), `camera_diagnostics_controller.dart` (one-time probes, lens cycling, focus preset),
`capture_calibration_cache.dart`, `time_lapse_camera_coordinator.dart`, `schedule_plan.dart`,
`location_fix.dart`, `plan_sentence.dart` (`planSentence`), `screen_idle.dart`, `session_guards.dart`,
`site_photos.dart`.

**tracking/** `tracker.dart` (`InsectTracker`, `TrackEventBuffer`), `byte_track.dart` (default),
`c_biou_track.dart`, `tracker_replay.dart` (`replayTracker`, offline replay of `raw_detections`).

**capture/** `roi_capture.dart` (`RoiCaptureScheduler`, `TrackKeepRule`, `chooseCapturePath`,
`savedSidePx`/`capSavedSidePx`, `rawRectForUprightRect`, `uprightHighResDims`,
`roiPhotoFileName`, background JPEG crop `_cropJpeg`), `time_lapse_plan.dart`, `roi_video.dart`
(ROI video clips, storage estimate, `VideoClipTotals`, `roiVideoFileName`), `crop_export.dart`
(crop export, gallery copy, `scanSessionPhotos`).

**logging/** `session_logger.dart` (append-only JSONL writer), `session_log_index.dart`
(`SessionLogIndex.build`: one pass over a session, feeds every summary tab), `past_sessions.dart`
(`sessionsRoot`, `scanPastSessions`, `PastSession`, `RecordingKind`, `recordingKindOf`),
`session_filter.dart`, `session_rename.dart`, `track_source.dart` (`trackSourceOf`),
`dashboard_stats.dart`, `visit_stats.dart`, `photo_box_matcher.dart`, `roi_update_debouncer.dart`
(`SettledUpdateDebouncer`), `device_thermal.dart`, `device_storage.dart` (`formatBytes`,
`folderSizeBytes`, `freeStorageClause`, `formatMegabytes`), `thermal_pause.dart` (`kDefaultPauseTempC` 43), `diagnostics.dart`,
`app_error_hooks.dart` (`logSwallowed`), `crash_store.dart`, `error_reporter.dart`,
`report_bundle.dart`.

**perf/** `adaptive_inference_throttle.dart`, `slow_phone_hint.dart`.

**postprocess/** FaunaLapse photo-session import: `faunalapse_import.dart` (r300;
`parseFaunaLapseLog`, `faunaLapseConfig`, `importFaunaLapseZips[InBackground]`, flow in
`screens/faunalapse_import_flow.dart`, Sessions ⋮); photos: `post_detector.dart`, `photo_keep.dart` (`keepDecisions`), `sahi.dart`,
`sahi_profile.dart`, `photo_tracker.dart`; videos: `video_import.dart`, `video_start_time.dart`,
`video_detector.dart`, `video_tracker.dart`, `video_frame_keeper.dart`, `video_box_timeline.dart`,
`video_run_samples.dart`, `clip_cleanup.dart`; `track_export.dart`.

**identification/** `label_pack.dart` (`.fpack` reader, `LabelPack`, `Scorer`),
`crop_planner.dart` (`planCrop`), `crop_worker.dart`, `identification_job.dart`,
`identification_store.dart` (result files, `stemOf`, `modelIdOf`, `modelKey`,
`LatestIdentification`), `track_fusion.dart`, `visit_merge.dart`, `taxa_table.dart`,
`identification_assets.dart` (model and list folders, `listBelongsTo`, GPU notes),
`identification_choice.dart` (`IdentificationChoice`, shared model + list choice).

**screens/** `home_screen.dart`; `camera_session_screen.dart` (live orchestration UI; logic in
`session/`); `settings_sheet.dart`; `session_summary_screen.dart`; `sessions_screen.dart` +
`session_actions.dart` (`SessionActions` mixin, `DeleteAllSessionsDialog`);
`dashboard_screen.dart`; `models_screen.dart` (Download & import models, `openModelsScreen`,
`NoModelNotice`); `watch_plan_screen.dart` (the "What do you want to watch?" pages);
`analysis_screen.dart` (Find animals in photos); `field_notes_screen.dart` (Field notes, from the
camera screen's pin button); `video_import_screen.dart`
(`pickAndImportVideos`); `video_analysis_screen.dart` (Find animals in videos,
`VideoSquareEditor`, `VideoAnalysisPrefs`); `video_tuning_screen.dart` (its "Detection, track ID
and identification settings" cards); `identify_settings_fields.dart` (`IdentifySettingsFields`,
shared by Identify organisms and the video cards); `identification_screen.dart`, `identification_results_screen.dart`,
`identification_choice_fields.dart` (`AlsoIdentify`); `problem_description_screen.dart`.

**widgets/** `roi_overlay.dart`, `roi_mask.dart`, `track_box_painter.dart` (live boxes cyan
`0xFF00E5FF`; ROI yellow `0xFFFFEB3B`), `preview_transform.dart`, `setting_help.dart`
(`HelpLabel`, `HelpSwitchTile`, `HelpRow`, `FoldSection`, `helperTextStyle`, `NotApplicable`: greyed,
not editable, with the reason),
`numeric_setting_field.dart`, `duration_setting_field.dart`, `session_tile.dart`,
`video_review_player.dart` (`VideoReviewPlayer`; `embedded` + null `onOpenAnalysis` on the Find
screen, `reload()`, `pause()`, `view`/`startAt`), `video_timeline_bar.dart` (`VideoTimelineBar`, the
one time bar of every video player), `screen_on.dart` (`ScreenOn.hold/release`: ref-counted
screen-on for the video players and video runs; never call WakelockPlus directly there), `video_speed_chips.dart`, `temperature_gauge.dart`,
`mini_bar_chart.dart`, `scroll_hint.dart`, `watch_tiles.dart` (`WatchIcon`, `SetupPicture`,
`roiPicture`), `model_kind_panel.dart` (`ModelKindPanel`, the kind colours and icons; optional
`color`/`icon`, `kTrackingColor` light green + `Icons.timeline` for track ID cards),
`tracker_tuning_fields.dart` (`TrackerTuning`, `newTrackGapWarning`: amber note when New-track is
under 0.10 above the confidence, shared by camera Settings and the video Track IDs card), `dialog_title.dart`
(`DialogTitle`, the X of every window),
`download_files_dialog.dart`, `download_model_dialog.dart`, `external_link.dart`,
`support_faunapulse.dart`, `session_info_dialog.dart`, `location_dialog.dart`,
`roi_size_sheet.dart`, `calibrating_banner.dart`, `home_button.dart` (`HomeButton`, `goHome`, `FitTitle`),
`selection_app_bar.dart`, `before_record_sheet.dart` (r298, `BeforeRecordSheet`, pref
`before_record_sheet`).

**services/** `recording_keepalive.dart` (foreground service + wake-lock), `analysis_keepalive.dart`
(`AnalysisKeepAlive`: reference-counted holds on native `AnalysisService.kt` for Find in
videos/photos and Identify).

## Current defaults

`SessionConfig` constructor in `models/session_config.dart`:

| Setting | Default | Notes |
|---|---|---|
| Detection model `modelPath` | `''` (none) | nothing ships; the camera starts without a model; live detection asks for one |
| Confidence / IoU | 0.25 / 0.7 | |
| Capture trigger | `detector` ("Live detection") | `motion`, `timelapse`: no detections, `predict()` never runs |
| Photo step / duration | 1 s / 10 s per track ID | step ≥ 0.1 s; duration > step |
| Session length | 60 min | ignored in scheduled runs |
| Scheduled recording | off | 1–3 daily windows (06:00–10:00) × N days |
| Inference FPS cap | 15 | 1–30 |
| Camera FPS cap | 15 | 0 = no cap; max 30 |
| Screen off by itself after | 0 min (never) | `screenOffAfterMin`, 0–10; Power tab |
| Stop at battery level / keep free storage | 15 % / 200 MB | `lowBatteryStopPercent` (on own battery only, 0 = never), `storageReserveMb` (50 to 5000, `fromJson` clamps a saved 0 to 50: the phone and the last files need room); `session/session_guards.dart`, checked in `_sampleThermal`. Start is blocked while free storage is already below the reserve (`storageBelowReserve`; red line on the Before you record sheet, `not_enough_storage_dialog.dart` on Start/REC; a scheduled window is skipped with a log line) |
| Auto-throttle | on | min 3 fps, duty target 0.5 |
| Motion gate | off | pixel delta 25, area 0.5 %, wake 3 s, grid 48 (16–160), idle check 5 fps (1–30) |
| Time between bursts | 30 min | `timeLapseGapSeconds`: end of a burst to start of the next; 0 = continuous |
| Save bursts as | photos | `timeLapseSaveAs`; `video`: one MP4 per burst at `timeLapseVideoFps` 5 (the video analysis rate) |
| Live AI video | off | `liveAiVideo`, 15 fps, 5-min segments |
| Camera sleep between bursts | on | `timeLapseCameraSleep`; idle gap ≥ 30 s; wake lead 10 s (1–60) |
| Time-lapse torch | off | `timeLapseTorch`; lead 5 s (1–60) |
| Stream resolution | auto | smallest probed size whose short side ≥ saved photo side; a manual pick sets `streamResolutionExplicit` |
| Photo source | `fast` | `auto`, `highRes` (wire name `still`) |
| High-res sync companion | on | `…_live.jpg` beside each high-res photo |
| Saved photo side | 1024 px | never upscaled |
| Occlusion tolerance | 3 s | |
| Minimum track length | 0.2 s | videos 1 s (Find animals in videos) |
| Tracker | `bytetrack` | `cbiou` |
| Log raw detections | off | |
| Reference photos | on, every 30 s | `gt_frames/` |
| Samples fps / temperature / power | 5 s / 10 s / 10 s | always logged |
| Use the GPU when it can run the model / CPU threads | on / 0 = auto = 2 | no speed check; only the benchmark compares |
| Crop 1:1 lock | off | |

Outside `SessionConfig` (shared_preferences): focus (manual close-up preset, screen state);
Find animals in photos `analysis_*` (tracker = camera's); Find animals in videos `video_analysis_*`
(5 fps, occlusion 3 s, min track 1 s, own tracker `video_analysis_tracker`/`_bytetrack`/`_cbiou`
from the class defaults: ByteTrack, New-track 0.50, never touching the camera's); Identify `identify_*`; thermal pause 43 °C (resume 3 °C lower) for video
analysis and identification; chosen models `analysis_model`, `video_analysis_model`,
`identify_model`, `identify_pack`; `home_watch_use`, `watch_choice_<answer id>` (the models used last per answer).

## Key invariants

### Words and screens
- **"Track ID", not "visit"**, in every text, file and record name (`track_ids.csv`,
  `post_track_end.track_ids`, …); durations say "track length". **A track length runs from the
  tracker's first sighting to its last frame everywhere** (summary, Dashboard, identification,
  Video tab = `track_ids.csv`): one rule, `TrackSpans` in `session_log_index.dart` (start =
  `created` event's `first_seen_ms` when logged, frame time `frame_ms ?? time_ms`, clamped to the
  session start); `video_box_timeline.dart` applies the same lead. "Visit" only for the ecological
  quantity (hand counts, visitation rate). Readers accept older names; saved-settings keys and
  Dart identifiers kept old names on purpose.
- Screen names in the UI: "Download & import models", "Find animals in photos", "Find animals in
  videos", capture trigger "Live detection", settings tab "Detection". Refer to screens by their top
  title. User-facing words: "name list" (Hugging Face and fauna-pulse-models say "label pack":
  the models screen help, README and IDENTIFICATION give it as the other name), "detector rate" (not
  inference rate), "yellow square" before "ROI"; download and import errors in plain words.
- **Every new tunable ships user-adjustable:** Settings control + `SessionConfig` JSON + summary
  row (`_settingsSection()`, `na:` when not applicable) + round-trip test, in the same round.
- **Settings are kept as typed (r313):** `NumericSettingField` never clamps silently (a number
  outside the range is refused, a red "Allowed: a to b" line shows, and leaving the box puts back
  the value it had); a comma is a decimal point; only the shown decimals can be typed; "Saved as X"
  when a host stores another number; `warning`/`rangeNote`/`zeroMeans`/`enabled`. **No control
  writes a second stored setting** (every keystroke commits, so "2" on the way to "20" used to leave
  ratchets): a rule between two settings is applied where the values are used
  (`SessionConfig.effectiveInferenceFps`/`effectiveMinInferenceFps`, C-BIoU uses the larger search
  margin) and shown as the box's amber `warning`. `FoldSection` is keyed by its title (give a fixed
  `key` when the title changes with a value); `NotApplicable` keeps one tree shape. Guarded by
  `settings_fields_test.dart` (every control of every settings screen typed or switched and back;
  a stored camera setting without a control must be listed there) and `tracker_effect_test.dart`
  (each tracker setting changes the result and reaches the built tracker).
- **New-screen layout checklist** (new screens keep shipping with these bugs): body in
  `SafeArea`, ListView bottom padding ≥ 32 or `+ MediaQuery.paddingOf(context).bottom` (an
  explicit `padding:` loses the automatic inset; a `Positioned(bottom:)` anchors to the screen
  bottom, under the gesture bar, since the app is edge-to-edge); `DropdownButtonFormField`
  `isExpanded: true`; long text in `Expanded`/`Flexible` + ellipsis (also in ListTile titles and
  sheets); a widget test at 360 px width with `simulateBottomSystemBar` that scrolls to the end
  and checks the last row with `expectAboveBottomInset` (templates:
  `summary_bottom_inset_test.dart`, `identification_results_screen_test.dart`).
- **Settings sheet tabs:** Setup / Detection / Photos / Power. All heat controls (auto-throttle,
  inference and camera caps, motion gate) are on Power, because Detection is greyed in the no-AI
  modes while the gate must stay editable. Expert knobs in `FoldSection`s. Every explanation sits
  behind an ⓘ (`setting_help.dart`); live status that depends on values (`statusText`) is always
  visible; on tiles only the ⓘ toggles help; `HelpSwitchTile` draws help below the tile, never as
  a `ListTile.subtitle` (toggling it trips a baseline assertion; tested).
- Session settings stay on the camera screen (they need the live camera); app-level actions go in
  the home Menu (drawer).
- **The house (`HomeButton`) in every title bar** but Home and Camera (left of a ⋮ menu):
  `goHome` closes screens one by one with `maybePop`, as that many Back presses would, so a
  screen that asks before closing (PopScope: a run, an import, a selection) stops the way there.
  New screens add `actions: const [HomeButton()]`; a long one-line title uses `FitTitle` (shrinks
  instead of being cut with a large system font size).
- **Every window (AlertDialog) closes the same way**: `title: DialogTitle(Text(...), onClose:
  <the Cancel/Close callback>)` puts an X at the top right that does what the bottom button does;
  that button says "Cancel" when the window asks to confirm something, "Close" when it only informs
  or offers something extra (no "Not now", "OK", "Done", "Got it"; "Keep running", "Stay" and "Keep
  the one on the phone" stay, as "Cancel" could be misread there). Windows with 2+ buttons set
  `actionsOverflowDirection: VerticalDirection.up` (stacked: main action on top, Cancel/Close at the
  bottom right). Progress windows without buttons have no X.
- **One unit per sentence:** two sizes in one sentence share the larger one's unit
  (`formatBytes(unitOf:)`; "only 0.0 GB" reads "almost no storage is free", `freeStorageClause`);
  a free amount next to the *Keep free storage* setting is whole MB rounded down
  (`formatMegabytes`), so 4999.6 MB never reads "5000 MB free … needs at least 5000 MB".
- **A SnackBar with a button stays until tapped** unless `persist: false` (Flutter's default):
  set it, with a `duration`, on bars that should go (camera permission, "Settings closed without
  Apply"). A kept `ScaffoldFeatureController` must be forgotten when the bar closes by itself, else
  a later `close()` hits an empty queue (debug crash file; release hides another bar): keep such
  a bar in `widgets/closable_snack_bar.dart` (`ClosableSnackBar`, forgets it on `closed`).
  Likewise a dialog's `TextEditingController` belongs to the dialog's own `State` (disposed in
  its `dispose`), never to the caller: the closing dialog still rebuilds its field when the
  keyboard goes down.
- **Selection mode** (Sessions, Download & import models): `selectionAppBar` (X "Stop selecting",
  "n selected", bar tinted like the selected rows). Back, the X, or unticking the last item ends
  it; a tap on empty space does not (not an Android convention).

### Camera and native view
- **Every new native camera view gets the live settings.** `YOLOView` is keyed on the stream
  size, so a stream change builds a new native view that only knows its creation params.
  `onNativeViewCreated` → the camera screen resets `_captureProbeStarted`, and the next frame map
  re-sends ROI, motion gate, camera fps cap, time-lapse mode and re-runs the probes. Anything new
  sent through the controller belongs in that start-up sequence. Thresholds travel as creation
  params. Check: `integration_test/view_recreate_check_test.dart`; logcat `FRAMEPERF`.
- **Camera2 interop options go through one funnel:** `applyInteropOptions()` in `YOLOView.kt`
  is the only caller of `setCaptureRequestOptions` (it replaces the whole option set, so manual
  focus and the fps cap are always applied together). Re-runs after every (re)bind and preview
  reattach. The fps cap picks a HAL AE range (closest ≤ requested; logged).
- **Plugin lifecycle:** `YOLOView.stop()` is restartable (never shut executors there);
  `YOLOView.release()` (from `YOLOPlatformView.dispose()`) is terminal. Model loads go through
  the one `modelLoadExecutor` + generation token; completions run on a main-looper Handler, not
  `View.post`. `stop()` closes models only after a frame still inside `predict()` ends.
- **No model:** `modelPath ''` → plugin `startWithoutModel()` + `startStreaming()`; frames
  without a predictor (outside motion/time-lapse) send a ~1 Hz `noModel` heartbeat so the Dart
  start-up still runs. The camera passes `_cameraModelPath` (the config path only when that file
  exists) and re-checks after Settings or the models screen (`_recheckModelFile`); live detection
  without a usable model asks (`_askForDetector`), never picks silently. A failed load
  (`onInitialModelLoadFailed` → `onModelError` → `_onModelLoadError`) reverts via
  `modelLoadRecovery()` (still-loaded model, else none) + dialog. `migrateModelPath` maps old ids
  to ''. The dialog never shows the raw reason (logged as `model_load_error`): `modelLoadAdvice`
  gives the QNN hints for `*_qnn.onnx`, else `kModelDamagedAdvice` (delete, then download or
  import again), the same words as Find animals in videos.
- **Camera lifecycle hold (r292):** CameraX binds to `YOLOView`'s own `CameraLifecycle`, which
  follows the Activity (started = RESUMED, stopped = CREATED) unless Dart holds it
  (`setCameraHold`, sent by `_pushCameraHold` while `_recording || _schedule != null`, also in
  `_startUpOnce`). Held + hidden: the camera runs, the preview is detached
  (`previewShouldAttach` = `previewEnabled && activityStarted`; `applyPreviewAttachment` never
  binds the preview while the camera is paused); a camera started while hidden never gets a
  surface provider. `RecordingService.running` stops a second (background) service start;
  the notification permission is asked only while visible. `screen` records mark hidden/visible.
  Screen-off timer (r293, `session/screen_idle.dart` + `_syncScreenIdle` on every hold change):
  with `screenOffAfterMin` > 0 the wakelock is let go N min after the last touch (global pointer
  route; app resume counts as a touch) and blackout comes up without re-taking the wakelock.
- **Blackout (power save) detaches only the Preview use case** (`setPreviewEnabled(false)`);
  analysis and ImageCapture stay bound, a recording continues. A timed session end calls
  `_exitBlackout()` before pushing the summary (brightness override is per Activity).
- **No YUV→RGB in Dart**: the native pipeline does it.
- **Photos only from a live camera:** the fast cut (`captureRoiFromFrame`) and the preview
  snapshot (`captureFrame`) return null when no frame arrived for 1.5 s (`FRAME_STALE_NS`;
  a frame still in `onFrame` counts as alive) or the preview is detached;
  `pauseCamera`/`stop`/lifecycle `onStop` clear the frame cache. Dart: time-lapse and
  reference photos wait while the app is hidden or no stream event came for 5 s
  (`_cameraFramesFresh`; `timelapse_skipped`, clip end `app_hidden`/`no_camera_frames`); a
  refused cut logs `app_error`. Reason: without the camera hold (r292) the power button and
  Home stop CameraX silently; with it (every recording) `_appHidden` no longer counts.
- **Portrait only**, locked in the manifest and `main()` (crop/rotation math assumes it). No
  code reads the tilt sensor: a sideways mount only turns every picture. Lift both locks only
  with a full orientation audit.
- **Start-up calibration is one cycle and cached:** `_calibrating` (first analysis frame +
  photo probe + analysis-ceiling probe) gates the controls; a failed model load still completes
  it. The slow photo-size probe is cached per device + app version + lens zoom
  (`capture_calibration_cache.dart`); start record `capture_dims_from_cache`.
- **Focus is always manual:** preset `kFocusPresetDioptres` 7.5 dpt (~13 cm), re-applied per lens
  switch; amber badge until the user moves the slider. No autofocus anywhere.
- **GPU vs CPU** depends on whether the GPU backend compiles the model's op graph, not on int8 vs
  fp16. A 2-strike GPU-crash blocklist demotes crashing models to CPU (`LiteRtModel.kt`). The
  engine benchmark (Settings) is user-triggered only.
- **Stream resolution:** the dropdown hides sizes above the probed analysis ceiling; the live
  "Stream: W×H" readout is the truth. Stream size only affects fast-crop sharpness, not
  detection. Logs record requested and delivered (`analysis_w/h`).
- **Motion gate idle:** only `motionGateIdleFps` frames/s are inspected (the rest are dropped in
  `YOLOView.onFrame` before conversion), so the camera fps readout shows ~that number while the
  gate sleeps; time-lapse shows ~1 fps between bursts. That is correct.

- **Swiping FaunaPulse away in Recents ends a recording:** `RecordingService.onTaskRemoved` calls
  `stopSelf()`, so the wake lock and notification go (r318); `AnalysisService` does the same.
- **Long jobs on saved files hold `AnalysisService`** (Find in videos/photos, saving kept frames,
  Identify): one reference-counted foreground service (type `dataSync`, `mediaProcessing` on
  Android 15+, both capped at 6 h a day there; `onTimeout` stops it; not yet run on an
  Android 15 phone) + partial wake lock. Taking a hold also asks for the notification
  permission (Android 13+), once per app start and only while the app is `resumed` (the system
  dialog cannot show otherwise); never awaited, the job runs whatever the answer. Every
  notification (recording, analysis, "Animals found") uses `R.drawable.ic_notification`, a
  one-color vector: Android draws only the shape of a small icon, so the app icon was a white
  square. Android
  12+ refuses a start from the background, so a job takes its hold on the tap on Start and a
  chained job ("Also identify them") takes its own before the first releases. Both permissions
  (`FOREGROUND_SERVICE_DATA_SYNC`, `..._MEDIA_PROCESSING`) must be declared in Play Console.
  `RecordingService` stays type `camera`: dataSync's daily cap would end long recordings.
- **Stop shows "Stopping…"** (`widgets/record_button.dart`): taps are ignored until the stop
  has closed the files, so a double Stop opens one summary.

### ROI and photos
- **ROI is ÷32 WYSIWYG:** the box, readout, saved crop and inference ROI are the same square (a
  square needs no letterbox padding before the square model input);
  side snaps to a multiple of 32, capped to the frame's short side (720 → 704). Single mutation
  funnel `_onRoiChanged` (camera screen); helpers in `models/roi.dart`.
- **One scale:** the box readout, slider and snapping use the analysis stream grid
  (`_roiSourceWidth == _imageWidth`); the high-res source only feeds the "saves N×N" label
  (`_savedSideNow`). Never make the box grid follow `_activePath`.
- **Crop paths already snap and cap** (don't fix again): plugin `ImageUtils.cropRoiFromFrame`
  (fast, on `stillExecutor` via `captureRoiFromFrameAsync`), `MainActivity.cropRoiJpeg`
  (high-res), Dart fallback `_cropJpeg`. Downscale above the target, never upscale.
- **Photo source is chosen per photo** (`chooseCapturePath`, `savedSidePx`, `capSavedSidePx`;
  `targetRoiSavedPx` is both threshold and cap). High-res photos pause the analysis stream
  0.13–1.5 s and show the scene after the detection; the `_live` companion is the trigger-moment
  crop. Records log `path`, `saved_px`, `content_lag_ms`, `live_*`. True zero-shutter-lag never
  engages on the Xiaomi (~0.17 s is the floor): don't chase it in software.
- **ZSL buffer only for Auto/High-res (r294):** `ImageCapture` uses ZERO_SHUTTER_LAG only when
  the photo source is not `fast` (`_stillZslFor`; creation param `stillZsl` + `setStillZsl`,
  pushed in `_startUpOnce` and before the settings-close resume; read at each `startCamera`).
  ZSL adds two 4000×3000 streams the camera fills all the time (`dumpsys media.camera`).
- **High-res photos are processed off the main thread and never full-frame rotated:**
  `capturePhotoRaw` returns the unrotated JPEG; ROI mapped by `rawRectForUprightRect` (Dart, with
  a Kotlin mirror in `MainActivity.kt`: keep in sync); probe dims go through
  `uprightHighResDims` (the probe decode may already be upright). Don't reintroduce
  `normalizeJpegOrientation` on this path.
- **ROI logging:** the `roi` block is expressed against the photo source; start and `roi_update`
  records also carry `roi_side_stream_px` (what the summary shows). `roi_update` is debounced
  (2 s, flushed in `_stopRecording`).
- **Photo file names:** `roi_<token>_<yyyy-MM-dd>_<HHmmss>_<SSS>.jpg` (4-char session token
  `file_token`, then the trigger moment in local time; path sort = capture order). No track IDs
  in names. Session photos carry no EXIF; only user-exported crops get DateTimeOriginal + GPS.
  The trigger moment is logged as `captured_at_ms`.

### Logging and session data
- **`session.jsonl` is append-only JSON Lines** (one object per line, never pretty-printed):
  start record (config, `app_version`, `app_build`, `build_mode`, `file_token`, `location`,
  `tracker_params`, `config_not_applicable`), one `detections` record per frame (`tracks[]` with
  track ID, `box_in_roi` 0..1, saved file names, `frame_ms`, `frame_sensor_ms`), `track_event`
  (`created`/`lost`/`recovered`/`removed`), `capture`/`motion_capture`/`timelapse_capture`/`timelapse_skipped`,
  `raw_detections` (opt-in), `fps`/`thermal`/`power` (with `is_plugged`), `motion_gate`,
  `roi_update`, `blackout`, `screen`, `guard_stop`, `focus_change`, `camera_sleep`, `torch`, `video_clip`,
  `video_skipped`, `app_error`, `end_of_session` (`ended_normally`). Record dictionary:
  `docs/DATA_GUIDE.md`. Parsers also accept the old per-track `detection` records.
- `detections[].tracks[]` boxes are always detector-observed (unmatched tracks go `lost`).
- **Frozen wire names** (do not rename): reference photos `gt_frames/`, `gt_capture`,
  `gtFramesEnabled`/`gtFrameSeconds`; high-res photo source `still` (config `captureMode`,
  capture `path`, `roi_source`); JSON key `stillSyncCompanion` (Dart `highResSyncCompanion`).
- Each session is one folder in `<app external files>/sessions/` (`sessionsRoot`, reachable over
  USB). The session folder also holds `logcat_start.txt` / `logcat_end.txt` (the app's own logcat
  lines), `roi_frames/`, `gt_frames/`, `videos/`, and the post-hoc files.
- While the gate is idle (or in no-AI modes) `fps` records omit inference fields and carry
  `gate_idle: true` / `motion_only: true`: never log stale or zero inference numbers. The fps
  EMAs skip long gaps (`Predictor.finishTiming` ↔ `FrameProcessor.updatePipelineFps`: keep in
  sync).
- **Writes:** an in-logger queue with one async writer (never sync I/O in the frame callback),
  fsync ~0.5 s, `close()` must be awaited so `end_of_session` lands.
- **A session never dies silently:** the logger counts write failures (storage full) and shows a
  red banner; global hooks (`app_error_hooks.dart`) route uncaught errors to `app_error` lines.
  No naked fire-and-forget futures; best-effort `catch` blocks call `logSwallowed(site, e)`.
- **Rename** (`renameSession`) is the one allowed edit of a finished log: folder rename,
  `config.folderName` rewritten via temp file + atomic replace, plus an appended
  `session_renamed` record.
- **Derived results stay out of `session.jsonl`:** post-hoc files (`post_detections.jsonl`,
  `video_detections.jsonl`, `post_tracks.jsonl`, identification files) join on file names and
  track IDs. Exceptions appended after the end: `session_renamed`, `video_cleanup`.
- **Location:** one GPS fix per session (`LocationFixTracker`: done at the user's goal, default
  `kDefaultGpsGoalM` 10 m, 0 = whole time, or `kGpsMaxWaitMs` 3 min, r302), or manual
  / previous; `redactLocation` strips it (and `field.location`) from problem reports.
- **Before you record (r298):** REC (start) shows `BeforeRecordSheet` while the pref is on
  (default): field notes + position, `planSentence`, phone tips; Change opens Field notes or
  Settings and the sheet comes back; Start → `_startRecording` or `_startSchedule(batteryNudge:
  false)`. Pref off → the older battery nudge and schedule confirmation. The start record gets
  `phone_state`. Device checks that tap REC call `skipBeforeRecordSheet()`
  (`integration_test/skip_before_record_sheet.dart`).
- **Field notes (r297):** the pin button opens `FieldNotesScreen` (position first, via the
  location dialog; fields saved as typed); the start record gets `field` (`FieldNotes.recordBlock`,
  phone maker/model filled from `device` in `SessionRecorder._withPhone`); summary Overview rows.
  Site photos (r302, `session/site_photos.dart`): taken with the camera app into
  `site_photos_waiting/`, listed in `field.site_photos` and moved into `<session>/site_photos/`
  at Start; `site_photos_about` cleared after each Start.
- **Problem reports** (Menu → Report a problem; built in `error_reports/`, the only folder the
  report FileProvider serves): one `.txt`, or one `report_<stamp>.zip` when
  screenshots or session samples ride along (sharing several files made WhatsApp drop all).
  Session samples stay valid JSON Lines (`{"type":"sample_omitted",…}` marker), flood records and
  logcat noise dropped, location redacted. Send via share sheet or the GitHub Issues link
  (`ErrorReporter.githubIssuesUrl`); e-mail code stays dormant. Crash files
  `crashes/crash_<stamp>.txt` (newest 20) from Dart `crash_store.dart` and Kotlin
  `MainActivity` (keep `writeCrashFile` ↔ `crashFileBody` in sync).

### Capture modes
- **Motion gate** (native `MotionGate.kt`, EMA background diff on the ROI): skips inference while
  nothing moves; motion, detections and ROI drags extend the wake window; idle heartbeats
  `gateIdle: true` ~1 Hz; on wake after > occlusion, lost tracks expire. Never gate in Dart.
- **Motion-only capture** (`motion` trigger): a `motionOnlyMode` branch in `onFrame` before
  `predictor?.let`; awake maps at ≤ 10 Hz with dims (mandatory for the Dart ROI bootstrap); a new
  motion event = a gate sleep→wake cycle (`resetMotionWindow`). Returns before the 0-FPS
  watchdog. `recordFrame` is skipped (no `detections`).
- **Time-lapse** (`timelapse` trigger): photos on a Dart clock (`TimeLapsePlan`, gap-based:
  `cycleMs` = burst + gap) with a self-rescheduling `_timeLapseTick` (≤ 60 s). Native
  `setTimeLapse` drops frames before conversion (ceil(2/step) fps in a burst, 1 fps between);
  gate forced off; `predict()` never runs, also not the inference-cap check.
- **Camera sleep between bursts** (`TimeLapseCameraCoordinator`, pure state machine
  running/parked/warming/fallbackBound): photos only when `framesUsable`; the burst grid never
  shifts; a failed park/wake → camera stays on for the session; the dead-camera watchdog is
  suppressed only while the camera is intentionally down. Torch: `_setTorch` reconciles with the
  confirmed state, retried only while `framesUsable`; prewake = max(wake lead, torch lead).
- **ROI video clips** (Save bursts as: Video; live AI video): plugin `RoiVideoWriter.kt` +
  `YOLOView.startRoiVideo/stopRoiVideo`. Frames are the unrotated ROI square copied into reused
  bitmaps, made upright and scaled on the GPU in the writer's own EGL context; PTS from sensor
  time. Never `lockHardwareCanvas` (aborted the app on the Xiaomi). H.264, files
  `videos/roi_<token>_<stamp>.mp4`; records `video_clip` / `video_skipped`. `pauseCamera`/`stop`
  close an open clip. Live AI video: segments of `kLiveVideoSegmentMs` (5 min), frames taken
  before the gate/detector path.
- **Scheduled recording** (`SchedulePlan`, reconciled by `_scheduleTick` ≤ 60 s): each window is
  its own session (`<name>_d<day>w<win>`); between windows the camera is fully unbound
  (`_controller.pause()`) behind a status-tap blackout; `SessionRecorder.stop(retainKeepAlive:
  true)` keeps the foreground service and wake-lock. No AlarmManager: staying in the foreground
  is the MIUI survival strategy.
- **Field power:** the phone is on a power bank in the field. Charging heat is expected; the W
  graph hides when plugged or charging (current then measures charging).
- **Keep-alive service** is non-sticky and renews a 30-min wake-lock every 25 min.

### Tracking
- Two pure-Dart trackers behind `InsectTracker`: ByteTrack-style (default; distance fallback
  against ID fragmentation) and C-BIoU-style (buffered IoU). Shared seconds-based settings
  (frame counts re-derived live; videos use one fixed rate per run). New track IDs start only at
  "New-track confidence" (`highThresh` 0.5; Find animals in videos keeps its own tracker values in
  `VideoAnalysisPrefs`). New-track is the user's value (0.05 to 0.95), never floored or raised by
  the confidence (r313; the reference trackers keep 0.15 to 0.6 between the detector's lowest box
  and the new-track threshold, none forces it). Faint boxes (confidence to New-track) can confirm
  a tentative track and revive a lost one here, unlike Ultralytics/BoT-SORT (audit r313: kept,
  tune with the annotated videos first). `kMinDetectionsInARow` 2 (`tracker.dart`): a track starts
  on its first box and confirms on a later match, so the seconds-to-frames conversions use at
  least 2. The camera swaps the tracker only when settings close (settings are locked while
  recording); a GPU/CPU-thread change reloads the model at once (plugin `didUpdateWidget`, r313).
  The start record's `tracker_params` holds the values and frame budgets used (the summary's
  derived rows read it).
- `replayTracker` (videos, photos, session replay) treats a gap as a pause (expires lost tracks)
  only when it is longer than the occlusion tolerance AND twice the frame rhythm (r313: an
  occlusion at or below the frame gap wiped every track).
- Replay: `flutter test test/fauna_pulse/tracker_replay_test.dart
  --dart-define=REPLAY_SESSION=…/session.jsonl`. A tracker variant becomes default only after
  it wins on hand-counted sessions (ByteTrack matched them; C-BIoU fragmented).

### Find animals in photos (`analysis_screen.dart`)
- `PostDetector` runs the plugin's camera-free `YOLO.predict` over `roi_frames/` →
  `post_detections.jsonl` (`post_start`/`post_detection`/`post_end`/`post_cleanup`); resumable;
  a high-res/`_live` pair is one capture moment ("photos" count moments, "files" count files).
  Settings in prefs `analysis_*`, not SessionConfig.
- Purpose: storage triage for no-AI sessions: keep photos with a detection plus neighbours
  within a gap (2 s), delete the rest after review (`keepDecisions` is the one keep rule).
  Re-analysis of a live-AI session with the same model is blocked.
- SAHI tiles (`sahi.dart`, own pure-Dart code, no SAHI library; native `predictTiledImage` with
  automatic fallback): merge by IoS, opt-in tiny-box filter applied live at review
  (`applyMinBoxFrac`).
- Track IDs from photos (`PhotoTracker`, `PhotoTrackability.possible`): only for no-AI sessions
  with step ≤ 0.5 s; writes
  `post_tracks.jsonl` (`source: photos`).
- "Also identify them" (both Find screens, pref `find_also_identify`): after detection and track
  IDs, starts `IdentificationRun.autoStart` itself (no frames are drawn in the background, so a
  page could not start it) and pushes `IdentificationScreen`, which attaches to that run.

### Find animals in videos (`video_analysis_screen.dart`)
- Import (`video_import.dart`): files moved into `<session>/videos/`; `session.jsonl` = start
  (`source: imported_video`) + `video_clip` per clip + end. Clip start time: `video_clip` record
  > file name > MP4 time minus duration (Android stores the stop time) > day-only name > mtime
  (DATA_GUIDE §9; names "date at time" read, 12-hour AM/PM names only the day). Import screen:
  the note under the start says what the file name and the stored time gave before any change;
  Change… sets day, hour and minute with seconds 0 (24-h picker), one shift for every clip,
  "Back to the time(s) read from the file(s)" undoes it; the suggested name follows the day.
  Fragmented MP4s (top-level `moof`) are rewritten at import by native
  `VideoFrameSource.remux` (`isFragmentedMp4`) and checked (same frames, times within rounding),
  else `ImportRewriteFailed` with a ready ffmpeg command; 10-bit/HDR refused. While an import
  fills a folder it holds `.import_unfinished` (`kImportUnfinishedMarker`); `main()` runs
  `deleteVideoImportLeftovers` (marker + no end record = deleted; plus the photo picker's UUID
  copy folders in the cache) after the `.part` sweep. The Import videos screen re-reads free
  storage on resume and before the copy; picker and copy errors are plain words.
- Progress: *ms per frame* and time left leave out heat pauses; an unknown clip length says
  "time left not known yet" (clip lengths read with `VideoFrameSource.info` when no
  `video_clip` record has them).
- Detection (`VideoDetector`): MediaCodec decode → ROI-only YUV→RGB (banded thread pool) →
  detect → `video_detections.jsonl` (`video_run_start`, `video_clip_start`, `raw_detections` with
  `clip`/`pts_us`/`frame`, `video_clip_done`/`video_clip_error`, `video_run_end`; boxes
  `[l,t,r,b,conf,class]` normalised to the whole upright frame, the live shape). Sampled by PTS
  at `kDefaultVideoAnalysisFps` 5; resumable per clip; one native video source at a time
  (`_busy`). Cut-off clips (no `moov`; `isReadableVideo`, `cutOffClipsOf`) are skipped with a
  delete option.
- Area: a session never analysed proposes the largest centred square of its first clip
  (`largestSquareSidePx`, one rule for camera, editor and default); a session run before keeps
  its last area. `VideoSquareEditor` plays clips muted at 4×.
- Settings: one tile "Detection, track ID and identification settings" (three summary lines,
  disabled while busy) opens `VideoTuningScreen`, also before any run: `ModelKindPanel` cards
  Detection (confidence, fps, IoU, pause temperature, sample interval), Track IDs (`TrackerTuning`
  on `VideoAnalysisPrefs.trackerConfig`: the values as typed; the New-track note compares with the
  last run's `confidence`, `analysedConfidence`; occlusion note under two analysed frames;
  minimum length, keep frames, fine-tuning fold, reset to plain defaults; a note when the videos
  were deleted) and Identification
  (`IdentifySettingsFields` in `NotApplicable` when live AI, keep frames off or Also identify
  off). Prefs are edited in place and saved on change.
- One main button for what is due: analyze (pending clips or changed detection settings) >
  find track IDs (missing, `_stale`, or `_trackChanged` vs `post_track_start` incl.
  `trackerUserValues`) > "Identify the animals found"; with clips left, a text button "Find
  track IDs for the clips analyzed so far". Results section only once track IDs exist.
- "Watch the results" (last item, `_watchSection`): the embedded `VideoReviewPlayer` once a clip is
  analysed and a video exists; left out of the tree while `_busy` (one native video reader at a
  time; `endOfFrame` wait before the run and frame saving), paused before every push/dialog,
  `reload()` after changes when it stayed, a new player starts at the old `view`; `GlobalKey`
  per session.
- Video tab (`VideoReviewPlayer`, ExoPlayer via `video_player`, over `VideoBoxTimeline`): play
  state on a `ValueNotifier`, not the controller (rebuilding at 10 Hz made playback stutter);
  boxes hidden while the player fetches the picture after a jump; wake-lock while playing. One
  time bar that is also the slider (`VideoTimelineBar`, also in `VideoSquareEditor`): grey, cyan
  `ClipBoxes.trackSpans` (green `rawSpans` in All boxes), white kept-frame marks, marker from
  `_posMs`; tap/drag seeks go through `_seekTo` (drag pauses, max one seek per 150 ms); the line
  under it gives the share of the clip with track IDs. Live AI video sessions can switch
  "Live AI | AI afterwards".
- Track IDs (`VideoTracker.run` via `replayTracker`): one tracker across clips only when the gap
  ≤ occlusion; writes `post_tracks.jsonl` (`post_track_start`, live-shaped `detections` +
  `track_event`, `post_track_end`; tmp + rename), `track_ids.csv`, `mot/<clip>.txt`.
  **One tracks file per session:** `trackSourceOf(dir)` = afterwards when `post_tracks.jsonl`
  exists and no live tracker ran, else live; every reader (index, identification, dashboard)
  uses it.
- Kept frames (`TrackKeepRule`, shared with live capture; `VideoFrameKeeper`): live-shaped
  `capture` records with `source: video`; a new run deletes frames the old one kept, never when
  their video is gone. Identification stores `visits_run_id`: crops from an older run are
  outdated (`cropsOutdated`).
- Free storage: `ClipCleanup` (`planWithoutVisits`/`planAll`/`planCutOff`/`run`) deletes clips
  without track IDs, all clips, or cut-off clips and
  appends `video_cleanup`; sessions whose clips were deleted stay listed.
- Phone samples during a run (`thermal`, `power`, `analysis_speed`) feed the summary's "While
  the AI ran" graphs (`VideoRunSamples`).
- PC evaluation kit: `docs/VIDEO_ANALYSIS.md`, `tool/video_eval/` (`evaluate_track_ids.py`,
  `prepare_square.py`, VIA3 hand counts `via3_to_hand_count.py`); sweep test
  `test/fauna_pulse/video_fps_sweep_test.dart`.

### Identification (`docs/IDENTIFICATION.md`)
- Job: plan crops from the log index (one per photo per track ID, `_live` preferred; square on
  the box's longer side by default (`square_crops`), margin × side; CLIP-mean padding) → crop in an isolate →
  native embed (batches of 8, plugin `Embedder.kt`) → append-only
  `embeddings_<model>.{jsonl,bin}` (resumable) → score → `tracks_<pack>.{csv,json}`,
  `crops_<pack>.csv`, `summary_<pack>.json`. Settings in prefs `identify_*`.
- Score per track ID: "Average Logit" (Dussert et al. 2025): crops' unit embeddings averaged with
  certainty weights
  (top-1 p), crops below max weight / `drop_factor` (10) left out, scored once, rolled up the
  taxonomy; ladder tau 0.6 (prefs `identify_tau`). Columns Conf. / Agree; suspect flags (short, few detections, weak
  ID; defaults from insect-detect-post's `filter_tracks`, Sittinger 2026, Zenodo
  10.5281/zenodo.21822140: credit the idea's source and the implementer separately). Optional merge of consecutive track IDs (off). `reproduce_track_conf.py` reproduces the
  numbers on a PC. Defaults are not validated on pollinators (IDENTIFICATION.md).
- Class lists: a classifier (`insectdct-cls-v7-eff2s_224_fp16.tflite`, raw scores) pairs with the
  `.fpack` of the same name (`LabelPack.isClassList`, `ImageEmbedder.load(normalize: false)`).
  Label packs pair by the first part of the name (`listBelongsTo`, else header `model_id`).
  A row counts only down to the rank above its first empty slot (`rollUp`, `_buildRankIds`):
  v2 packs empty the slots below genus or family for odd names (header `name_rules`).
  Identify needs a matching list; a dimension mismatch is refused before embedding.
- GPU: checked once per model file + `Build.FINGERPRINT` against CPU (cosine ≥ 0.995
  `GPU_MIN_AGREEMENT`, else CPU with a note); refused when `GPU_MEMORY_FACTOR` 4.5 × file size >
  `GPU_MEMORY_SHARE` 0.6 × phone memory (`Embedder.kt`). BioCLIP 2 needs the 4-D
  attention export (`export_image_tower.py --attention 4d`); BioCLIP 2.5 is CPU-only on today's
  phones. fp16 everywhere (int8 changed answers).
- Results screens: taxon table → track-ID sheets → one track ID (ladder, photo with detector box
  and crop). Mini-table kit measures column widths; ids/names left, numbers right.

- **One job, one model user:** one Identify job per session at a time (`IdentificationJob`
  `_activeSessions`); runs and Test speed take the static model lock
  (`IdentificationRun.takeModel`) before `ImageEmbedder.load` and free it after `close()`.
  The run lives in `identification/identification_run.dart` (`IdentificationRun`, one per
  session, `of`/`start`/`autoStart`), apart from the page, so it starts and runs in the
  background; `IdentificationScreen` only shows it. Back during a run asks first (`PopScope`);
  leaving cancels the job (r318).
- **A chained identify load in the background checks memory first** (owner's decision, r319):
  only when "Also identify them" hands over while the app is not `resumed`,
  `IdentificationRun` asks the plugin (`ImageEmbedder.memory` → `Embedder.memoryCheck`) and loads
  only if `identifyFitsInBackground`: free (the smaller of `availMem` and MemAvailable) minus need
  (CPU `CPU_MEMORY_FACTOR` 2.15 × file, GPU 4.5 × file) ≥ Android's threshold +
  `kIdentifyMemoryMarginBytes` (100 MB). Else it does not load (the Find results are saved already): it releases its service hold,
  shows "Animals found" (channel *Identification waiting*, `AnalysisService.showReminder`) and
  waits in memory for `resumed`, then takes a new hold and loads. A run started in front never
  checks (Android frees other apps for the app in front). Calibrated on the 3.6 GB Redmi (BioCLIP 2
  fp16 609 MB: +1.25 GB native at load; killed at 0.94 and 1.08 GB free; insectDCT needs ~90 MB).
  Strict on purpose and accepted as is (owner, 2026-10-21: a measuring tool; no special rule for
  large phones): a wait costs one tap, a kill loses the run silently. So BioCLIP 2 on the GPU
  always waits in the background on the 11T Pro (reports 7.2-7.4 GB). Instead users are told to
  keep the app on screen: one line (`identification_choice_fields.dart`) under *Also identify
  them* and on *Identify organisms* (above Start and under the progress). Logged as logcat
  `identify_memory_check` and `identify_start.memory_check` (`decision`, `waited_s`).
- **A run survives or reports a closed app** (`identification/identify_wait_note.dart`): a chained
  run that waits or loads in the background first writes `identify_waiting.json` in the app's
  files folder (session dir, chain, `created`, `attempts` 0); every other run writes it with
  `attempts` 1 once it has the model (`_go`). Home takes it when the app opens or resumes
  (`takeOnOpen`): 0 starts the run again, setting 1 BEFORE the start; ≥ 1 starts nothing (no
  heavy work by surprise; a start that gets the app closed is never repeated) and shows a 10 s
  bar saying how to continue from the Sessions ⋮ menu. Ignored after 24 h; deleted at the run's
  end, on Stop and with its session.
- **Native memory is given back after the embedder closes** (`NativeMemory.giveBack`, bionic
  `mallopt`): each step is checked by the app's resident memory (RSS) and the next tried only if
  nothing came back (M_PURGE_ALL, then M_PURGE, then decay 0 + purge), since on Android 12
  M_PURGE_ALL answers "done" and frees nothing. Frees about 1.2 GB at once on both test phones.
  Logcat tag `NativeMemory`: one `mallopt from <path>` line, then each step's answer and RSS
  before -> after (no "(mode N)" any more).
- `identify_end.unreadable` counts crops whose photo could not be read (part of `failed`); the
  screen gives them their own red line and promises no retry. Identify's time left leaves out
  heat pauses (as Find in videos).

### Models and downloads
- **Model facts** (origin, licence, conversion, citation of each offered model): its model card
  on Hugging Face (https://huggingface.co/collections/Valen-Peregrine/faunapulse, `kModelsCollectionUrl`; card sources `hf_cards/` in
  fauna-pulse-models). This repository keeps only `assets/model_downloads.json` (licence and
  source per model, also for models not offered, such as ArthroNat n).
- Formats: `.tflite` or `*_qnn.onnx` (Snapdragon NPU; its runtime only in the NPU edition,
  `-P qnn=true`, r299; the normal build fails such a model with `modelLoadHint`'s edition
  line); plain `.onnx` refused
  (`isSupportedModelFileName`). LiteRT `format=litert` NCHW exports run (detect only).
- **Security:** models live in private app storage; intake is HTTPS-only, rejects unsafe names
  and traversal, streams through a temp file, checks the `TFL3` identifier; one size limit of
  2 GiB for every model file and name list, detectors included (`kMaxModelFileBytes`; the
  plugin's Kotlin label reader maps the whole file, which Java allows only up to 2 GiB). A web
  page answer (`text/html`) is refused before its body downloads; 401/403/404 get plain
  words (`downloadStatusMessage`; a pasted link's 404/401/403 say to check the link), other failures
  too (`plainModelError`: no internet, connection lost, no storage; the technical text only in the log); a pasted Hugging Face `/blob/` link becomes `/resolve/`
  (`directFileUri`, link downloads only). These checks run only at intake, never in the
  camera path.
- **No bundled models:** `assets/models/bundled_models.txt` is empty; the camera picker lists only
  imported/downloaded files. Debug builds still pack local weights for device checks.
- **Download & import models** (`models_screen.dart`) is the only place to import, download and
  delete model files and name lists. Each kind is ONE list by file name (`fileNameOrder`: case
  ignored, "_" before ".", so bioclip-2 before bioclip-2.5), files on the phone and files to
  download together: a file on the phone has the green `OnThisPhoneLine` (shared with the watch
  pages), ⓘ and delete; a file to download shows its catalogue title and size and a Download
  button (its name may break after "_"). Details behind ⓘ (from the file: classes, input size,
  "Number format" fp16/int8/fp32 in words; plus title, licence and source when listed; a name list
  from Hugging Face links its model card, `_modelCardUrl`). Deleting an identification model takes
  its name lists along unless another model still uses them; "Delete all …" per kind; press and
  hold selects several. Each kind sits in a `ModelKindPanel`: detection light blue,
  identification orange (faint fill, thick line on top, framed-circle or microscope icon); the
  same panels split the watch pages' fold. A listed identification model counts as on the phone
  by its file name or, for BioCLIP (label packs), by any file of the same model key
  (`idModelFor`). Under each identification model sit its name lists (on the phone or to
  download, by file name, "Name lists for your region and the animals you watch:"); a BioCLIP
  model not on the phone has its own Download (model alone) and two numbered steps ("1. The
  model, needed once", "2. Then the name lists…"), a list's Download also brings the model; name
  lists on the phone of an offered model that is not sit under that model; "Name lists without
  their model" holds only lists of models neither on the phone nor offered. A classifier to
  download is one row (model + class list). The ⓘ card of a model to download does not repeat
  its label packs (only their shared licence and source). The note at the top ("About these
  models": adapted to run on a phone, each model's own licence and how to cite it from ⓘ, the
  Download buttons get the files from Hugging Face) names no makers; the Hugging Face collection
  link (`kModelsCollectionUrl`, to download on a computer and import) sits under "Your own
  models", next to Import (at the top it invited downloads there). The panel's first text says
  what a name list is and why a list that fits the region and the animals gives better names.
- **Download list** `assets/model_downloads.json` (format 3; `tool/model_downloads/README.md`):
  one `models` array (`id` = the `<model>` part of the naming rule, `kind`, `licence`, `source`,
  optional `file` = offered, `name_lists` with `kind` class_list/label_pack; `former_name_lists`
  = never offered, a copy on the phone keeps its details and shows its `note`/`warning`) and `uses` (the home
  answers: `id`, `icon`, `title`, `setup`, `find` ids, `name` {model, list}; insect answers find
  flat-bug n, then flat-bug s, then insectDCT (flat-bug = default demo, owner); the first of each is
  "Suggested AI models"; naming is BioCLIP 2 first in every answer: the Europe v2 list for
  pollinators and flat surface, the world v2 list for mammals and birds). Presence on the phone = file name only; `sha256` only verifies a download.
  Files kept under the names used before the Hugging Face move get the new names at app start
  (`former_model_names.dart`, `renameFormerModelFiles` in `main()`: old name + same size, new name
  free), and the saved choices that name them follow (`faunapulse_session_config`,
  `analysis_model`, `video_analysis_model`, `identify_model`/`identify_pack`, `watch_choice_*`);
  the old insectDCT class list (it names the old model file inside) is deleted once its model is
  renamed. Sessions keep the old names: `VideoResume.parse` maps the stored model through
  `currentModelPath` (a stopped run can be continued), and `IdentificationPaths` renames
  `embeddings_<old stem>.*` to the new stem when looked for. A future rename of a published file
  needs a line in `kFormerModelNames`.
  `update_catalogue.py` refreshes sizes and checksums; `--urls <published.json>` takes the
  published names and Hugging Face links pinned to a commit (from fauna-pulse-models'
  `publish/published.json`, matched by SHA-256; renames the `uses` lists too). Every offered file has its own Hugging Face link pinned to an upload commit (account
  `Valen-Peregrine`, one repository per model family, public since 2026-10-16); `base_url`
  (GitHub release v0.8.0-alpha.1) is used by no file now. Device check of the whole list:
  `integration_test/catalogue_download_check_test.dart` (side-by-side `.check` copy, `MAX_MB`).
- **What do you want to watch? pages** (`watch_plan_screen.dart`): setup drawing, "Suggested AI
  models" / "Your choice" by file name, each file with a green tick (on the phone) or the
  download icon and its size; the answer in use (`home_watch_use`) opens with
  `currentModelChoice` (param `inUse`) plus "Back to the suggested models"; one button at the bottom edge ("Download and use (size)" / "Use
  these"; it pops the `ModelChoice`); the fold "Choose other models" lists the other suggestions plus "Other models on this
  phone" (every other detector and identification model + name list pair, `namingPairs`), in two `ModelKindPanel`s
  ("To find the animals", "To name them"); each row is a radio icon centred on the file name, details under it (no
  `ListTile`: it moved the icon off the name). Saving
  = `useModels`: camera `modelPath` + task, `analysis_model`, `video_analysis_model`,
  `identify_model`/`identify_pack` ("Not now" removes both).
- **A tap on an answer switches to it** when its models are on the phone (`readyChoice`): the
  models used last for it (`watch_choice_<id>`, `rememberWatchChoice`/`watchChoices`), or for an
  answer without them its first suggested detector on the phone plus its first suggested
  naming on the phone; the answer in `home_watch_use` without them keeps the models in use. Then
  its page opens (Back keeps the switch; unsaved choices on the page are dropped). Nothing
  ready: only the page's button switches. The answer in use (`_activeUse`: `home_watch_use`
  while the camera's detector is the one remembered for it, or one of its `find` if none) has a
  ring, a tick and bold words (`WatchIcon.selected`); step 2 shows its phone screen.
- A model needs a list entry only to be offered or suggested; any model on the phone can be
  chosen everywhere.

- **Downloads:** a second download of a file that is already being written is refused
  (`_activeDownloadTargets`); leftover `.part` files are deleted at app start
  (`deleteLeftoverPartFiles`) (r318). A write that hits full storage (`isNoSpaceLeft`, errno 28)
  deletes the `.part` and ends the download with plain words and the amount to free (never a
  hang); the Download dialog checks free storage when it opens and on app resume, and greys
  Download while the files do not fit (one unit for both sizes). *Import model files…* does the
  same (`copyAndValidateModel`, logged `model_import_no_space`: stops at once, deletes the half file)
  and shows its progress and green-tick result under its button (`ModelImportProgress`), not a
  snack bar. "Could not reach the server" names airplane mode when it is on with Wi-Fi off
  (`plainModelError(phone:)`).
- **Write errors end jobs with plain words, never a raw exception:** downloads (above), Find in
  videos (`isStorageFullError`: "Storage full: … press Continue"; Continue first repairs a cut
  last line of `video_detections.jsonl`), finding track IDs, saving kept frames, video import.
- **A model that cannot load is a model problem:** the plugin returns `model_error`
  (`VideoModelException`), Dart writes `video_model_error` and stops the run instead of marking
  clips unreadable; camera and video screens show `kModelDamagedAdvice`.

### Home, Sessions, summary
- **Home** (`home_screen.dart`): tagline "Your phone as a camera trap: find, count and name
  animals" (no "follow": the phone stays in place); numbered steps that stay on the page: 1 AI models (amber frame
  when none; tiles from `uses` + "Other models"; with an answer in use: "Set up for: <answer>" or
  "Chosen AI models" with Find/Name file names from `currentModelChoice`, "none (…)" lines), 2
  Record (the answer's phone-screen drawing `roiPicture(icon)`), 3 Import videos…, 4 the two Find
  buttons; Support box last. Steps keep their numbers (no ticks). Bottom bar Menu, Sessions |
  New session | Dashboard, AI models. Menu (drawer): Download & import models, Show setup tips
  at session start, Report a problem, Share, Cite, About (Support is only the home box). Menu
  "Cite FaunaPulse" and the box's "Cite this version" open `CitationDialog`
  (`support_faunapulse.dart`): `citationText(version)` = the README citation plus "(Version
  <PackageInfo.version>)", concept DOI, Copy; works offline. `ScrollHint` scroll bar. Donation
  link only with `--dart-define=DONATION_LINK=true` (GitHub APKs), never in the Play build. About
  is the custom `AboutFaunaPulseDialog` (AGPL-3.0 line; the licences button pushes the generated
  LicensePage, needed for store compliance). Home top, Menu and About show `AppIcon`
  (`assets/images/faunapulse_icon.png`, a copy of the 192 px launcher picture); the bee with a
  flower is only the pollinators answer.
- **Sessions** (`sessions_screen.dart`): search, Filters sheet, chips, Sort, press and hold to
  select; ⋮ Select / Import videos… / Delete all sessions… (type "delete"; never deletes the
  `sessions/` root). Row ⋮ actions from `SessionActions`.
- **Summary** tabs: Photos (Video for video sessions) | Graphs | Setup. Setup reads the start
  record's `config`; inert settings show "Not applicable". Graphs: track-ID timeline,
  track-length histogram, time of day; extra graphs folded. Photo viewer: cyan = box that
  triggered the photo, amber = other boxes in that frame; high-res view interpolates boxes to the
  photo's `content_at_ms`; no buttons over the photo; while zoomed every ancestor scrollable
  freezes; the interpolation tolerance only sets the info-row tone, it never rejects boxes. Crop
  export cuts from the original JPEG. Gallery copy → `Pictures/FaunaPulse/<session>`
  (paths, chunks of 25, idempotent, channel `faunapulse/crop` in `MainActivity`; videos →
  `Movies/FaunaPulse/`).
- **Dashboard** (`dashboard_screen.dart`; `logging/dashboard_stats.dart`, `aggregateDashboard`):
  big number = track IDs in the period (default All time; 7/30 days are calendar days, as the
  Sessions filter) with an (i) that a track ID is not an animal count; tiles watched | track IDs
  per hour watched (a number only from `kRateMinWatchMs` 1 h, else "–" and "shown from 1 h
  watched"; note "rough estimate", its (i) opens at full width under the tile row) | typical
  (median) | longest track length, each as tall as its text; the two charts by time of day and by
  day are always shown once loading ends, also with no sessions (under the empty-state text) or no
  track IDs (zero bars + a line why; `activity` is never empty: every day of a fixed period, else
  the last 7 days without timed data), busiest hour / record day in their subtitles only with a
  clear winner; "Track IDs by name":
  each session's newest identification (as View results), `aggregateTracks` per rank, suspects
  and outdated results left out, chips only for ranks reached, family first, "Named: X of Y".
  Imported videos with a guessed filming time (`video_clip.start_time_weak` or a guessed source)
  count but stay out of the time charts. Cache `<session>/dashboard_stats.json` v4, key = size +
  mtime of session.jsonl, post_tracks.jsonl and the newest identification summary (a new
  identification re-reads only the names); a crashed session ends at its last logged record.
  `DashboardScreen(sessionsDir:, now:)` for tests.
- **Slow-phone hint** (camera, live detection): median work per picture > 200 ms after 15 s →
  banner suggesting time-lapse video + Find animals afterwards; "Don't show again" pref
  `faunapulse_hide_slow_phone_hint`.

### Build, release, repository
- **Branches:** `main` = stable, `develop` = integration (base for PRs and Dependabot). Git and
  commit rules: `AGENTS.md`.
- **Toolchain:** Gradle 9.1.0, AGP 9.0.1, Kotlin 2.3.20; `compileSdk`/`targetSdk` 36, `minSdk`
  24 pinned in `android/app/build.gradle`. Keep `android.builtInKotlin=false` and
  `android.newDsl=false`; `file_picker` stays `^10.3.10`. Root lint disables only the
  `geolocator_android` `MissingPermission` false positive. App id `com.faunapulse.app`; native
  classes stay in `com.ultralytics.yolo` (fully qualified manifest names). Keep the tracked
  Gradle wrapper files.
- **Release:** release builds fail without a keystore (`scripts/create_release_keystore.sh`);
  `scripts/security_release_gate.sh` = analyze, tests, native security tests, release lint,
  signed AAB. `scripts/build_release_apks.sh` gives per-ABI APKs the Play versionCode and sets
  the donation define; `QNN=1` builds the NPU edition (`-npu` names). QNN deps sit behind
  `project.findProperty('qnn')` in `android/app/build.gradle`. Backup = shared preferences only (`PRIVACY_POLICY.md`); cleartext
  blocked.
- **Versioning:** pubspec `version:` (now `0.9.0-beta.1+14`, released 2026-10-18; release recipe in `~/InsectDetectApp/RELEASE_PLAN.md`, outside git; beta since 0.9.0, so an update keeps older sessions and saved settings readable) is the single source; bump the
  build number for every tester APK; tags `v<version>`. Move together: pubspec version,
  CITATION.cff `version` + `date-released` + version DOI (concept DOI `10.5281/zenodo.22309221`
  never changes), CHANGELOG.md, `fastlane/.../changelogs/<versionCode>.txt`, the year in
  `citationText` (a home-screen test compares it, the title, authors and DOI with CITATION.cff). Licence
  `AGPL-3.0-only`. Pubspec `description` == CITATION.cff `title`; never retitle an archived
  version.

## Device quirks (test phones)

- **Xiaomi 11T Pro `2107113SG`** (Snapdragon 888, 7.4 GB): primary; debug builds
  only. PIN lock: a person unlocks it. Reports the laptop USB cable as AC power, so keep it awake
  with `adb -s <serial> shell svc power stayon true`. Hot: camera throttles at ~41–42 °C, then
  auto-throttle holds ~6 fps; MIUI `thermal_status` always "none". Lowest forced camera rate 12
  (AE range [12,12]). Battery voltage is 2-cell series: the summary halves it,
  `tool/perf_summary.dart` does not. Only the main lens is offered. Often tethers the laptop's
  internet over USB: avoid big downloads. GPU speeds at 640 px: flat-bug n 19 ms, flat-bug s
  and insectDCT v8-s 34 ms (insectDCT at 1024: ~75 ms); BioCLIP 2 0.27 s/crop (CPU 2.6 s); BioCLIP 2.5 CPU only,
  5.5 s/crop; insectDCT classifier eff2s 0.02 s/crop (the cnb variant gives wrong GPU output).
- **Samsung `SM-M127F`** (Galaxy M12-class, Exynos 850, Mali-G52, 3.9 GB, Android 13):
  secondary; since round 312 it runs release-signed APKs (the update test from 0.7.0), so no
  `run-as`, and a debug build needs an uninstall (deletes its data: ask the owner).
  Compute-limited, never hot. `battery_current_ua` broken (use battery % drop). Lowest forced
  camera rate 15. BioCLIP 2 GPU refused by the memory guard (CPU ~15 s/crop); flat-bug n 640
  GPU ~0.22 s per picture live. Swipe lock (adb can wake and swipe).
- **Redmi Note 9S** (Snapdragon 720G, 3.6 GB, Android 12 MIUI): third phone,
  debug builds; stays awake on USB. Check `adb devices -l` first: which phones are connected
  changes (its `model:` field tells them apart). No adb serials in tracked files. Memory-bound:
  BioCLIP 2 on the CPU loaded in the background is killed by lowmemorykiller (about 1 GB free);
  MIUI's `PeriodicCleaner` closed a cached FaunaPulse 15 to 75 s after it left the
  foreground service (on the 11T Pro the app was still alive after 87 s).
- On Android 14 (11T Pro) neither `adb shell` nor `run-as` can read the folders the app makes
  under `Android/data`: check results in the app and delete test sessions with the app's own
  *Delete session*.

## Pointers

- **History:** `docs/AGENT_CHANGELOG.md` (append only; never read it whole; ask before reading
  past rationale).
- **Docs:** `FIELD_GUIDE.md` (run a session), `INSTALL.md`, `SETTINGS_REFERENCE.md` (every
  setting), `DATA_GUIDE.md` (record dictionary, R/Python analysis), `ARCHITECTURE.md` (data flow,
  channel contract, keep-in-sync pairs), `CONTRIBUTING.md`, `IDENTIFICATION.md`,
  `VIDEO_ANALYSIS.md`, `MODEL_CONVERSION.md`,
  `PERFORMANCE_BENCHMARKING.md`, `HOW_PHOTO_RESOLUTION_WORKS.md`, `LEAN_QNN_PACKAGING.md`, `SAM3.md` (parked experiment, code on branch
  `sam3`).
- **PC tools:** `tool/model_downloads/` (download list, naming rule), `tool/video_eval/`,
  `tool/perf_summary.dart`. The model export tools (`detector_export/` .pt → fp16 `.tflite` +
  agreement check, `classifier_export/` insectDCT classifier + class list, `bioclip_export/` image
  tower, label packs, quantisation, the `.fpack` writer that also writes the test fixtures) live
  in the separate repository `fauna-pulse-models` (GitHub `valentinitnelav/fauna-pulse-models`,
  usually `~/fauna-pulse-models`; round 311). Its `docs/AGENT_OVERVIEW.md` maps it and lists the
  rules both repositories share; `FAUNAPULSE_MODELS_REPO` lets `model_file_kind_test` see its files.
- **Outside git:** release plan `~/InsectDetectApp/RELEASE_PLAN.md` (checklist and recipe;
  re-ground there for release work); Play Console draft answers
  `~/InsectDetectApp/PLAY_STORE_LISTING_DRAFT.md`; performance and robustness review
  `~/InsectDetectApp/PERF_AND_ROBUSTNESS_REVIEW.md` (the "perf review A1"-style tags in code
  comments; all parts closed except E9, build-time camera A/B experiments; owed field checks:
  heap/thread plateau after E2, paired camera-sleep run (E3), paired cap 12 vs 15 on the
  Xiaomi); design notes `~/InsectDetectApp/BIOCLIP_ON_DEVICE_PLAN.md`; setup-drawing
  sources `~/InsectDetectApp/generated_art/` (`make_setup_sketches.py`); test videos and the hand
  count set `~/InsectDetectApp/test_videos/` (feature references only; check pictures
  `frames_bumblebees_720p`, crops `crops_bumblebees_720p_square`); plans
  `~/.claude/plans/pasted-content-id-f534-you-proposed-fluttering-eagle.md` (video evaluation
  next steps), `~/.claude/plans/pasted-content-id-a09e-what-about-pure-yeti.md` (video plan).
- **Agent rules:** `AGENTS.md` (repository root). Deny list:
  `~/InsectDetectApp/.claude/settings.local.json` (do not read).
- **Session start:** a SessionStart hook (`~/InsectDetectApp/.claude/settings.json`, outside git) runs
  `~/InsectDetectApp/.claude/hooks/session_start.sh`: branch, uncommitted files, unpushed commits and
  author check of both repositories, the last changelog round (committed or not), overview size.

## Build and test

- `flutter analyze`; `flutter test test/` (about 990 tests, ~2.5 min). No whole-file `dart format`
  (the repository is not formatter-clean).
- Debug APK: `flutter build apk --debug`, then `adb -s <serial> install -r`.
- Device checks: `flutter test integration_test/<file> -d <serial> --no-uninstall`. Always pass
  `--no-uninstall` (otherwise flutter uninstalls the app and every session on the phone is
  deleted). Afterwards rebuild and reinstall the normal debug app. Ask the owner before using a
  phone, back up the app's settings first (`adb exec-out run-as com.faunapulse.app cat
  shared_prefs/FlutterSharedPreferences.xml`) and compare after. Camera checks need the phone
  awake and unlocked at the start. Screenshots: checks print `SHOT <name>` lines. A side-by-side
  `com.faunapulse.app.check` copy (no risk to the installed app) is described in
  `test/README.md`.
- Checks in `integration_test/`: app launch, camera modes, screen off (`screen_off_check`:
  Home during time-lapse, live detection, a camera wake and a scheduled window; the runner
  presses Home on `HOME_NOW <part> <s>` and brings the app back after that time), camera streams
  (`MEASURE_NOW fast|auto`: read `dumpsys media.camera` and `top`), high-res photos
  (`TARGET=` saved side), view recreate, slow-phone hint, CPU
  threads, detector speed, identify speed, BioCLIP GPU, find and identify, home and sessions,
  models screen, models delete, catalogue downloads, photo track IDs, video decode / import / convert / samples /
  default area / keep frames / review / cleanup / cut-off / fragmented MP4, video bursts (+
  after), live video (+ after), QNN smoke / benchmark; shared session builder
  `check_sessions.dart`.
- KGP/Gradle deprecation warnings are known and unrelated.
