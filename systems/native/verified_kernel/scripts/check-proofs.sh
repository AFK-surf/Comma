#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-1}"
lake build VerifiedKernel VerifiedKernelProofs
lake env lean -j1 -M4096 --run scripts/audit-axioms.lean
