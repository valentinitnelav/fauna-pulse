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
- Owner: pollination ecologist, not a mobile developer. UI text is plain English for citizen
  scientists; expert settings sit in closed folds.

## Where things live

- **App = repository root:** `lib/main.dart` → `lib/fauna_pulse/` (all app code);
  `test/fauna_pulse/` (unit + widget tests); `integration_test/` (device checks); `assets/`
  (`model_downloads.json`, `images/` setup drawings, `models/` local weights for debug device
  checks only); `docs/`; `tool/` (PC scripts); `scripts/` (release builds).
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
- `model_catalog.dart`: detection models on the phone (`ModelCatalog.build`, `entryOf`,
  `modelsDir`; `isSupportedModelFileName` = the one format filter; `fileNameOrder`).
- `model_file_kind.dart`: `modelFileKind` reads a `.tflite`'s tensor shapes from its FlatBuffer
  (first output 3-D = detection, all outputs 2-D = identification, input must be a 4-D colour
  picture); `.fpack` by header; `*_qnn.onnx` = detection.
- `model_file_security.dart` (intake checks, size limits), `model_import.dart`
  (`ModelImport.importFiles`/`pickAndImport`/`download`/`onPhoneAs`, `ReplaceQuestion`),
  `file_download.dart` (shared HTTPS download), `bundled_models.dart`.
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
`location_fix.dart`.

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
`folderSizeBytes`), `thermal_pause.dart` (`kDefaultPauseTempC` 43), `diagnostics.dart`,
`app_error_hooks.dart` (`logSwallowed`), `crash_store.dart`, `error_reporter.dart`,
`report_bundle.dart`.

