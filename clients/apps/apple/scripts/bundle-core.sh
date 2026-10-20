#!/bin/bash
# The Comma target's "Bundle the client core" build phase: compiles the client core (clients/packages/core) to the
# Hermes bytecode the app carries (core.hbc), with the repository's Node tools, so `pnpm install` must have run at the
# repository root. The bundle is made again only when a source of it is newer than the one the app has.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
apple="${COMMA_APPLE_DIR:?}"
packages="$apple/../../packages"
out="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/core.hbc"
sources=("$packages"/{core,core-kernel,chat-contract,session-contract,recommendation-contract,mesh,i18n}/src
  "$packages/core/scripts" "$packages/i18n/messages" "$apple/../android/gradle/libs.versions.toml")
if [[ -f "$out" ]] && [[ -z "$(find "${sources[@]}" -newer "$out" -print -quit 2>/dev/null)" ]]; then exit 0; fi
mkdir -p "$DERIVED_FILE_DIR" "$(dirname "$out")"
# Babel finds its plugins from the working directory: the core's, wherever the project was generated.
cd "$packages/core"
node scripts/mobile-bundle.ts "$DERIVED_FILE_DIR/core.js" "$out"
