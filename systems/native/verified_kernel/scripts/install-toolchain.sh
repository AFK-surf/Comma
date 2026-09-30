#!/usr/bin/env bash
set -euo pipefail
toolchain_file="${1:?Pass the lean-toolchain file}"
installer_dir="$(mktemp -d)"
trap 'rm -rf -- "$installer_dir"' EXIT
case "$(uname -m)" in
  x86_64) elan_arch=x86_64 ;;
  aarch64|arm64) elan_arch=aarch64 ;;
  *) echo 'Unsupported Lean build architecture' >&2; exit 1 ;;
esac
case "$(uname -s)" in
  Linux) elan_os=unknown-linux-gnu ;;
  Darwin) elan_os=apple-darwin ;;
  *) echo 'Unsupported Lean build operating system' >&2; exit 1 ;;
esac
curl --fail --location --retry 3 \
  "https://github.com/leanprover/elan/releases/download/v4.2.4/elan-${elan_arch}-${elan_os}.tar.gz" \
  --output "$installer_dir/elan.tar.gz"
tar -xzf "$installer_dir/elan.tar.gz" -C "$installer_dir"
"$installer_dir/elan-init" -y --no-modify-path --default-toolchain none
elan_dir="${ELAN_HOME:-$HOME/.elan}"
"$elan_dir/bin/elan" toolchain install "$(tr -d '\r\n' < "$toolchain_file")"
