#!/bin/sh
# The AWS CLI as scripts/release-storage.mjs calls it, over a directory of buckets ($FAKE_R2_ROOT/<bucket>/<key>).
# Each call is noted in $FAKE_AWS_LOG as a JSON line {"arguments": [...]} (without --endpoint-url). An upload to
# $FAKE_AWS_SKIP_UPLOAD_KEY succeeds without writing. A shell script, since every upload and check is a process of
# its own: a Node process each costs the release-storage tests seconds on a loaded machine.
if [ "$1" = "--endpoint-url" ]; then shift 2; fi

fail() {
  echo "$1" >&2
  exit 1
}

# The call as a JSON line, built in the shell (no process of its own): the release script passes no quote or backslash.
line=
for value in "$@"; do
  case "$value" in *[\\\"]*) fail "fake aws cannot log an argument with a quote or backslash: $value" ;; esac
  line="$line${line:+,}\"$value\""
done
printf '{"arguments":[%s]}\n' "$line" >> "$FAKE_AWS_LOG"

# remote <value>: bucket, key and path of an s3:// URI; status 1 for anything else.
remote() {
  case "$1" in
    s3://?*) ;;
    *) return 1 ;;
  esac
  rest=${1#s3://}
  bucket=${rest%%/*}
  case "$rest" in
    */*) key=${rest#*/} ;;
    *) key= ;;
  esac
  path="$FAKE_R2_ROOT/$bucket/$key"
}

copy() {
  [ -d "${2%/*}" ] || mkdir -p "${2%/*}" || return 1
  cp "$1" "$2"
}

if [ "$1" = "s3api" ] && [ "$2" = "head-object" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --bucket) bucket=$2 ;;
      --key) key=$2 ;;
    esac
    shift
  done
  [ -e "$FAKE_R2_ROOT/$bucket/$key" ] || fail "not found: $key"
  set -- $(wc -c < "$FAKE_R2_ROOT/$bucket/$key")
  printf '{"ContentLength":%s}' "$1"
  exit 0
fi

if [ "$1" = "s3api" ] && [ "$2" = "list-objects-v2" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --bucket) bucket=$2 ;;
      --prefix) prefix=$2 ;;
    esac
    shift
  done
  objects=
  for file in "$FAKE_R2_ROOT/$bucket/$prefix"*; do
    [ -f "$file" ] || continue
    set -- $(wc -c < "$file")
    objects="$objects${objects:+,}{\"Key\":\"${file#"$FAKE_R2_ROOT/$bucket/"}\",\"Size\":$1}"
  done
  printf '{"Contents":[%s]}' "$objects"
  exit 0
fi

[ "$1" = "s3" ] || fail "unsupported fake aws command"

if [ "$2" = "sync" ]; then
  source=$3
  remote "$4" || fail "unsupported fake aws arguments: $*"
  shift 4
  excluded=/
  while [ $# -gt 0 ]; do
    if [ "$1" = "--exclude" ]; then
      excluded="$excluded$2/"
      shift
    fi
    shift
  done
  for file in "$source"/* "$source"/.[!.]*; do
    [ -f "$file" ] || continue
    name=${file##*/}
    case "$excluded" in *"/$name/"*) continue ;; esac
    [ "$FAKE_AWS_SKIP_UPLOAD_KEY" = "$key/$name" ] && continue
    copy "$file" "$FAKE_R2_ROOT/$bucket/$key/$name" || exit 1
  done
  exit 0
fi

if [ "$2" = "cp" ]; then
  source=$3
  destination=$4
  if remote "$source"; then
    [ -e "$path" ] || fail "not found: $key"
    from=$path
    [ "$destination" = "-" ] && exec cat "$from"
    if remote "$destination"; then
      copy "$from" "$path"
    else
      copy "$from" "$destination"
    fi
    exit $?
  fi
  if remote "$destination"; then
    [ "$FAKE_AWS_SKIP_UPLOAD_KEY" = "$key" ] || copy "$source" "$path" || exit 1
    exit 0
  fi
fi

fail "unsupported fake aws arguments: $*"
