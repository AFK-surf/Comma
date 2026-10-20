#!/bin/sh
# End to end under the launcher, with the runner and the fake claude (test/fake), asked over the mesh as a member's
# client asks (tools/load): a chat is made, a message starts a turn, and while it runs the station hands over to a new
# process (SIGUSR2, as an update does). The turn goes on under the new process: the agent's chat_post reaches it through
# the agents' door, and the turn ends all_done. The launcher's pid stays the same throughout.
# e2e.sh <work>   (the bundle built: pnpm run build; the native parts prebuilt: scripts/native.ts)
set -eu
work=$1
here=$(cd "$(dirname "$0")/.." && pwd)
native() { node "$here/../scripts/native.ts" file "$1"; } # prebuilt, or built here (scripts/native.ts)
load=${E2E_LOAD:-$(native station-load)}
# E2E_APP: a release (scripts/station-bundle.sh) instead of this checkout: its launcher, its
# Node, its runner and mesh addon, as an installed station runs them.
rm -rf "$work" && mkdir -p "$work/data/homes/cc"
if [ -n "${E2E_APP:-}" ]; then
  app=$E2E_APP
  # A release names its Node (NODE_VERSION) rather than carrying it (cloud/src/install.ts links it at node/): this one's.
  export PATH="$here/test/fake:$PATH" STILLFAIL_NO_DISCOVERY=1 STILLFAIL_NODE=${STILLFAIL_NODE:-$(command -v node)}
else
  app=$work/app
  mkdir -p "$app/node/bin"
  ln -s "$here/dist" "$app/station"
  ln -s "$(command -v node)" "$app/node/bin/node"
  export PATH="$here/test/fake:$PATH" STILLFAIL_NO_DISCOVERY=1
  export STILLFAIL_MESH_NATIVE=${STILLFAIL_MESH_NATIVE:-$(native mesh)}
  export STILLFAIL_RUNNER=${STILLFAIL_RUNNER:-$(native runner)}
fi
launch=${E2E_APP:+$app/mesh/target/release/stillfail-station}
launch=${launch:-${STILLFAIL_LAUNCHER:-$(native launcher)}}
id=$("$load" setup "$work/data")
echo '{"profiles":[{"id":"cc","runtime":"claude","home":"homes/cc"}],"autoUpdate":false}' > "$work/data/config.json"
echo '{}' > "$work/data/homes/cc/.credentials.json"
"$launch" run --app "$app" --data "$work/data" > "$work/station.log" 2>&1 &
launcher=$!
trap 'kill $launcher 2>/dev/null; sleep 3; pkill -f "$work/data" 2>/dev/null || true' EXIT
node_pid() { pgrep -f "station/main.js run .*$work/data" | head -1; }
udp_port() { lsof -nP -iUDP -a -p "$1" | awk 'NR>1 && $9 ~ /^\*:/ {sub("\\*:","",$9); print $9}' | grep -v 5353 | head -1; }
sleep 5
first=$(node_pid)
port=$(udp_port "$first")
ask() { "$load" send "$work/data" "$id" "127.0.0.1:$port" "$@" 2>/dev/null; }
made=$(ask POST /admin/api/sessions '{"runtime":"claude"}')
key=$(echo "$made" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
thread=$(echo "$made" | python3 -c 'import json,sys; print(json.load(sys.stdin)["thread"]["id"])')
echo "made $key in thread $thread"
ask POST "/admin/api/threads/$thread/messages" '{"text":"slow:60 post:said after the handover"}'
sleep 2
echo "turn running: $(sqlite3 "$work/data/stillfail.db" "select running from sessions where key='$key'")"
kill -USR2 $launcher
for i in $(seq 1 100); do
  second=$(node_pid)
  [ -n "$second" ] && [ "$second" != "$first" ] && ! kill -0 "$first" 2>/dev/null && break
  sleep 0.2
done
echo "handed over: node $first -> $second, launcher $launcher alive: $(kill -0 $launcher && echo yes)"
for i in $(seq 1 150); do
  ended=$(sqlite3 "$work/data/stillfail.db" "select count(*) from turns where session_key='$key' and ended_at is not null")
  [ "$ended" -ge 1 ] && break
  sleep 0.2
done
# Then a crash in the middle of a turn: the launcher starts Node again, which takes the turn up from its runner.
port=$(udp_port "$second")
ask POST "/admin/api/threads/$thread/messages" '{"text":"slow:60 post:said after a crash"}'
sleep 2
kill -9 "$second"
for i in $(seq 1 100); do
  third=$(node_pid)
  [ -n "$third" ] && [ "$third" != "$second" ] && break
  sleep 0.2
done
echo "crashed: node $second -> $third, launcher $launcher alive: $(kill -0 $launcher && echo yes)"
for i in $(seq 1 200); do
  ended=$(sqlite3 "$work/data/stillfail.db" "select count(*) from turns where session_key='$key' and ended_at is not null")
  [ "$ended" -ge 2 ] && break
  sleep 0.2
done
echo "turns: $(sqlite3 "$work/data/stillfail.db" "select outcome || '/' || coalesce(declared,'-') from turns where session_key='$key'" | tr '\n' ' ')"
echo "chat:"
sqlite3 "$work/data/stillfail.db" "select '  ' || author_kind || ': ' || text from entries where thread=$thread order by n"
grep -E "ERROR|WARN" "$work/station.log" | grep -v presence || true
