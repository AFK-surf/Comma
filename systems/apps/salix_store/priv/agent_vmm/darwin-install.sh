#!/bin/sh
set -eu
umask 077

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(uname -s)" = Darwin ] || fail 'This command installs a macOS Compute Host.'
[ "$(uname -m)" = arm64 ] || fail 'This command requires a Mac with Apple silicon.'
# The Host runs as a login agent of the Mac user who runs this command.
[ "$(id -u)" != 0 ] || fail 'Run this install command as the Mac user who keeps the Host, without sudo.'

request_id=@REQUEST_ID@
# The lifecycle helper publishes only from a canonical path; TMPDIR is under the /var symlink.
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agent-vmm-install.XXXXXXXX")" && pwd -P)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
archive="$work/host.zip"
printf '%s\n' 'Download the macOS Compute Host.'
# A dropped or stalled transfer resumes from the received bytes: 1 attempt and 5 retries.
download_attempt=0
while :; do
  if [ -f "$archive" ] && [ "$(wc -c < "$archive" | tr -d '[:space:]')" -ge @SIZE@ ]; then
    break
  fi
  download_attempt=$((download_attempt + 1))
  download_status=0
  curl --fail --silent --show-error --location --continue-at - \
    --connect-timeout 30 --max-time 600 --speed-time 60 --speed-limit 1 --max-filesize @SIZE@ \
    --output "$archive" @URL@ || download_status=$?
  [ "$download_status" != 0 ] || break
  [ "$download_attempt" -lt 6 ] || exit "$download_status"
  # 33: the server cannot resume, so the next attempt starts again.
  [ "$download_status" != 33 ] || rm -f "$archive"
  printf 'The download stopped. Retry %s of 5 continues it.\n' "$download_attempt" >&2
  sleep $((download_attempt < 4 ? 1 << (download_attempt - 1) : 8))
done
[ "$(wc -c < "$archive" | tr -d '[:space:]')" = @SIZE@ ] || fail 'The Host archive has the wrong size.'
actual_sha=$(shasum -a 256 < "$archive" | cut -d ' ' -f 1)
[ "$actual_sha" = @SHA@ ] || fail 'The Host archive failed verification.'
mkdir "$work/release"
ditto -x -k "$archive" "$work/release"
staged="$work/release/Agent VMM Host.app"
for helper in MacOS/agent-vmm-host Helpers/agent-vmm-lifecycle Helpers/agent-vmm Helpers/agent-vmm-service-executor; do
  [ -x "$staged/Contents/$helper" ] || fail 'The Host archive is not a complete Agent VMM Host.'
done
codesign --verify --deep --strict "$staged" || fail 'The Host archive failed signature verification.'

release_of() {
  "$1/Contents/Helpers/agent-vmm-lifecycle" version --json | plutil -extract release_id raw -o - -
}

target_release=$(release_of "$staged") || fail 'The Host archive has no release identity.'
current="$HOME/Library/Application Support/Agent VMM Host/current"
app="$current/Agent VMM Host.app"
printf '%s\n' 'Install and connect this Compute Host.'
if [ ! -d "$app" ]; then
  "$staged/Contents/Helpers/agent-vmm-lifecycle" publish-host --source-app "$staged" \
    --service-type agent > /dev/null
elif [ "$(release_of "$app" 2> /dev/null || true)" != "$target_release" ]; then
  # Replace the installed Host in place with its data; the source sits beside the target.
  source_app="$current/.Agent VMM Host.$request_id.app"
  [ -d "$source_app" ] || ditto "$staged" "$source_app"
  printf '{"version":1,"requestId":"%s","action":"update","dataPolicy":"preserve","sourceApp":"%s","targetApp":"%s","targetReleaseId":"%s","confirmSharedHost":true}' \
    "$request_id-update" "$source_app" "$app" "$target_release" |
    "$source_app/Contents/Helpers/agent-vmm-lifecycle" host-maintain --service-type auto > /dev/null
  rm -rf "$source_app"
fi
cat > "$work/descriptor.json" <<'VMM_REGISTRATION_DESCRIPTOR'
@DESCRIPTOR@
VMM_REGISTRATION_DESCRIPTOR
"$app/Contents/Helpers/agent-vmm-lifecycle" registration-claim --service-type agent \
  --disable-personal-mesh-pairing --request-id "$request_id" --descriptor-stdin < "$work/descriptor.json" > /dev/null
