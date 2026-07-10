# Pollinator Monitor

An Android field application that detects flower-visiting insects in real time and
logs their visits. The primary scientific deliverable is the **visitation rate** 
(how often insects visit a given flower and how long each visit lasts).

Insect identification (to the lowest taxonomic level possible) is planned.

Detection runs **fully on-device** (no network needed) using [LiteRT](https://github.com/google-ai-edge/litert). 
A draggable square **region of interest (ROI)** is placed over the target flower 
(or portion of inflorescence or path of flowers). 
When an insect enters the ROI, a combined detection + tracking pipeline activates, 
assigns each insect a tracking ID, saves ROI-cropped JPEGs, 
and writes an append-only JSON log of the session. 

Intended usage:

- pollination researchers can compare visitation rates across various treatments 
(e.g. plant species, experimental treatments, land use management, etc.);
- citizen scientists curious about pollination (e.g. monitor your outdoor plants
capture images of those pollinators in the moment of visiting your plants).


## Build & run (Android)

See the step-by-step [Installation & Testing Guide](docs/INSTALL.md). 
It covers both installing a ready-made app (no coding) and building from source.


## Vibe coding

I was curious to see how far I could push the limits of what is possible with "vibe coding." 
Initially, developing a custom field tool felt like a costly and daunting endeavor, 
likely requiring me to apply for grants just to hire Android developers. 
However, as coding agents grew more capable and popular, I decided to give them a try. 
While I am not completely new to programming (and I doubt I could have built this app 
without some prior understanding of software development) this process has been 
an incredibly rewarding journey. It is worth noting that I use paid tools like Claude Code, 
which I recognize is a luxury that may not be accessible to everyone, 
but it has been instrumental in bringing this project to life.

So, [Claude Code](https://claude.com/product/claude-code) was used for software development.
See [`./docs/POLLINATOR_OVERVIEW.md`](./docs/POLLINATOR_OVERVIEW.md) & the detailed [`./docs/POLLINATOR_MONITOR.md`](./docs/POLLINATOR_MONITOR.md) for the full development log history and pipeline configuration.

This app is built on Ultralytics' [`yolo-flutter-app`](https://github.com/ultralytics/yolo-flutter-app) 
(forked from upstream commit `22b2e5d`). 
That Ultralytics plugin is in [`packages/ultralytics_yolo/`](packages/ultralytics_yolo/) 
and retains its own `LICENSE`.

iOS compatibility is planned for a later phase.


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


## Models

Note to collaborators: all model binaries are and should stay git-ignored for now.

Model weights (`.tflite` files) are not stored in this online repository. 
This is because they are large to be under git history and some detectors 
belong to research collaborators and must not be redistributed without approval. 

See the [Installation & Testing Guide](docs/INSTALL.md) for details.


## The app idea & scientific background

The ideas, app features and motivation is rooted in my work at [UFZ](https://www.ufz.de/) & [iDiv](https://www.idiv.de/).

- UFZ: Helmholtz Centre for Environmental Research
- iDiv: German Centre for Integrative Biodiversity Research Halle-Jena-Leipzig – iDiv e. V.

Specifically, see the published manuscripts:

> Stark, T., Ştefan, V., Wurm, M., Spanier, R., Taubenböck, H., & Knight, T. M. (2023). **YOLO object detection models can locate and classify broad groups of flower-visiting arthropods in images**. Scientific reports, 13(1), 16364. https://doi.org/10.1038/s41598-023-43482-3

> Ștefan, V., Workman, A., Cobain, J. C., Rakosy, D., & Knight, T. M. (2025). **Utilising affordable smartphones and open-source time-lapse photography for pollinator image collection and annotation**. Journal of Pollination Ecology, 38, 1–21. https://doi.org/10.26786/1920-7603(2025)778

> Ștefan, V., Stark, T., Wurm, M., Taubenböck, H., & Knight, T. M. (2025). **Successes and limitations of pretrained YOLO detectors applied to unseen time-lapse images for automated pollinator monitoring**. Scientific Reports, 15(1), 30671. https://doi.org/10.1038/s41598-025-16140-z

> Stark, T., Wurm, M., Ştefan, V., Wolf, F., Taubenböck, H., & Knight, T. M. (2025). **Utilizing CNNs for classification and uncertainty quantification for 15 families of European fly pollinators**. Plos one, 20(9), e0323984. https://doi.org/10.1371/journal.pone.0323984

A story about the motivation, main features, ideas and the road ahead:

- During my work and PhD time at iDiv and UFZ, we captured **large volume of image datasets** 
using a simple time-lapse approach. It became clear that this data volume must be reduced 
by using a camera trigger to capture images only when insects are within the field of view of the camera. 
Since insects cannot be easily distinguished by the heat difference between their body and the surroundings, 
AI object detectors became a good candidate. Also, motion detectors can be often triggered 
by natural wind movements or differences in light intensity.
- The focus on a **square Region of Interest (ROI)** within the field of view of the camera 
came from the fact that we were interested in reducing the noisy and complex image background 
and focus as much as possible on a target flower, or inflorescence or patch of flowers. 
This is not only ecologically important, but also sensible thing to implement 
in terms of computer vision (out of focus, blurred insects on flowers in the background 
add extra information noise). The square, 1:1 aspect ratio of ROI is also a usual 
input for computer vision models, without having to post process it, 
which can introduce unwanted stretching or interpolation artifacts.
- **Insect classification**: we plan to integrate classification models 
(e.g. Vision Foundation Models like [BioCLIP](https://imageomics.github.io/bioclip-ecosystem/index.html) ones) 
or using citizen-science platforms (such as [iNaturalist](https://www.inaturalist.org/) 
or [Observation.org](https://observation.org/)). 
At UFZ & iDiv (lab of [Prof. Tiffany Knight](https://www.idiv.de/research/core-research-groups/species-interaction-ecology/ai-tools/)), 
we are already testing BioCLIP models in our [SEPPI](https://seppi-pollinate.weebly.com/) project 
and explore with many more approaches.
- **Stats / Analytics reporting** derived from visitation rates and classification of insects: 
this will vary from case to case (pollination ecologists, citizen scientists, the agriculture & industry sector, etc.).

Last but not least, I wanted this to be open and free for scientists, especially trying to help in this way 
labs that are underfunded.

## License

This project is licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)), inherited from the
Ultralytics `ultralytics_yolo` plugin it builds upon.
