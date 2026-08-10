#!/usr/bin/env bash
set -euo pipefail

# Final local release gate. Unlike CI's debug bundle, this deliberately uses
# the real git-ignored android/key.properties or ANDROID_* signing variables.
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

flutter pub get
flutter analyze
flutter test test/fauna_pulse

(
  cd packages/ultralytics_yolo
  flutter pub get
  flutter test
)

(
  cd android
  ./gradlew :ultralytics_yolo:testDebugUnitTest :app:lintRelease
)

flutter build appbundle --release

echo "Security release gate passed: build/app/outputs/bundle/release/app-release.aab"
