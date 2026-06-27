# Pollinator Monitor

An Android-first field application that detects flower-visiting insects in real time and
logs every detection with its timestamp. The primary scientific deliverable is the
**visitation rate** — how often insects visit a given flower and how long each visit
lasts — so that researchers can compare plant types or experimental treatments.

Detection runs **fully on-device** (no network needed) using LiteRT, with real-time
inference through a camera preview. A draggable square **region of interest (ROI)** is
placed over the target flower; when an insect enters the ROI, a combined
detection + tracking pipeline activates, assigns each insect a tracking ID, saves
cropped JPEGs, and writes an append-only JSON log of the session. See
[`POLLINATOR_MONITOR.md`](POLLINATOR_MONITOR.md) for the full development log and the
current pipeline configuration.

Android-first. iOS compatibility is planned for a later phase and will live in a separate repository.

## Repository layout

This repository is the app — it sits at the root, not in a subfolder (previosly `yolo-flutter-app/example/`).

```
pollinator-monitor/
├── lib/                     # the Pollinator Monitor app (Dart)
├── android/                 # app platform code
├── assets/                  # app assets, including assets/models/custom/ detectors
├── pubspec.yaml             # depends on the ultralytics plugin via a local path
├── POLLINATOR_MONITOR.md    # development log / change history
├── LICENSE                  # AGPL-3.0
└── packages/
    └── ultralytics_yolo/    # MODIFIED YOLO Flutter plugin (see below)
```

The app depends on the plugin locally:

```yaml
# pubspec.yaml
dependencies:
  ultralytics_yolo:
    path: packages/ultralytics_yolo
```

## Build & run (Android)

```bash
flutter pub get
flutter run            # with a device connected over USB (debug build)
# or build an installable debug APK:
flutter build apk --debug
```

> **Collaborators / non-developers:** see the step-by-step
> **[Installation & Testing Guide](docs/INSTALL.md)** — it covers both installing a
> ready-made app (no coding) and building from source on Windows / macOS / Linux.

## Models

Model weights (`.tflite` files) are **not stored in this repository** — they are large
and **some detectors belong to collaborators and must not be redistributed**. All model
binaries are git-ignored.

To add models, use the in-app **Settings → Import…** button (or drop `.tflite` files into
the app's `…/Pollinator Monitor/models/` folder over USB). The model picker is built
**dynamically** from whatever `.tflite` files it finds, so the app works with however
many models you provide. For developers, models can instead be placed in
`assets/models/` / `assets/models/custom/` before building (those folders stay
git-ignored). See the [Installation & Testing Guide](docs/INSTALL.md) for details.

## Built on

Pollinator Monitor is built on Ultralytics'
[`yolo-flutter-app`](https://github.com/ultralytics/yolo-flutter-app) (the
`ultralytics_yolo` Flutter plugin), forked from upstream commit `22b2e5d`. That plugin —
with project-specific modifications to its Dart and native Android (Kotlin) code (e.g. a
GPU-crash guard, tracker-fragmentation fix, and an on-device recording service) — is 
in [`packages/ultralytics_yolo/`](packages/ultralytics_yolo/) and retains its own `LICENSE`.

## License

This project is licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)), inherited from the
Ultralytics `ultralytics_yolo` plugin it builds upon. This is the academic / research
("AGPL") edition of the work.
