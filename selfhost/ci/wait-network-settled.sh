#!/usr/bin/env bash
# Chromium aborts page loads with ERR_NETWORK_CHANGED when a host interface or
# address changes. Docker adds a bridge and container interfaces when Compose
# starts, and IPv6 addresses stay "tentative" for a moment after that. Return
# once no address is tentative and two readings a second apart agree.
set -euo pipefail
previous=""
for _ in $(seq 120); do
  current="$(ip -o addr show)"
  if [ "$current" = "$previous" ] && ! grep -q tentative <<<"$current"; then
    exit 0
  fi
  previous="$current"
  sleep 1
done
echo "host network did not settle" >&2
exit 1
