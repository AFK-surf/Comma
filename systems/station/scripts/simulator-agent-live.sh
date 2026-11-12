#!/bin/bash
# Runs scripts/simulator-agent-live.ts on this Mac: a simulator of its own (made, booted, then deleted) and a
# Computer Use helper instance on a socket of its own (started, then stopped). Any other simulator or helper is left
# alone. The helper is the installed Comma Dev one unless COMMA_SIM_LIVE_HELPER names another app.
# Usage: scripts/simulator-agent-live.sh [screenshots dir]
set -euo pipefail
cd "$(dirname "$0")/.."

SIMCTL=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl
HELPER_APP="${COMMA_SIM_LIVE_HELPER:-$HOME/Library/Application Support/Comma Computer Use/surf.comma.desktop.dev.computer-use/Comma Dev Computer Use.app}"
TYPE="${COMMA_SIM_LIVE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
RUNTIME="${COMMA_SIM_LIVE_RUNTIME:-$("$SIMCTL" list runtimes | awk '/^iOS / && !/iPhone/ {id=$NF} END {print id}')}"

dir=$(mktemp -d /tmp/sim-agent-live.XXXXXX)
socket="$dir/helper.sock"
token=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
udid=""
helper=""
cleanup() {
  [ -n "$helper" ] && kill "$helper" 2>/dev/null || true
  if [ -n "$udid" ]; then
    "$SIMCTL" shutdown "$udid" 2>/dev/null || true
    "$SIMCTL" delete "$udid" 2>/dev/null || true
  fi
  rm -rf "$dir"
}
trap cleanup EXIT

udid=$("$SIMCTL" create "comma-sim-agent-live" "$TYPE" "$RUNTIME")
echo "simulator $udid ($TYPE, $RUNTIME)"
"$SIMCTL" boot "$udid"
"$SIMCTL" bootstatus "$udid" -b >/dev/null

daemons() { pgrep -f "$HELPER_APP/Contents/MacOS/CommaComputerUseDaemon" || true; }
before=$(daemons)
open -n -g --env "COMMA_COMPUTER_USE_SOCKET_PATH=$socket" --env "COMMA_COMPUTER_USE_AUTH_TOKEN=$token" "$HELPER_APP"
for _ in $(seq 1 100); do [ -S "$socket" ] && break; sleep 0.1; done
[ -S "$socket" ] || { echo "the helper did not start (no socket)"; exit 1; }
helper=$(comm -13 <(echo "$before" | sort) <(daemons | sort) | head -1)
echo "helper $helper on $socket"

COMMA_SIM_LIVE_UDID="$udid" COMMA_SIM_LIVE_SOCKET="$socket" COMMA_SIM_LIVE_TOKEN="$token" COMMA_SIM_LIVE_SHOTS="${1:-}" \
  node --test --test-timeout=120000 scripts/simulator-agent-live.ts
