# Tests

FaunaPulse's tests, replacing the upstream plugin's test notes (this repo has
no `example/` app).

## Unit + widget tests (no device needed)

```bash
flutter test test/fauna_pulse
```

Pure-Dart coverage of the app's logic, mirroring `lib/fauna_pulse/`: ROI math,
both trackers, the session logger (including the write-failure path), capture
scheduling and crop geometry, frame processing, config round-trips/migrations,
schedule and time-lapse plans, post-hoc analysis + SAHI, video import and
start-time guesses, offline tracking of videos and its exports
(`video_tracker_test.dart`), the one-track-ID-file rule for summary, dashboard
and identification (`track_source_test.dart`), error reporting, and
widget regressions (e.g. the bottom-inset pattern in
`summary_bottom_inset_test.dart`, which also documents the widget-test async
traps). One more trap (round 227, `video_screens_test.dart`): a widget test
that writes through `SessionLogger` must pump with a duration, because the
logger yields with a zero-length timer that a bare `pump()` never fires.
The summary's Video tab (`video_review_player_test.dart`, round 231) runs
against a fake `VideoPlayerPlatform`; its rows sit in a lazy `ListView`, so
the test scrolls to them (`scrollUntilVisible`) before looking for them.
`phone_during_analysis.csv` (round 232) is compared with the golden file
`fixtures/phone_during_analysis.csv` in `video_run_samples_test.dart`; after
an intended change to its columns, rewrite it with
`flutter test test/fauna_pulse/video_run_samples_test.dart --update-goldens`
and check the diff.
Run `flutter analyze` alongside it; both must be clean before a PR.

**Settings: can be set, and take effect (round 313).** `settings_fields_test.dart`
types into every number box of every settings screen one character at a time (the
camera Settings in four starting setups and all tabs with every fold open, the video
settings, Identify organisms; the photo screen in `photo_tracker_test.dart`) and
switches every switch, list and slider and back. Each must show what was typed, change
exactly one stored setting (no hidden link, no "ratchet" from a half-typed number),
give every value back when the old one is typed again, refuse a number above its
maximum, and leave the same controls on screen. A new control is covered without
changing the test; a stored camera setting that no control changes fails the test until
it is listed there with the reason. `tracker_effect_test.dart` shows that each tracker
setting changes the tracker's result and that every stored value reaches the tracker
the camera, videos and photos build. When one of them fails, fix the screen, not the
test: a rule between two settings belongs where the values are used (see
`SessionConfig.effectiveInferenceFps`), shown with the box's `warning`.

