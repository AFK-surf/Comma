#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export LEAN_NUM_THREADS=1
bash scripts/build.sh "$@"
mix format --check-formatted mix.exs 'lib/*.ex' 'test/*.exs'
mix test
case "$(uname -s)" in
  Darwin)
    dependencies="$(otool -L priv/verified_kernel.so | tail -n +2)"
    exports="$(nm -gUj priv/verified_kernel.so | sed 's/^_//')"
    ;;
  Linux)
    dependencies="$(ldd priv/verified_kernel.so)"
    exports="$(nm -D --defined-only priv/verified_kernel.so | awk '{print $3}')"
    ;;
esac
printf '%s\n' "$dependencies"
if printf '%s\n' "$dependencies" | grep -Eiq 'lean|libInit|libLake|not found'; then
  echo 'The NIF has an unresolved or Lean dynamic dependency.' >&2
  exit 1
fi
if [ "$exports" != nif_init ]; then
  echo 'The NIF exports symbols other than nif_init.' >&2
  exit 1
fi
