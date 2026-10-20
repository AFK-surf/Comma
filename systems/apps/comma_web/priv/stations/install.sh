#!/bin/sh
# Installs the still.fail station on this machine and enrolls it in a Comma Workspace:
#   curl -fsSL __ORIGIN__/stations/install.sh | sh -s -- <token>
# The token comes from "Add station" in Comma (single use, one hour). Without a token, a station that is
# already enrolled is updated in place and keeps its data (~/.stillfail).
# Served by Comma (CommaWeb.StationEndpoints); mirrors still.fail's cloud/src/install.ts: the release is the one
# Comma's manifest pins, Node comes from __RELEASES__, the station runs as a user service (launchd, or systemd
# --user with lingering), and an update
# hands over to the new release (SIGUSR2) or drains and restarts (SIGUSR1) so running turns are not cut off.
set -eu
origin="__ORIGIN__"
releases="__RELEASES__"
token="${1:-}"
data="${STILLFAIL_DATA:-$HOME/.stillfail}"
# Where the update is, for the station to show (download, handoff, drain, restart).
step() { [ -d "$data/run" ] && printf '%s\n' "$1" > "$data/run/update.step" 2>/dev/null || true; }
if [ -z "$token" ] && [ ! -f "$data/mesh/cloud.json" ]; then
  echo "usage: curl -fsSL $origin/stations/install.sh | sh -s -- <token>" >&2
  echo "Get a token from \"Add station\" in Comma. Without one, only an enrolled station is updated." >&2
  exit 2
fi
# A station enrolled elsewhere (still.fail cloud, or another Comma) is left alone: updating it from here would
# replace its release with Comma's, and enrolling it would move it out of its workspace. Moving it needs
# --move-station after the token. A cloud.json without a provider is a still.fail one.
cloud="$data/mesh/cloud.json"
if [ -f "$cloud" ]; then
  enrolled_provider=$(sed -n 's/.*"provider" *: *"\([^"]*\)".*/\1/p' "$cloud" | head -1)
  enrolled_origin=$(sed -n 's/.*"origin" *: *"\([^"]*\)".*/\1/p' "$cloud" | head -1)
  if [ "${enrolled_provider:-stillfail}" != comma ] || [ "$enrolled_origin" != "$origin" ]; then
    if [ -z "$token" ]; then
      echo "The station in $data is enrolled with ${enrolled_provider:-stillfail} at ${enrolled_origin:-an unknown origin}, not this Comma ($origin)." >&2
      echo "Update it from where it is enrolled. Nothing was changed." >&2
      exit 3
    fi
    if [ "${2:-}" != "--move-station" ]; then
      echo "The station in $data is enrolled with ${enrolled_provider:-stillfail} at ${enrolled_origin:-an unknown origin}." >&2
      echo "Enrolling it here moves it to Comma and replaces its release. To do that, run:" >&2
      echo "  curl -fsSL $origin/stations/install.sh | sh -s -- $token --move-station" >&2
      echo "Nothing was changed." >&2
      exit 3
    fi
  fi
fi
os=$(uname -s)
# The release Comma pins (/stations/releases/station.json), written in when this script was served: the bundle of
# each platform, its sha256 when the manifest gives one, and the commit the bundle must be built from.
release_version="__VERSION__"
release_commit="__COMMIT__"
case "$os-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64; artifact="__URL_DARWIN_ARM64__"; artifact_sha="__SHA_DARWIN_ARM64__" ;;
  Linux-x86_64) platform=linux-x64; artifact="__URL_LINUX_X64__"; artifact_sha="__SHA_LINUX_X64__" ;;
  Linux-aarch64|Linux-arm64) platform=linux-arm64; artifact="__URL_LINUX_ARM64__"; artifact_sha="__SHA_LINUX_ARM64__" ;;
  *) echo "This machine is not supported: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
