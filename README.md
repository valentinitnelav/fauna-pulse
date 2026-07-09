# Pollinator Monitor

An Android field application that detects flower-visiting insects in real time and
logs their visits. The primary scientific deliverable is the **visitation rate** 
(how often insects visit a given flower and how long each visit lasts) so that 
pollination researchers can compare plant species, experimental treatments, land use management, etc.

Detection runs **fully on-device** (no network needed) using [LiteRT](https://github.com/google-ai-edge/litert). 
A draggable square **region of interest (ROI)** is
placed over the target flower (or portion of inflorescence or path of flowers). 
When an insect enters the ROI, a combined detection + tracking pipeline activates, 
assigns each insect a tracking ID, saves ROI-cropped JPEGs, and writes an append-only JSON log of the session. 

[Claude Code](https://claude.com/product/claude-code) was used for software development.
See [`./docs/POLLINATOR_OVERVIEW.md`](./docs/POLLINATOR_OVERVIEW.md) & the detailed [`./docs/POLLINATOR_MONITOR.md`](./docs/POLLINATOR_MONITOR.md) for the full development log history and pipeline configuration.

iOS compatibility is planned for a later phase and might live in a separate repository.

## Repository layout

General layout:
```
pollinator-monitor/
├── lib/                     # the Pollinator Monitor app (Dart scripts)
├── android/                 # app platform code
├── assets/                  # app assets, including assets/models/ detectors
├── docs/                    # app install doc, development logs / change history, etc.
├── LICENSE                  # AGPL-3.0 (inherited from ultralytics)
└── packages/
    └── ultralytics_yolo/    # MODIFIED YOLO Flutter plugin from ultralytics (see below)
```

This repository is the app, it sits at the root, not in a subfolder (previously `/yolo-flutter-app/example/`).

The app depends on the ultralytics plugin:

```yaml
# pubspec.yaml
dependencies:
  ultralytics_yolo:
    path: packages/ultralytics_yolo
```

## Documentation

| Doc | Audience | Purpose |
|---|---|---|
| [INSTALL.md](docs/INSTALL.md) | tester / collaborator | Install a ready-made APK or build from source; import models. |
| [FIELD_GUIDE.md](docs/FIELD_GUIDE.md) | field researcher | Run a session, read the live screen, troubleshoot. |
| [SETTINGS_REFERENCE.md](docs/SETTINGS_REFERENCE.md) | field researcher | What every setting does. |
| [DATA_GUIDE.md](docs/DATA_GUIDE.md) | researcher / analyst | `session.jsonl` data dictionary; compute visitation rates (R/Python). |
| [HOW_PHOTO_RESOLUTION_WORKS.md](docs/HOW_PHOTO_RESOLUTION_WORKS.md) | advanced user | Why a small ROI still yields sharp photos. |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | developer | Data flow, native↔Dart contract, keep-in-sync pairs. |
| [CONTRIBUTING.md](docs/CONTRIBUTING.md) | developer | Build/test, conventions, docs index. |
| [PERF_AND_ROBUSTNESS_REVIEW.md](docs/PERF_AND_ROBUSTNESS_REVIEW.md) | maintainer | Prioritized speed/robustness roadmap. |
| [POLLINATOR_OVERVIEW.md](docs/POLLINATOR_OVERVIEW.md) / [POLLINATOR_MONITOR.md](docs/POLLINATOR_MONITOR.md) | maintainer | Current-state snapshot / append-only development journal. |

## Build & run (Android)

See the step-by-step [Installation & Testing Guide](docs/INSTALL.md). 
It covers both installing a ready-made app (no coding) and building from source.


## Models

Model weights (`.tflite` files) are not stored in this repository. They are large
and some detectors belong to collaborators and must not be redistributed. 
All model binaries are and should stay git-ignored.

See the [Installation & Testing Guide](docs/INSTALL.md) for details.

## Built on

Pollinator Monitor is built on Ultralytics'
[`yolo-flutter-app`](https://github.com/ultralytics/yolo-flutter-app) (the
`ultralytics_yolo` Flutter plugin), forked from upstream commit `22b2e5d`. That plugin —
with project-specific modifications to its Dart and native Android (Kotlin) code (e.g. a
GPU-crash guard, tracker-fragmentation fix, and an on-device recording service) — is 
in [`packages/ultralytics_yolo/`](packages/ultralytics_yolo/) and retains its own `LICENSE`.

## License

This project is licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)), inherited from the
Ultralytics `ultralytics_yolo` plugin it builds upon.
