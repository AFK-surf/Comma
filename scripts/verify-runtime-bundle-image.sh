#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <server-image> <expected-release-revision>" >&2
  exit 1
fi

server_image="$1"
expected_revision="$2"
verification_dir="$(mktemp -d)"
container_id=""

cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  rm -rf "${verification_dir}"
}
trap cleanup EXIT

container_id="$(docker create "${server_image}")"
docker cp "${container_id}:/opt/comma/runtime-images/." "${verification_dir}/"

test -f "${verification_dir}/manifest.json"
jq -e --arg revision "${expected_revision}" '
  .schemaVersion == 3 and
  .sourceRevision == $revision and
  ([.images[].class] | sort == ["external", "meeting", "shell"]) and
  all(.images[]; . as $image |
    $image.platform == "linux/arm64" and
    ($image.inputDigest | test("^sha256:[0-9a-f]{64}$")) and
    ($image.manifestDigest | test("^sha256:[0-9a-f]{64}$")) and
    $image.reference == ("comma.local/runtime/" + $image.class + "@" + $image.manifestDigest) and
    ($image.archiveSize | type == "number" and . > 0 and floor == .) and
    ($image.archiveSha256 | test("^[0-9a-f]{64}$")) and
    ($image | keys | sort == ["archiveSha256", "archiveSize", "class", "inputDigest", "manifestDigest", "platform", "reference"]))
' "${verification_dir}/manifest.json" >/dev/null
echo "runtime-bundle-valid source_revision=${expected_revision}"