app="$data/app"
label="fail.still.station"
plist="$HOME/Library/LaunchAgents/$label.plist"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit="stillfail-station.service"
user_systemd() { command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading the still.fail station $release_version..."
step download
curl -fL --progress-bar "$artifact" -o "$tmp/stillfail.tar.gz"
if [ -n "$artifact_sha" ]; then
  got=$({ shasum -a 256 "$tmp/stillfail.tar.gz" 2>/dev/null || sha256sum "$tmp/stillfail.tar.gz"; } | cut -d' ' -f1)
  if [ "$got" != "$artifact_sha" ]; then
    echo "The station download does not match the sha256 Comma pins for $release_version. Nothing was changed." >&2
    exit 1
  fi
fi
tar -xzf "$tmp/stillfail.tar.gz" -C "$tmp"
if [ -n "$release_commit" ] && [ "$(cat "$tmp/stillfail/VERSION" 2>/dev/null)" != "$release_commit" ]; then
  echo "The station at $artifact is not the release Comma pins ($release_version). Nothing was changed." >&2
  exit 1
fi
printf '%s\n' stable > "$tmp/stillfail/CHANNEL"

# The Node the release runs on (NODE_VERSION) is kept apart in <data>/node/v<version>, once per version, and linked
# at <app>/node. The machine's own Node is used when it is exactly that version; else it is downloaded and checked.
node_dir=""
if [ -f "$tmp/stillfail/NODE_VERSION" ]; then
  node_version=$(cat "$tmp/stillfail/NODE_VERSION")
  node_dir="$data/node/v$node_version"
  if [ ! -x "$node_dir/bin/node" ]; then
    rm -rf "$node_dir.part"
    mkdir -p "$node_dir.part/bin"
    own=$(command -v node 2>/dev/null || true)
    if [ -n "$own" ] && [ "$("$own" -v 2>/dev/null)" = "v$node_version" ]; then
      cp "$own" "$node_dir.part/bin/node"
    else
      node_file="node-v$node_version-$platform.tar.gz"
      echo "Downloading Node $node_version..."
      if ! curl -fL --progress-bar "$releases/node/$node_file" -o "$tmp/$node_file" || ! curl -fsSL "$releases/node/$node_file.sha256" -o "$tmp/$node_file.sha256"; then
        echo "Node $node_version could not be downloaded from $releases." >&2
        exit 1
      fi
      want=$(cut -d' ' -f1 < "$tmp/$node_file.sha256")
      got=$({ shasum -a 256 "$tmp/$node_file" 2>/dev/null || sha256sum "$tmp/$node_file"; } | cut -d' ' -f1)
      if [ -z "$want" ] || [ "$want" != "$got" ]; then
        echo "The Node $node_version download does not match its checksum." >&2
        exit 1
      fi
      tar -xzf "$tmp/$node_file" -C "$node_dir.part"
    fi
    "$node_dir.part/bin/node" -v >/dev/null 2>&1 || { echo "Node $node_version does not run on this machine." >&2; exit 1; }
    mv "$node_dir.part" "$node_dir"
  fi
  ln -s "$node_dir" "$tmp/stillfail/node"
fi
prune_node() {
  [ -n "$node_dir" ] || return 0
  for d in "$(dirname "$node_dir")"/v*; do
    [ "$d" = "$node_dir" ] || rm -rf "$d"
  done
}

# The agents the station starts are found on this PATH (Claude Code, Codex); each directory once.
agent_path=$(printf '%s' "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH:/usr/bin:/bin" | tr ':' '\n' | awk 'NF && !seen[$0]++' | paste -sd: -)
if [ "$os" = Darwin ]; then
  service_file="$plist"
  cat > "$tmp/service" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>$app/bin/stillfail</string><string>start</string></array>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>$agent_path</string><key>STILLFAIL_DATA</key><string>$data</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$data/stillfail.log</string>
    <key>StandardErrorPath</key><string>$data/stillfail.log</string>
</dict>
</plist>
PLIST
elif user_systemd; then
  service_file="$unit_dir/$unit"
  # KillMode=process: stopping the service stops the station, not the jobs it runs.
  cat > "$tmp/service" <<UNIT
[Unit]
Description=still.fail station
After=network-online.target

[Service]
ExecStart=$app/bin/stillfail start
Environment=PATH=$agent_path
Environment=STILLFAIL_DATA=$data
Restart=always
RestartSec=5
KillMode=process
StandardOutput=append:$data/stillfail.log
StandardError=append:$data/stillfail.log

[Install]
WantedBy=default.target
UNIT
else
  service_file=""
fi

# What the running station says of itself (run/station.json): its pid, when it started, what it can do.
station_json="$data/run/station.json"
said() { sed -n "s/.*\"$1\": *\([0-9]*\).*/\1/p" "$station_json" 2>/dev/null | head -1; }
pid=""
if [ -z "$token" ] && [ -f "$station_json" ]; then
  pid=$(said pid)
  case "$(ps -p "${pid:-0}" -o command= 2>/dev/null)" in
    *stillfail-station*) ;;
    *) pid="" ;;
  esac
