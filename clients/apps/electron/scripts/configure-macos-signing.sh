#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ELECTRON_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
KEYCHAIN_DB="${COMMA_MACOS_KEYCHAIN:-$ELECTRON_ROOT/build/Keychain/AFK-Developer-ID-Keychain.keychain}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD_AFK:-}"

if [[ ! -f "$KEYCHAIN_DB" ]]; then
  echo "Keychain not found: $KEYCHAIN_DB" >&2
  exit 1
fi

if [[ -z "$KEYCHAIN_PASSWORD" ]]; then
  echo "KEYCHAIN_PASSWORD_AFK is not set" >&2
  exit 1
fi

KEYCHAIN_DB=$(realpath "$KEYCHAIN_DB")

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_DB"

CURRENT_KEYCHAINS=$(security list-keychains -d user | sed 's/"//g' | tr '\n' ' ')
security list-keychains -d user -s "$KEYCHAIN_DB" $CURRENT_KEYCHAINS
security set-keychain-settings -t 3600 -l "$KEYCHAIN_DB"

CODE_SIGNING_CONTENTS=$(security find-identity -v -p codesigning "$KEYCHAIN_DB")
DEVELOPER_ID_LINE=$(echo "$CODE_SIGNING_CONTENTS" | grep "Developer ID Application" | head -n 1)
CODE_SIGNING_IDENTITY_HASH=$(echo "$DEVELOPER_ID_LINE" | awk '{print $2}')
CODE_SIGNING_TEAM=$(echo "$DEVELOPER_ID_LINE" | sed 's/.*(\(.*\)).*/\1/')

if [[ -z "$CODE_SIGNING_IDENTITY_HASH" ]]; then
  echo "Cannot find Developer ID Application identity in keychain" >&2
  exit 1
fi

if [[ -z "$CODE_SIGNING_TEAM" ]]; then
  echo "Cannot find Team ID from Developer ID Application identity" >&2
  exit 1
fi

NOTARIZE_KEYCHAIN_PROFILE=$(
  security dump-keychain -r "$KEYCHAIN_DB" |
    strings |
    grep "com.apple.gke.notary.tool.saved-creds" |
    head -n 1 |
    awk -F. '{print $NF}' |
    tr -d '"'
)

if [[ -z "$NOTARIZE_KEYCHAIN_PROFILE" ]]; then
  echo "Cannot find notarytool keychain profile in keychain" >&2
  exit 1
fi

if ! xcrun notarytool history \
  --keychain-profile "$NOTARIZE_KEYCHAIN_PROFILE" \
  --keychain "$KEYCHAIN_DB" \
  --output-format json >/dev/null; then
  echo "Notarytool authentication failed for keychain profile: $NOTARIZE_KEYCHAIN_PROFILE" >&2
  echo "Refresh the Apple app-specific password in the tartelet keychain before retrying the release." >&2
  exit 1
fi

{
  echo "COMMA_MACOS_SIGN=1"
  echo "COMMA_MACOS_NOTARIZE=1"
  echo "COMMA_MACOS_KEYCHAIN=$KEYCHAIN_DB"
  echo "COMMA_MACOS_SIGN_IDENTITY=$CODE_SIGNING_IDENTITY_HASH"
  echo "COMMA_MACOS_TEAM_ID=$CODE_SIGNING_TEAM"
  echo "COMMA_MACOS_NOTARY_PROFILE=$NOTARIZE_KEYCHAIN_PROFILE"
} >> "$GITHUB_ENV"

echo "Configured macOS signing identity: $CODE_SIGNING_IDENTITY_HASH"
echo "Configured macOS signing team: $CODE_SIGNING_TEAM"
echo "Configured notarization profile: $NOTARIZE_KEYCHAIN_PROFILE"
