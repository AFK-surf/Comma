#!/usr/bin/env bash
# Runs one shard of a Go package's top-level tests.
#
#   scripts/ci/go_test_shard.sh INDEX COUNT PACKAGE_DIR [go test flags...]
#
# Lists the package's tests, deals the sorted names round-robin into COUNT
# shards and runs shard INDEX (1-based) with -run. Every test runs in exactly
# one shard, and subtests stay with their parent.
set -euo pipefail
index="${1:?shard index}"
count="${2:?shard count}"
dir="${3:?package directory}"
shift 3

names="$(go test -C "$dir" -list '.*' . | grep -E '^(Test|Example|Fuzz)' | sort)"
shard="$(printf '%s\n' "$names" | awk -v i="$index" -v n="$count" '(NR - 1) % n == i - 1' | paste -sd '|' -)"
if [ -z "$shard" ]; then
  echo "shard $index/$count of $dir is empty" >&2
  exit 1
fi
go test -C "$dir" "$@" -run "^(${shard})\$" .