**Stress tests (round 318).** `test/fauna_pulse/stress/` feeds the app damaged and
odd files (FaunaLapse zips, session logs, saved settings, name lists, the model
catalogue, video analysis files), very large inputs, and timing races (double taps,
Back during a run, two downloads of one file). They run with the normal
`flutter test test/fauna_pulse`. A case that shows a known bug is kept and marked
`skip: 'BUG: ...'`; a case for an input the app can never receive is marked
`skip: 'NOT FIXED (audit): ...'`. Add `--run-skipped` to see them fail.
The `r319_*_test.dart` files there (round 319) cover the fixes of the bugs that stress
test left open, one file per problem: storage filling up during a model download or
before it (`r319_l1_*`), a damaged detector model, heat pauses and full storage in *Find
animals in videos* (`r319_l2_*`), video import errors, free storage and leftovers
(`r319_l3_*`), the analysis foreground service and Identify in the background
(`r319_l4_*`), and the camera's storage block, *Keep free storage* minimum, *Stopping…*
button, temperature gauge line and airplane-mode tip (`r319_l5_*`).
The `r319b_*_test.dart` files (round 319, part 2) cover the fixes found by its phone
tests: the memory check before an *Also identify them* model loads in the background, the
rule against the phones' numbers, Identify's time left, singular counts and photos that
could not be read (`r319b_m_*`); *Import other videos…* left with Back, the *Continue* label
and clips where a track ID only ends (`r319b_s1_*`); model imports on full storage, import
progress, the download dialog's storage line, the airplane-mode message and one unit per
sentence (`r319b_s2_*`); and bars that go away after their time and the import note's
button name (`r319b_s4_*`). `packages/ultralytics_yolo/test/yolo_view_switch_error_test.dart`
covers a failed model switch in the camera that the app handles itself.
The `r319c_*_test.dart` files (round 319, part 3) cover the fixes found by the part-2 phone
tests: a stored bar closed after it timed out, the *Rename session* dialog, the scheduled-run
line during a window skipped for low storage, singular counts, the clip count of *Find track
IDs*, the results header's name list and an import line kept in view (`r319c_a_*`); the
waiting identification kept in a note when Android closes the app (round 320: every other
run's note only gives the line), the notification
permission asked when an analysis starts and the keep-on-screen line (`r319c_b_*`, with the
shared `r319c_b_identify_fixture.dart`); and the analysis service held until the model's
memory is given back (`r319c_k_*`).


## Security and release gate

CI runs app and plugin tests, native model-metadata bounds tests, Android lint,
and an unsigned debug App Bundle packaging check. Before uploading to Google
Play, run the signed local gate with the real release keystore:

```bash
scripts/security_release_gate.sh
```

The final command builds `build/app/outputs/bundle/release/app-release.aab`.
## Tracker replay harness (offline accuracy, not speed)

Replays a real session's logged raw detections (the "Log raw detections"
setting) through both trackers and prints a variant comparison matrix:

```bash
flutter test test/fauna_pulse/tracker_replay_test.dart \
  --dart-define=REPLAY_SESSION=/absolute/path/to/session.jsonl
```

Skipped when the define is missing. Judge results against a hand count from
the session's `gt_frames/` photos (rounds 105/108 workflow), not against MOT
benchmarks.

## Files made in fauna-pulse-models (round 311)

The PC export tools live in the separate repository
[fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models). Its `bioclip_export/fpack.py` writes the
`.fpack` fixtures (`fixtures/tiny_pack.fpack`, `tiny_classes.fpack`) that
`label_pack_test.dart` and `track_fusion_test.dart` read; after a format change,
regenerate them there (command in its README, "Keep in sync with the app").
`model_file_kind_test.dart` also checks real exported files when
`FAUNAPULSE_MODELS_REPO` points at a clone of that repository (its `*_export/out/`
folders), besides `../weights`:

```bash
FAUNAPULSE_MODELS_REPO=~/fauna-pulse-models flutter test test/fauna_pulse/model_file_kind_test.dart
```

## Video frame-rate sweep (round 230)

Re-runs *Find track IDs* on an analysed video session at lower frame rates (the
frames a run at that rate would have looked at) for both trackers, and writes
`fps_sweep/track_ids_<tracker>_<fps>fps.csv` for
`tool/video_eval/evaluate_track_ids.py` to score against a hand count
(`docs/VIDEO_ANALYSIS.md` §5). Analyse the videos at their full rate first.

```bash
flutter test test/fauna_pulse/video_fps_sweep_test.dart \
  --dart-define=SWEEP_SESSION=/absolute/path/to/session_folder \
  --dart-define=SWEEP_FPS=15,10,5,2,1
```

Only the frame-thinning unit tests run when the define is missing. The PC
scripts have their own tests: `python3 -m unittest` in `tool/video_eval/`.

## Integration tests (device attached)

Always pass `--no-uninstall`: without it flutter uninstalls the app after the
test (and also when installing fails, e.g. a signature mismatch), which deletes
every session stored on the phone.

