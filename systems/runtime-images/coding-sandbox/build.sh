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
cp systems/runtime-images/station/{entrypoint.sh,silk2wav,file-tools-packages,file-tools-requirements.txt} "$context/systems/runtime-images/station/"
cp systems/runtime-images/coding-sandbox/{comma-station.service,comma-station-start,tmp.mount,docker-daemon.json} "$context/systems/runtime-images/coding-sandbox/"

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

"$engine" build --platform linux/amd64 -f systems/runtime-images/station/Dockerfile \
  --build-context "station=$station" --build-arg DEBIAN_SUITE=trixie "${args[@]}" -t comma-station-runtime:amd64 "$context"
"$engine" build --platform linux/amd64 -f systems/runtime-images/coding-sandbox/Dockerfile \
  --build-arg STATION_RUNTIME_IMAGE=comma-station-runtime:amd64 -t comma-coding-sandbox:amd64 "$context"

mkdir -p "$out"
out=$(cd "$out" && pwd)
container=$("$engine" create --platform linux/amd64 comma-coding-sandbox:amd64)
trap 'rm -rf -- "$context"; "$engine" rm -f "$container" >/dev/null' EXIT
# The image tools from Debian trixie at the locked snapshot: mkfs.erofs (erofs-utils 1.8: Ubuntu 24.04's 1.7.1 writes,
# for this image, big-pcluster indexes that its superblock does not announce, which the sandbox kernel refuses) and
# veritysetup.
snapshot=$(lock_value packageSnapshot)
printf '%s\n' "FROM $(lock_value baseImages.imageTools)" \
  "RUN printf 'Types: deb\\nURIs: http://snapshot.debian.org/archive/debian/$snapshot\\nSuites: trixie\\nComponents: main\\nCheck-Valid-Until: no\\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\\n' > /etc/apt/sources.list.d/debian.sources && apt-get update && apt-get install -y --no-install-recommends erofs-utils cryptsetup-bin && rm -rf /var/lib/apt/lists/*" |
  "$engine" build --platform linux/amd64 -t comma-image-tools:amd64 -
# L4ES boots a verified system image (l4h-sandbox image/verity.py, README "Custom system images"): the EROFS file
# system, then its dm-verity hash tree (format 1, SHA-256, 4 KiB blocks, no superblock), salted with the file system's
# SHA-256 so that a rebuild of the same files is the same image. The tree is checked against its root hash once made.
"$engine" export "$container" |
  "$engine" run --rm -i --platform linux/amd64 -v "$out:/out" comma-image-tools:amd64 sh -euc '
    cd /out
    mkfs.erofs --quiet --tar=f -zlz4hc -b4096 rootfs.erofs
    size=$(stat -c %s rootfs.erofs)
    [ $((size % 4096)) = 0 ] && [ "$size" -le $((8 * 1024 * 1024 * 1024)) ]
    salt=$(sha256sum rootfs.erofs | cut -d" " -f1)
    opts="--format=1 --hash=sha256 --data-block-size=4096 --hash-block-size=4096 --no-superblock --salt=$salt --data-blocks=$((size / 4096))"
    veritysetup format rootfs.erofs tree $opts --root-hash-file=root >/dev/null
    cat rootfs.erofs tree > rootfs.verity
    veritysetup verify rootfs.verity rootfs.verity "$(cat root)" $opts --hash-offset="$size"
    echo "$(cat root) $salt $((size / 4096))" > verity
    rm rootfs.erofs tree root'
read -r root salt blocks < "$out/verity"
rm "$out/verity"
# L4ES reserves a sandbox's raw region from the zstd frame's content size.
zstd -q -T0 -10 --content-size -f "$out/rootfs.verity" -o "$out/rootfs.verity.zst"
rm "$out/rootfs.verity"
sha=$(sha256sum "$out/rootfs.verity.zst" | cut -d' ' -f1)
mv "$out/rootfs.verity.zst" "$out/$sha"
printf '{"rootfs_sha256":"%s","verity":{"root_hash":"%s","salt":"%s","data_blocks":%s},"revision":"%s"}\n' \
  "$sha" "$root" "$salt" "$blocks" "$(git rev-parse HEAD)" | tee "$out/image.json"
