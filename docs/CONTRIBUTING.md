# Contributing

**Who this is for:** developers contributing to FaunaPulse. For how the
code fits together, read [ARCHITECTURE.md](ARCHITECTURE.md) first.

---

## Toolchain & setup

The Flutter/Android toolchain setup (SDK versions, `flutter doctor`, device
setup) is covered in the [Installation & Testing Guide](INSTALL.md). The app
lives at the repository root (not in a subfolder) and depends on the vendored
plugin via a `path:` dependency:

```yaml
dependencies:
  ultralytics_yolo:
    path: packages/ultralytics_yolo
```

## Everyday commands

```bash
flutter pub get                      # after changing dependencies
flutter analyze                      # static analysis (must be clean)
flutter test test/fauna_pulse         # the app's unit tests
flutter build apk --debug            # dev build (the Xiaomi dev phone runs this)
flutter build apk --release          # release build (needs the keystore, INSTALL.md B4)
flutter run                          # run on a connected device
```

Run `flutter analyze` and `flutter test test/fauna_pulse` before every PR.

## Testing

Unit tests live in `test/fauna_pulse/` and mirror the module map: ROI math,
both trackers (plus the offline replay harness), the logger including its
write-failure path, capture scheduling and crop geometry, frame processing
(the per-frame logic extracted from the camera screen in round 73), config
round-trip/migration, schedule and time-lapse plans, post-hoc analysis + SAHI,
error reporting, and widget regressions. See [test/README.md](../test/README.md)
for the commands, the replay harness, and the on-device integration tests.

**Benchmarking caveat:** debug builds run slower than release; don't quote
debug FPS as a device's real speed. Convention since round 158: the Samsung is
the release-test phone, the Xiaomi stays debug/dev (so the two signatures
never fight on one device). For any performance claim follow the paired-run
protocol in [PERFORMANCE_BENCHMARKING.md](PERFORMANCE_BENCHMARKING.md) and
summarize sessions with `dart tool/perf_summary.dart`.

## Device quirks

Recorded from field testing (kept here so they're not buried in the
Claude-facing overview):

- **Xiaomi (test device `2107113SG`):** the debug/dev phone. Install the
  **debug** build, and on MIUI use the **"Install via USB"** path. Its GPU has
  needed the crash guard. Thermal character: fast but hot (camera-first
  throttle from ~41 °C).
- **Samsung (`RF8T403A3AT`, mid-range):** the release-test phone (round 158).
  Camera analysis stream caps around **960×720** (selecting higher silently
  falls back), useful for validating the "truthful stream readout" behaviour.
  Its `battery_current_ua` reading is broken (wrong scale), so compare energy
  by battery-percent drop, never `power_w`.

## Project rules (please follow)

- **Every new tunable ships fully wired in the same change:** a Settings
  control, persistence in `SessionConfig` (add to constructor, `toJson`,
  `fromJson`) with a round-trip test, and a row in the end-of-session summary.
  A parameter that exists only in code is considered incomplete. See
  [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
- **Don't reimplement YUV→RGB or ROI cropping in Dart** — the native plugin
  already does it (see ARCHITECTURE.md §2).
- **Respect the keep-in-sync pairs** (ARCHITECTURE.md §4): ROI ÷32 snapping
  across all three crop paths, and the Dart↔Kotlin crop rotation.
- **Adding a custom model:** accepted formats are `.tflite` (including the
  official `format=litert` exports) and `*_qnn.onnx` Snapdragon-NPU context
  binaries; plain `.onnx` is rejected everywhere. Model files are git-ignored
  (large, and some are collaborators'). The full export/conversion guide is
  [MODEL_CONVERSION.md](MODEL_CONVERSION.md); INSTALL.md covers how users
  import models. Note the engine implication: whether a model runs on GPU or
  CPU is decided by whether the GPU backend can compile the model's op graph,
  **not** simply by int8 vs fp16.

## Documentation maintenance

- **[AGENT_CHANGELOG_OVERVIEW.md](AGENT_CHANGELOG_OVERVIEW.md)** is the current-state
  snapshot — **rewrite it in place, never append**, and keep it short. Update
  it whenever a change alters a default, invariant, or the file map.
- **[AGENT_CHANGELOG.md](AGENT_CHANGELOG.md)** is the append-only
  development journal — add a round entry describing what changed and why.
- Keep the human-facing docs (this file, ARCHITECTURE, FIELD_GUIDE,
  SETTINGS_REFERENCE, DATA_GUIDE) accurate when behaviour changes; they are the
  durable references, whereas OVERVIEW is primarily for AI-assisted grounding.

## Git etiquette

The project owner manages version control. **Advise on Git commands rather than
running them** — do not commit, push, or run git operations without the owner's
explicit consent.

## License

The project is **AGPL-3.0** (see [`LICENSE`](../LICENSE)), inherited from the
Ultralytics `ultralytics_yolo` plugin it builds upon. The vendored plugin
retains its own `LICENSE`. Contributions are made under AGPL-3.0.

## Documentation index

| Doc | Audience | Purpose |
|---|---|---|
| [README.md](../README.md) | everyone | Project pitch, layout, license. |
| [INSTALL.md](INSTALL.md) | tester / collaborator | Install a ready-made APK or build from source; import models. |
| [FIELD_GUIDE.md](FIELD_GUIDE.md) | field researcher | Run a session, read the live screen, troubleshoot. |
| [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md) | field researcher | What every setting does. |
| [DATA_GUIDE.md](DATA_GUIDE.md) | researcher / analyst | `session.jsonl` data dictionary; compute visitation rates (R/Python). |
| [HOW_PHOTO_RESOLUTION_WORKS.md](HOW_PHOTO_RESOLUTION_WORKS.md) | advanced user | Why a small ROI still yields sharp photos. |
| [MODEL_CONVERSION.md](MODEL_CONVERSION.md) | collaborator | Accepted model formats; export/convert a trained model for the app. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | developer | Data flow, native↔Dart contract, keep-in-sync pairs. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | developer | Build/test, conventions, this index. |
| [PERFORMANCE_BENCHMARKING.md](PERFORMANCE_BENCHMARKING.md) | developer | How to measure performance honestly (paired-run protocol, `tool/perf_summary.dart`). |
| [../packages/ultralytics_yolo/FAUNAPULSE_FORK.md](../packages/ultralytics_yolo/FAUNAPULSE_FORK.md) | developer / reviewer | What the vendored plugin fork changed vs upstream; re-audit checklist. |
| [PERF_AND_ROBUSTNESS_REVIEW.md](PERF_AND_ROBUSTNESS_REVIEW.md) | maintainer | Prioritized speed/robustness roadmap. |
| [RELEASE_PLAN.md](RELEASE_PLAN.md) | maintainer | Phased checklist for the first public release (DOI, GitHub/Obtainium, Play). |
| [LEAN_QNN_PACKAGING.md](LEAN_QNN_PACKAGING.md) | maintainer | Documented-only design for a lean (no-QNN) default build + separate QNN artifact; reopen triggers. |
| [AGENT_CHANGELOG_OVERVIEW.md](AGENT_CHANGELOG_OVERVIEW.md) | AI grounding | Current-state snapshot (rewrite in place). |
| [AGENT_CHANGELOG.md](AGENT_CHANGELOG.md) | maintainer | Append-only development journal. |
