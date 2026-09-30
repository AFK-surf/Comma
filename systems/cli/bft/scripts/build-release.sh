#!/usr/bin/env sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
dist_input="${BFT_CLI_DIST_DIR:-$root/dist}"
case "$dist_input" in
  /*) dist="$dist_input" ;;
  *) dist="$(pwd)/$dist_input" ;;
esac
version="${BFT_CLI_VERSION:-dev}"

mkdir -p "$dist"

build_one() {
  os="$1"
  arch="$2"
  platform="$os-$arch"
  out_dir="$dist/$platform"
  out="$out_dir/bft"

  mkdir -p "$out_dir"
  printf 'building %s\n' "$platform" >&2
  (
    cd "$root"
    GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 \
      go build \
        -trimpath \
        -ldflags "-s -w -X github.com/AFK-surf/comma/systems/cli/bft/internal/commands.version=$version" \
        -o "$out" \
        ./cmd/bft
  )
  chmod 0755 "$out"
  (cd "$out_dir" && shasum -a 256 bft > bft.sha256)
}

build_one darwin arm64
build_one darwin amd64
build_one linux arm64
build_one linux amd64

cat > "$dist/metadata.json" <<EOF
{
  "name": "bft",
  "version": "$version",
  "targets": [
    {"os": "darwin", "arch": "arm64", "path": "darwin-arm64/bft"},
    {"os": "darwin", "arch": "amd64", "path": "darwin-amd64/bft"},
    {"os": "linux", "arch": "arm64", "path": "linux-arm64/bft"},
    {"os": "linux", "arch": "amd64", "path": "linux-amd64/bft"}
  ]
}
EOF

printf 'wrote %s\n' "$dist" >&2
