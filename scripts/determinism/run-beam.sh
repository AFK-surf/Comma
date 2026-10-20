#!/usr/bin/env bash
# Runs the BEAM test files of the determinism manifest five times, each under
# one perturbation, and writes each run's execution records (SystemsSim.Record)
# to OUT_DIR/beam-<perturbation>.jsonl:
#
#   base      the files as they are, ExUnit seed 0
#   shuffle   another ExUnit seed: other module and test order
#   io_delay  Postgres and Redis behind a proxy that delays every chunk
#   cpu_slow  one online BEAM scheduler, beside busy loops on half the CPUs
#   all       the three together
#
# A file joins the manifest once these five runs agree (scripts/determinism/
# compare.mjs); CI then runs it once, as any other test.
#
# NEIGHBORS, a space-separated list of other BEAM test files (relative to
# systems/), runs in the same VM in every run, so a file is proven beside
# ordinary tests that run before and after it.
#
# Usage: scripts/determinism/run-beam.sh MANIFEST OUT_DIR
# Postgres listens on PG_PORT (5432) and Redis on REDIS_PORT (6379).
set -uo pipefail

manifest=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$(mkdir -p "$2" && cd "$2" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
pg_port=${PG_PORT:-5432}
redis_port=${REDIS_PORT:-6379}

files=()
while IFS= read -r file; do files+=("$file"); done < <(grep -v '^\s*#' "$manifest" | grep '^systems/' | sed 's#^systems/##')
if [ ${#files[@]} -eq 0 ]; then
  echo "no BEAM files in $manifest"
  exit 0
fi

cd "$here/../../systems" || exit 2

start_proxy() {
  python3 "$here/latency_proxy.py" 15432 "127.0.0.1:$pg_port" 1 20 16379 "127.0.0.1:$redis_port" 2 20 &
  proxy=$!
  for port in 15432 16379; do
    until (: >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
      kill -0 "$proxy" 2>/dev/null || { echo "latency proxy did not start"; exit 1; }
      sleep 0.1
    done
  done
}

start_spinners() {
  spinners=()
  for _ in $(seq 1 $(($(getconf _NPROCESSORS_ONLN) / 2))); do
    (while :; do :; done) &
    spinners+=($!)
  done
}

run() {
  local name=$1 seed=$2
  shift 2
  rm -f "$out/beam-$name.jsonl"
  echo "::group::beam $name"
  env DETERMINISM_RECORD="$out/beam-$name.jsonl" "$@" \
    mix test --no-compile "${files[@]}" ${NEIGHBORS:-} --seed "$seed" --exclude live_llm \
    --formatter ExUnit.CLIFormatter --formatter SystemsSim.Record
  echo "::endgroup::"
}

delayed=(ALERT_ROUTER_TEST_DB_PORT=15432 SALIX_TEST_DB_PORT=15432 COMMA_TEST_DB_PORT=15432
  BILLING_TEST_DB_PORT=15432 BRIDGE_TEST_DB_PORT=15432
  REDIS_TEST_URL=redis://127.0.0.1:16379/3 REDIS_URL=redis://127.0.0.1:16379/4
  COMMA_TEST_REDIS_URL=redis://127.0.0.1:16379/5)
# Four schedulers, one of them online: a VM with a single scheduler orders
# the keys of ETS tables with write concurrency differently (SystemsSim).
slow=(ELIXIR_ERL_OPTIONS="+S 4:1")

run base 0
run shuffle 4099
start_proxy
run io_delay 0 "${delayed[@]}"
start_spinners
run all 7919 "${delayed[@]}" "${slow[@]}"
kill "$proxy" 2>/dev/null
run cpu_slow 0 "${slow[@]}"
kill "${spinners[@]}" 2>/dev/null
wait 2>/dev/null
exit 0
