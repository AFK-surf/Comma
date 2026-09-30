#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$harness_dir/../../.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
MIX_ENV=test mix run --no-start --no-compile "$harness_dir/core_test.exs"
MIX_ENV=test mix run --no-start --no-compile "$harness_dir/abi_test.exs"
