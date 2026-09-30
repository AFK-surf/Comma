#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export LEAN_NUM_THREADS=1
bash scripts/check-proofs.sh
bash scripts/check-runtime.sh "$@"
