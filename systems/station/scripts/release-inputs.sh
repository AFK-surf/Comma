#!/bin/sh
# Prints the input hash of the station's standalone release at revision REV (default HEAD): the sha256 of the git tree
# entries of what its build reads. station-release.yml publishes main's release under it (inputs/<hash>.json), and a
# Comma release pins the manifest of its own revision's hash. Only trees are read.
#
# Keep each of these in station.yml's push `paths`: the release runs after that workflow.
set -eu
rev=${1:-HEAD}
entries=$(git ls-tree -r --full-tree "$rev" -- \
  systems/station \
  clients/packages/mesh \
  .github/actions/station-zig \
  .github/workflows/station-release.yml)
[ -n "$entries" ] || { echo "release-inputs.sh: no inputs at $rev" >&2; exit 1; }
printf '%s\n' "$entries" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-64
