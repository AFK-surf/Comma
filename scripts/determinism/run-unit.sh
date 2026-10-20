#!/usr/bin/env bash
# Runs the client unit tests (Vitest projects node, jsdom and jsdom-shared:
# every unit test file outside determinism/unit-real-io.txt) twice and writes each run's
# execution records (clients/packages/test-utils/src/unit-record.ts) to
# <out>/unit-<run>.jsonl. Compare them with scripts/determinism/compare.mjs.
#
#   base  the suite as it is
#   all   every perturbation at once: another order of files and tests
#         (Vitest's sequence seed), beside busy loops on half the CPUs. The
#         suite does no real IO (the IO guard fails it): there is none to delay.
#
#   scripts/determinism/run-unit.sh <out-dir>
set -uo pipefail

out=$(mkdir -p "${1:?out dir}" && cd "$1" && pwd)
node "$(dirname "$0")/check-unit-record.mjs" "$out/control" || exit 1
seed=${DETERMINISM_SEED:-20261010}
cd "$(dirname "$0")/../../clients" || exit 2

spinners=()
start_spinners() {
  for _ in $(seq 1 $(($(getconf _NPROCESSORS_ONLN) / 2))); do
    (while :; do :; done) &
    spinners+=($!)
  done
}
stop_spinners() {
  if [ "${spinners[*]:-}" ]; then
    kill "${spinners[@]}" 2>/dev/null
    wait "${spinners[@]}" 2>/dev/null
  fi
}
trap stop_spinners EXIT

run() {
  local name=$1
  shift
  rm -f "$out/unit-$name.jsonl"
  echo "== $name"
  DETERMINISM_RECORD="$out/unit-$name.jsonl" npx vitest run --project node --project jsdom --project jsdom-shared "$@" \
    >"$out/unit-$name.log" 2>&1
  local status=$?
  grep -E "Test Files|Tests  " "$out/unit-$name.log"
  return "$status"
}

# A failing test is recorded as failed: the comparison reports it, and the
# second run still runs.
run base
start_spinners
run all --sequence.shuffle --sequence.seed="$seed"
