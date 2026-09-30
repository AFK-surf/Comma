#!/usr/bin/env sh
set -eu

export SALIX_VM_WORKSPACE="${SALIX_VM_WORKSPACE:-/workspace}"
# Retained native Session identities contain these absolute entry paths.
# Back the legacy path with the archived workspace; do not rewrite bindings.
managed_home="$SALIX_VM_WORKSPACE/.salix/sprite-home"
export HOME=/home/sprite/.local/share/salix/connector-home
export SALIX_MANAGED_RUNTIME_ROOT=/home/sprite/.local/share/salix/runtimes
export PYTHONUSERBASE=/home/sprite/.local

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
        if SALIX_CONNECTOR_VERSION="${SALIX_RUNTIME_AGENT_VERSION:-dev}" \
          /usr/local/bin/salix-runtime-agent \
          --runtime-agent \
          --listen "${SALIX_RUNTIME_AGENT_LISTEN:-0.0.0.0:8080}" \
          --root "$SALIX_VM_WORKSPACE" \
          --state-root "$HOME"; then
          echo "Connector exited; restarting" >&2
        else
          echo "Connector unavailable; retrying" >&2
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
