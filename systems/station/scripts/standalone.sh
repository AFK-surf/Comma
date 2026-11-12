#!/bin/sh
# The station's standalone release for PLATFORM, as /stations/install.sh takes it: OUT/comma-station-PLATFORM.tar.gz
# holding the layout of bundle.sh in comma-station/, with its Node, and BUILD (the version it says, 0.1.BUILD).
#   standalone.sh OUT PLATFORM BUILD
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: standalone.sh OUT PLATFORM BUILD}
platform=${2:?usage: standalone.sh OUT PLATFORM BUILD}
build=${3:?usage: standalone.sh OUT PLATFORM BUILD}
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sh "$here/bundle.sh" "$work/comma-station" "$platform"
printf '%s\n' "$build" > "$work/comma-station/BUILD"
tar -czf "$out/comma-station-$platform.tar.gz" -C "$work" comma-station
