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
toolchain="$(tr -d '\r\n' < "$toolchain_file")"
# On Linux, take a leanprover/lean4 release from GitHub over parallel range
# requests and unpack it where elan keeps that toolchain: one connection gets
# a small share of a busy office link, and elan downloads over one.
version="${toolchain#leanprover/lean4:v}"
if [[ "$elan_os" == unknown-linux-gnu && "$toolchain" == leanprover/lean4:v* ]] && command -v zstd >/dev/null; then
  case "$elan_arch" in
    aarch64) asset="lean-$version-linux_aarch64.tar.zst" ;;
    *) asset="lean-$version-linux.tar.zst" ;;
  esac
  url="https://github.com/leanprover/lean4/releases/download/v$version/$asset"
  size="$(curl --fail --silent --location --head "$url" |
    awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')"
  parts=16
  if [[ "$size" -gt 0 ]]; then
    part=$(((size + parts - 1) / parts))
    pids=()
    for ((i = 0; i < parts; i++)); do
      curl --fail --silent --show-error --location --retry 5 \
        --range "$((i * part))-$((i * part + part - 1))" --output "$installer_dir/part-$i" "$url" &
      pids+=("$!")
    done
    complete=1
    for pid in "${pids[@]}"; do wait "$pid" || complete=0; done
    if [[ "$complete" == 1 ]]; then
      for ((i = 0; i < parts; i++)); do cat "$installer_dir/part-$i"; done > "$installer_dir/lean.tar.zst"
      target="$elan_dir/toolchains/$(printf '%s' "$toolchain" | sed 's|/|--|; s|:|---|')"
      if [[ "$(wc -c < "$installer_dir/lean.tar.zst")" -eq "$size" ]] &&
        mkdir -p "$target.partial" &&
        zstd -dc "$installer_dir/lean.tar.zst" | tar -xf - -C "$target.partial" --strip-components=1 &&
        mv "$target.partial" "$target" &&
        "$elan_dir/bin/elan" toolchain list | grep -xF "$toolchain" >/dev/null; then
        exit 0
      fi
      rm -rf "$target" "$target.partial"
    fi
  fi
  echo "Lean $version: parallel download failed; installing through elan"
fi
"$elan_dir/bin/elan" toolchain install "$toolchain"