**perf/** `adaptive_inference_throttle.dart`, `slow_phone_hint.dart`.

**postprocess/** photos: `post_detector.dart`, `photo_keep.dart` (`keepDecisions`), `sahi.dart`,
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
`analysis_screen.dart` (Find animals in photos); `video_import_screen.dart`
(`pickAndImportVideos`); `video_analysis_screen.dart` (Find animals in videos,
`VideoSquareEditor`); `identification_screen.dart`, `identification_results_screen.dart`,
`identification_choice_fields.dart` (`AlsoIdentify`); `problem_description_screen.dart`.

**widgets/** `roi_overlay.dart`, `roi_mask.dart`, `track_box_painter.dart` (live boxes cyan
`0xFF00E5FF`; ROI yellow `0xFFFFEB3B`), `preview_transform.dart`, `setting_help.dart`
(`HelpLabel`, `HelpSwitchTile`, `HelpRow`, `FoldSection`, `helperTextStyle`),
`numeric_setting_field.dart`, `duration_setting_field.dart`, `session_tile.dart`,
`video_review_player.dart`, `video_speed_chips.dart`, `temperature_gauge.dart`,
`mini_bar_chart.dart`, `scroll_hint.dart`, `watch_tiles.dart` (`WatchIcon`, `SetupPicture`,
`roiPicture`), `download_files_dialog.dart`, `download_model_dialog.dart`, `external_link.dart`,
`support_faunapulse.dart`, `session_info_dialog.dart`, `location_dialog.dart`,
`roi_size_sheet.dart`, `calibrating_banner.dart`, `home_button.dart` (`HomeButton`, `goHome`, `FitTitle`),
`selection_app_bar.dart`.

**services/** `recording_keepalive.dart` (foreground service + wake-lock).

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
| Auto-throttle | on | min 3 fps, duty target 0.5 |
| Motion gate | off | pixel delta 25, area 0.5 %, wake 3 s, grid 48 (16–160), idle check 5 fps (1–30) |
| Time between bursts | 30 min | `timeLapseGapSeconds`: end of a burst to start of the next; 0 = continuous |
| Save bursts as | photos | `timeLapseSaveAs`; `video`: one MP4 per burst at `timeLapseVideoFps` 15 |
| Live AI video | off | `liveAiVideo`, 15 fps, 5-min segments |
| Camera sleep between bursts | off | `timeLapseCameraSleep`; idle gap ≥ 30 s; wake lead 10 s (1–60) |
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
| GPU when faster / CPU threads | on / 0 = auto = 2 | |
| Crop 1:1 lock | off | |

Outside `SessionConfig` (shared_preferences): focus (manual close-up preset, screen state);
Find animals in photos `analysis_*`; Find animals in videos `video_analysis_*` (5 fps, occlusion 3
s, min track 1 s); Identify `identify_*`; thermal pause 43 °C (resume 3 °C lower) for video
analysis and identification; chosen models `analysis_model`, `video_analysis_model`,
`identify_model`, `identify_pack`; `home_watch_use`.

## Key invariants

### Words and screens
- **"Track ID", not "visit"**, in every text, file and record name (`track_ids.csv`,
  `post_track_end.track_ids`, …); durations say "track length". "Visit" only for the ecological
  quantity (hand counts, visitation rate). Readers accept older names; saved-settings keys and
  Dart identifiers kept old names on purpose.
- Screen names in the UI: "Download & import models", "Find animals in photos / videos",
  capture trigger "Live detection", settings tab "Detection". Refer to screens by their top title.
- **Every new tunable ships user-adjustable:** Settings control + `SessionConfig` JSON + summary
  row (`_settingsSection()`, `na:` when not applicable) + round-trip test, in the same round.
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
  to ''.
- **Blackout (power save) detaches only the Preview use case** (`setPreviewEnabled(false)`);
  analysis and ImageCapture stay bound, a recording continues. A timed session end calls
  `_exitBlackout()` before pushing the summary (brightness override is per Activity).
- **No YUV→RGB in Dart**: the native pipeline does it.
- **Portrait only**, locked in the manifest and in `main()`; the crop/rotation math assumes an
  upright phone. Lift both locks only with a full orientation audit.
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

### ROI and photos
- **ROI is ÷32 WYSIWYG:** the box, readout, saved crop and inference ROI are the same square;
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
  (`created`/`lost`/`recovered`/`removed`), `capture`/`motion_capture`/`timelapse_capture`,
  `raw_detections` (opt-in), `fps`/`thermal`/`power` (with `is_plugged`), `motion_gate`,
  `roi_update`, `blackout`, `focus_change`, `camera_sleep`, `torch`, `video_clip`,
  `video_skipped`, `app_error`, `end_of_session` (`ended_normally`). Record dictionary:
  `docs/DATA_GUIDE.md`. Parsers also accept the old per-track `detection` records.
- `detections[].tracks[]` boxes are always detector-observed (unmatched tracks go `lost`).
- **Frozen wire names** (do not rename): reference photos `gt_frames/`, `gt_capture`,
  `gtFramesEnabled`/`gtFrameSeconds`; high-res photo source `still` (config `captureMode`,
  capture `path`, `roi_source`); JSON key `stillSyncCompanion` (Dart `highResSyncCompanion`).
- The session folder also holds `logcat_start.txt` / `logcat_end.txt` (the app's own logcat
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
- **Location:** one GPS fix per session (`LocationFixTracker`: done at ≤ 15 m or 60 s), or manual
  / previous; `redactLocation` strips it from problem reports.
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
  "New-track confidence" (`highThresh` 0.5). The camera swaps the tracker only when settings
  close (settings are locked while recording). The start record's
  `tracker_params.algorithm` names it.
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
  IDs, pushes `IdentificationScreen(autoStart: true)`.

### Find animals in videos (`video_analysis_screen.dart`)
- Import (`video_import.dart`): files moved into `<session>/videos/`; `session.jsonl` = start
  (`source: imported_video`) + `video_clip` per clip + end. Clip start time: `video_clip` record
  > file name > MP4 time minus duration (Android stores the stop time) > day-only name > mtime
  (DATA_GUIDE §9). Fragmented MP4s (top-level `moof`) are rewritten at import by native
  `VideoFrameSource.remux` (`isFragmentedMp4`) and checked (same frames, times within rounding),
  else `ImportRewriteFailed` with a ready ffmpeg command; 10-bit/HDR refused.
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
- Video tab (`VideoReviewPlayer`, ExoPlayer via `video_player`, over `VideoBoxTimeline`): play
  state on a `ValueNotifier`, not the controller (rebuilding at 10 Hz made playback stutter);
  boxes hidden while the player fetches the picture after a jump; wake-lock while playing. Live
  AI video sessions can switch "Live AI | AI afterwards".
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
  taxonomy; ladder tau 0.7. Columns Conf. / Agree; suspect flags (short, few detections, weak
  ID; defaults from insect-detect-post's `filter_tracks`, Sittinger 2026, Zenodo
  10.5281/zenodo.21822140: credit the idea's source and the implementer separately). Optional merge of consecutive track IDs (off). `reproduce_track_conf.py` reproduces the
  numbers on a PC. Defaults are not validated on pollinators (IDENTIFICATION.md).
- Class lists: a classifier (`insectdct-cls-v7_eff2s_fp16.tflite`, raw scores) pairs with the
  `.fpack` of the same name (`LabelPack.isClassList`, `ImageEmbedder.load(normalize: false)`).
  Label packs pair by the first part of the name (`listBelongsTo`, else header `model_id`).
  Identify needs a matching list; a dimension mismatch is refused before embedding.
- GPU: checked once per model file + `Build.FINGERPRINT` against CPU (cosine ≥ 0.995
  `GPU_MIN_AGREEMENT`, else CPU with a note); refused when `GPU_MEMORY_FACTOR` 4.5 × file size >
  `GPU_MEMORY_SHARE` 0.6 × phone memory (`Embedder.kt`). BioCLIP 2 needs the 4-D
  attention export (`export_image_tower.py --attention 4d`); BioCLIP 2.5 is CPU-only on today's
  phones. fp16 everywhere (int8 changed answers).
- Results screens: taxon table → track-ID sheets → one track ID (ladder, photo with detector box
  and crop). Mini-table kit measures column widths; ids/names left, numbers right.

### Models and downloads
- Formats: `.tflite` or `*_qnn.onnx` (Snapdragon NPU); plain `.onnx` refused
  (`isSupportedModelFileName`). LiteRT `format=litert` NCHW exports run (detect only).
- **Security:** models live in private app storage; intake is HTTPS-only, rejects unsafe names
  and traversal, streams through a temp file, checks the `TFL3` identifier; limits 30 MiB for
  detection `.tflite` (`kMaxTfliteModelBytes`), 256 MiB for QNN, 2 GiB for identification files
  (`kMaxIdentificationFileBytes`). These checks run only at intake, never in the camera path.
- **No bundled models:** `assets/models/bundled_models.txt` is empty; the camera picker lists only
  imported/downloaded files. Debug builds still pack local weights for device checks.
- **Download & import models** (`models_screen.dart`) is the only place to import, download and
  delete model files and name lists. Every file is listed by its file name, details behind ⓘ
  (from the file: classes, input size, precision; plus title, licence and source when listed).
  Deleting an identification model takes its name lists along unless another model still uses
  them; "Delete all …" per kind; press and hold selects several.
- **Download list** `assets/model_downloads.json` (format 3; `tool/model_downloads/README.md`):
  one `models` array (`id` = the `<model>` part of the naming rule, `kind`, `licence`, `source`,
  optional `file` = offered, `name_lists` with `kind` class_list/label_pack) and `uses` (the home
  answers: `id`, `icon`, `title`, `setup`, `find` ids, `name` {model, list}; the first of each is
  "Suggested AI models"; naming is BioCLIP 2 first in every answer: the Europe 5-order list for
  pollinators and flat surface, the world list for mammals and birds). Presence on the phone = file name only; `sha256` only verifies a download.
  `update_catalogue.py` refreshes sizes and checksums. Files are not online yet except
  MegaDetector (base_url = release v0.8.0-alpha.1).
- **What do you want to watch? pages** (`watch_plan_screen.dart`): setup drawing, "Suggested AI
  models" / "Your choice" by file name; the answer used last (`home_watch_use`) opens with
  `currentModelChoice` (param `inUse`) plus "Back to the suggested models"; one button at the bottom edge ("Download and use (size)" / "Use
  these"); the fold "Choose other models" lists the other suggestions plus "Other models on this
  phone" (every other detector and identification model + name list pair, `namingPairs`). Saving
  = `useModels`: camera `modelPath` + task, `analysis_model`, `video_analysis_model`,
  `identify_model`/`identify_pack` ("Not now" removes both).
- A model needs a list entry only to be offered or suggested; any model on the phone can be
  chosen everywhere.

### Home, Sessions, summary
- **Home** (`home_screen.dart`): tagline "Your phone as a camera trap: find, count and name
  animals" (no "follow": the phone stays in place); numbered steps that stay on the page: 1 AI models (amber frame
  when none; tiles from `uses` + "Other models"; after a page saved: "Set up for: <answer>" or
  "Chosen AI models" with Find/Name file names from `currentModelChoice`, "none (…)" lines), 2
  Record (the answer's phone-screen drawing `roiPicture(icon)`), 3 Import videos…, 4 the two Find
  buttons; Support box last. Steps keep their numbers (no ticks). Bottom bar Menu, Sessions |
  New session | Dashboard, AI models. Menu (drawer): Download & import models, Show setup tips
  at session start, Report a problem, Share, Support, About. `ScrollHint` scroll bar. Donation
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
- **Dashboard:** totals and activity over AI sessions (`aggregateDashboard`), per-session cache
  `<session>/dashboard_stats.json` (`DashboardStatsCache`, key: log size + mtime).
- **Slow-phone hint** (camera, live detection): median work per picture > 200 ms after 15 s →
  banner suggesting time-lapse video + Find animals afterwards; "Don't show again" pref
  `faunapulse_hide_slow_phone_hint`.

### Build, release, repository
- **Branches:** `main` = stable, `develop` = integration (base for PRs and Dependabot). Never
  commit or push without the owner's request. Commit messages start "Round <n>".
- **Toolchain:** Gradle 9.1.0, AGP 9.0.1, Kotlin 2.3.20; `compileSdk`/`targetSdk` 36, `minSdk`
  24 pinned in `android/app/build.gradle`. Keep `android.builtInKotlin=false` and
  `android.newDsl=false`; `file_picker` stays `^10.3.10`. Root lint disables only the
  `geolocator_android` `MissingPermission` false positive. App id `com.faunapulse.app`; native
  classes stay in `com.ultralytics.yolo` (fully qualified manifest names). Keep the tracked
  Gradle wrapper files.
- **Release:** release builds fail without a keystore (`scripts/create_release_keystore.sh`);
  `scripts/security_release_gate.sh` = analyze, tests, native security tests, release lint,
  signed AAB. `scripts/build_release_apks.sh` gives per-ABI APKs the Play versionCode and sets
  the donation define. Backup = shared preferences only (`PRIVACY_POLICY.md`); cleartext
  blocked.
- **Versioning:** pubspec `version:` (now `0.8.0-alpha.1+13`) is the single source; bump the
  build number for every tester APK; tags `v<version>`. Move together: pubspec version,
  CITATION.cff `version` + `date-released` + version DOI (concept DOI `10.5281/zenodo.22309221`
  never changes), CHANGELOG.md, `fastlane/.../changelogs/<versionCode>.txt`. Licence
  `AGPL-3.0-only`. Pubspec `description` == CITATION.cff `title`; never retitle an archived
  version.

## Device quirks (test phones)

- **Xiaomi 11T Pro `2107113SG`** (adb `2b2dc560`, Snapdragon 888, 7.4 GB): primary; debug builds
  only. PIN lock: a person unlocks it. Reports the laptop USB cable as AC power, so keep it awake
  with `adb -s 2b2dc560 shell svc power stayon true`. Hot: camera throttles at ~41–42 °C, then
  auto-throttle holds ~6 fps; MIUI `thermal_status` always "none". Lowest forced camera rate 12
  (AE range [12,12]). Battery voltage is 2-cell series: the summary halves it,
  `tool/perf_summary.dart` does not. Only the main lens is offered. Often tethers the laptop's
  internet over USB: avoid big downloads. GPU speeds: flat-bug n/s and insectDCT v8-s detectors
  34 ms at 640 px (s at 1024: ~75 ms); BioCLIP 2 0.27 s/crop (CPU 2.6 s); BioCLIP 2.5 CPU only,
  5.5 s/crop; insectDCT classifier eff2s 0.02 s/crop (the cnb variant gives wrong GPU output).
- **Samsung `RF8T403A3AT`** (Galaxy M12-class, Exynos 850, 3.9 GB, Android 13): secondary; debug
  builds now (no Play build). Compute-limited, never hot. `battery_current_ua` broken (use
  battery % drop). Lowest forced camera rate 15. BioCLIP 2 GPU refused by the memory guard (CPU
  ~15 s/crop). Swipe lock (adb can wake and swipe).

## Pointers

- **History:** `docs/AGENT_CHANGELOG.md` (append only; never read it whole; ask before reading
  past rationale).
- **Docs:** `FIELD_GUIDE.md` (run a session), `INSTALL.md`, `SETTINGS_REFERENCE.md` (every
  setting), `DATA_GUIDE.md` (record dictionary, R/Python analysis), `ARCHITECTURE.md` (data flow,
  channel contract, keep-in-sync pairs), `CONTRIBUTING.md`, `IDENTIFICATION.md`,
  `VIDEO_ANALYSIS.md`, `MODEL_CONVERSION.md`, `THIRD_PARTY_MODELS.md`,
  `PERFORMANCE_BENCHMARKING.md`, `HOW_PHOTO_RESOLUTION_WORKS.md`, `RELEASE_PLAN.md` (re-ground
  there for release work), `LEAN_QNN_PACKAGING.md`, `SAM3.md` (parked experiment, code on branch
  `sam3`), `PLAY_STORE_LISTING_DRAFT.md`. `PERF_AND_ROBUSTNESS_REVIEW.md`: all parts closed except
  E9 (build-time camera A/B experiments); owed field checks: heap/thread plateau after E2, paired
  camera-sleep run (E3), paired cap 12 vs 15 on the Xiaomi.
- **PC tools:** `tool/model_downloads/` (download list, naming rule), `tool/detector_export/`
  (.pt → fp16 `.tflite`, agreement check), `tool/classifier_export/` (insectDCT classifier +
  class list), `tool/bioclip_export/` (image tower, label packs, quantisation), `tool/video_eval/`,
  `tool/perf_summary.dart`.
- **Outside git:** design notes `~/InsectDetectApp/BIOCLIP_ON_DEVICE_PLAN.md`; setup-drawing
  sources `~/InsectDetectApp/generated_art/` (`make_setup_sketches.py`); test videos and the hand
  count set `~/InsectDetectApp/test_videos/` (feature references only; check pictures
  `frames_bumblebees_720p`, crops `crops_bumblebees_720p_square`); plans
  `~/.claude/plans/pasted-content-id-f534-you-proposed-fluttering-eagle.md` (video evaluation
  next steps), `~/.claude/plans/pasted-content-id-a09e-what-about-pure-yeti.md` (video plan).
- **Agent rules:** `AGENTS.md` (repository root). Deny list:
  `~/InsectDetectApp/.claude/settings.local.json` (do not read).

## Build and test

- `flutter analyze`; `flutter test test/` (about 840 tests, ~1 min). No whole-file `dart format`
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
- Checks in `integration_test/`: app launch, camera modes, view recreate, slow-phone hint, CPU
  threads, detector speed, identify speed, BioCLIP GPU, find and identify, home and sessions,
  models screen, models delete, photo track IDs, video decode / import / convert / samples /
  default area / keep frames / review / cleanup / cut-off / fragmented MP4, video bursts (+
  after), live video (+ after), QNN smoke / benchmark; shared session builder
  `check_sessions.dart`.
- KGP/Gradle deprecation warnings are known and unrelated.
