#!/bin/sh
# Prints the input hash of the coding sandbox image at revision REV (default HEAD): the sha256 of the git tree
# entries of everything its build reads. The Coding sandbox image workflow publishes the image of main under it
# (coding-sandbox/inputs/<hash>.json), and a Comma release gives Salix the manifest of its own revision's hash,
# so a release runs the sandbox image built from the same sources, however many commits since changed none of them.
# Only trees are read: a clone without blobs (--filter=blob:none) is enough.
#
# Keep this list and the workflow's `paths` (.github/workflows/coding-sandbox-image.yml) the same.
set -eu
rev=${1:-HEAD}
# Read first, so that a revision git does not have fails here instead of hashing nothing.
entries=$(git ls-tree -r --full-tree "$rev" -- \
  systems/runtime-images/coding-sandbox \
  systems/runtime-images/station \
  systems/runtime-images/runtime-dependencies.lock.json \
  systems/station \
  .github/actions/station-zig \
  .github/workflows/coding-sandbox-image.yml)
[ -n "$entries" ] || { echo "inputs.sh: no image inputs at $rev" >&2; exit 1; }
printf '%s\n' "$entries" | sha256sum | cut -c1-64
