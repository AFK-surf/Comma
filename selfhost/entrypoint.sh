#!/bin/sh
set -eu
export RELEASE_COOKIE="$(cat /config/release-cookie)"
case "$COMMA_PUBLIC_URL" in
  http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) export COMMA_SESSION_COOKIE_SECURE=false ;;
  *) export COMMA_SESSION_COOKIE_SECURE=true ;;
esac
exec bin/comma "$@"
