#!/bin/sh
# Lays out the Comma station's release in DIR (the desktop app carries it in its Resources; the runtime images put it
# in /opt/comma-station) for PLATFORM (default darwin-arm64): the station in TypeScript with its native parts, prebuilt
# (scripts/native.ts: launcher, mesh, runner) and the Node it runs on (scripts/node.sh). The layout, as still.fail's
# station release has it:
#   DIR/mesh/target/release/stillfail-station   the launcher: `run --app DIR --data DATA [--with-parent] [-- …]`
#   DIR/node/bin/node
#   DIR/station/{main.js, read/worker.js, skills/, mesh.node, stillfail-runner, package.json}
#   DIR/VERSION                                  the commit
# On win32-x64 the executables are .exe, the launcher has stillfail-station-w.exe (no window) beside it, and the Node
# is DIR/node/node.exe, where the launcher looks for it there.
#   bundle.sh DIR [darwin-arm64|linux-x64|linux-arm64|win32-x64]
set -eu
station=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: bundle.sh DIR [PLATFORM]}
platform=${2:-darwin-arm64}
case "$platform" in
  darwin-arm64|linux-x64|linux-arm64|win32-x64) ;;
  *) echo "no such platform: $platform" >&2; exit 1 ;;
esac
native() { node "$station/scripts/native.ts" file "$1" "$platform"; }
x=; [ "$platform" = win32-x64 ] && x=.exe
launcher="$(native launcher)"
mesh="$(native mesh)"
runner="$(native runner)"
node="$("$station/scripts/node.sh" "$platform")"
(cd "$station" && pnpm run build >&2)
rm -rf "$out"
mkdir -p "$out/mesh/target/release" "$out/station/read"
if [ "$platform" = win32-x64 ]; then
  mkdir -p "$out/node"
  cp "$node" "$out/node/node.exe"
  # The launcher's artifact carries it (scripts/native.ts withHidden).
  cp "$(dirname "$launcher")/stillfail-station-w.exe" "$out/mesh/target/release/"
else
  mkdir -p "$out/node/bin"
  cp "$node" "$out/node/bin/node"
  # nodejs.org's macOS build keeps its local symbols (24 MB of its 122): they go, its exports (Node-API, for mesh.node)
  # stay. Stripping breaks nodejs.org's signature, so it is signed ad hoc until the desktop app signs what it carries.
  if [ "$platform" = darwin-arm64 ] && [ "$(uname)" = Darwin ]; then
    strip -x "$out/node/bin/node" 2>/dev/null
    codesign --sign - --force --identifier node "$out/node/bin/node"
  fi
fi
cp "$launcher" "$out/mesh/target/release/stillfail-station$x"
cp "$mesh" "$runner" "$out/station/"
cp "$station/dist/main.js" "$out/station/"
cp "$station/dist/read/worker.js" "$out/station/read/"
cp -R "$station/dist/skills" "$out/station/skills"
# The bundle is an ES module: said, so Node neither guesses nor takes the type of a package.json above the release.
printf '{"type":"module"}\n' > "$out/station/package.json"
git -C "$station" rev-parse HEAD > "$out/VERSION"
