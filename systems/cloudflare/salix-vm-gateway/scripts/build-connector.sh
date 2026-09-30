#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/cloudflare/salix-vm-gateway/.build"
mkdir -p "$OUT"

cd "$ROOT/connector/salix-connect"
build_revision="${SALIX_CONNECTOR_BUILD_REVISION:-dev}"
case "$build_revision" in
  *[!a-zA-Z0-9._-]*|'') echo "invalid Connector build revision" >&2; exit 1 ;;
esac
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -ldflags="-s -w -X main.connectorBuildRevision=$build_revision" \
  -o "$OUT/salix-runtime-agent" .
