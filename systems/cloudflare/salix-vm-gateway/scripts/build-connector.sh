#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/cloudflare/salix-vm-gateway/.build"
mkdir -p "$OUT"
cp "$ROOT/runtime-images/runtime-dependencies.lock.json" "$OUT/runtime-dependencies.lock.json"
cp "$ROOT/cloudflare/salix-vm-gateway/scripts/install-harnesses.mjs" "$OUT/install-harnesses.mjs"
cp "$ROOT/runtime-images/station/silk2wav" "$OUT/silk2wav"
cp "$ROOT/runtime-images/station/file-tools-packages" "$ROOT/runtime-images/station/file-tools-requirements.txt" "$OUT/"
node -e '
const fs = require("fs");
const [lockPath, source, output] = process.argv.slice(1);
const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
fs.writeFileSync(output, fs.readFileSync(source, "utf8")
  .replace("ARG NODE_IMAGE\n", `ARG NODE_IMAGE=${lock.baseImages.station}\n`)
  .replace("ARG UV_IMAGE\n", `ARG UV_IMAGE=${lock.uv.image}\n`)
  .replace("ARG SILK_V3_DECODER_TARBALL\n", `ARG SILK_V3_DECODER_TARBALL=${lock.silkV3Decoder.tarball}\n`)
  .replace("ARG SILK_V3_DECODER_INTEGRITY\n", `ARG SILK_V3_DECODER_INTEGRITY=${lock.silkV3Decoder.integrity}\n`));
' "$OUT/runtime-dependencies.lock.json" "$ROOT/cloudflare/salix-vm-gateway/Dockerfile" "$OUT/Dockerfile"

# The Comma station, for linux-x64, laid out as its release (systems/station/scripts/bundle.sh).
rm -rf "$OUT/station"
sh "$ROOT/station/scripts/bundle.sh" "$OUT/station" linux-x64
