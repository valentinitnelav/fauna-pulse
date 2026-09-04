#!/usr/bin/env bash
# Build the per-ABI release APKs for a GitHub release (round 193).
#
# WHAT THIS IS: the universal release APK bundles all 4 CPU architectures
# (~116 MB, round-160 measurement). `--split-per-abi` builds one APK per
# architecture instead, so the file a phone actually downloads is far
# smaller. This script builds them and copies the two that matter to
# dist/ under STABLE names (faunapulse-v<version>-<abi>.apk). Obtainium
# users filter on that name pattern, so keep it identical across releases.
#
# PREREQUISITES: the release keystore must exist (see
# scripts/create_release_keystore.sh); the build fails by design without it.
#
# Usage, from the repo root:
#   bash scripts/build_release_apks.sh

set -euo pipefail
cd "$(dirname "$0")/.."

version="$(grep '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f1)"
if [ -z "$version" ]; then
  echo "ERROR: could not read version: from pubspec.yaml" >&2
  exit 1
fi

echo "Building per-ABI release APKs for v${version}..."
# By default Flutter stamps each split APK with versionCode = ABI index * 1000 +
# the pubspec build number (arm64-v8a -> 2011, armeabi-v7a -> 1011 for build 11).
# A phone that installed such a GitHub APK would then refuse the Google Play
# build of the same release (same app, LOWER versionCode). The flag below keeps
# the pubspec build number unchanged, so GitHub APKs and the Play AAB share one
# versionCode and can update each other (RELEASE_PLAN.md, signing strategy).
flutter build apk --release --split-per-abi -P force-version-code-ignoring-abi=true

out="build/app/outputs/flutter-apk"
mkdir -p dist

# arm64-v8a covers virtually all modern phones; armeabi-v7a covers the old
# 32-bit ones. x86_64 exists in the build output but is emulator-only, so it
# is deliberately not shipped as a release asset.
for abi in arm64-v8a armeabi-v7a; do
  src="${out}/app-${abi}-release.apk"
  dst="dist/faunapulse-v${version}-${abi}.apk"
  if [ ! -f "$src" ]; then
    echo "ERROR: expected build output missing: $src" >&2
    exit 1
  fi
  cp "$src" "$dst"
  echo "  $(du -h "$dst" | cut -f1)  $dst"
done

echo
echo "Done. Upload the files in dist/ as GitHub release assets for tag v${version}."
