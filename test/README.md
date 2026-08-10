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
schedule and time-lapse plans, post-hoc analysis + SAHI, error reporting, and
widget regressions (e.g. the bottom-inset pattern in
`summary_bottom_inset_test.dart`, which also documents the widget-test async
traps). Run `flutter analyze` alongside it; both must be clean before a PR.


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

## Integration tests (device attached)

```bash
flutter test integration_test/app_launch_test.dart -d <device>   # app-launch smoke
flutter test integration_test/qnn_smoke_test.dart -d <device>    # QNN runtime presence
flutter test integration_test/qnn_benchmark_test.dart -d <device> \
  --dart-define=RUN_BENCH=true   # optional: --dart-define=RUN_SOAK=true
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
