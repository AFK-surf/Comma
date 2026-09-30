#!/usr/bin/env bash
set -Eeuo pipefail

dev_user=vscode
dev_uid="$(id -u "${dev_user}")"
dev_gid="$(id -g "${dev_user}")"
owner_marker=/var/lib/comma-dev/.owner
owner="${dev_uid}:${dev_gid}"

install -d -m 0755 /var/lib/comma-dev
install -d -m 0755 /workspace/Comma/systems/apps/salix_agent/priv

if [[ ! -f "${owner_marker}" ]] || [[ "$(<"${owner_marker}")" != "${owner}" ]]; then
  chown -R "${owner}" /var/lib/comma-dev /workspace/Comma/systems/apps/salix_agent/priv
  printf '%s\n' "${owner}" >"${owner_marker}"
else
  chown "${owner}" /var/lib/comma-dev /workspace/Comma/systems/apps/salix_agent/priv
fi

exec gosu "${dev_user}" "$@"
