<p align="center">
  <img
    src="android/app/src/main/ic_launcher-playstore.png"
    alt="FaunaPulse app icon"
    width="140"
  />
</p>

<h1 align="center">FaunaPulse</h1>

<p align="center">
  An Android field application for detecting, tracking and documenting animals using on-device artificial intelligence.
</p>

<p align="center">
  <strong>On-device AI · Real-time tracking · Configurable models · Offline field use</strong>
</p>

## Overview

FaunaPulse is an Android field application for detecting, tracking and documenting animals and other moving subjects at a fixed observation point.

Its initial and primary scientific use case is the monitoring of flower-visiting insects. For pollination studies, FaunaPulse can measure **visitation rate**: how often insects visit a flower or inflorescence and how long each visit lasts.

The application is not limited to pollinators. By loading a suitable object-detection model, end-users can adapt it to monitor arthropods, birds, mammals, pets or other organisms. It can also operate without an AI model by using motion-triggered capture or time-lapse photography, making it suitable for documenting a wide range of activity and other observable events.

Future development may include automated identification of detected organisms to the lowest taxonomic level supported by the available classification models.

Detection, tracking and image processing run **fully on-device**, without requiring an internet connection (using the [LiteRT](https://github.com/google-ai-edge/litert) framework for edge-AI).

End-users can place a draggable square **region of interest (ROI)** over a flower, inflorescence, feeding site, nest entrance, animal path or any other area of interest. When a target is detected within the ROI, the detection and tracking pipeline assigns it a tracking ID, records its activity and saves ROI-cropped JPEG images together with detailed session metadata.

Captured ROI images can also be reviewed directly within FaunaPulse. End-users can also crop the monitored organism from a saved image and export or share the resulting crop with a identification application installed on the same smartphone, such as [Seek by iNaturalist](https://www.inaturalist.org/pages/seek_app), [ObsIdentify](https://observation.org/apps/obsidentify/), [BeeMachine](https://www.beemachine.ai/), or another preferred classification tool. Where direct image sharing is not supported, the crop can instead be saved locally and imported manually into the chosen application. This allows FaunaPulse to remain focused on detection, tracking and documentation while giving end-users the extra option to select the taxonomic identification service best suited to their interests.

Depending on the selected operating mode, FaunaPulse can be used for:

* **AI-based** object detection and tracking;
* **motion-triggered** image capture;
* scheduled **time-lapse** photography.

## Intended usage

* **Pollination research:** measure and compare flower-visitation rates among plant species, experimental treatments, habitats, land-management practices, environmental conditions, etc.
* **Citizen science:** observe flower visitors, garden wildlife and other local fauna using an ordinary Android smartphone.
* **Wildlife monitoring:** detect and track animals such as arthropods, birds, mammals or even pets using a compatible custom detection model.
* **Activity monitoring:** record when, how often and for how long organisms appear within a selected observation area.
* **Biodiversity documentation:** capture images of fauna occurrences or short-lived biological events using AI detection, motion triggering or time-lapse capture.
* **Model-specific surveys:** monitor any target category represented by a compatible object-detection model.
* **Non-biological observation:** where appropriate, use motion detection or a custom model to document other moving objects or events of interest.

FaunaPulse is intended as a flexible observation platform rather than a detector restricted to a particular taxonomic group. Its usefulness therefore depends on the selected capture mode, the observation setup and, for AI-based monitoring, the capabilities of the loaded custom detection model.

## Build & run (Android)

See the step-by-step [Installation & Testing Guide](docs/INSTALL.md). 
It covers both installing a ready-made app (no coding) and building from source.

## Vibe coding

I was curious to see how far I could push the limits of what is possible with "vibe coding". 
Initially, developing a custom field tool felt like a costly and daunting endeavor, 
likely requiring me to apply for grants just to hire Android developers. 
However, as coding agents grew more capable and popular, I decided to give them a try. 
While I am not new to programming (and I doubt I could have built this app 
without some prior understanding of software development) this process has been 
a rewarding journey. It is worth noting that I use paid tools like Claude Code, 
which I recognize is a luxury that may not be accessible to everyone, 
but it has been instrumental in bringing this project to life.

So, mainly [Claude Code](https://claude.com/product/claude-code) was used for software development.
See [`./docs/AGENT_CHANGELOG_OVERVIEW.md`](./docs/AGENT_CHANGELOG_OVERVIEW.md) & the detailed [`./docs/AGENT_CHANGELOG.md`](./docs/AGENT_CHANGELOG.md) for the full development log history and pipeline configuration.
Occasionally, I used the free versions of ChatGPT and Gemini chat bots in online sessions to double check Claude (and vice versa) when I had some doubts (suspicions of "hallucinations" of these LLMs).
I conducted literature search on scientific topics using [Google Scholar](https://scholar.google.com), and also [Elicit](https://elicit.com/) and [Consensus](https://consensus.app/).

This app is built on Ultralytics' [`yolo-flutter-app`](https://github.com/ultralytics/yolo-flutter-app) 
(forked from upstream commit `22b2e5d`). 
That Ultralytics plugin is in [`packages/ultralytics_yolo/`](packages/ultralytics_yolo/) 
and retains its own `LICENSE`.

iOS compatibility is planned for a later phase.


## Repository layout

General layout:

```text
fauna-pulse/
├── lib/                     # the FaunaPulse app (Dart scripts)
├── android/                 # app platform code
├── assets/                  # app assets, including assets/models/ detectors
├── docs/                    # app install doc, development logs / change history, etc.
├── LICENSE                  # AGPL-3.0 (inherited from ultralytics)
└── packages/
    └── ultralytics_yolo/    # MODIFIED YOLO Flutter plugin from ultralytics (see below)
```

This repository is the app, it sits at the root, not in a subfolder (previously `/yolo-flutter-app/example/`).
That older path might appear in the log history.

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
| [INSTALL.md](docs/INSTALL.md) | tester / developer | Install a ready-made APK or build from source; import models. |
| [FIELD_GUIDE.md](docs/FIELD_GUIDE.md) | field researcher | Run a session, read the live screen, troubleshoot. |
| [SETTINGS_REFERENCE.md](docs/SETTINGS_REFERENCE.md) | field researcher | What every setting does. |
| [DATA_GUIDE.md](docs/DATA_GUIDE.md) | researcher / analyst | `session.jsonl` data dictionary; compute visitation rates (R/Python). |
| [HOW_PHOTO_RESOLUTION_WORKS.md](docs/HOW_PHOTO_RESOLUTION_WORKS.md) | developer | Why a small ROI still yields sharp photos. |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | developer | Data flow, native↔Dart contract, keep-in-sync pairs. |
| [CONTRIBUTING.md](docs/CONTRIBUTING.md) | developer | Build/test, conventions, docs index. |
| [PERF_AND_ROBUSTNESS_REVIEW.md](docs/PERF_AND_ROBUSTNESS_REVIEW.md) | maintainer | Prioritized speed/robustness roadmap. |
| [AGENT_CHANGELOG_OVERVIEW.md](docs/AGENT_CHANGELOG_OVERVIEW.md) / [AGENT_CHANGELOG.md](docs/AGENT_CHANGELOG.md) | Code agent / maintainer | Current-state snapshot / append-only development journal. |


## Models

Note to collaborators: all model binaries are and should stay git-ignored for now.

Model weights (`.tflite` files) are not stored in this online repository. 
This is because they are large to be under git history and some detectors 
belong to research collaborators and must not be redistributed without approval. 

See the [Installation & Testing Guide](docs/INSTALL.md) for details.


## The app idea & scientific background

The ideas, app features and motivation are rooted in my work at [UFZ](https://www.ufz.de/) & [iDiv](https://www.idiv.de/).

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

Working on this app I have also realized that it can be used not only fo pollinator monitoring, but for any other project that requires detection + tracking of a moving object/subject/organism within a region of interest.
So I hope this can be useful for citizen science projects as well by uploading custom object detectors (not just for pollinators).

Last but not least, I wanted this to be open and free for scientists, especially trying to help in this way labs that are underfunded.

## License

This project is licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)), inherited from the
Ultralytics `ultralytics_yolo` plugin it builds upon.
