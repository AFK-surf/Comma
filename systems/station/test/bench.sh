#!/bin/sh
# Each station alone on the same data (test/prepare.sh), fresh, under the same load from one member's client: its
# memory idle, at the peak and after, and how the requests went. bench.sh <work> <rust station binary> [seconds] [concurrency]
set -u
work=$1 rust=$2 secs=${3:-30} conc=${4:-8}
here=$(cd "$(dirname "$0")/.." && pwd)
load=${E2E_LOAD:-$(node "$here/../scripts/native.ts" file station-load)} # prebuilt, or built here (scripts/native.ts)
node=${NODE:-node}
NODE_ARGS=${NODE_ARGS:-}
id=$(cat "$work/station-id")
threads=$(sqlite3 "$work/ts/stillfail.db" "select id from threads order by id desc limit 8" | tr '\n' ' ')
paths="/admin/api/chats /admin/api/chats?archived=1"
for t in $threads; do paths="$paths /admin/api/threads/$t/entries"; done
stop() { pkill -f "data $work/" 2>/dev/null; sleep 2; }
# What macOS counts as the process's memory (Activity Monitor's): RSS also counts pages shared with every other process
# (Node's and the system's code), which says little about what the station itself costs. MB.
footprint() { vmmap --summary "$1" 2>/dev/null | awk '/^Physical footprint:/ {v=$3; u=substr(v, length(v)); n=v+0; if (u=="K") n/=1024; if (u=="G") n*=1024; printf "%d", n}'; }
udp_port() { lsof -nP -iUDP -a -p "$1" | awk 'NR>1 && $9 ~ /^\*:/ {sub("\\*:","",$9); print $9}' | grep -v 5353 | head -1; }
measure() { # measure <name> <data dir name> <command…>
  name=$1 dir=$2; shift 2
  stop
  (cd "$work" && nohup "$@" > "$name.log" 2>&1 &)
  sleep 15
  pid=$(pgrep -f "data $work/$dir" | head -1)
  [ -n "$pid" ] || { echo "$name is not running"; tail -5 "$work/$name.log"; return; }
  port=$(udp_port "$pid")
  idle=$(ps -o rss= -p "$pid"); peak=$idle
  fidle=$(footprint "$pid"); fpeak=$fidle
  "$load" load "$work/$dir" "$id" "127.0.0.1:$port" "$secs" "$conc" $paths > "$work/load-$name.json" 2>&1 &
  lp=$!
  while kill -0 $lp 2>/dev/null; do r=$(ps -o rss= -p "$pid"); [ "$r" -gt "$peak" ] && peak=$r; f=$(footprint "$pid"); [ "${f:-0}" -gt "$fpeak" ] && fpeak=$f; done
  sleep 2
  after=$(ps -o rss= -p "$pid"); fafter=$(footprint "$pid")
  # And once it has had nothing to do for a while (readers let go after a minute).
  sleep ${LATER:-70}
  later=$(ps -o rss= -p "$pid"); flater=$(footprint "$pid")
  echo "{\"station\":\"$name\",\"footprint\":{\"idle\":$fidle,\"peak\":$fpeak,\"after\":$fafter,\"later\":$flater},\"rss\":{\"idle\":$((idle/1024)),\"peak\":$((peak/1024)),\"after\":$((after/1024)),\"later\":$((later/1024))},\"load\":$(cat "$work/load-$name.json")}"
}
measure rust rust "$rust" run --app "$(dirname "$(dirname "$(dirname "$(dirname "$rust")")")")" --data "$work/rust"
# ENTRY=dist/main.js measures the bundle (STILLFAIL_MESH_NATIVE then says where the addon is).
measure ts ts "$node" $NODE_ARGS "$here/${ENTRY:-src/main.ts}" run --app "$here" --data "$work/ts"
stop
