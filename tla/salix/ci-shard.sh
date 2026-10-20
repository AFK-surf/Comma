#!/usr/bin/env bash
# Four shards: all configs round-robin over four.
# CI runs each shard on its own runner.
# The check.sh manifest remains the only coverage roster, including new configs.
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in
  1|2|3|4) shard="$1" ;;
  *) echo "usage: $0 <1|2|3|4> [--list]" >&2; exit 2 ;;
esac
case "${2:-}" in
  ""|--list) ;;
  *) echo "unknown option: $2" >&2; exit 2 ;;
esac
roster="$(./check.sh --list)"
configs=()
index=0
while read -r cfg; do
  [[ -n "$cfg" ]] || continue
  owner=$((index % 4 + 1))
  index=$((index + 1))
  if [[ "$owner" == "$shard" ]]; then configs+=("$cfg"); fi
done <<< "$roster"
if [[ ${#configs[@]} -eq 0 ]]; then
  echo "empty TLA shard $shard" >&2
  exit 1
fi
if [[ "${2:-}" == --list ]]; then
  printf '%s\n' "${configs[@]}"
else
  exec ./check.sh "${configs[@]}"
fi
