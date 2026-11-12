#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 pack <component> <source-sha> <root> <entry> <archive> | publish <component> <source-sha> <archive> | probe <component> <source-sha> <destination> | download <component> <source-sha> <sha256> <size> <destination>" >&2
  exit 2
}

fail() {
  echo "$*" >&2
  exit 1
}

validate_component() {
  case "$1" in
    agent-vmm-host|agent-vmm-guest) ;;
    *) fail "unsupported CI intermediate component: $1" ;;
  esac
}

validate_revision() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || fail "source revision must be a 40-character lowercase commit SHA"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

key_for() {
  printf 'ci-intermediates/%s/commit/%s.tar.gz' "$1" "$2"
}

emit_archive_facts() {
  local archive="$1"
  local digest size
  digest="$(sha256_file "$archive")"
  size="$(file_size "$archive")"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "sha256=$digest"
      echo "size=$size"
    } >> "$GITHUB_OUTPUT"
  else
    printf '%s\t%s\n' "$digest" "$size"
  fi
}

inspect_archive() {
  local component="$1"
  local revision="$2"
  local archive="$3"
  local scratch listing extracted inventory build_info
  [[ -s "$archive" ]] || fail "CI intermediate is missing or empty: $archive"
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-vmm-ci-inspect.XXXXXX")"
  listing="$scratch/listing"
  tar -tzf "$archive" > "$listing" || { rm -rf "$scratch"; return 1; }
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "$listing"; then
    rm -rf "$scratch"
    fail "CI intermediate contains an unsafe archive path"
  fi
  extracted="$scratch/extracted"
  mkdir -p "$extracted"
  tar -xzf "$archive" -C "$extracted" || { rm -rf "$scratch"; return 1; }
  case "$component" in
    agent-vmm-host)
      inventory="$extracted/Agent VMM Host.app/Contents/Resources/release-inventory.json"
      build_info="$extracted/Agent VMM Host.app/Contents/Resources/host-build-info.json"
      jq -e --arg revision "$revision" --arg release_id "agent-vmm-$revision" \
        '.release_id == $release_id' "$inventory" >/dev/null || \
        { rm -rf "$scratch"; return 1; }
      jq -e --arg revision "$revision" \
        '(.Settings | map({key:.Key, value:.Value}) | from_entries)["vcs.revision"] == $revision' \
        "$build_info" >/dev/null || { rm -rf "$scratch"; return 1; }
      test -x "$extracted/Agent VMM Host.app/Contents/MacOS/agent-vmm-host" || \
        { rm -rf "$scratch"; return 1; }
      test -x "$extracted/Agent VMM Host.app/Contents/Helpers/agent-vmm-lifecycle" || \
        { rm -rf "$scratch"; return 1; }
      test -x "$extracted/Agent VMM Host.app/Contents/Helpers/agent-vmm" || \
        { rm -rf "$scratch"; return 1; }
      test -x "$extracted/Agent VMM Host.app/Contents/Helpers/agent-vmm-data" || \
        { rm -rf "$scratch"; return 1; }
      test -x "$extracted/Agent VMM Host.app/Contents/Helpers/agent-vmm-service-executor" || \
        { rm -rf "$scratch"; return 1; }
      ;;
    agent-vmm-guest)
      for artifact in Image initramfs.xz rootfs.squashfs manifest.json; do
        test -s "$extracted/guest-bundle/$artifact" || { rm -rf "$scratch"; return 1; }
      done
      jq -e '.architecture == "arm64"' "$extracted/guest-bundle/manifest.json" >/dev/null || \
        { rm -rf "$scratch"; return 1; }
      ;;
  esac
  rm -rf "$scratch"
}

fetch_r2() {
  local component="$1"
  local revision="$2"
  local destination="$3"
  local key partial diagnostic
  : "${CLOUDFLARE_R2_ACCOUNT_ID:?required}"
  : "${CLOUDFLARE_R2_BUCKET:?required}"
  : "${AWS_ACCESS_KEY_ID:?required}"
  : "${AWS_SECRET_ACCESS_KEY:?required}"
  : "${AWS_DEFAULT_REGION:=auto}"
  export AWS_DEFAULT_REGION
  command -v aws >/dev/null
  key="$(key_for "$component" "$revision")"
  partial="${destination}.partial.$$"
  diagnostic="${partial}.error"
  trap 'rm -f "$partial" "$diagnostic"' RETURN
  mkdir -p "$(dirname "$destination")"
  if ! AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=3 aws \
    --endpoint-url "https://${CLOUDFLARE_R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    --cli-connect-timeout 30 --cli-read-timeout 60 \
    s3api get-object --bucket "$CLOUDFLARE_R2_BUCKET" --key "$key" "$partial" \
    >/dev/null 2>"$diagnostic"; then
    if grep -q '(NoSuchKey)' "$diagnostic"; then return 3; fi
    cat "$diagnostic" >&2
    return 4
  fi
  mv "$partial" "$destination"
  rm -f "$diagnostic"
  trap - RETURN
}

