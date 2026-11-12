#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
script="$repo/systems/connector/agent-vmm-ci-intermediate.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-vmm-ci-intermediate-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
revision="${AGENT_VMM_TEST_REVISION:-$(git -C "$repo" rev-parse HEAD)}"
app="$scratch/input/Agent VMM Host.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$resources"
for executable in "$app/Contents/MacOS/agent-vmm-host" "$app/Contents/Helpers/agent-vmm" "$app/Contents/Helpers/agent-vmm-lifecycle" "$app/Contents/Helpers/agent-vmm-data" "$app/Contents/Helpers/agent-vmm-service-executor"; do
  printf '#!/bin/sh\nexit 0\n' > "$executable"
  chmod +x "$executable"
done
jq -n --arg revision "$revision" --arg release_id "agent-vmm-$revision" \
  '{schema_version:1,component:"agent-vmm-host-runtime",release_id:$release_id}' > "$resources/release-inventory.json"
jq -n --arg revision "$revision" \
  '{Settings:[{Key:"vcs.revision",Value:$revision}]}' > "$resources/host-build-info.json"

first="$scratch/first.tar.gz"
second="$scratch/second.tar.gz"
"$script" pack agent-vmm-host "$revision" "$scratch/input" "Agent VMM Host.app" "$first" >/dev/null
if tar -tzf "$first" | LC_ALL=C sort | uniq -d | grep -q .; then
  echo "archive contains duplicate paths that cross-platform tar may encode as self-hardlinks" >&2
  exit 1
fi
touch "$app/Contents/MacOS/agent-vmm-host" "$resources/release-inventory.json"
"$script" pack agent-vmm-host "$revision" "$scratch/input" "Agent VMM Host.app" "$second" >/dev/null
cmp "$first" "$second"

if command -v sha256sum >/dev/null 2>&1; then
  first_sha="$(sha256sum "$first" | awk '{print $1}')"
else
  first_sha="$(shasum -a 256 "$first" | awk '{print $1}')"
fi

if "$script" download agent-vmm-host "$revision" "$first_sha" \
    "$(wc -c < "$first" | tr -d '[:space:]')" "$scratch/no-server.tar.gz" >/dev/null 2>&1; then
  echo "download unexpectedly succeeded without R2 credentials" >&2
  exit 1
fi

mkdir -p "$scratch/bin"
cat > "$scratch/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "${AWS_TRANSPORT_FAILURE:-}" == true ]]; then echo "AccessDenied" >&2; exit 255; fi
echo "$*" >> "$AWS_LOG"
case "$*" in
  *" head-object "*) test -f "$AWS_OBJECT" ;;
  *" put-object "*)
    if [[ -f "$AWS_OBJECT" ]]; then exit 1; fi
    previous=
    for arg in "$@"; do
      if [[ "$previous" == --body ]]; then cp "$arg" "$AWS_OBJECT"; fi
      previous="$arg"
    done
    ;;
  *" get-object "*)
    if [[ ! -f "$AWS_OBJECT" ]]; then echo 'An error occurred (NoSuchKey) when calling GetObject' >&2; exit 255; fi
    cp "$AWS_OBJECT" "${@: -1}"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$scratch/bin/aws"
export AWS_OBJECT="$scratch/object.tar.gz"
export AWS_LOG="$scratch/aws.log"
export CLOUDFLARE_R2_ACCOUNT_ID=account CLOUDFLARE_R2_BUCKET=bucket
export AWS_ACCESS_KEY_ID=key AWS_SECRET_ACCESS_KEY=secret
export PATH="$scratch/bin:$PATH"
output="$scratch/output"
AWS_LOG="$scratch/aws.log" GITHUB_OUTPUT="$output" \
  CLOUDFLARE_R2_ACCOUNT_ID=account CLOUDFLARE_R2_BUCKET=bucket \
  AWS_ACCESS_KEY_ID=key AWS_SECRET_ACCESS_KEY=secret \
  PATH="$scratch/bin:$PATH" \
  "$script" publish agent-vmm-host "$revision" "$first"
grep -q "key=ci-intermediates/agent-vmm-host/commit/$revision.tar.gz" "$output"
grep -q -- "--if-none-match \*" "$scratch/aws.log"

"$script" download agent-vmm-host "$revision" "$first_sha" \
  "$(wc -c < "$first" | tr -d '[:space:]')" "$scratch/download.tar.gz"
cmp "$first" "$scratch/download.tar.gz"
"$script" probe agent-vmm-host "$revision" "$scratch/probe.tar.gz" >/dev/null
cmp "$first" "$scratch/probe.tar.gz"
if "$script" download agent-vmm-host "$revision" "$(printf '%064d' 0)" \
  "$(wc -c < "$first" | tr -d '[:space:]')" "$scratch/wrong-digest.tar.gz" >/dev/null 2>&1; then
  echo "download accepted bytes with the wrong builder digest" >&2
  exit 1
fi
wrong_revision="0000000000000000000000000000000000000000"

expect_probe_failure() {
  local expected="$1" status
  set +e
  "$script" probe agent-vmm-host "$revision" "$scratch/rejected.tar.gz" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" == "$expected" ]] || { echo "probe returned $status instead of $expected" >&2; exit 1; }
}
export AWS_TRANSPORT_FAILURE=true
expect_probe_failure 4
unset AWS_TRANSPORT_FAILURE
rm "$AWS_OBJECT"
expect_probe_failure 3
cp "$first" "$AWS_OBJECT"
# A valid archive from another source must not become a cache hit.
jq --arg revision "$wrong_revision" '.source_revision=$revision | .release_id="agent-vmm-"+$revision' "$resources/release-inventory.json" > "$scratch/inventory.json"
mv "$scratch/inventory.json" "$resources/release-inventory.json"
jq --arg revision "$wrong_revision" '.Settings[0].Value=$revision' "$resources/host-build-info.json" > "$scratch/build-info.json"
mv "$scratch/build-info.json" "$resources/host-build-info.json"
"$script" pack agent-vmm-host "$wrong_revision" "$scratch/input" "Agent VMM Host.app" "$AWS_OBJECT" >/dev/null
expect_probe_failure 5

echo "Agent VMM CI intermediate contract passed"
