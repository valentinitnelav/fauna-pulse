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

> Status: Android-first. iOS compatibility is planned for a later phase and will live in
> a separate repository.

## Repository layout

This repository **is** the app — it sits at the root, not in a subfolder.

```
pollinator-monitor/
├── lib/                     # the Pollinator Monitor app (Dart)
├── android/  ios/           # app platform code
├── assets/                  # app assets, including assets/models/custom/ detectors
├── pubspec.yaml             # depends on the vendored plugin via a local path
├── POLLINATOR_MONITOR.md    # development log / change history
├── LICENSE                  # AGPL-3.0
└── packages/
    └── ultralytics_yolo/    # the vendored, MODIFIED YOLO Flutter plugin (see below)
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

## Models

Custom pollinator detectors live in `assets/models/custom/` (e.g. an arthropod detector
and a flower detector). The model picker in the app is built **dynamically** from
whatever `.tflite` files are present, so you can drop in additional custom models.

Large **stock** Ultralytics demo models (`yolo26n*`, generic `yolo11n*`) are **not**
tracked in git to keep the repository small; re-export them from Ultralytics if you want
the baseline options back. Only the project-specific custom detectors are committed.

## Built on

Pollinator Monitor is built on Ultralytics'
[`yolo-flutter-app`](https://github.com/ultralytics/yolo-flutter-app) (the
`ultralytics_yolo` Flutter plugin), forked from upstream commit `22b2e5d`. That plugin —
with project-specific modifications to its Dart and native Android (Kotlin) code (e.g. a
GPU-crash guard, tracker-fragmentation fix, and an on-device recording service) — is
**vendored** in [`packages/ultralytics_yolo/`](packages/ultralytics_yolo/) and retains
its own `LICENSE`.

## License

This project is licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)), inherited from the
Ultralytics `ultralytics_yolo` plugin it builds upon. This is the academic / research
("AGPL") edition of the work.
