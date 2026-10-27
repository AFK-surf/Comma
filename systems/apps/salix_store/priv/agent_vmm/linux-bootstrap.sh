#!/bin/sh
# Stage 1 of the Linux Compute Host install command. This script has no secret.
# The command gives the install token as the only argument. This script sends
# the token in a POST body, never in a URL, and runs the returned stage 2 script.
# The whole body is in main, so a truncated download runs nothing.
main() {
  umask 077

  if [ "$#" -ne 1 ]; then
    printf '%s\n' 'Give the install token from Compute settings as the only argument.' >&2
    exit 2
  fi

  token=$1
  # The token is <operation_id>.<one_time_secret>: two non-empty parts of
  # [A-Za-z0-9_-] with one dot between them.
  case "$token" in
    *[!A-Za-z0-9_.-]*|*.*.*|.*|*.) token_valid=0 ;;
    *.*) token_valid=1 ;;
    *) token_valid=0 ;;
  esac
  if [ "$token_valid" != 1 ]; then
    printf '%s\n' 'The install token is not valid. Copy the command again from Compute settings.' >&2
    exit 2
  fi

  operation_id=${token%%.*}
  secret=${token#*.}

  work=$(mktemp -d) || exit 1
  trap 'rm -rf "$work"' EXIT
  trap 'exit 1' HUP INT TERM
  script="$work/install.sh"

  status=0
  printf '{"operation_id":"%s","one_time_secret":"%s"}' "$operation_id" "$secret" |
    curl --fail --silent --show-error --connect-timeout 30 --max-time 60 \
      --header 'content-type: application/json' --data-binary @- \
      @STAGE2_URL@ > "$script" || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' 'The install script download failed. Run the same command again.' >&2
    exit "$status"
  fi

  status=0
  sh "$script" || status=$?
  exit "$status"
}

main "$@"
