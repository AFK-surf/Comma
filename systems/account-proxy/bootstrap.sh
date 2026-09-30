#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ -e .upstream ]; then
  echo 'The local fork already exists at .upstream. Existing changes were preserved.'
  exit 0
fi
git clone https://github.com/router-for-me/CLIProxyAPI.git .upstream
git -C .upstream switch --detach d33f63f8e3d98428440ebca5a5b6a981a61ff71e
git -C .upstream switch -c codex/salix-embedded-runtime
git -C .upstream apply ../patches/embedded-sdk.patch
