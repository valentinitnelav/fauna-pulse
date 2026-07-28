# Changelog

User-facing changes, newest first. This file is for people using FaunaPulse. 

Versions follow the `MAJOR.MINOR.PATCH` scheme of the `version:` field in
`pubspec.yaml`, and each release is tagged `v<version>` on GitHub.

## Unreleased (towards 0.7.0, the first public release)

- The app now ships with a general-purpose detection model, so it works straight
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

## 0.6.4 and earlier

Developed and tested privately. See
[`docs/AGENT_CHANGELOG.md`](docs/AGENT_CHANGELOG.md) for the full history.

## Notes

For transparency, the extra-detailed AI-assisted development journal lives in [`docs/AGENT_CHANGELOG.md`](docs/AGENT_CHANGELOG.md).