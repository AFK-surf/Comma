#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <runtime-bundle-directory>" >&2
  exit 2
fi

bundle_dir="$1"
manifest="$bundle_dir/manifest.json"

: "${CLOUDFLARE_R2_ACCOUNT_ID:?required}"
: "${CLOUDFLARE_R2_BUCKET:?required}"
: "${AWS_ACCESS_KEY_ID:?required}"
: "${AWS_SECRET_ACCESS_KEY:?required}"
: "${AWS_DEFAULT_REGION:=auto}"

command -v aws >/dev/null
command -v jq >/dev/null
command -v sha256sum >/dev/null

jq -e '
  .schemaVersion == 3 and
  (.sourceRevision | type == "string" and length > 0) and
  ([.images[].class] | sort == ["external", "meeting", "shell"]) and
  (all(.images[]; . as $image |
    ($image.inputDigest | test("^sha256:[0-9a-f]{64}$")) and
    ($image.manifestDigest | test("^sha256:[0-9a-f]{64}$")) and
    $image.reference == ("comma.local/runtime/" + $image.class + "@" + $image.manifestDigest) and
    (.archiveSha256 | test("^[0-9a-f]{64}$")) and
    (.archiveSize | type == "number" and . > 0 and floor == .)))
' "$manifest" >/dev/null

endpoint="https://${CLOUDFLARE_R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

while IFS=$'\t' read -r class expected size; do
  archive="$bundle_dir/$class.oci.tar"
  key="runtime-bundles/sha256/${expected}.oci.tar"
  observed="$(sha256sum "$archive" | awk '{print $1}')"
  observed_size="$(wc -c < "$archive" | tr -d ' ')"
  if [[ "$observed" != "$expected" || "$observed_size" != "$size" ]]; then
    echo "runtime bundle does not match manifest: $class" >&2
    exit 1
  fi

  if ! aws --endpoint-url "$endpoint" s3api head-object --bucket "$CLOUDFLARE_R2_BUCKET" --key "$key" >/dev/null 2>&1; then
    aws --endpoint-url "$endpoint" s3api put-object \
      --bucket "$CLOUDFLARE_R2_BUCKET" \
      --key "$key" \
      --body "$archive" \
      --content-type application/vnd.oci.image.layer.v1.tar \
      --cache-control public,max-age=31536000,immutable \
      --if-none-match '*' >/dev/null
  fi
done < <(jq -r '.images[] | [.class, .archiveSha256, (.archiveSize | tostring)] | @tsv' "$manifest")
