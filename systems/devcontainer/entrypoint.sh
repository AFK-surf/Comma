#!/usr/bin/env bash
set -Eeuo pipefail

dev_user=vscode
dev_uid="$(id -u "${dev_user}")"
dev_gid="$(id -g "${dev_user}")"
owner_marker=/var/lib/comma-dev/.owner
owner="${dev_uid}:${dev_gid}"

install -d -m 0755 /var/lib/comma-dev
install -d -m 0755 \
  /var/lib/comma-dev/cargo-home \
  /var/lib/comma-dev/cargo-target \
  /var/lib/comma-dev/native-cache \
  /var/lib/comma-dev/tool-cache \
  /workspace/Comma/systems/apps/salix_agent/priv/native \
  /workspace/Comma/systems/native/verified_kernel/.lake \
  /workspace/Comma/systems/native/verified_kernel/.native \
  /workspace/Comma/systems/native/verified_kernel/priv

generated_paths=(
  /workspace/Comma/systems/native/verified_kernel/.lake
  /workspace/Comma/systems/native/verified_kernel/.native
  /workspace/Comma/systems/native/verified_kernel/priv
)

if [[ ! -f "${owner_marker}" ]] || [[ "$(<"${owner_marker}")" != "${owner}" ]]; then
  chown -R "${owner}" /var/lib/comma-dev "${generated_paths[@]}"
  find /workspace/Comma/systems/apps/salix_agent/priv -mindepth 1 -maxdepth 1 \
    ! -name model_catalog.json ! -name dynamic_ui -exec chown -R "${owner}" {} +
  printf '%s\n' "${owner}" >"${owner_marker}"
else
  chown "${owner}" /var/lib/comma-dev "${generated_paths[@]}"
fi
chown "${owner}" /workspace/Comma/systems/apps/salix_agent/priv

exec gosu "${dev_user}" "$@"
