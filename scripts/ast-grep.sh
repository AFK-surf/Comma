#!/bin/sh
# Runs the pinned ast-grep release, downloading it on first use into
# ${XDG_CACHE_HOME:-~/.cache}/cue-ast-grep. An `ast-grep` of the same version
# on PATH (for example from `brew install ast-grep`) is used instead.
set -eu
version=0.45.3

if command -v ast-grep >/dev/null 2>&1 &&
  [ "$(ast-grep --version 2>/dev/null)" = "ast-grep $version" ]; then
  exec ast-grep "$@"
fi

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) target=aarch64-apple-darwin sum=6d2279dea5bea2ad79c66ea93f5fe54ba926e398a8a26de76c56db68fe59eac6 ;;
  Linux/x86_64) target=x86_64-unknown-linux-gnu sum=f8ac830881339d1edee6b2652f54798c0f4da5a827f2db38a08ee31117783ce8 ;;
  *)
    echo "ast-grep.sh: no pinned ast-grep $version for $(uname -s)/$(uname -m); install it on PATH." >&2
    exit 3
    ;;
esac

dir="${XDG_CACHE_HOME:-$HOME/.cache}/cue-ast-grep/$version-$target"
if [ ! -x "$dir/ast-grep" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/ast-grep.zip" \
    "https://github.com/ast-grep/ast-grep/releases/download/$version/app-$target.zip"
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/ast-grep.zip" | cut -d' ' -f1)
  else
    actual=$(shasum -a 256 "$tmp/ast-grep.zip" | cut -d' ' -f1)
  fi
  if [ "$actual" != "$sum" ]; then
    echo "ast-grep.sh: checksum mismatch for app-$target.zip" >&2
    exit 1
  fi
  unzip -q -o "$tmp/ast-grep.zip" ast-grep -d "$tmp"
  mkdir -p "$dir"
  mv "$tmp/ast-grep" "$dir/ast-grep"
fi
exec "$dir/ast-grep" "$@"
