# Contributing

**Who this is for:** developers contributing to FaunaPulse. For how the
code fits together, read [ARCHITECTURE.md](ARCHITECTURE.md) first.

---

## Toolchain & setup

The [Installation & Testing Guide](INSTALL.md) covers the Flutter and Android
tools (SDK versions, `flutter doctor`, phone setup). The app sits at the
repository root and uses the Ultralytics plugin through a `path:` dependency:

```yaml
dependencies:
  ultralytics_yolo:
    path: packages/ultralytics_yolo
```

## Branch and pull-request workflow

FaunaPulse has two long-lived branches:

- `main` is the stable public branch. It must always build, and it receives
  changes only after review.
- `develop` is the branch for ongoing work. Normal code, documentation and
  library-update pull requests target `develop`.

The maintainer merges `develop` into `main` when it is stable. Only an urgent
release or security fix may target `main` directly.

For a normal contribution:

1. Fork the repository and update your fork's `develop` branch.
2. Make a short-lived branch from the latest `develop`:

   ```bash
   git switch develop
   git pull --ff-only
   git switch -c fix/short-description # or some feature
   ```

3. Make one focused change and run the checks for it.
4. Push the branch to your fork and open a pull request with **base:
   `develop`**.
5. Delete the branch after the pull request is merged or closed.

Start the branch name with a short prefix such as `fix/`, `feature/`, `docs/`
or `test/`.

### Library updates

Dependabot only keeps a private list of security alerts (Security tab of the
repository). It opens no pull requests: there is no `.github/dependabot.yml`,
and its security updates are off (their automatic fixes cannot change Android
libraries that come in through other libraries, and showed as failed runs on
`main`).

Before each release, check the open alerts and fix the real ones in a round on
`develop`. Libraries are updated on purpose, in a round before a release.
Update Gradle, the Android Gradle Plugin and Kotlin together (they must stay
compatible). Native libraries (LiteRT, QNN, ONNX Runtime) also need a check on
a phone.

GitHub cannot read Gradle files by itself. The workflow
`.github/workflows/dependency_graph.yml` sends the list of Android libraries in
the app to GitHub, so the alerts cover them too. Alerts exist only for `main`,
so a change to that workflow shows its effect after the next merge into `main`.

### Maintainer repository settings

Keep `main` as the default branch. In GitHub's repository settings:

- Turn on **Automatically delete head branches** (after a merge).
- Under **Advanced Security**, turn on **Dependabot alerts**. Leave Dependabot
  security updates and version updates off (see *Library updates*).
- Protect `main` with a ruleset that blocks force pushes and deletion and
  requires a pull request plus the security and release checks.
- Run `git fetch --prune` locally from time to time, to remove references to
  branches that GitHub has deleted.

## Everyday commands

```bash
flutter pub get                                   # after changing dependencies
flutter analyze                                   # static analysis (must be clean)
flutter test test/fauna_pulse/*_test.dart         # while working (about 1,100 tests)
flutter test                                      # whole suite, before a commit
flutter build apk --debug --target-platform android-arm64   # debug build (test phones are arm64)
flutter build apk --release                       # release build (needs the keystore, INSTALL.md B4)
flutter run                                       # run on a connected phone
```

Before every pull request, run `flutter analyze` and the whole `flutter test`.

## Testing

Unit tests live in `test/fauna_pulse/` and follow the module map: ROI maths,
both trackers (plus the offline replay harness), the logger and its
write-failure path, photo scheduling and crop geometry, frame processing,
settings round trips and migrations, schedule and time-lapse plans, analysis
afterwards and SAHI, error reports, and widget regressions.
[test/README.md](../test/README.md) has the commands, the replay harness and
the checks on a phone.

**Benchmarking caveat:** debug builds are slower than release builds, so never
quote debug FPS as a phone's real speed. For any performance claim, follow the
paired-run protocol in [PERFORMANCE_BENCHMARKING.md](PERFORMANCE_BENCHMARKING.md)
and summarise the sessions with `dart tool/perf_summary.dart`.

