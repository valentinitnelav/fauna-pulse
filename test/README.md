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
(`video_tracker_test.dart`), the one-visits-file rule for summary, dashboard
and identification (`track_source_test.dart`), error reporting, and
widget regressions (e.g. the bottom-inset pattern in
`summary_bottom_inset_test.dart`, which also documents the widget-test async
traps). One more trap (round 227, `video_screens_test.dart`): a widget test
that writes through `SessionLogger` must pump with a duration, because the
logger yields with a zero-length timer that a bare `pump()` never fires.
Run `flutter analyze` alongside it; both must be clean before a PR.


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

## Video frame-rate sweep (round 230)

Re-runs *Find visits* on an analysed video session at lower frame rates (the
frames a run at that rate would have looked at) for both trackers, and writes
`fps_sweep/visits_<tracker>_<fps>fps.csv` for
`tool/video_eval/evaluate_visits.py` to score against a hand count
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
flutter test integration_test/video_import_check_test.dart -d <device> --no-uninstall # first-frame picture, start times, import (r227; uses the video_check clips)
```

On a phone that has the Play build installed (the Samsung), never run the
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
