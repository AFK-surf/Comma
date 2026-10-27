#!/bin/bash
# Gets the phones' iroh (clients/packages/mesh/native), which the core's engine links in to reach stations, for the
# iPhone and its simulator: prebuilt (systems/station/scripts/native.ts, part client-mesh), or, outside CI, built here
# when it is not and this machine has Rust. It goes into Vendor/mesh, with Vendor/mesh/mesh.xcconfig, which the Comma
# target reads: with the library it links it and builds the engine with COMMA_MESH; without one it says nothing, and
# the app reaches no station. XcodeGen runs it before it generates the project, after fetch-hermes.sh.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
apple=$(cd "$(dirname "$0")/.." && pwd)
repository=$(cd "$apple/../../.." && pwd)
vendor="$apple/Vendor/mesh"
mode=path
[[ -n "${CI:-}" ]] && mode=fetch
mkdir -p "$vendor"
config="// Written by scripts/fetch-mesh.sh."
got=1
for target in ios-arm64 ios-sim-arm64; do
  if dir=$(node "$repository/systems/station/scripts/native.ts" "$mode" client-mesh "$target"); then
    mkdir -p "$vendor/$target"
    cp "$dir/libcomma_mesh.a" "$vendor/$target/libcomma_mesh.a"
  else
    got=0
  fi
done
if [[ $got == 1 ]]; then
  config+="
COMMA_MESH_DEFINES = COMMA_MESH=1
COMMA_MESH_LIBS[sdk=iphoneos*] = \$(COMMA_APPLE_DIR)/Vendor/mesh/ios-arm64/libcomma_mesh.a
COMMA_MESH_LIBS[sdk=iphonesimulator*] = \$(COMMA_APPLE_DIR)/Vendor/mesh/ios-sim-arm64/libcomma_mesh.a
// What its iroh takes from the system: certificates (Security), the network's state (SystemConfiguration, Network).
COMMA_MESH_LDFLAGS = \$(COMMA_MESH_LIBS) -framework Security -framework SystemConfiguration -framework Network -framework CoreFoundation"
else
  echo "The phones' iroh (client-mesh) is not prebuilt for this source: this build reaches no station." >&2
fi
printf '%s\n' "$config" > "$vendor/mesh.xcconfig"