## Device quirks

Found in field tests. The Samsung runs release builds and the Xiaomi debug
builds, so the two signatures never meet on one phone.

- **Xiaomi 11T Pro (`2107113SG`):** the development phone. On MIUI answer the
  **"Install via USB"** question. Its GPU needed the GPU-crash guard. It is fast
  but hot: the camera throttles from about 41 °C.
- **Samsung Galaxy M12 (`SM-M127F`):** the release-test phone. Its camera
  analysis stream stops at about **960×720** (a higher choice silently falls
  back), which is useful to test that the app reports the stream it really got.
  Its `battery_current_ua` reading has the wrong scale, so compare energy by the
  drop in battery percent, never by `power_w`.

## Project rules (please follow)

- **Every new tunable ships fully wired in the same change:** a Settings
  control, persistence in `SessionConfig` (constructor, `toJson`, `fromJson`)
  with a round-trip test, and a row in the end-of-session summary. A parameter
  that exists only in code is not finished. See
  [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
- **Do not write YUV→RGB conversion or ROI cropping in Dart:** the native
  plugin already does both (ARCHITECTURE.md §2).
- **Respect the keep-in-sync pairs** (ARCHITECTURE.md §4): ROI ÷32 snapping in
  all three crop paths, and the Dart and Kotlin crop rotation.
- **Adding a custom model:** the app accepts `.tflite` (also the official
  `format=litert` exports) and `*_qnn.onnx` Snapdragon NPU context binaries;
  plain `.onnx` is refused everywhere, and so are segmentation, pose and
  rotated-box (OBB) exports (detectors must be plain detection models). Model
  files are git-ignored (large, and some belong to collaborators). Formats:
  [MODEL_CONVERSION.md](MODEL_CONVERSION.md); export tools: the separate
  repository [fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models);
  how users import models: INSTALL.md. A model runs on the GPU if the GPU
  backend can compile its operations, **not** simply because it is int8 or
  fp16.

## Documentation maintenance

- Keep the documentation table in [/README.md](../README.md) up to date.
- Keep the docs for people (this file, ARCHITECTURE, FIELD_GUIDE,
  SETTINGS_REFERENCE, DATA_GUIDE) correct when behaviour changes. They are the
  lasting references; the overview is mainly for coding agents.
- [AGENT_CHANGELOG_OVERVIEW.md](AGENT_CHANGELOG_OVERVIEW.md) says what is true
  now: **rewrite it in place, never append**, and keep it short. Update it
  whenever a change alters a default, a rule or the file map.
- [AGENT_CHANGELOG.md](AGENT_CHANGELOG.md) is the append-only development
  history: a short entry per round with the reason, what was checked and what
  is open; the round's commit ("Round N: ...") says what changed.
- Code comments tagged "perf review A1" (and similar codes) refer to a
  performance and robustness review of 2026 that is not in the repository; the
  round number next to the tag leads to its reasoning in AGENT_CHANGELOG.md.

## Git etiquette

Do not force-push or delete `main` or `develop`. You may rewrite your own
unmerged short-lived branch, but after review has started, rebase it only if
you tell the reviewers.

Write clear commit messages. The maintainer gives a contribution its
`Round N` number when merging it, so you do not need to guess the next number.
Never commit private session data, signing keys or model weights.

## License

The project is **AGPL-3.0** (see [`LICENSE`](../LICENSE)), inherited from the
Ultralytics `ultralytics_yolo` plugin it builds on. That plugin
(`packages/ultralytics_yolo/`) keeps its own `LICENSE`. Contributions are made
under AGPL-3.0.

Give credit where it is due. Code that follows a published method cites the
paper (authors, year, venue, DOI) in a comment where it is implemented. Code
copied or adapted from another project needs a licence compatible with
AGPL-3.0 (for example MIT, BSD, Apache-2.0 or GPL-3.0), keeps its original
copyright notice and gets a comment with the source link. Please say so in the
pull request. Do not copy large parts of other projects.
