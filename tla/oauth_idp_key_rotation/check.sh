#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

TLA_TOOLS_VERSION="1.7.4"
TLA_TOOLS_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
CACHE_DIR="${TLA_CACHE_DIR:-${HOME}/.cache/comma-tla}"
JAR="${TLA_TOOLS_JAR:-${CACHE_DIR}/tla2tools-${TLA_TOOLS_VERSION}.jar}"

if [ ! -f "$JAR" ]; then
  mkdir -p "$(dirname "$JAR")"
  curl -fsSL --retry 4 --retry-delay 2 \
    -o "${JAR}.tmp" \
    "https://github.com/tlaplus/tlaplus/releases/download/v${TLA_TOOLS_VERSION}/tla2tools.jar"
  echo "${TLA_TOOLS_SHA256}  ${JAR}.tmp" | sha256sum -c - >/dev/null
  mv "${JAR}.tmp" "$JAR"
fi

echo "${TLA_TOOLS_SHA256}  ${JAR}" | sha256sum -c - >/dev/null
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
workers="${TLA_WORKERS:-auto}"

run() {
  local cfg="$1" expected="$2" module="$3" code=0
  java -cp "$JAR" tlc2.TLC -deadlock -workers "$workers" -metadir "$tmp/$cfg" \
    -config "$cfg.cfg" "$module" >"$tmp/$cfg.out" 2>&1 || code=$?
  if [ "$expected" = ok ] && [ "$code" -eq 0 ]; then
    printf '  ok         %s\n' "$cfg"
  elif [ "$expected" = violation ] && { [ "$code" -eq 12 ] || [ "$code" -eq 13 ]; }; then
    printf '  violation  %s (expected)\n' "$cfg"
  else
    tail -n 40 "$tmp/$cfg.out"
    return 1
  fi
}

run OauthIdpRoutineRotation_Safety ok OauthIdpRoutineRotation
run OauthIdpRoutineRotation_UnsafeImmediateActivate violation OauthIdpRoutineRotation
run OauthIdpRoutineRotation_UnsafeEqualWait violation OauthIdpRoutineRotation