fi
without_path() { sed -e 's#<key>PATH</key><string>[^<]*</string>##' -e '/^Environment=PATH=/d' "$1"; }
same_service() { [ -z "$service_file" ] || { [ -f "$service_file" ] && [ "$(without_path "$tmp/service")" = "$(without_path "$service_file")" ]; }; }
inside_station() {
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$p" = "$pid" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

if [ -n "$pid" ] && [ -f "$app/VERSION" ] && cmp -s "$tmp/stillfail/VERSION" "$app/VERSION" && same_service; then
  echo "The station is up to date ($(cut -c1-7 "$app/VERSION"))."
  exit 0
fi

swapped=""
swap_app() {
  mkdir -p "$data"
  rm -rf "$app.old"
  [ -d "$app" ] && mv "$app" "$app.old"
  mv "$tmp/stillfail" "$app"
  swapped=yes
}

# Handed over without stopping: the new release takes the old one's place and the running station execs it.
handed=""
if [ -n "$pid" ] && [ -n "$(said handoff)" ] && same_service; then
  started=$(said startedAt)
  swap_app
  rm -f "$data/run/handoff-failed"
  step handoff
  echo "Handing over to the new release..."
  kill -USR2 "$pid"
  for _ in $(seq 1 120); do
    sleep 1
    if [ "$(said startedAt)" != "$started" ]; then
      [ "$(said pid)" = "$pid" ] && handed=yes
      break
    fi
    [ -f "$data/run/handoff-failed" ] && break
  done
  if [ -n "$handed" ]; then
    rm -rf "$app.old"
    prune_node
  elif [ -f "$data/run/handoff-failed" ]; then
    echo "The handoff failed ($(cat "$data/run/handoff-failed")); restarting instead." >&2
  elif [ "$(said startedAt)" != "$started" ]; then
    handed=restarted
    rm -rf "$app.old"
  else
    echo "The station did not answer the handoff; restarting instead." >&2
  fi
fi

restart_and_finish() {
if [ -z "$handed" ] && [ -n "$pid" ] && [ -n "$(said drain)" ] && [ -z "${STILLFAIL_NO_DRAIN:-}" ]; then
  # Restarted once no turn runs (at most about 10 minutes; it takes no new turns meanwhile).
  rm -f "$data/run/drained"
  step drain
  kill -USR1 "$pid"
  echo "Waiting for running turns to finish before the restart..."
  for _ in $(seq 1 630); do
    { [ -f "$data/run/drained" ] || ! kill -0 "$pid" 2>/dev/null; } && break
    sleep 1
  done
fi

if [ -z "$handed" ]; then
step restart
if [ "$os" = Darwin ]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break; sleep 1; done
else
  if user_systemd; then
    systemctl --user stop "$unit" 2>/dev/null || true
  fi
  if [ -f "$data/stillfail.pid" ]; then
    kill "$(cat "$data/stillfail.pid")" 2>/dev/null || true
    rm -f "$data/stillfail.pid"
  fi
fi
[ -n "$swapped" ] || swap_app
rm -rf "$app.old"
prune_node
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$app/bin/stillfail" "$HOME/.local/bin/stillfail"

if [ -n "$token" ]; then
  echo "Enrolling this station in Comma..."
  "$app/bin/stillfail" station enroll "$origin" "$token" --provider comma
fi

if [ -n "$handed" ]; then
  :
elif [ "$os" = Darwin ]; then
  mkdir -p "$(dirname "$plist")"
  cp "$tmp/service" "$plist"
  started=""
  for _ in 1 2 3 4 5; do
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && { started=yes; break; }
    sleep 2
  done
  [ -n "$started" ] || { echo "The station service did not start: launchctl bootstrap gui/$(id -u) $plist" >&2; exit 1; }
else
  if user_systemd; then
    mkdir -p "$unit_dir"
    cp "$tmp/service" "$unit_dir/$unit"
    systemctl --user daemon-reload
    systemctl --user enable "$unit" >/dev/null 2>&1
    systemctl --user restart "$unit"
    loginctl enable-linger "$(id -un)" 2>/dev/null || lingering="no"
  else
    nohup env PATH="$agent_path" STILLFAIL_DATA="$data" "$app/bin/stillfail" start >> "$data/stillfail.log" 2>&1 &
    echo $! > "$data/stillfail.pid"
    no_service="yes"
  fi
fi

echo
if [ "$handed" = yes ]; then
  echo "The station is updated."
else
  echo "The station is installed and running."
fi
echo "  App: $app"
echo "  Data: $data"
echo "  Status: stillfail status"
[ "$os" = Linux ] && [ -z "${no_service:-}" ] && echo "  Service: systemctl --user status $unit"
[ -n "${lingering:-}" ] && echo "  To keep it running while signed out: sudo loginctl enable-linger $(id -un)"
[ -n "${no_service:-}" ] && echo "  No user service manager here: it runs in the background and does not start again after a reboot."
missing=""
command -v claude >/dev/null 2>&1 || missing="$missing Claude Code"
command -v codex >/dev/null 2>&1 || missing="$missing Codex"
if [ -n "$missing" ]; then
  echo
  echo "Not found on this machine:$missing"
  echo "  Claude Code: curl -fsSL https://claude.ai/install.sh | bash"
  echo "  Codex: npm install -g @openai/codex"
  echo "Sign in to them once; the station uses them as they are."
fi
}

if [ -z "$handed" ] && [ -n "$pid" ] && inside_station; then
  # Apart from the caller (its own process group, output to a file): it restarts once the caller's turn is over.
  mkdir -p "$data/run"
  echo "Updating in the background once this turn ends."
  echo "  Log: $data/run/update.log"
  trap - EXIT
  set -m
  ( trap '' HUP; restart_and_finish; rm -rf "$tmp" ) > "$data/run/update.log" 2>&1 < /dev/null &
  exit 0
fi
restart_and_finish
