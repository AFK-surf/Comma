#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

TLA_TOOLS_VERSION="1.7.4"
TLA_TOOLS_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
TLA_CACHE_DIR="${TLA_CACHE_DIR:-${HOME}/.cache/comma-tla}"
JAR="${TLA_TOOLS_JAR:-${TLA_CACHE_DIR}/tla2tools-${TLA_TOOLS_VERSION}.jar}"

if [ ! -f "$JAR" ]; then
  mkdir -p "$(dirname "$JAR")"
  curl -fsSL --retry 4 --retry-delay 2 \
    -o "${JAR}.tmp" \
    "https://github.com/tlaplus/tlaplus/releases/download/v${TLA_TOOLS_VERSION}/tla2tools.jar"
  echo "${TLA_TOOLS_SHA256}  ${JAR}.tmp" | sha256sum -c - >/dev/null
  mv "${JAR}.tmp" "$JAR"
fi
echo "${TLA_TOOLS_SHA256}  ${JAR}" | sha256sum -c - >/dev/null

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cp ./*.tla ./*.cfg "$workdir/"

manifest='PersonalMeshTrust PersonalMeshTrust_Safety ok
PersonalMeshTrust PersonalMeshTrust_Liveness ok
PersonalMeshTrust PersonalMeshTrust_RevokeLiveness ok
PersonalMeshTrust PersonalMeshTrust_UnsafeRejoin violation
PersonalMeshTrust PersonalMeshTrust_UnsafeRouteReplay violation
PersonalMeshTrust PersonalMeshTrust_UnsafePairingBypass violation'

while read -r spec config expectation; do
  output="$workdir/${config}.out"
  set +e
  (cd "$workdir" && java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
    -deadlock -workers auto -metadir "$workdir/states-$config" \
    -config "$config.cfg" "$spec") >"$output" 2>&1
  code=$?
  set -e
  if [ "$expectation" = ok ]; then
    if [ "$code" -ne 0 ] || ! grep -q 'No error has been found' "$output"; then
      tail -n 60 "$output"
      exit 1
    fi
    printf '  ok         %s\n' "$config"
  elif [ "$code" -eq 12 ] || [ "$code" -eq 13 ]; then
    printf '  violation  %s (expected)\n' "$config"
  else
    tail -n 60 "$output"
    exit 1
  fi
done <<EOF
$manifest
EOF
