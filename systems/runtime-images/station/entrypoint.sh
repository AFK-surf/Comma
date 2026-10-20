#!/bin/sh
# The Comma station of a Group's Cloud VM on an Agent VMM Host. It connects out
# to SALIX_SERVER with SALIX_WORKLOAD_CREDENTIAL, both given at the container's
# creation, as the Cloudflare Container's station does. The root filesystem is
# read-only; /workspace is the Workload's persistent volume, and the station's
# databases, temporary files and the CLIs' homes live under it.
set -eu

workspace=/workspace
export HOME="$workspace"
export TMPDIR="$workspace/.tmp"
mkdir -p "$TMPDIR" "$workspace/.comma/station"

child=""
stopping=""
stop() {
  stopping=1
  if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; fi
}
trap stop TERM INT

# The station exits to take a restored state or a new release and starts again
# here; stopping the container stops it.
while [ -z "$stopping" ]; do
  SALIX_CONNECTOR_ROOT="$workspace" SALIX_CONNECTOR_NAME="${SALIX_CONNECTOR_NAME:-Cloud VM}" \
    /opt/comma-station/mesh/target/release/stillfail-station run \
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