[[ $# -ge 1 ]] || usage
mode="$1"
shift

case "$mode" in
  pack)
    [[ $# -eq 5 ]] || usage
    component="$1"
    revision="$2"
    root="$3"
    entry="$4"
    archive="$5"
    validate_component "$component"
    validate_revision "$revision"
    [[ "$entry" != /* && "$entry" != *".."* ]] || fail "archive entry must be a safe relative path"
    [[ -e "$root/$entry" ]] || fail "archive entry does not exist: $root/$entry"
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-vmm-ci-pack.XXXXXX")"
    trap 'rm -rf "$scratch"' EXIT
    mkdir -p "$scratch/stage" "$(dirname "$archive")"
    cp -R "$root/$entry" "$scratch/stage/$entry"
    # 1980 is representable by ustar in every CI runner timezone.
    find "$scratch/stage/$entry" -exec touch -h -t 198001010000 {} +
    (cd "$scratch/stage" && LC_ALL=C find "$entry" -print | LC_ALL=C sort > "$scratch/files")
    partial="${archive}.partial.$$"
    if tar --version 2>&1 | grep -q bsdtar; then
      COPYFILE_DISABLE=1 tar --no-recursion --format=ustar --uid 0 --gid 0 --uname root --gname wheel \
        -C "$scratch/stage" -cf - -T "$scratch/files" | gzip -n -9 > "$partial"
    else
      tar --no-recursion --format=ustar --owner=0 --group=0 --numeric-owner \
        -C "$scratch/stage" -cf - -T "$scratch/files" | gzip -n -9 > "$partial"
    fi
    mv "$partial" "$archive"
    ;;

  publish)
    [[ $# -eq 3 ]] || usage
    component="$1"
    revision="$2"
    archive="$3"
    validate_component "$component"
    validate_revision "$revision"
    : "${CLOUDFLARE_R2_ACCOUNT_ID:?required}"
    : "${CLOUDFLARE_R2_BUCKET:?required}"
    : "${AWS_ACCESS_KEY_ID:?required}"
    : "${AWS_SECRET_ACCESS_KEY:?required}"
    : "${AWS_DEFAULT_REGION:=auto}"
    command -v aws >/dev/null
    digest="$(sha256_file "$archive")"
    size="$(file_size "$archive")"
    key="$(key_for "$component" "$revision")"
    endpoint="https://${CLOUDFLARE_R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    existing="$(mktemp "${TMPDIR:-/tmp}/agent-vmm-ci-existing.XXXXXX")"
    trap 'rm -f "$existing"' EXIT
    verify_existing() {
      aws --endpoint-url "$endpoint" s3api get-object \
        --bucket "$CLOUDFLARE_R2_BUCKET" --key "$key" "$existing" >/dev/null
      [[ "$(sha256_file "$existing")" == "$digest" && "$(file_size "$existing")" == "$size" ]] || \
        fail "immutable CI intermediate differs: $key"
    }
    if aws --endpoint-url "$endpoint" s3api head-object \
      --bucket "$CLOUDFLARE_R2_BUCKET" --key "$key" >/dev/null 2>&1; then
      verify_existing
    elif ! aws --endpoint-url "$endpoint" s3api put-object \
      --bucket "$CLOUDFLARE_R2_BUCKET" --key "$key" --body "$archive" \
      --content-type application/gzip --if-none-match '*' >/dev/null; then
      verify_existing
    fi
    emit_archive_facts "$archive"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "key=$key" >> "$GITHUB_OUTPUT"
    fi
    ;;

  probe)
    [[ $# -eq 3 ]] || usage
    component="$1"
    revision="$2"
    destination="$3"
    validate_component "$component"
    validate_revision "$revision"
    fetch_r2 "$component" "$revision" "$destination"
    inspect_archive "$component" "$revision" "$destination" || exit 5
    emit_archive_facts "$destination"
    ;;

  download)
    [[ $# -eq 5 ]] || usage
    component="$1"
    revision="$2"
    expected_sha="$3"
    expected_size="$4"
    destination="$5"
    validate_component "$component"
    validate_revision "$revision"
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || fail "invalid expected archive sha256"
    [[ "$expected_size" =~ ^[1-9][0-9]*$ ]] || fail "invalid expected archive size"
    fetch_r2 "$component" "$revision" "$destination"
    [[ "$(sha256_file "$destination")" == "$expected_sha" && "$(file_size "$destination")" == "$expected_size" ]] || \
      fail "CI intermediate differs from the selected builder output"
    ;;

  *) usage ;;
esac
