<!--
Versions follow the `MAJOR.MINOR.PATCH` scheme of the `version:` field in
`pubspec.yaml`, and each release is tagged `v<version>` on GitHub.
-->

## 0.7.0-alpha.1

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
- The Ultralytics plugin has its own CHANGELOG.md at `./fauna-pulse/packages/ultralytics_yolo/CHANGELOG.md`
