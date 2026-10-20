#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ -e .upstream ]; then
  echo 'The local fork already exists at .upstream. Existing changes were preserved.'
  exit 0
fi
# Only the pinned commit: a full clone moves the whole history, which a slow
# link drops partway through.
git init -q .upstream
git -C .upstream remote add origin https://github.com/router-for-me/CLIProxyAPI.git
git -C .upstream fetch --depth 1 origin d33f63f8e3d98428440ebca5a5b6a981a61ff71e
git -C .upstream switch --detach FETCH_HEAD
git -C .upstream switch -c codex/salix-embedded-runtime
git -C .upstream apply ../patches/embedded-sdk.patch
