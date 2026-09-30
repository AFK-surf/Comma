#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${repository_root}/systems/runtime-images/runtime-dependencies.lock.json"
release_revision="${SALIX_APP_REVISION:-}"
output_dir="${RUNTIME_IMAGE_OUTPUT_DIR:-${repository_root}/systems/runtime-images/dist}"
meetnative_source_dir="${MEETNATIVE_SOURCE_DIR:-${repository_root}/../meetnative}"
reuse_bundle_dir="${RUNTIME_REUSE_BUNDLE_DIR:-}"

if [[ -z "${release_revision}" ]]; then
  echo "SALIX_APP_REVISION is required" >&2
  exit 1
fi
command -v docker >/dev/null
command -v jq >/dev/null

mkdir -p "${output_dir}"
rm -f "${output_dir}/external.oci.tar" "${output_dir}/meeting.oci.tar" "${output_dir}/shell.oci.tar" "${output_dir}/manifest.json" "${output_dir}/inputs.json"
build_context="$(mktemp -d)"
meetnative_context="$(mktemp -d)"
cleanup() {
  rm -rf "${build_context}" "${meetnative_context}"
}
trap cleanup EXIT

mkdir -p \
  "${build_context}/systems/connector" \
  "${build_context}/systems/runtime-images"
cp -R \
  "${repository_root}/systems/connector/salix-connect" \
  "${build_context}/systems/connector/salix-connect"
rm -rf "${build_context}/systems/connector/salix-connect/native"
cp \
  "${repository_root}/systems/runtime-images/go.mod" \
  "${build_context}/systems/runtime-images/go.mod"
cp -R \
  "${repository_root}/systems/runtime-images/cmd" \
  "${build_context}/systems/runtime-images/cmd"

lock_value() {
  jq -er "${1}" "${lock_file}"
}

go_image="$(lock_value '.baseImages.go')"
shell_image="$(lock_value '.baseImages.shell')"
external_image="$(lock_value '.baseImages.external')"
meeting_image="$(lock_value '.baseImages.meeting')"
npm_version="$(lock_value '.npm.version')"
npm_tarball="$(lock_value '.npm.tarball')"
npm_integrity="$(lock_value '.npm.integrity')"
npm_brace_expansion_version="$(lock_value '.npmSecurityPatches.braceExpansion.version')"
npm_brace_expansion_tarball="$(lock_value '.npmSecurityPatches.braceExpansion.tarball')"
npm_brace_expansion_integrity="$(lock_value '.npmSecurityPatches.braceExpansion.integrity')"
npm_undici_version="$(lock_value '.npmSecurityPatches.undici.version')"
npm_undici_tarball="$(lock_value '.npmSecurityPatches.undici.tarball')"
npm_undici_integrity="$(lock_value '.npmSecurityPatches.undici.integrity')"
npm_ip_address_version="$(lock_value '.npmSecurityPatches.ipAddress.version')"
npm_ip_address_tarball="$(lock_value '.npmSecurityPatches.ipAddress.tarball')"
npm_ip_address_integrity="$(lock_value '.npmSecurityPatches.ipAddress.integrity')"
npm_tar_version="$(lock_value '.npmSecurityPatches.tar.version')"
npm_tar_tarball="$(lock_value '.npmSecurityPatches.tar.tarball')"
npm_tar_integrity="$(lock_value '.npmSecurityPatches.tar.integrity')"
codex_tarball="$(lock_value '.codex.tarball')"
codex_integrity="$(lock_value '.codex.integrity')"
claude_version="$(lock_value '.claude.version')"
claude_tarball="$(lock_value '.claude.tarball')"
claude_integrity="$(lock_value '.claude.integrity')"
claude_platform_tarball="$(lock_value '.claude.platformTarball')"
claude_platform_integrity="$(lock_value '.claude.platformIntegrity')"
pi_tarball="$(lock_value '.pi.tarball')"
pi_integrity="$(lock_value '.pi.integrity')"
meetnative_repository="$(lock_value '.meetnative.repository')"
meetnative_revision="$(lock_value '.meetnative.revision')"

if [[ ! -d "${meetnative_source_dir}/.git" ]]; then
  echo "meetnative checkout not found at ${meetnative_source_dir}" >&2
  echo "check out ${meetnative_repository} and set MEETNATIVE_SOURCE_DIR" >&2
  exit 1
