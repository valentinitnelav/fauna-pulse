<p align="center">
  <img
    src="android/app/src/main/ic_launcher-playstore.png"
    alt="FaunaPulse app icon"
    width="140"
  />
</p>

<h1 align="center">FaunaPulse</h1>

<p align="center">
  <strong>Transform your smartphone into an AI-powered wildlife camera</strong>
</p>

<p align="center">
  Detect, track and document pollinators and other fauna using on-device artificial intelligence, motion-trigger or time-lapse image capture (including night mode).
</p>

<p align="center">
  On-device AI · Real-time tracking · Custom models · Works offline
</p>

## Overview

The first and primary scientific use case of FaunaPulse is estimating *visitation rates* in pollination studies: how often pollinators visit a flower or inflorescence and how long each visit lasts.
However, with a suitable object-detection model, it can be configured for various wildlife groups and ecological observation settings.

FaunaPulse is intended as a passive, non-invasive imaging tool. Detection, tracking and image processing run **fully on-device** using [LiteRT](https://github.com/google-ai-edge/litert), so an internet connection is not required in the field. A draggable square **region of interest (ROI)** can be placed over a flower (or feeding site, nest entrance, animal path, observation area of interest, etc.). FaunaPulse then records activity within that region and also saves ROI-cropped JPEG images together with metadata. At the end of the recording session, it outputs a dashboard screen with info and graphs about the visitation rates and the captured images with the tracked objects for preview an check.

For interested end-users, saved images can also be reviewed and cropped within the app. Organism crops can then be shared with or imported into identification apps such as: [Seek by iNaturalist](https://www.inaturalist.org/pages/seek_app), [ObsIdentify](https://observation.org/apps/obsidentify/), [BeeMachine](https://www.beemachine.ai/) or another preferred app or classification service. At the moment, FaunaPulse remains focused on detection and tracking, while end-users choose the identification service best suited to their needs. Note that at the time of releasing this repository, the apps enumerated above do not perform bulk (en mass) identification, but they work with one image per upload and internet connection is needed. FaunaPulse is designed mostly with offline usage in mind and bulk processing for scaling monitoring.

Saved images and session metadata can later be exported for analysis in research workflows. Image-classification tools such as [BioCLIP][bioclip] may be used separately to assist with taxonomic identification. A companion analysis workflow will also be developed.

Depending on the selected mode, FaunaPulse supports several modes of operation:

1. **Real-time AI-based object detection and tracking** using a compatible custom model;
2. **Motion-triggered** image capture;
3. **Time-lapse** image capture, including nocturnal mode using the phone's torch / flashlight;
4. **Post-capture AI detection** processing of the motion or time-lapse images using either a single-detector pass or the moving window / tiling approach - [SAHI (Slicing Aided Hyper Inference)][sahi]. This can help reduce the amount of "empty" images (without pollinators / target object) that are usually captured via the motion-triggered or time-lapse modes.

Modes 1-3 can also be **scheduled** - for example 1st run 9:00-12:00, 2nd run 13:00-17:00, daily; or with over night time if the smartphone(s) are deployed over multiple days or for recording in time-lapse mode for nocturnal activity.

## Examples of usage

- **Pollination research:** measure and compare flower-visitation rates among plant species, (e.g., across habitats, land-management practices, environmental conditions / gradients, research treatments, etc.).
- **Citizen science:** observe flower visitors, garden wildlife and other local fauna using an ordinary smartphone.
- **Wildlife and activity monitoring:** record when, how often and for how long organisms appear within a selected observation area.
- **Biodiversity documentation:** capture fauna occurrences or events using AI detection, motion triggering or time-lapse capture.
- **Model-based wildlife surveys:** monitor wildlife categories supported by a compatible object-detection model.

## Project status & General limitations

FaunaPulse is an **early research preview (alpha)**, provided as an experimental field tool rather than a validated monitoring product. Field validation is ongoing. Please treat it accordingly:

- Android is currently supported; iOS compatibility postponed for a later phase (if there will be significant demand).
- AI-based monitoring requires a compatible quantized `.tflite` object-detection model. FaunaPulse was designed with the goal that end-users can add their own AI models.
- Built-in (on device) en masse automated taxonomic identification is not available (yet).
- Detection accuracy and tracking performance depend on the model, smartphone, target organism and field setup, including weather conditions. Smartphones are not usually designed to endure under the scorching sun or rained on, so please use waterproof and/or thermal casing, USB (magnetic) coolers or simple shading if you plan to operate in such conditions - there are options on online markets and I prefer to avoid advertising any in particular; advise and creative solutions are very much welcomed.
- Visit counts may include missed, duplicated, split or merged tracks. Therefore, review outputs and consider those limitations before drawing strong scientific conclusions.
- Performance varies substantially between phone models. Prolonged continuous inference can cause the device to heat up, thermally throttle and drain the battery faster.
- Each scientific application should be validated under its intended field conditions before data collection at scale.

## Getting started

1. **Install the app.** Download the latest APK file from the [Releases](https://github.com/valentinitnelav/fauna-pulse/releases) page, or build from source - both are covered in the [Installation & Testing Guide](docs/INSTALL.md).
2. **Grant permissions** when prompted: camera, location (one GPS fix per session) and notifications (used by the long-running recording service).
3. **Choose a detection model.** Some general detectors are bundled, so the app runs immediately after install. A purpose-trained model can be added with **Download…** (a link) or **Import…** (a file) in the model picker. Motion-triggered and time-lapse capture need no model at all. See [Models](#models).
4. **Set up the shot.** Position the phone over your flower or observation area and drag the square region of interest (ROI) over it. See also the [Field Guide](docs/FIELD_GUIDE.md).
5. **Run a short test session** first to confirm framing, detections and capture behave as expected before a long deployment.
6. **Inspect the output.** Review the captured crops on-device, and read `session.jsonl` on a computer — the [Data Guide](docs/DATA_GUIDE.md) documents the format and how to compute visitation rates in R or Python.

## Build and run on Android

For testers and collaborators, see the step-by-step [Installation & Testing Guide](docs/INSTALL.md).

It covers both installing a ready-made app without coding and building FaunaPulse from source.

## Documentation

| Document | Audience | Purpose |
|---|---|---|
| [INSTALL.md](docs/INSTALL.md) | Tester / developer | Install a ready-made APK or build from source; import models. |
| [FIELD_GUIDE.md](docs/FIELD_GUIDE.md) | Field researcher | Run a session, read the live screen and troubleshoot. |
| [SETTINGS_REFERENCE.md](docs/SETTINGS_REFERENCE.md) | Field researcher | Understand every user setting. |
| [DATA_GUIDE.md](docs/DATA_GUIDE.md) | Researcher / analyst | Read the `session.jsonl` data dictionary and compute visitation rates in R or Python. |
| [HOW_PHOTO_RESOLUTION_WORKS.md](docs/HOW_PHOTO_RESOLUTION_WORKS.md) | Developer | Understand why a small ROI can still yield sharp photographs. |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Developer | Understand the data flow and native-to-Dart contract. |
| [CONTRIBUTING.md](docs/CONTRIBUTING.md) | Developer | Build, test and follow repository conventions. |
| [MODEL_CONVERSION.md](docs/MODEL_CONVERSION.md) | Developer | Export detectors to run inside FaunaPulse app. |
| [PERF_AND_ROBUSTNESS_REVIEW.md](docs/PERF_AND_ROBUSTNESS_REVIEW.md) | Code agent | Review the prioritized performance and robustness roadmap. |
| [AGENT_CHANGELOG_OVERVIEW.md](docs/AGENT_CHANGELOG_OVERVIEW.md) | Code agent | Read the current-state development overview. |
| [AGENT_CHANGELOG.md](docs/AGENT_CHANGELOG.md) | Code agent | Read the detailed append-only development journal. |

## Technical foundation

FaunaPulse is built on Ultralytics' open-source [`yolo-flutter-app`](https://github.com/ultralytics/yolo-flutter-app), forked from upstream commit `22b2e5d`.

The modified Ultralytics plugin is retained in [`packages/ultralytics_yolo/`](packages/ultralytics_yolo/) and remains subject to its own `LICENSE`.

## Models

The app bundles one general-purpose detector for popular wildlife - [MegaDetector v6][mgdetv6] with 3 classes: animal, person, vehicle.
See also [THIRD_PARTY_MODELS.md](docs/THIRD_PARTY_MODELS.md).

To detect insects, add a model trained for that purpose:

- **Download…** in the model picker, pasting a link to a `.tflite` file (for example a GitHub release asset), or
- **Import…**, selecting a file already on the phone, or
- train and export your own, see [MODEL_CONVERSION.md](docs/MODEL_CONVERSION.md).

Motion-triggered and time-lapse capture record without any detection model.

Model weights are not stored in this repository. They can be too large to keep in Git history, and some test detectors belong to research collaborators and must not be redistributed without approval, so all model binaries stay Git-ignored. See the [Installation & Testing Guide](docs/INSTALL.md) for how models reach the phone.

<!-- OWNER TODO (round 158): the single biggest adoption question for citizen
     scientists is whether they can get a working insect detector in one click.
     Decide whether an insect-trained .tflite can be published as a GitHub release
     asset (licence and collaborator approval), and if so link it here plus in
     docs/QUICK_START.md, so "Download…" becomes a copy-paste step. -->

## Why I built FaunaPulse

The idea for FaunaPulse grew from my research at the Helmholtz Centre for Environmental Research [(UFZ)][ufz] and the German Centre for Integrative Biodiversity Research [(iDiv)][idiv].

During my [PhD][phd-stef] research, my field-team and I used affordable smartphones in time-lapse mode to record flower-visiting insects. 
While this was ok, it quickly highlighted some core challenges that motivated the creation of FaunaPulse:

- **Eliminating data overload at the source**: Pollinator visits are brief and infrequent, meaning time-lapse capture generated millions of empty images that overloaded storage and processing time. Post-processing tools like [MegaDetector][mgdet] filter out empty trail camera photos of popular wildlife after collection, and FaunaPulse places that kind of AI processing directly on the phone. So, running detection on-device ensures one captures and stores images when fauna are actually present.
- **Overcoming traditional sensor limitations**: Standard motion sensors trigger continuously on wind, moving vegetation, or changing sunlight. Heat-based sensors ([Passive infrared sensors][PIR]) are impractical on small insects whose body temperature matches their surroundings. So, on-device computer vision seems like the only reliable way to trigger recordings for flower visiting insects.
- **Focusing AI on ecological context (Region of Interest - ROI)**: As first suggested in [Ștefan et al. 2025][stefan-2025-a], focusing the camera on a target area (for example, a single flower), it reduces background clutter and matches the square input format standard in object-detection models.
- **Democratizing wildlife monitoring through accessible and affordable hardware**: Commercial camera traps, microcomputers or other gadgets are not available on all markets at all time, some are expensive and some can also be complex to work with. Modern smartphones are powerful, globally accessible microcomputers and almost everyone understands nowadays how to use one. By releasing FaunaPulse as free and open-source software, I want to enable citizen scientists, students, and under-funded research groups to turn everyday phones into tailored camera traps for documenting local biodiversity.

## AI-assisted development and transparency

FaunaPulse also began as a personal experiment in what is called **“vibe coding”**. Developing a custom smartphone field tool initially seemed likely to require substantial funding and professional app developers. As AI-assisted software-development tools became more capable, I decided to explore whether they could help me build the application myself.

I am a scientist with experience in R, Python, statistics and computer vision, but I am not a professional mobile-app developer. Most software development was assisted by [Claude Code](https://claude.com/product/claude-code), a paid tool that was instrumental in making this project possible. I recognize that access to paid AI tools is not equally available.

I defined the scientific requirements and design decisions, tested the application repeatedly on smartphones, inspected its outputs, created and updated documentation and overall architected the resulting software. Occasionally, ChatGPT or Gemini are used as additional sources of "critique".

Scientific literature was located using [Google Scholar](https://scholar.google.com), [Elicit](https://elicit.com/) and [Consensus](https://consensus.app/).

For transparency, the development process is documented in [`AGENT_CHANGELOG_OVERVIEW.md`](docs/AGENT_CHANGELOG_OVERVIEW.md) and the detailed [`AGENT_CHANGELOG.md`](docs/AGENT_CHANGELOG.md). Also, the Git history provides the corresponding code-level record.

## Related research

FaunaPulse builds on research conducted with colleagues at [UFZ][ufz] and [iDiv][idiv] on smartphone-based pollinator monitoring, object detection and insect classification:

- Stark, T., Ștefan, V., Wurm, M., Spanier, R., Taubenböck, H., & Knight, T. M. (2023). **YOLO object detection models can locate and classify broad groups of flower-visiting arthropods in images.** *Scientific Reports*, 13, 16364. [https://doi.org/10.1038/s41598-023-43482-3][stark-2023]
- Ștefan, V., Workman, A., Cobain, J. C., Rakosy, D., & Knight, T. M. (2025). **Utilising affordable smartphones and open-source time-lapse photography for pollinator image collection and annotation.** *Journal of Pollination Ecology*, 38, 1–21. [https://doi.org/10.26786/1920-7603(2025)778][stefan-2025-a]
- Ștefan, V., Stark, T., Wurm, M., Taubenböck, H., & Knight, T. M. (2025). **Successes and limitations of pretrained YOLO detectors applied to unseen time-lapse images for automated pollinator monitoring.** *Scientific Reports*, 15, 30671. [https://doi.org/10.1038/s41598-025-16140-z][stefan-2025-b]
- Stark, T., Wurm, M., Ștefan, V., Wolf, F., Taubenböck, H., & Knight, T. M. (2025). **Utilizing CNNs for classification and uncertainty quantification for 15 families of European fly pollinators.** *PLOS ONE*, 20(9), e0323984. [https://doi.org/10.1371/journal.pone.0323984][stark-2025]

[stark-2023]: https://doi.org/10.1038/s41598-023-43482-3
[stefan-2025-a]: https://doi.org/10.26786/1920-7603(2025)778
[stefan-2025-b]: https://doi.org/10.1038/s41598-025-16140-z
[stark-2025]: https://doi.org/10.1371/journal.pone.0323984

Future work may include (on-device or computer / server) taxonomic identification using classification models, including vision foundation models such as [BioCLIP][bioclip], and further analytical reporting derived from visitation and classification data.

## Citation

If you use FaunaPulse in your research, please cite it using the metadata in [`CITATION.cff`](CITATION.cff). GitHub renders a ready-made "Cite this repository" button from that file (top-right of the repository page).

<!-- Once the first release is archived on Zenodo, add the DOI badge here and the
     versioned DOI to CITATION.cff. -->

## Privacy

FaunaPulse collects and transmits nothing: no account, no analytics, no tracking. Detection runs on the phone and everything recorded stays in the app's folder on the device. See [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md) for the permission-by-permission detail, and [`CHANGELOG.md`](CHANGELOG.md) for what changed between releases.

## License

This repository is licensed under **AGPL-3.0**. See [`LICENSE`](LICENSE) for details.

The modified `ultralytics_yolo` plugin retained in this repository remains subject to its own license terms.

## Notes on repository layout

<details>
<summary>Show repository structure</summary>

```text
fauna-pulse/
├── android/                 # Android platform code
├── assets/models            # Application assets and optional local models
├── docs/                    # Installation, field-use and developer documentation
├── lib/                     # FaunaPulse application code (Dart)
├── ...
└── packages/
    └── ultralytics_yolo/    # Modified Ultralytics YOLO Flutter plugin
```

The application now sits at the repository root. The older path `/yolo-flutter-app/example/` may still appear in the historical development logs.

The application uses the local modified plugin through `pubspec.yaml`:

```yaml
dependencies:
  ultralytics_yolo:
    path: packages/ultralytics_yolo
```

</details>

<!-- 
Reference links: [id]: URL
These are links used throughout this file
-->

[ufz]: https://www.ufz.de/
[idiv]: https://www.idiv.de/
[bioclip]: https://imageomics.github.io/bioclip-ecosystem/index.html
[sahi]: https://github.com/obss/sahi
[mgdet]: https://github.com/microsoft/MegaDetector
[mgdetv6]: https://github.com/microsoft/MegaDetector/releases/tag/megadetector-v6.0
[phd-stef]: https://repo.bibliothek.uni-halle.de/handle/1981185920/125596
[PIR]: https://en.wikipedia.org/wiki/Passive_infrared_sensor