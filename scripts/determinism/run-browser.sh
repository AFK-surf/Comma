#!/usr/bin/env bash
# Runs browser component tests (clients, Vitest browser project) twice for the
# determinism proof, as they are (base) and with every perturbation at once
# (all: another order, delayed IO, a slowed CPU), and writes one execution
# record per run: <out>/browser-<run>.jsonl. Compare them with
# scripts/determinism/compare.mjs.
#
# The specs that run the web app itself read its shipped build: build it
# first (pnpm --dir clients build:web).
#
#   scripts/determinism/run-browser.sh <out-dir> [test files, relative to clients/]
set -euo pipefail

out=$(cd "${1:?out dir}" && pwd)
shift
files=("$@")
# By default, the whole browser suite.
[ ${#files[@]} -gt 0 ] || files=(e2e/app-shell apps packages)
seed=${DETERMINISM_SEED:-20261009}
cpu=${DETERMINISM_CPU_SLOWDOWN_RATE:-4}
io=${DETERMINISM_IO_DELAY_MAX_MS:-50}

cd "$(dirname "$0")/../../clients"
run() {
  local name=$1
  shift
  rm -f "$out/browser-$name.jsonl"
  echo "== $name"
  env DETERMINISM_RECORD="$out/browser-$name.jsonl" "$@" \
    npx vitest run --project browser "${files[@]}" ${order[@]+"${order[@]}"} >"$out/browser-$name.log" 2>&1 || true
  grep -E "Test Files|Tests  " "$out/browser-$name.log" || tail -5 "$out/browser-$name.log"
}
order=()
run base
order=(--sequence.shuffle --sequence.seed="$seed")
run all DETERMINISM_IO_DELAY_MS="$io" DETERMINISM_CPU_SLOWDOWN="$cpu"
