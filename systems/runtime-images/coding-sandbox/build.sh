#!/usr/bin/env bash
# Builds the coding sandbox system image as L4ES takes it, for x86_64 (L4ES nodes): the station runtime image
# (runtime-images/station) with the linux-x64 station release STATION_DIR (systems/station/scripts/bundle.sh, its
# native parts for glibc 2.28) and the locked Claude Code and Codex, the coding sandbox layer on it, and its file system
# as a verified EROFS image (its dm-verity hash tree after it), zstd-compressed: OUT_DIR/<sha256> and OUT_DIR/image.json
# ({rootfs_sha256, verity, revision}). L4ES serves it as a workspace's custom image (SalixWeb.L4ES.ensure_image/1) and
# boots it with its node release's initramfs, which brings the platform layer (l4h-sandbox DESIGN.md §7.3).
#
#   build.sh OUT_DIR STATION_DIR        from the repository root; needs zstd, node and the container engine
set -euo pipefail
out=${1:?usage: build.sh OUT_DIR STATION_DIR}
station=${2:?usage: build.sh OUT_DIR STATION_DIR}
engine=${CONTAINER_ENGINE:-docker}
lock=systems/runtime-images/runtime-dependencies.lock.json
lock_value() { node -e 'let v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); for (const k of process.argv[2].split(".")) v = v[k]; if (typeof v !== "string") process.exit(1); console.log(v)' "$lock" "$1"; }
test "$(lock_value claudeAmd64.version)" = "$(lock_value claude.version)"

# The station image's context, as scripts/build-runtime-images.sh lays it out, with the coding sandbox's files.
context=$(mktemp -d)
trap 'rm -rf -- "$context"' EXIT
mkdir -p "$context/systems/runtime-images/station" "$context/systems/runtime-images/coding-sandbox"
cp systems/runtime-images/station/{apt-package-recovery.mjs,entrypoint.sh,initialize-access.mjs,silk2wav,file-tools-packages,file-tools-requirements.txt} "$context/systems/runtime-images/station/"
cp systems/runtime-images/coding-sandbox/{comma-display.service,comma-station.service,comma-station-start,tmp.mount,docker-daemon.json,native-build-packages,browser-mcp.json} "$context/systems/runtime-images/coding-sandbox/"

args=()
for pair in \
  STATION_IMAGE=baseImages.codingSandbox PACKAGE_SNAPSHOT=packageSnapshot \
  NPM_VERSION=npm.version NPM_TARBALL=npm.tarball NPM_INTEGRITY=npm.integrity \
  NPM_BRACE_EXPANSION_VERSION=npmSecurityPatches.braceExpansion.version \
  NPM_BRACE_EXPANSION_TARBALL=npmSecurityPatches.braceExpansion.tarball \
  NPM_BRACE_EXPANSION_INTEGRITY=npmSecurityPatches.braceExpansion.integrity \
  NPM_UNDICI_VERSION=npmSecurityPatches.undici.version NPM_UNDICI_TARBALL=npmSecurityPatches.undici.tarball \
  NPM_UNDICI_INTEGRITY=npmSecurityPatches.undici.integrity \
  NPM_IP_ADDRESS_VERSION=npmSecurityPatches.ipAddress.version NPM_IP_ADDRESS_TARBALL=npmSecurityPatches.ipAddress.tarball \
  NPM_IP_ADDRESS_INTEGRITY=npmSecurityPatches.ipAddress.integrity \
  NPM_TAR_VERSION=npmSecurityPatches.tar.version NPM_TAR_TARBALL=npmSecurityPatches.tar.tarball \
  NPM_TAR_INTEGRITY=npmSecurityPatches.tar.integrity \
  CODEX_TARBALL=codex.tarball CODEX_INTEGRITY=codex.integrity \
  CLAUDE_VERSION=claude.version CLAUDE_TARBALL=claude.tarball CLAUDE_INTEGRITY=claude.integrity \
  CLAUDE_PLATFORM_TARBALL=claudeAmd64.tarball CLAUDE_PLATFORM_INTEGRITY=claudeAmd64.integrity \
  SILK_V3_DECODER_TARBALL=silkV3Decoder.tarball SILK_V3_DECODER_INTEGRITY=silkV3Decoder.integrity; do
  args+=(--build-arg "${pair%%=*}=$(lock_value "${pair#*=}")")
done

"$engine" build --platform linux/amd64 -f systems/runtime-images/station/Dockerfile --target comma-station \
  --build-context "station=$station" --build-arg DEBIAN_SUITE=trixie "${args[@]}" -t comma-station-runtime:amd64 "$context"
"$engine" build --platform linux/amd64 -f systems/runtime-images/coding-sandbox/Dockerfile \
  --build-arg STATION_RUNTIME_IMAGE=comma-station-runtime:amd64 \
  --build-arg "PACKAGE_SNAPSHOT=$(lock_value packageSnapshot)" \
  --build-arg "ELAN_TARBALL=$(lock_value elanAmd64.tarball)" --build-arg "ELAN_INTEGRITY=$(lock_value elanAmd64.integrity)" \
  --build-arg "PLAYWRIGHT_MCP_TARBALL=$(lock_value playwrightMcp.tarball)" \
  --build-arg "PLAYWRIGHT_MCP_INTEGRITY=$(lock_value playwrightMcp.integrity)" -t comma-coding-sandbox:amd64 "$context"

systems/runtime-images/export-sandbox-image.sh "$out" comma-coding-sandbox:amd64
