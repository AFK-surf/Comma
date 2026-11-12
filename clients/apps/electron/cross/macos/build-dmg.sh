#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = shell ]; then
  shift
  set -- bash "$@"
fi

opendropkit_token=${OPENDROPKIT_RELEASE_TOKEN:-}
unset OPENDROPKIT_RELEASE_TOKEN
git config --global --add safe.directory '*'

src=${COMMA_SRC:-/src}
cache=${COMMA_CROSS_CACHE:-/cache}
arch=${COMMA_TARGET_ARCH:-arm64}

export COMMA_CROSS_CACHE=$cache
export COMMA_TARGET_PLATFORM=darwin
export COMMA_TARGET_ARCH=$arch
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
export COMMA_BUILD_FLAVOR=${COMMA_BUILD_FLAVOR:-staging}
export npm_config_store_dir=$cache/pnpm-store
export COMMA_STATION_NATIVE_CACHE=$cache/comma-station-native
export COMMA_TOOL_CACHE=$cache/tools
export electron_config_cache=$cache/electron
# SwiftPM keeps its clones of package dependencies in ~/.cache.
mkdir -p "$cache/user-cache"
rm -rf "$HOME/.cache"
ln -s "$cache/user-cache" "$HOME/.cache"
MACOS_SDK=$(/opt/macos-cross/prepare-sdk.sh)
export MACOS_SDK

# A fresh checkout gives the sources new times, so SwiftPM alone would rebuild the macros every run.
macros=$src/clients/apps/electron/cross/macos/macros
macros_hash=$(cd "$macros" && find Package.swift Package.resolved Sources -type f | sort | xargs sha256sum | sha256sum | cut -c1-64)
if [ "$(cat "$cache/macros-build/.sources" 2>/dev/null)" != "$macros_hash" ]; then
  /opt/swift/usr/bin/swift build -c release --package-path "$macros" --scratch-path "$cache/macros-build" >&2
  echo "$macros_hash" > "$cache/macros-build/.sources"
fi
export MACOS_SWIFT_PLUGIN_DIR=$cache/macros-build/release

universal_archive() {
  local output=$1 source=$2 work slice
  work=$(mktemp -d)
  for slice in arm64 x86_64; do
    xcrun clang -target "${slice}-apple-macosx10.13" -O2 -c "$source" -o "$work/$slice.o"
  done
  libtool -static -o "$output" "$work/arm64.o" "$work/x86_64.o"
  rm -rf "$work"
}

runtime=$cache/darwin-runtime
if [ ! -f "$runtime/.ready" ]; then
  rm -rf "$runtime"
  mkdir -p "$runtime/swift"
  universal_archive "$runtime/libclang_rt.osx.a" /opt/macos-cross/compiler-rt/os_version_check.c
  for name in swiftCompatibility50 swiftCompatibility51 swiftCompatibility56 \
    swiftCompatibilityConcurrency swiftCompatibilityDynamicReplacements swiftCompatibilityPacks; do
    printf '.section __DATA,__data\n.globl "__swift_FORCE_LOAD_$_%s"\n"__swift_FORCE_LOAD_$_%s":\n.byte 0\n' \
      "$name" "$name" > "$runtime/$name.s"
    universal_archive "$runtime/swift/lib$name.a" "$runtime/$name.s"
    rm "$runtime/$name.s"
  done
  touch "$runtime/.ready"
fi
clang_rt_dir=$(/opt/swift/usr/bin/clang -print-resource-dir)/lib/darwin
mkdir -p "$clang_rt_dir" "$SWIFT_DARWIN_RESOURCE_DIR/macosx"
cp "$runtime/libclang_rt.osx.a" "$clang_rt_dir/"
cp "$runtime"/swift/*.a "$SWIFT_DARWIN_RESOURCE_DIR/macosx/"

if [ $# -gt 0 ]; then
  exec "$@"
fi

cd "$src"
pnpm install --frozen-lockfile --os darwin --os current --cpu "$arch" --cpu current

cd "$src/clients/apps/electron"
OPENDROPKIT_RELEASE_TOKEN=$opendropkit_token NODE_ENV=production pnpm build:native
pnpm exec electron-forge package --platform darwin --arch "$arch"

COMMA_FORGE_PLATFORM=darwin COMMA_FORGE_ARCH=$arch \
  COMMA_MACOS_ENTITLEMENTS=$src/clients/apps/electron/build/entitlements.mac.entitlements \
  pnpm exec tsx scripts/release-velopack.ts
