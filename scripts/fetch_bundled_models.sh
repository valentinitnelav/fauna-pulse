#!/usr/bin/env bash
# Example for a possible future downloadable bundled-model workflow. This script
# is NOT called by the Android build (round 194); running it is always manual.
# It still demonstrates downloading the historical YOLO26 test weight into
# assets/models/.
#
# Model binaries are git-ignored (large files, and some collaborator detectors may
# not be redistributable), so a clean clone has none.
#
# Only the historical example model is fetched. Do NOT add the other yolo26n task
# variants (seg/cls/pose/obb/sem): they were deliberately removed because they
# never load in this app and cost about 13.6 MB of APK size.
#
# Best-effort by design: any failure (offline machine, GitHub down) prints a
# warning and exits 0.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/assets/models"

# Keep in sync with the plugin's resolver
# (packages/ultralytics_yolo/lib/core/yolo_model_resolver.dart) and with
# ModelCatalog.bundledIds in lib/fauna_pulse/models/model_catalog.dart.
BASE="https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.3.5"
MODEL="yolo26n_int8.tflite"

mkdir -p "$DEST"
OUT="$DEST/$MODEL"

if [ -s "$OUT" ]; then
  echo "fetch_bundled_models: have $MODEL"
  exit 0
fi

TMP="$OUT.download"
rm -f "$TMP"
echo "fetch_bundled_models: downloading $MODEL"
if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$TMP" "$BASE/$MODEL" && [ -s "$TMP" ]; then
  mv -f "$TMP" "$OUT"
  echo "fetch_bundled_models: saved $OUT"
else
  rm -f "$TMP"
  echo "fetch_bundled_models: WARNING could not download $MODEL." >&2
  echo "fetch_bundled_models: no file was installed." >&2
fi

exit 0
