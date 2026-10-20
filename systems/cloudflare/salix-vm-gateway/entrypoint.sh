#!/usr/bin/env sh
set -eu

export SALIX_VM_WORKSPACE="${SALIX_VM_WORKSPACE:-/workspace}"
# The station's data directory: under the workspace, so the VM's archive carries its chats.
station_data="$SALIX_VM_WORKSPACE/.comma/station"
# Retained native Session identities contain these absolute entry paths.
# Back the legacy path with the archived workspace; do not rewrite bindings.
managed_home="$SALIX_VM_WORKSPACE/.salix/sprite-home"
export HOME=/home/sprite/.local/share/salix/connector-home
export SALIX_MANAGED_RUNTIME_ROOT=/home/sprite/.local/share/salix/runtimes
export PYTHONUSERBASE=/home/sprite/.local
# The Container is the agents' sandbox, and they run as root in it: Claude Code
# refuses --dangerously-skip-permissions as root unless told it is sandboxed.
export IS_SANDBOX=1

# A wake names the archive this Container's disk is to be (SALIX_RESTORE_ARCHIVE, in its start's environment: one
# short-lived read URL Salix signed, of the manifest of the archive's parts). It is unpacked onto the disk here, before anything runs on it: the station then starts
# once, on its own disk, with its key, its place and its Sessions. A station never starts without that disk: when the
# archive cannot be restored the Container exits with 65, nothing connects to Salix, and Salix reads the stop and
# starts another Container. A start that names no archive (a new VM) goes straight on. The restore is told the data
# directory the station will start with: what an archive holds of a station's runtime state there (its run/: runner
# records, pids, ports) was true of another Container and is not put on this one's disk.
if [ -n "${SALIX_RESTORE_ARCHIVE:-}" ]; then
  if ! SALIX_CONNECTOR_ROOT="$SALIX_VM_WORKSPACE" \
    /opt/comma-station/node/bin/node /opt/comma-station/station/main.js restore-archive --data "$station_data"; then
    echo "Archive not restored; no station starts on this disk" >&2
    exit 65
  fi
  # The signed URL is the restore's alone: neither the station nor what it runs gets them.
  unset SALIX_RESTORE_ARCHIVE
fi

# Keep the sandbox control plane reachable when a full disk prevents Connector
# state creation. Retry the same Connector after an operator frees cache space.
connector_loop() {
  while :; do
    if mkdir -p "$SALIX_VM_WORKSPACE" "$managed_home" /home; then
      if [ ! -e /home/sprite ] && [ ! -L /home/sprite ]; then
        if ! ln -s "$managed_home" /home/sprite; then
          echo "Legacy home link unavailable" >&2
        fi
      fi
      if [ "$(readlink -f /home/sprite)" = "$(readlink -f "$managed_home")" ] &&
         mkdir -p "$HOME" "$SALIX_MANAGED_RUNTIME_ROOT"; then
        # The station connects out to SALIX_SERVER with SALIX_WORKLOAD_CREDENTIAL (from the Container's start). Its
        # databases live under the workspace, so the VM's archive carries its chats, and a restored disk has them.
        if SALIX_CONNECTOR_ROOT="$SALIX_VM_WORKSPACE" SALIX_CONNECTOR_NAME="Cloud VM" \
          /opt/comma-station/mesh/target/release/stillfail-station run \
          --app /opt/comma-station \
          --data "$station_data"; then
          echo "Station exited; restarting" >&2
        else
          echo "Station stopped; restarting" >&2
          sleep 5
          continue
        fi
      else
        echo "Connector state unavailable; retrying" >&2
      fi
    else
      echo "Workspace unavailable; retrying" >&2
    fi
    sleep 30
  done
}
connector_loop &

exec /container-server/sandbox
