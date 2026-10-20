#!/bin/sh
# Two copies of a station's data for comparing the Rust station with this one (test/compare.sh), from a station's
# stillfail.db and archive/threads packed as <tar.gz>: <work>/rust and <work>/ts, the same test workspace (keys of our
# own: station-load setup), still.fail's relays, no agents left to run (a copy must not start the station's agents).
# prepare.sh <tar.gz> <work>
set -eu
tarball=$1 work=$2
here=$(cd "$(dirname "$0")/.." && pwd)
load=${E2E_LOAD:-$(node "$here/../scripts/native.ts" file station-load)} # prebuilt, or built here (scripts/native.ts)
rm -rf "$work" && mkdir -p "$work"
$load setup "$work/rust" > /dev/null
python3 - "$work/rust/mesh/cloud.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["relay_url"] = "https://app.still.fail"
d["relay_urls"] = ["https://app.still.fail", "https://39.105.157.122", "https://47.76.247.168"]
json.dump(d, open(p, "w"), indent=2)
PY
tar xzf "$tarball" -C "$work/rust"
echo '{"profiles":[],"autoUpdate":false}' > "$work/rust/config.json"
sqlite3 "$work/rust/stillfail.db" "
  update jobs set state='exited' where state not in ('exited','stopped','failed');
  delete from processes;
  update deliveries set delivered_at=coalesce(delivered_at,0);
  update sessions set running=0;
  update entries set attachments=null where attachments is not null;
  pragma wal_checkpoint(truncate);"
cp -R "$work/rust" "$work/ts"
python3 -c "import json;print(json.load(open('$work/rust/mesh/cloud.json'))['station'])" > "$work/station-id"