fi
if ! git -C "${meetnative_source_dir}" cat-file -e "${meetnative_revision}^{commit}"; then
  echo "meetnative checkout does not contain locked revision ${meetnative_revision}" >&2
  exit 1
fi
git -C "${meetnative_source_dir}" archive "${meetnative_revision}" | tar -x -C "${meetnative_context}"

go -C "${repository_root}/systems/runtime-images" run ./cmd/runtime-inputs \
  --root "${repository_root}" \
  --output "${output_dir}/inputs.json"

go -C "${repository_root}/systems/runtime-images" run ./cmd/runtime-reuse \
  --inputs "${output_dir}/inputs.json" \
  --approved "${reuse_bundle_dir}" \
  --output "${output_dir}"

build_archive() {
  local image_class="$1"
  shift
  if [[ -f "${output_dir}/${image_class}.oci.tar" ]]; then
    return
  fi
  local input_digest
  input_digest="$(jq -er --arg class "${image_class}" '
    [.images[] | select(.class == $class) | .inputDigest] |
    if length == 1 then .[0] else error("missing or duplicate runtime input") end
  ' "${output_dir}/inputs.json")"
  docker buildx build \
    --file "${repository_root}/systems/runtime-images/${image_class}/Dockerfile" \
    --platform linux/arm64 \
    --provenance=false \
    --tag "comma.local/runtime/${image_class}:sha256-${input_digest#sha256:}" \
    --output "type=oci,dest=${output_dir}/${image_class}.oci.tar" \
    --build-arg "GO_IMAGE=${go_image}" \
    "$@" \
    "${build_context}"
}

build_archive shell --build-arg "SHELL_IMAGE=${shell_image}"
build_archive external \
  --build-arg "EXTERNAL_IMAGE=${external_image}" \
  --build-arg "NPM_VERSION=${npm_version}" \
  --build-arg "NPM_TARBALL=${npm_tarball}" \
  --build-arg "NPM_INTEGRITY=${npm_integrity}" \
  --build-arg "NPM_BRACE_EXPANSION_VERSION=${npm_brace_expansion_version}" \
  --build-arg "NPM_BRACE_EXPANSION_TARBALL=${npm_brace_expansion_tarball}" \
  --build-arg "NPM_BRACE_EXPANSION_INTEGRITY=${npm_brace_expansion_integrity}" \
  --build-arg "NPM_UNDICI_VERSION=${npm_undici_version}" \
  --build-arg "NPM_UNDICI_TARBALL=${npm_undici_tarball}" \
  --build-arg "NPM_UNDICI_INTEGRITY=${npm_undici_integrity}" \
  --build-arg "NPM_IP_ADDRESS_VERSION=${npm_ip_address_version}" \
  --build-arg "NPM_IP_ADDRESS_TARBALL=${npm_ip_address_tarball}" \
  --build-arg "NPM_IP_ADDRESS_INTEGRITY=${npm_ip_address_integrity}" \
  --build-arg "NPM_TAR_VERSION=${npm_tar_version}" \
  --build-arg "NPM_TAR_TARBALL=${npm_tar_tarball}" \
  --build-arg "NPM_TAR_INTEGRITY=${npm_tar_integrity}" \
  --build-arg "CODEX_TARBALL=${codex_tarball}" \
  --build-arg "CODEX_INTEGRITY=${codex_integrity}" \
  --build-arg "CLAUDE_VERSION=${claude_version}" \
  --build-arg "CLAUDE_TARBALL=${claude_tarball}" \
  --build-arg "CLAUDE_INTEGRITY=${claude_integrity}" \
  --build-arg "CLAUDE_PLATFORM_TARBALL=${claude_platform_tarball}" \
  --build-arg "CLAUDE_PLATFORM_INTEGRITY=${claude_platform_integrity}" \
  --build-arg "PI_TARBALL=${pi_tarball}" \
  --build-arg "PI_INTEGRITY=${pi_integrity}"
build_archive meeting \
  --build-context "meetnative=${meetnative_context}" \
  --build-arg "MEETING_IMAGE=${meeting_image}"

go -C "${repository_root}/systems/runtime-images" run ./cmd/bundle-manifest \
  --revision "${release_revision}" \
  --inputs "${output_dir}/inputs.json" \
  --output "${output_dir}/manifest.json" \
  --image "shell=${output_dir}/shell.oci.tar" \
  --image "external=${output_dir}/external.oci.tar" \
  --image "meeting=${output_dir}/meeting.oci.tar"
