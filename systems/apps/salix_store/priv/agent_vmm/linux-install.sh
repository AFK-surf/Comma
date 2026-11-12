#!/bin/sh
set -eu
umask 077

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || fail 'Run this install command with sudo.'
[ "$(uname -s)" = Linux ] || fail 'This command installs a Linux arm64 Compute Host.'
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) fail 'This command requires a Linux arm64 machine.' ;;
esac

request_id=@REQUEST_ID@
work=$(mktemp -d /tmp/agent-vmm-install.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
archive="$work/host.tar.gz"
printf '%s\n' 'Download the Linux Compute Host.'
curl --fail --silent --show-error --location \
  --connect-timeout 30 --max-time 600 --max-filesize @SIZE@ \
  --output "$archive" @URL@
[ "$(wc -c < "$archive" | tr -d '[:space:]')" = @SIZE@ ] || fail 'The Host archive has the wrong size.'
# Compare the digest in the shell: BusyBox, GNU coreutils and uutils share no
# quiet flag for `sha256sum -c`.
actual_sha=$(sha256sum < "$archive" | cut -d ' ' -f 1)
[ "$actual_sha" = @SHA@ ] || fail 'The Host archive failed verification.'
mkdir "$work/release"
tar -xzf "$archive" --strip-components=1 -C "$work/release"
helper="$work/release/agent-vmm"
[ -x "$helper" ] || fail 'The Host archive has no executable installer.'
printf '%s\n' 'Install and connect this Compute Host.'
cat > "$work/descriptor.json" <<'VMM_REGISTRATION_DESCRIPTOR'
@DESCRIPTOR@
VMM_REGISTRATION_DESCRIPTOR
"$helper" lifecycle install --registration-stdin --request-id "$request_id" < "$work/descriptor.json"
