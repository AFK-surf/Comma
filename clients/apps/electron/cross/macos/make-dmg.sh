#!/usr/bin/env bash
# Make a DMG with APP and a link to /Applications, then sign it with sign.sh.
# Usage: make-dmg.sh APP DMG VOLUME
set -euo pipefail

app=${1:?usage: make-dmg.sh APP DMG VOLUME}
dmg=${2:?usage: make-dmg.sh APP DMG VOLUME}
volume=${3:?usage: make-dmg.sh APP DMG VOLUME}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stage"
cp -a "$app" "$work/stage/"
ln -s /Applications "$work/stage/Applications"
size_kb=$(du -sk "$work/stage" | cut -f1)
truncate -s "$((size_kb + size_kb / 5 + 32768))K" "$work/image.hfs"
mkfs.hfsplus -v "$volume" "$work/image.hfs" >/dev/null
hfsplus --symlinks clone_link --special-modes no "$work/image.hfs" addall "$work/stage" >/dev/null
mkdir -p "$(dirname "$dmg")"
rm -f "$dmg"
dmg build "$work/image.hfs" "$dmg" >/dev/null
"$(dirname "$0")/sign.sh" "$dmg"
