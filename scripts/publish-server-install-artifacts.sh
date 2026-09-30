#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <install-artifacts-directory>" >&2
  exit 2
fi

workspace="$1"
repo="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
descriptor_tool="$repo/scripts/server-release-descriptor.mjs"
node "$descriptor_tool" verify --root "$workspace" >/dev/null
build_id="$(node "$descriptor_tool" server-build-id --root "$workspace")"

: "${CLOUDFLARE_R2_ACCOUNT_ID:?required}"
: "${CLOUDFLARE_R2_BUCKET:?required}"
: "${AWS_ACCESS_KEY_ID:?required}"
: "${AWS_SECRET_ACCESS_KEY:?required}"
: "${AWS_DEFAULT_REGION:=auto}"

endpoint="https://${CLOUDFLARE_R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

while IFS=$'\t' read -r source expected path; do
  key="server-install-artifacts/releases/${build_id}/${path}"
  existing="$RUNNER_TEMP/r2-existing-${expected}"
  if aws --endpoint-url "$endpoint" s3api head-object --bucket "$CLOUDFLARE_R2_BUCKET" --key "$key" >/dev/null 2>&1; then
    aws --endpoint-url "$endpoint" s3api get-object --bucket "$CLOUDFLARE_R2_BUCKET" --key "$key" "$existing" >/dev/null
    observed="$(sha256sum "$existing" | awk '{print $1}')"
    if [[ "$observed" != "$expected" ]]; then
      echo "immutable R2 object differs: $key" >&2
      exit 1
    fi
  else
    aws --endpoint-url "$endpoint" s3api put-object \
      --bucket "$CLOUDFLARE_R2_BUCKET" --key "$key" --body "$workspace/$path" \
      --if-none-match '*' >/dev/null
  fi
done < <(node "$descriptor_tool" publication-list --root "$workspace" | while IFS=$'\t' read -r source sha path; do
  relative="${path#"$(cd "$workspace" && pwd)/"}"
  if [[ "$relative" = /* || "$relative" = ../* || "$relative" == *"/../"* ]]; then
    echo "publication path escapes workspace: $path" >&2
    exit 1
  fi
  printf '%s\t%s\t%s\n' "$source" "$sha" "$relative"
done)
