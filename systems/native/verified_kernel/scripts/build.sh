#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export LEAN_NUM_THREADS=1
lake build VerifiedKernel.Native
lean_prefix="$(lean --print-prefix)"
erts_include="$(erl +S 1:1 -noshell -eval 'io:format("~s/usr/include", [code:root_dir()]), halt().')"
cmake -S . -B .native -DCMAKE_BUILD_TYPE=Release \
  -DLEAN_PREFIX="$lean_prefix" -DERTS_INCLUDE="$erts_include" "$@"
cmake --build .native --parallel 2
case "$(uname -s)" in
  Darwin) otool -L priv/verified_kernel.so ;;
  Linux) readelf -d priv/verified_kernel.so | grep NEEDED ;;
esac
