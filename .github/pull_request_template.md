<!--
Normal pull requests target develop. Use main only for a maintainer-approved
release or urgent security hotfix.
-->

## Summary

Describe what changed and why.

## Verification

List the commands and device checks you ran. Mark items that do not apply and
explain why.

- [ ] `flutter analyze`
- [ ] `flutter test test/fauna_pulse`
- [ ] Vendored plugin tests, if the plugin changed
- [ ] Android lint/native tests, if Android or Kotlin changed
- [ ] On-device check, if camera, storage, permissions or native runtimes changed

## Review notes

Call out migrations, compatibility risks, scientific-output changes, or areas
where reviewer attention is especially useful.

## Checklist

- [ ] This pull request targets `develop` (unless the maintainer approved a
      direct `main` hotfix).
- [ ] The change is focused and does not include unrelated formatting.
- [ ] Tests and documentation were updated where behaviour changed.
- [ ] No private session data, signing credentials or model weights are included.
