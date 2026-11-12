#!/usr/bin/env bash
set -euo pipefail

sdk_name=MacOSX27.2.sdk
pkg_url=https://swcdn.apple.com/content/downloads/53/49/142-50405-A_WOBLDDXP4W/wk3d2yw94ir1jieuddcu9b9tffxrb09bq8/CLTools_macOSNMOS_SDK.pkg
pkg_sha256=1eb5196e069ad6e0abde1d750d967b7ea58f5b97f179dbf07aee2d00ca6c813e

cache=${COMMA_CROSS_CACHE:-/cache}
pkg_dir=$cache/sdk-pkg
sdk_dir=$cache/macos-sdk
pkg=$pkg_dir/$pkg_sha256.pkg
dest=$sdk_dir/$pkg_sha256

if [ ! -f "$pkg" ]; then
  mkdir -p "$pkg_dir"
  find "$pkg_dir" -mindepth 1 -delete
  curl -fsSL --retry 5 --retry-all-errors "$pkg_url" -o "$pkg.partial"
  echo "$pkg_sha256  $pkg.partial" | sha256sum -c --quiet -
  mv "$pkg.partial" "$pkg"
fi

pbzx='
import lzma, struct, sys
src, out = sys.stdin.buffer, sys.stdout.buffer
if src.read(4) != b"pbzx":
    sys.exit("prepare-sdk: the package payload is not a pbzx stream")
(flags,) = struct.unpack(">Q", src.read(8))
while flags & 1 << 24:
    flags, size = struct.unpack(">QQ", src.read(16))
    chunk = src.read(size)
    out.write(lzma.decompress(chunk) if chunk.startswith(b"\xfd7zXZ\0") else chunk)
'

if [ ! -f "$dest/.ready" ]; then
  mkdir -p "$sdk_dir"
  find "$sdk_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  mkdir -p "$dest.partial"
  bsdtar -xOf "$pkg" Payload | python3 -c "$pbzx" |
    bsdtar -xf - -C "$dest.partial" "Library/Developer/CommandLineTools/SDKs/$sdk_name"
  mv "$dest.partial/Library/Developer/CommandLineTools/SDKs/$sdk_name" "$dest.partial/$sdk_name"
  rm -rf "$dest.partial/Library"
  find "$dest.partial/$sdk_name" -name '*.tbd' -print0 |
    xargs -0 grep -lZ 'arm64e\.x1' |
    xargs -0 -r perl -0pi -e 's/,\s*arm64e\.x1-[a-z]+//g'
  touch "$dest.partial/.ready"
  mv "$dest.partial" "$dest"
fi
echo "$dest/$sdk_name"
