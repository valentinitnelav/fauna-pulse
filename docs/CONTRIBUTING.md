# Contributing

**Who this is for:** developers contributing to Pollinator Monitor. For how the
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
flutter test test/pollinator         # the app's unit tests
flutter build apk --debug            # the app is deployed as a debug build
flutter run                          # run on a connected device
```

Run `flutter analyze` and `flutter test test/pollinator` before every PR.

## Testing

Unit tests live in `test/pollinator/` and cover the pure logic: ROI math
(`roi_test.dart`), the ByteTrack tracker (`byte_track_test.dart`), the logger
(`session_logger_test.dart`), config round-trip/migration
(`session_config_test.dart`), the adaptive throttle
(`adaptive_inference_throttle_test.dart`), and ROI capture helpers
(`roi_capture_test.dart`).

Known coverage gaps (see [PERF_AND_ROBUSTNESS_REVIEW.md](PERF_AND_ROBUSTNESS_REVIEW.md)
§B8): the `RoiCaptureScheduler` scheduling cadence, the logger's write-failure
path, and `camera_session_screen.dart` orchestration are not yet tested.

**Benchmarking caveat:** the app deploys as a *debug* build, which runs slower
than release. Don't quote debug FPS as the device's real speed.

## Device quirks

Recorded from field testing (kept here so they're not buried in the
Claude-facing overview):

- **Xiaomi (test device `2107113SG`):** install the **debug** build, and on
  MIUI use the **"Install via USB"** path. Its GPU has needed the crash guard.
- **Samsung (`RF8T403A3AT`, mid-range):** camera analysis stream caps around
  **960×720** — selecting higher silently falls back. Useful for validating the
  "truthful stream readout" behaviour.

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
- **Adding a custom model:** models are `.tflite` files (git-ignored — large
  and some are collaborators'). They must match the detector's expected input
  size and class labels. Note the engine implication: whether a model runs on
  GPU or CPU is decided by whether the GPU backend can compile the model's op
  graph, **not** simply by int8 vs fp16. See INSTALL.md for how users import
  models, and `python_scripts/README_int8_export.md` for the INT8 export
  process.

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
| [ARCHITECTURE.md](ARCHITECTURE.md) | developer | Data flow, native↔Dart contract, keep-in-sync pairs. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | developer | Build/test, conventions, this index. |
| [PERF_AND_ROBUSTNESS_REVIEW.md](PERF_AND_ROBUSTNESS_REVIEW.md) | maintainer | Prioritized speed/robustness roadmap. |
| [AGENT_CHANGELOG.md](AGENT_CHANGELOG.md) | AI grounding | Current-state snapshot (rewrite in place). |
| [AGENT_CHANGELOG.md](AGENT_CHANGELOG.md) | maintainer | Append-only development journal. |
