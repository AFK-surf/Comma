#!/bin/sh
# The Comma station of a Group's Cloud VM on an Agent VMM Host. It connects out
# to SALIX_SERVER with SALIX_WORKLOAD_CREDENTIAL, both given at the container's
# creation, as the Cloudflare Container's station does. The root filesystem is
# read-only; /workspace is the Workload's persistent volume, and the station's
# databases, temporary files and the CLIs' homes live under it.
#
# Where the image has meet-native (the VMM Station target), it runs beside the
# station on a virtual display: the station reaches it on
# loopback (SALIX_MEET_URL) and offers the Group's meetings a runtime.
set -eu

workspace=/workspace
export HOME="$workspace"
export TMPDIR="$workspace/.tmp"
mkdir -p "$TMPDIR" "$workspace/.comma/station"
node /usr/local/lib/comma-station-initialize-access.mjs "$workspace/.comma/station"

child=""
meet=""
xvfb=""
stopping=""
stop() {
  stopping=1
  if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; fi
  if [ -n "$meet" ]; then kill -TERM "$meet" 2>/dev/null || true; fi
  if [ -n "$xvfb" ]; then kill -TERM "$xvfb" 2>/dev/null || true; fi
}
trap stop TERM INT

# meet-native, and the display its browser draws on, started again when either
# has exited.
meeting() {
  [ -x /usr/local/bin/meet-native ] || return 0
  if [ -z "$xvfb" ] || ! kill -0 "$xvfb" 2>/dev/null; then
    rm -f /tmp/.X99-lock
    Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
    xvfb=$!
  fi
  if [ -z "$meet" ] || ! kill -0 "$meet" 2>/dev/null; then
    DISPLAY=:99 /usr/local/bin/meet-native serve &
    meet=$!
  fi
  export SALIX_MEET_URL=http://127.0.0.1:8081
}

# The station exits to take a restored state or a new release and starts again
# here; stopping the container stops it.
while [ -z "$stopping" ]; do
  meeting
  SALIX_CONNECTOR_ROOT="$workspace" SALIX_CONNECTOR_NAME="${SALIX_CONNECTOR_NAME:-Cloud VM}" \
    /opt/comma-station/mesh/target/release/comma-station run \
    --app /opt/comma-station \
    --data "$workspace/.comma/station" &
  child=$!
  status=0
  wait "$child" || status=$?
  # A trapped signal interrupts wait before the station has exited.
  while kill -0 "$child" 2>/dev/null; do wait "$child" || status=$?; done
  child=""
  [ -n "$stopping" ] && break
  if [ "$status" -eq 0 ]; then
    echo "Station exited; restarting" >&2
  else
    echo "Station stopped ($status); restarting" >&2
    sleep 5
  fi
done
