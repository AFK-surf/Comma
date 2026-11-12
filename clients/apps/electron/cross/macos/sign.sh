#!/usr/bin/env bash
# Sign an app bundle or a disk image.
# Usage: sign.sh APP | sign.sh DMG
# With COMMA_MACOS_P12_FILE (and COMMA_MACOS_P12_PASSWORD_FILE for a protected file), sign with the
# Developer ID certificate, and with COMMA_MACOS_NOTARY_KEY_FILE also notarize and staple.
# An app gets COMMA_MACOS_ENTITLEMENTS. Without a certificate, an app is signed ad hoc and a DMG is not signed.
set -euo pipefail

target=${1:?usage: sign.sh APP | sign.sh DMG}

if [ -z "${COMMA_MACOS_P12_FILE:-}" ]; then
  [ -n "${COMMA_MACOS_NOTARY_KEY_FILE:-}" ] && { echo "sign.sh: notarization needs COMMA_MACOS_P12_FILE" >&2; exit 1; }
  [ ! -d "$target" ] || rcodesign sign "$target"
  exit 0
fi

cert=(--p12-file "$COMMA_MACOS_P12_FILE")
[ -n "${COMMA_MACOS_P12_PASSWORD_FILE:-}" ] && cert+=(--p12-password-file "$COMMA_MACOS_P12_PASSWORD_FILE")
# codesign records the certificate's team in each signature; rcodesign needs it named.
team=$(rcodesign analyze-certificate "${cert[@]}" | sed -n 's/^Team ID: *//p' | head -1)
[ -n "$team" ] || { echo "sign.sh: the certificate names no team" >&2; exit 1; }
args=(sign "${cert[@]}" --team-name "$team")

if [ -d "$target" ]; then
  app=$target
  entitlements=${COMMA_MACOS_ENTITLEMENTS:?COMMA_MACOS_ENTITLEMENTS is not set}
  # --for-notarization enables the hardened runtime on every Mach-O and requires a time stamp.
  args+=(--for-notarization --entitlements-xml-file "$entitlements")

  # rcodesign applies entitlements to the main executable only. The Mac release build
  # (sign-macos-app.ts) gives every executable the same entitlements, so scope them to
  # each nested bundle and to each executable outside a nested bundle.
  while IFS= read -r -d '' nested; do
    args+=(--entitlements-xml-file "${nested#"$app"/}:$entitlements")
  done < <(find "$app/Contents" -type d -name '*.app' -print0)

  while IFS= read -r -d '' file; do
    rel=${file#"$app"/}
    # The main executable takes the unscoped setting; nested bundles are scoped above.
    case "/$rel" in /Contents/MacOS/* | */*.app/*) continue ;; esac
    magic=$(head -c4 "$file" | od -An -tx1 | tr -d ' \n')
    case "$magic" in cffaedfe | cafebabe) ;; *) continue ;; esac
    otool -hv "$file" 2>/dev/null | grep -qw EXECUTE || continue
    args+=(--entitlements-xml-file "$rel:$entitlements")
  done < <(find "$app/Contents" -type f -perm -u+x -print0)

  if [ -f "$app/Contents/MacOS/UpdateMac" ]; then
    args+=(--entitlements-xml-file "Contents/MacOS/UpdateMac:$VELOPACK_VENDOR_DIR/Velopack.entitlements")
  fi
fi

rcodesign "${args[@]}" "$target"
[ -z "${COMMA_MACOS_NOTARY_KEY_FILE:-}" ] || rcodesign notary-submit --api-key-file "$COMMA_MACOS_NOTARY_KEY_FILE" --staple "$target"
