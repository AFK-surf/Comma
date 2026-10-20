#!/bin/sh
# The Node a station release carries (DIR/node/bin/node, bundle.sh): the official build of .node-version for PLATFORM,
# checked against the SHA-256 pinned below and kept in the native cache (scripts/native.ts), so a rebuild is offline.
# The desktop app cannot lend its Electron: its RunAsNode fuse is off. On win32-x64 it is nodejs.org's node.exe as it
# is (win-x64/node.exe): the one file the station needs of the zip.
#   node.sh [darwin-arm64|linux-x64|linux-arm64|win32-x64]   prints the binary's path
set -eu
station=$(cd "$(dirname "$0")/.." && pwd)
platform=${1:-darwin-arm64}
version=$(cat "$station/.node-version")
case "$version-$platform" in
  24.14.0-darwin-arm64) sum=a1a54f46a750d2523d628d924aab61758a51c9dad3e0238beb14141be9615dd3 ;;
  24.14.0-linux-arm64) sum=f44740cd218de8127f1c44c41510a3a740fa5c9c8d1cdce1c3bedada79f3cde7 ;;
  24.14.0-linux-x64) sum=dbf5b8665dec15e59e6359a517fefb47b23fdb9152d8def975b9bca3dfc6d355 ;;
  24.14.0-win32-x64) sum=63c259c81e5d472b5f11c8d506070130cb04a1ecf84b80377a34ed6ec9048088 ;;
  *) echo "no pinned Node $version for $platform: add its SHA-256 here" >&2; exit 1 ;;
esac
if [ -n "${STILLFAIL_NATIVE_CACHE:-}" ]; then cache=$STILLFAIL_NATIVE_CACHE
elif [ "$(uname)" = Darwin ]; then cache=$HOME/Library/Caches/stillfail-native
elif [ -n "${LOCALAPPDATA:-}" ]; then cache=$LOCALAPPDATA/stillfail-native
else cache=${XDG_CACHE_HOME:-$HOME/.cache}/stillfail-native; fi
dir=$cache/node/$version-$platform
# Read from stdin: given a Windows path, Git's shasum puts a backslash before the sum.
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1; }
if [ "$platform" = win32-x64 ]; then
  if [ ! -f "$dir/node.exe" ]; then
    mkdir -p "$dir.tmp"
    curl -fsSL "https://nodejs.org/dist/v$version/win-x64/node.exe" -o "$dir.tmp/node.exe"
    got=$(sha256 "$dir.tmp/node.exe")
    [ "$got" = "$sum" ] || { rm -rf "$dir.tmp"; echo "Node $version for $platform: SHA-256 $got, expected $sum" >&2; exit 1; }
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
  curl -fsSL "https://nodejs.org/dist/v$version/$name.tar.gz" -o "$tmp/node.tar.gz"
  got=$(sha256 "$tmp/node.tar.gz")
  [ "$got" = "$sum" ] || { echo "Node $version for $platform: SHA-256 $got, expected $sum" >&2; exit 1; }
  tar -xzf "$tmp/node.tar.gz" -C "$tmp" "$name/bin/node"
  mkdir -p "$dir.tmp/bin"
  mv "$tmp/$name/bin/node" "$dir.tmp/bin/node"
  rm -rf "$dir"
  mv "$dir.tmp" "$dir"
fi
echo "$dir/bin/node"
