#!/bin/sh
# The Node a station release carries (DIR/node/bin/node, bundle.sh): the official build of .node-version for PLATFORM,
# checked against the SHA-256 pinned below and kept in the native cache (scripts/native.ts), so a rebuild is offline.
# The desktop app cannot lend its Electron: its RunAsNode fuse is off. On win32-x64 it is nodejs.org's node.exe as it
# is (win-x64/node.exe): the one file the station needs of the zip.
# COMMA_STATION_NODE names a Node to take instead, when it is that version for that platform (CI's own).
#   node.sh [darwin-arm64|linux-x64|linux-arm64|win32-x64]   prints the binary's path
set -eu
station=$(cd "$(dirname "$0")/.." && pwd)
platform=${1:-darwin-arm64}
version=$(cat "$station/.node-version")
case "$version-$platform" in
  24.22.1-darwin-arm64) sum=89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7 ;;
  24.22.1-linux-arm64) sum=33c37be234ba8bee041961047b19160f4d7d0f164e8e246f78bdd10feff148b3 ;;
  24.22.1-linux-x64) sum=eb6728e77c576a35162c122c45ccadf224d89ff00abc8dae46cc2897c6002d7c ;;
  24.22.1-win32-x64) sum=d702daa815eabbff763c7d3808e235cf031cf2ca70211b56847bc72f51e240e5 ;;
  *) echo "no pinned Node $version for $platform: add its SHA-256 here" >&2; exit 1 ;;
esac
if [ -n "${COMMA_STATION_NATIVE_CACHE:-}" ]; then cache=$COMMA_STATION_NATIVE_CACHE
elif [ "$(uname)" = Darwin ]; then cache=$HOME/Library/Caches/comma-station-native
elif [ -n "${LOCALAPPDATA:-}" ]; then cache=$LOCALAPPDATA/comma-station-native
else cache=${XDG_CACHE_HOME:-$HOME/.cache}/comma-station-native; fi
dir=$cache/node/$version-$platform
# CI gives the same Node it already has (setup-pinned-node), when it is this platform's and this version.
if [ -n "${COMMA_STATION_NODE:-}" ] && [ "$("$COMMA_STATION_NODE" --version 2>/dev/null)" = "v$version" ] &&
  [ "$("$COMMA_STATION_NODE" -p 'process.platform + "-" + process.arch' 2>/dev/null)" = "$platform" ]; then
  echo "$COMMA_STATION_NODE"
  exit 0
fi
# Read from stdin: given a Windows path, Git's shasum puts a backslash before the sum.
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1; }
# fetch URL FILE NAME: a CI host keeps the checked download between jobs (COMMA_TOOL_CACHE), so FILE is its NAME there
# when that has the pinned SHA-256; else the download, tried again after a dropped connection. keep FILE NAME puts it there.
fetch() {
  if [ -n "${COMMA_TOOL_CACHE:-}" ] && [ -f "$COMMA_TOOL_CACHE/$3" ] && [ "$(sha256 "$COMMA_TOOL_CACHE/$3")" = "$sum" ]; then
    cp "$COMMA_TOOL_CACHE/$3" "$2"
  else
    curl -fsSL --retry 3 --retry-all-errors "$1" -o "$2"
  fi
}
keep() {
  [ -n "${COMMA_TOOL_CACHE:-}" ] || return 0
  [ -f "$COMMA_TOOL_CACHE/$2" ] && cmp -s "$1" "$COMMA_TOOL_CACHE/$2" && return 0
  mkdir -p "$COMMA_TOOL_CACHE" && cp "$1" "$COMMA_TOOL_CACHE/$2.$$" && mv -f "$COMMA_TOOL_CACHE/$2.$$" "$COMMA_TOOL_CACHE/$2"
}
if [ "$platform" = win32-x64 ]; then
  if [ ! -f "$dir/node.exe" ]; then
    mkdir -p "$dir.tmp"
    fetch "https://nodejs.org/dist/v$version/win-x64/node.exe" "$dir.tmp/node.exe" "node-v$version-win-x64.exe"
    got=$(sha256 "$dir.tmp/node.exe")
    [ "$got" = "$sum" ] || { rm -rf "$dir.tmp"; echo "Node $version for $platform: SHA-256 $got, expected $sum" >&2; exit 1; }
    keep "$dir.tmp/node.exe" "node-v$version-win-x64.exe"
    rm -rf "$dir"
    mv "$dir.tmp" "$dir"
  fi
  echo "$dir/node.exe"
  exit 0
fi
if [ ! -x "$dir/bin/node" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  name=node-v$version-$platform
  fetch "https://nodejs.org/dist/v$version/$name.tar.gz" "$tmp/node.tar.gz" "$name.tar.gz"
  got=$(sha256 "$tmp/node.tar.gz")
  [ "$got" = "$sum" ] || { echo "Node $version for $platform: SHA-256 $got, expected $sum" >&2; exit 1; }
  keep "$tmp/node.tar.gz" "$name.tar.gz"
  tar -xzf "$tmp/node.tar.gz" -C "$tmp" "$name/bin/node"
  mkdir -p "$dir.tmp/bin"
  mv "$tmp/$name/bin/node" "$dir.tmp/bin/node"
  rm -rf "$dir"
  mv "$dir.tmp" "$dir"
fi
echo "$dir/bin/node"
