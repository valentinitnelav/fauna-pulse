<!--
Versions follow the `MAJOR.MINOR.PATCH` scheme of the `version:` field in
`pubspec.yaml`, and each release is tagged `v<version>` on GitHub. While the app is
an early research preview, versions carry a SemVer pre-release suffix (e.g.
`0.7.0-alpha.1`) and the GitHub release is marked as a pre-release.
-->

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
- The vendored Ultralytics plugin keeps its own [`packages/ultralytics_yolo/CHANGELOG.md`](packages/ultralytics_yolo/CHANGELOG.md).
