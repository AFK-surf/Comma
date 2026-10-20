#!/bin/sh
# The Rust station and this one side by side on copies of the same data (test/prepare.sh), asked the same things by
# a member's client (tools/load), their answers compared field by field. compare.sh <work> <rust station binary>
# Prints each difference and "same N / M"; exits 1 on any difference.
set -u
work=$1 rust=$2
here=$(cd "$(dirname "$0")/.." && pwd)
load=${E2E_LOAD:-$(node "$here/../scripts/native.ts" file station-load)} # prebuilt, or built here (scripts/native.ts)
node=${NODE:-node}
id=$(cat "$work/station-id")
stop() { pkill -f "data $work/" 2>/dev/null; sleep 2; }
udp_port() { lsof -nP -iUDP -a -p "$1" | awk 'NR>1 && $9 ~ /^\*:/ {sub("\\*:","",$9); print $9}' | grep -v 5353 | head -1; }
stop
(cd "$work" && nohup "$rust" run --app "$(dirname "$(dirname "$(dirname "$(dirname "$rust")")")")" --data "$work/rust" > rust.log 2>&1 &)
(cd "$work" && STILLFAIL_NO_DISCOVERY=1 nohup "$node" "$here/src/main.ts" run --app "$here" --data "$work/ts" > ts.log 2>&1 &)
sleep 12
rpid=$(pgrep -f "data $work/rust" | head -1)
tpid=$(pgrep -f "data $work/ts" | head -1)
[ -n "$rpid" ] || { echo "the Rust station is not running"; tail -20 "$work/rust.log"; exit 1; }
[ -n "$tpid" ] || { echo "this station is not running"; tail -20 "$work/ts.log"; exit 1; }
rport=$(udp_port "$rpid")
tport=$(udp_port "$tpid")
ask() { perl -e 'alarm 30; exec @ARGV' "$load" ask "$work/$1" "$id" "127.0.0.1:$2" "$3" > "$4" 2> "$4.head"; }
threads=$(sqlite3 "$work/ts/stillfail.db" "select id from threads order by id desc limit 8" | tr '\n' ' ')
paths="/admin/api/chats /admin/api/chats?archived=1 /admin/api/threads/99999/entries /admin/api/threads/x/entries /admin/api/nothing"
for t in $threads 1 50 100; do
  paths="$paths /admin/api/threads/$t/entries /admin/api/threads/$t/entries?limit=5 /admin/api/threads/$t/entries?after=3 /admin/api/threads/$t/entries?before=10&limit=3 /admin/api/threads/$t/entries?from=2&to=4 /admin/api/threads/$t/entries?from=2"
done
# More from test/paths/*.txt: a path a line, `$THREAD`, `$SESSION` and `$JOB` filled in with ones of the data.
session=$(sqlite3 "$work/ts/stillfail.db" "select key from sessions order by last_active_at desc limit 1")
job=$(sqlite3 "$work/ts/stillfail.db" "select id from jobs order by started_at desc limit 1")
thread=$(sqlite3 "$work/ts/stillfail.db" "select id from threads order by id desc limit 1")
for f in "$here"/test/paths/*.txt; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    line=$(printf '%s' "$line" | sed "s#\$THREAD#$thread#g; s#\$SESSION#$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=''))" "$session")#g; s#\$JOB#$job#g")
    paths="$paths $line"
  done < "$f"
done
n=0; same=0
for p in $paths; do
  ask rust "$rport" "$p" "$work/r.json"; ask ts "$tport" "$p" "$work/t.json"; n=$((n+1))
  if python3 "$here/test/diff.py" "$work/r.json" "$work/t.json" > "$work/d.txt"; then same=$((same+1)); else echo "DIFF $p"; head -6 "$work/d.txt"; fi
done
stop
echo "same $same / $n"
[ "$same" = "$n" ]
