#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/cloudflare/salix-vm-gateway/.build"
mkdir -p "$OUT"
cp "$ROOT/runtime-images/runtime-dependencies.lock.json" "$OUT/runtime-dependencies.lock.json"
cp "$ROOT/cloudflare/salix-vm-gateway/scripts/install-harnesses.mjs" "$OUT/install-harnesses.mjs"
node -e '
const fs = require("fs");
const [lockPath, source, output] = process.argv.slice(1);
const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
fs.writeFileSync(output, fs.readFileSync(source, "utf8")
  .replace("ARG NODE_IMAGE\n", `ARG NODE_IMAGE=${lock.baseImages.external}\n`)
  .replace("ARG UV_IMAGE\n", `ARG UV_IMAGE=${lock.uv.image}\n`));
' "$OUT/runtime-dependencies.lock.json" "$ROOT/cloudflare/salix-vm-gateway/Dockerfile" "$OUT/Dockerfile"

cd "$ROOT/connector/salix-connect"
build_revision="${SALIX_CONNECTOR_BUILD_REVISION:-dev}"
case "$build_revision" in
  *[!a-zA-Z0-9._-]*|'') echo "invalid Connector build revision" >&2; exit 1 ;;
esac
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -ldflags="-s -w -X main.connectorBuildRevision=$build_revision" \
  -o "$OUT/salix-runtime-agent" .
