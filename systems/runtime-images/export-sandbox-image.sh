#!/usr/bin/env bash
# Export an existing sandbox image in the L4ES system-image format.
# Run from the repository root: export-sandbox-image.sh OUT_DIR IMAGE
set -euo pipefail
out=${1:?usage: export-sandbox-image.sh OUT_DIR IMAGE}
image=${2:?usage: export-sandbox-image.sh OUT_DIR IMAGE}
engine=${CONTAINER_ENGINE:-docker}
lock=systems/runtime-images/runtime-dependencies.lock.json
lock_value() { node -e 'let v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); for (const k of process.argv[2].split(".")) v = v[k]; if (typeof v !== "string") process.exit(1); console.log(v)' "$lock" "$1"; }
snapshot=$(lock_value packageSnapshot)
context=$(mktemp -d)
container=
trap 'rm -rf -- "$context"; if [ -n "$container" ]; then "$engine" rm -f "$container" >/dev/null; fi' EXIT
mkdir -p "$context/systems/runtime-images/station"
cp systems/runtime-images/station/apt-package-recovery.mjs "$context/systems/runtime-images/station/"

mkdir -p "$out"
out=$(cd "$out" && pwd)
container=$("$engine" create --platform linux/amd64 "$image")
# Use the locked trixie image tools. erofs-utils 1.8 matches guest support.
# Ubuntu 24.04's 1.7.1 can emit unsupported big-pcluster indexes for this image.
# The tool image includes Node for the existing package recovery script.
printf '%s\n' "FROM $(lock_value baseImages.codingSandbox)" \
  "RUN --mount=type=bind,source=systems/runtime-images/station/apt-package-recovery.mjs,target=/tmp/apt-package-recovery.mjs printf 'Types: deb\\nURIs: http://snapshot.debian.org/archive/debian/$snapshot\\nSuites: trixie\\nComponents: main\\nCheck-Valid-Until: no\\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\\n' > /etc/apt/sources.list.d/debian.sources && apt-get update && node /tmp/apt-package-recovery.mjs $snapshot install -y --no-install-recommends erofs-utils cryptsetup-bin && rm -rf /var/lib/apt/lists/*" |
  "$engine" build --platform linux/amd64 -t comma-image-tools:amd64 -f - "$context"
# Preserve the L4ES format: EROFS followed by its dm-verity tree.
# Use format 1, SHA-256, 4 KiB blocks, and no tree superblock.
# Salt the tree with the EROFS SHA-256. Verify the completed tree.
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