```bash
flutter test integration_test/app_launch_test.dart -d <device> --no-uninstall   # app-launch smoke
flutter test integration_test/qnn_smoke_test.dart -d <device> --no-uninstall    # QNN runtime presence
flutter test integration_test/qnn_benchmark_test.dart -d <device> --no-uninstall \
  --dart-define=RUN_BENCH=true   # optional: --dart-define=RUN_SOAK=true
flutter test integration_test/video_decode_check_test.dart -d <device> --no-uninstall  # video pass (r225; header: clips to push)
flutter test integration_test/cpu_threads_check_test.dart -d <device> --no-uninstall   # CPU thread timing (r226)
flutter test integration_test/catalogue_download_check_test.dart -d <device> --no-uninstall --dart-define=MAX_MB=100 # every file of the download list up to MAX_MB: download, kind, loads (r314; best in the side-by-side .check copy below, Wi-Fi)
flutter test integration_test/video_import_check_test.dart -d <device> --no-uninstall # first-frame picture, start times, import (r227; uses the video_check clips)
flutter test integration_test/video_review_check_test.dart -d <device> --no-uninstall # Video tab: boxes, 4x frame times, soak, re-analysis (r231; header: model, screenshots)
flutter test integration_test/video_samples_check_test.dart -d <device> --no-uninstall # phone samples during Find animals in videos: stop, forced cooling pause, continue, graphs, CSV (r232)
flutter test integration_test/video_convert_check_test.dart -d <device> --no-uninstall # frame conversion: same boxes as a saved reference, ms per step (r233; run once before a converter change to save the reference)
flutter test integration_test/camera_modes_check_test.dart -d <device> --no-uninstall  # recording modes through the camera screen: time-lapse photos/video with camera sleep + torch, continuous video, motion-only, live AI photos, a scheduled run (r245; MODES=ACF picks sessions; E_SUBJECT=true when the phone looks at a video of pollinators/animals, so live AI photos are really tested)
flutter test integration_test/live_video_check_test.dart -d <device> --no-uninstall   # live AI + ROI video and the motion gate (r240; LIVE_CHECK_ONLY=BD, LIVE_SECONDS=330 for the 5-minute clip rollover)
flutter test integration_test/view_recreate_check_test.dart -d <device> --no-uninstall # live settings (ROI, gate, time-lapse, lens) reach a rebuilt camera view (r244; START_LENS=0.5)
```

Camera-screen checks need the phone awake and unlocked when they start: behind a lock screen
the camera delivers no frames and the check waits for ever. A swipe lock can be passed with
`adb shell input keyevent KEYCODE_WAKEUP` and `adb shell input swipe 360 1300 360 400`; a PIN
lock needs a person. The checks keep the screen on once running and restore the phone's saved
settings afterwards; their sessions stay on the phone (delete them there). A scheduled run asks
for the notification permission, so grant it first:
`adb shell pm grant com.faunapulse.app android.permission.POST_NOTIFICATIONS`.

On a phone that has the Play build installed, never run the
commands above: they would replace or uninstall it. Build a side-by-side debug
copy instead and read the results from logcat:

```bash
ORG_GRADLE_PROJECT_debugIdSuffix=.check flutter build apk --debug -t integration_test/<file>.dart
adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <serial> shell am start -n com.faunapulse.app.check/com.ultralytics.yolo.MainActivity
adb -s <serial> logcat -v brief flutter:I '*:S'
```

The QNN benchmark needs network access (downloads models and a test image) and
a QNN-capable Snapdragon (Hexagon v73+; the SD888 Xiaomi test phone is v68 and
cannot run the pinned assets, round 151). The opt-in flags are exact-spelling
booleans: `=true` works, `=1` silently does nothing (round 160).

## Performance measurements

Do not quote debug-build FPS or one-off runs. The honest protocol
(device/build matrix, paired cooled runs, acceptance criteria) is
[`docs/PERFORMANCE_BENCHMARKING.md`](../docs/PERFORMANCE_BENCHMARKING.md),
with `dart tool/perf_summary.dart` to summarize a session log.
