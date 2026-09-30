#!/usr/bin/env bash
# Installs the pinned prebuilt spinfoam runtime
# (https://github.com/AFK-surf/spinfoam/releases) into OUT. spinfoam is the
# child process that runs Agent background Loops
# (docs/salix/task-dynamic-workflow.md, "Background loops").
#
#   fetch.sh OUT=/path/to/spinfoam              download the pinned release
#   SPINFOAM_BIN=/path/spinfoam fetch.sh OUT=   copy a local binary instead
#
# The release tag is pinned in SPINFOAM_VERSION and every tarball's digest in
# SHA256SUMS (copied from the release), both next to this script. Nothing is
# compiled here: the release binary embeds its C compiler, so neither the
# build host nor the runtime needs cargo, LLVM or any toolchain.
#
# Exit 3 means this platform has no release package; callers treat that as
# "background loops unavailable on this node". Any other failure is an error.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
version="$(tr -d '\r\n' < "$here/SPINFOAM_VERSION")"
out=""
for arg in "$@"; do
  case "$arg" in
    OUT=*) out="${arg#OUT=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [ -z "$out" ]; then
  echo 'usage: fetch.sh OUT=/path/to/spinfoam' >&2
  exit 2
fi
mkdir -p "$(dirname "$out")"

if [ -n "${SPINFOAM_BIN:-}" ]; then
  install -m 0755 "$SPINFOAM_BIN" "$out"
  exit 0
fi

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) target=x86_64-unknown-linux-gnu ;;
  Linux/aarch64 | Linux/arm64) target=aarch64-unknown-linux-gnu ;;
  Darwin/x86_64) target=x86_64-apple-darwin ;;
  Darwin/arm64) target=aarch64-apple-darwin ;;
  *)
    echo "spinfoam: no release package for $(uname -s)/$(uname -m); background loops stay unavailable on this node" >&2
    exit 3
    ;;
esac

package="spinfoam-$target.tar.gz"
url="https://github.com/AFK-surf/spinfoam/releases/download/$version/$package"
expected="$(awk -v p="$package" '$2 == p { print $1 }' "$here/SHA256SUMS")"
if [ -z "$expected" ]; then
  echo "spinfoam: $package is not listed in SHA256SUMS" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/$package" "$url"
actual="$(sha256sum "$tmp/$package" 2>/dev/null || shasum -a 256 "$tmp/$package")"
actual="${actual%% *}"
if [ "$actual" != "$expected" ]; then
  echo "spinfoam: $package digest $actual does not match pinned $expected" >&2
  exit 1
fi
tar -xzf "$tmp/$package" -C "$tmp" "spinfoam-$target/spinfoam"
install -m 0755 "$tmp/spinfoam-$target/spinfoam" "$out"
"$out" --version >&2
