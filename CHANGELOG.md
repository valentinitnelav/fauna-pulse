<!--
Versions follow the `MAJOR.MINOR.PATCH` scheme of the `version:` field in
`pubspec.yaml`, and each release is tagged `v<version>` on GitHub. While the app is
an early research preview, versions carry a SemVer pre-release suffix (e.g.
`0.7.0-alpha.1`) and the GitHub release is marked as a pre-release.
-->

## 0.9.0-alpha.1 (not released yet)

- **No AI model inside the app any more.** The home screen asks what you want to watch
  (pollinators on flowers, insects on a flat surface, mammals and birds), suggests
  published models for it and downloads them once: the flat-bug and insectDCT insect
  detectors, MegaDetector V6, the insectDCT insect classifier, and BioCLIP 2 or 2.5 with
  their name lists. **Download & import models** lists every model and name list on the
  phone with its licence and source; your own `.tflite` models can still be imported. The
  camera starts without a model and asks for one only for live detection.
- **AI later:** *Find animals in photos* and *Find animals in videos* find animals, track
  IDs and names after recording, also in videos imported from the phone's gallery. The
  video player shows the AI's boxes and a time bar of the track IDs.
- Recording: time-lapse bursts can be saved as short video clips of the yellow square;
  live AI can also save video; the camera sleeps between bursts; a recording continues
  with the screen off, and the screen can switch off by itself after some minutes; a clean
  stop at low battery or low storage.
- Field notes (with your own fields, site photos and a GPS accuracy goal) are saved with
  every session; a *Before you record* sheet checks the phone for the field.
- Identification: the insectDCT fixed-class insect classifier as a second option;
  BioCLIP 2 runs on the phone's graphics processor where the phone allows it (checked once
  per phone); one score per track ID from all its photos.
- New Sessions screen (search, filters, select several) and Dashboard (track IDs per hour
  watched, by time of day, by day and by name). "Visit" is now "track ID" everywhere, and
  a track length runs from the first sighting to the last.
- Photo sessions of the sister app FaunaLapse can be imported for *AI later*.
- Menu, *Cite FaunaPulse*: the citation of the installed version.
- Smaller app: the normal build leaves out the Snapdragon NPU runtime; detection on the
  main processor uses two threads by default (about twice as fast as one).

## 0.8.0-alpha.1 (2026-09-23)

- **Identify organisms (experimental):** after a session, the saved photos of every
  tracked visit can be identified on the phone with the BioCLIP 2 vision model, against
  a label pack (the list of candidate taxa), with a confidence per taxonomic rank. The
  model and the label pack are prepared on a computer, see
  [`docs/IDENTIFICATION.md`](docs/IDENTIFICATION.md).
- Session summary, Photos tab: choose how many photos to show (10 / 50 / 100 / All) and
  draw a new random sample; identified taxa appear under the photos.
- The citation title now reads "FaunaPulse: a smartphone application for on-device
  detection, tracking and identification of animals" (`CITATION.cff`, and Zenodo from
  this release on). Earlier Zenodo versions keep their original title.

## 0.7.0-alpha.1 (2026-09-04)

The first public, citable release: an early research preview, tagged so it can be
archived on Zenodo with a DOI and installed from GitHub Releases.

- The app ships with a general-purpose detection model, so it works straight
  after installation and needs no download in the field. Insect detection still
  requires a purpose-trained model (see the README).
- Added a privacy policy: nothing is collected or transmitted, everything stays on
  the phone.
- Release builds are now signed with a proper release key and refuse to build if
  the signing key or the bundled model is missing, so a broken build can never be
  published by accident.
- Documentation: fixed the Field Guide title, added a physical field-setup section
  (mounting, distance, power), and made the README state clearly what the bundled
  model can and cannot do.
- For transparency, the extra-detailed AI-assisted development journal lives in [`docs/AGENT_CHANGELOG.md`](docs/AGENT_CHANGELOG.md)
  with an overview at [`docs/AGENT_CHANGELOG_OVERVIEW.md`](docs/AGENT_CHANGELOG_OVERVIEW.md).
- The Ultralytics plugin (`packages/ultralytics_yolo`, modified for FaunaPulse) keeps its own [`packages/ultralytics_yolo/CHANGELOG.md`](packages/ultralytics_yolo/CHANGELOG.md).
