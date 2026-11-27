#!/usr/bin/env bash
# Build the Android layer on an existing amd64 coding image. Export it for L4ES.
# Run from the repository root: build.sh OUT_DIR [CODING_SANDBOX_IMAGE]
set -euo pipefail
out=${1:?usage: build.sh OUT_DIR [CODING_SANDBOX_IMAGE]}
base=${2:-comma-coding-sandbox:amd64}
engine=${CONTAINER_ENGINE:-docker}
snapshot=$(node -p 'JSON.parse(require("fs").readFileSync("systems/runtime-images/runtime-dependencies.lock.json", "utf8")).packageSnapshot')
context=$(mktemp -d)
trap 'rm -rf -- "$context"' EXIT
mkdir -p "$context/systems/runtime-images/station"
cp systems/runtime-images/station/apt-package-recovery.mjs "$context/systems/runtime-images/station/"
cp -R systems/runtime-images/android-sandbox "$context/systems/runtime-images/"
"$engine" build --platform linux/amd64 -f systems/runtime-images/android-sandbox/Dockerfile \
    --build-arg "CODING_SANDBOX_IMAGE=$base" --build-arg "PACKAGE_SNAPSHOT=$snapshot" \
    -t comma-android-sandbox:amd64 "$context"
systems/runtime-images/export-sandbox-image.sh "$out" comma-android-sandbox:amd64
