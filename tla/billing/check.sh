#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

TLA_TOOLS_VERSION="1.7.4"
TLA_TOOLS_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA_TOOLS_VERSION}/tla2tools.jar"
TLA_TOOLS_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
CACHE_DIR="${TLA_CACHE_DIR:-${HOME}/.cache/comma-tla}"
JAR="${TLA_TOOLS_JAR:-${CACHE_DIR}/tla2tools-${TLA_TOOLS_VERSION}.jar}"

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

if [ ! -f "$JAR" ]; then
  mkdir -p "$(dirname "$JAR")"
  curl -fsSL --retry 4 --retry-delay 2 -o "${JAR}.tmp" "$TLA_TOOLS_URL"
  [ "$(checksum "${JAR}.tmp")" = "$TLA_TOOLS_SHA256" ] || { rm -f "${JAR}.tmp"; exit 1; }
  mv "${JAR}.tmp" "$JAR"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp ./*.tla ./*.cfg "$work/"

run() {
  cfg="$1"
  expected="$2"
  module="${3:-StripeCredits}"
  set +e
  (cd "$work" && java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -deadlock -workers 1 -config "$cfg.cfg" "$module") >"$work/$cfg.out" 2>&1
  code=$?
  set -e
  if [ "$expected" = ok ] && [ "$code" -eq 0 ] && grep -q "No error has been found" "$work/$cfg.out"; then
    printf '  ok         %s\n' "$cfg"
  elif [ "$expected" = violation ] && { [ "$code" -eq 12 ] || [ "$code" -eq 13 ]; }; then
    printf '  violation  %s (expected)\n' "$cfg"
  else
    tail -n 80 "$work/$cfg.out"
    exit 1
  fi
}

run StripeCredits_Safety ok
run StripeCredits_UnsafeUnpaidGrant violation

run WebhookJournal_Safety ok WebhookJournal
run WebhookJournal_UnsafeAck violation WebhookJournal
run SubscriptionReconcile_Safety ok SubscriptionReconcile
run SubscriptionReconcile_UnsafeOrder violation SubscriptionReconcile
