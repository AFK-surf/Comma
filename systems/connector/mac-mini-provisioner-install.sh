#!/usr/bin/env sh
set -eu

log() {
  printf '%s\n' "$*" >&2
}

say() {
  printf '%s\n' "$*"
}

ok() {
  say "[ok] $*"
}

fail() {
  code="$1"
  shift
  log "BridgeForTeams runner"
  log "Status: failed"
  log "Code: $code"
  log "Reason: $*"
  log "Next: fix the reported input or generate a fresh install command from BridgeForTeams."
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "preflight.command_missing" "$1 is required"
  fi
}

detect_platform() {
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    darwin) goos="darwin" ;;
    linux) goos="linux" ;;
    *) fail "preflight.unsupported_os" "unsupported OS: $os" ;;
  esac

  case "$arch" in
    x86_64 | amd64) goarch="amd64" ;;
    arm64 | aarch64) goarch="arm64" ;;
    *) fail "preflight.unsupported_arch" "unsupported architecture: $arch" ;;
  esac

  printf '%s-%s\n' "$goos" "$goarch"
}

expand_platform_url() {
  url="$1"
  platform_value="$2"

  printf '%s\n' "$url" | sed "s#__BFT_PLATFORM__#$platform_value#g"
}

download() {
  label="$1"
  url="$2"
  output="$3"
  expected_size="$4"

  case "$expected_size" in
    '' | 0 | *[!0-9]*)
      fail "preflight.${label}_size_missing" "$label exact artifact size is required"
      ;;
  esac

  if python3 - "$url" "$output" "$expected_size" <<'PY'
import os
import pathlib
import sys
import urllib.parse
import urllib.request

url, output, expected_raw = sys.argv[1:4]
expected = int(expected_raw)
parsed = urllib.parse.urlparse(url)

try:
    if parsed.scheme == "":
        source = open(pathlib.Path(url), "rb")
        content_length = os.fstat(source.fileno()).st_size
    else:
        request = urllib.request.Request(
            url, headers={"User-Agent": "bridge-for-teams-installer/1"}
        )
        source = urllib.request.urlopen(request, timeout=60)
        raw_length = source.headers.get("Content-Length")
        content_length = int(raw_length) if raw_length is not None else None

    with source:
        if content_length is not None and content_length != expected:
            raise SystemExit(20 if content_length > expected else 21)
        total = 0
        with open(output, "wb") as target:
            while True:
                chunk = source.read(min(64 * 1024, expected + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                if total > expected:
                    raise SystemExit(20)
                target.write(chunk)
        if total < expected:
            raise SystemExit(21)
except SystemExit:
    raise
except Exception as error:
    print(error, file=sys.stderr)
    raise SystemExit(22)
PY
  then
    return 0
  else
    status=$?
    rm -f "$output"
    case "$status" in
      20) fail "preflight.${label}_size_mismatch" "$label artifact exceeds expected size $expected_size" ;;
      21) fail "preflight.${label}_size_mismatch" "$label artifact is smaller than expected size $expected_size" ;;
      *) fail "preflight.${label}_download_failed" "$label artifact download failed" ;;
    esac
  fi
}

sha256_file() {
  file_path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
    return 0
  fi

  fail "preflight.sha256_missing" "sha256sum or shasum is required"
}

install_binary() {
  label="$1"
  url="$2"
  expected_sha="$3"
  expected_size="$4"
  target_bin="$5"
  temp_dir="$6"

  [ -n "$url" ] || fail "preflight.${label}_url_missing" "$label artifact URL is required"
  [ -n "$expected_sha" ] || fail "preflight.${label}_sha_missing" "$label sha256 is required"
  case "$expected_size" in
    '' | 0 | *[!0-9]*) fail "preflight.${label}_size_missing" "$label exact artifact size is required" ;;
  esac

  if [ -f "$target_bin" ]; then
    actual_size="$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$target_bin")"
    actual="$(sha256_file "$target_bin")"
    if [ "$actual_size" = "$expected_size" ] && [ "$actual" = "$expected_sha" ]; then
      chmod +x "$target_bin"
      return 0
    fi
  fi

  temp_binary="$temp_dir/$label"
  download "$label" "$url" "$temp_binary" "$expected_size"
  actual_sha="$(sha256_file "$temp_binary")"
  if [ "$actual_sha" != "$expected_sha" ]; then
    fail "preflight.${label}_checksum_mismatch" \
      "$label checksum mismatch: expected=$expected_sha got=$actual_sha"
  fi

  chmod +x "$temp_binary"
  mv "$temp_binary" "$target_bin"
}

agent_vmm_host_ready() {
  helper="$1"
  observed="$2"
  attempt=1
  while [ "$attempt" -le 15 ]; do
    if run_agent_vmm_lifecycle "$helper" status \
      --service-type "$BFT_AGENT_VMM_SERVICE_TYPE_RESOLVED" \
      --service-user "$BFT_AGENT_VMM_SERVICE_USER_RESOLVED" --shared-host > "$observed" && \
      python3 - "$observed" <<'PY'
import json
import sys

required = (
    "hostInstalled",
    "hostLoaded",
    "hostReadable",
    "hostHealthy",
)
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    status = json.load(handle)
missing = [key for key in required if status.get(key) is not True]
if missing:
    raise SystemExit("Agent VMM Host is not ready: " + ", ".join(missing))
PY
    then
      return 0
    fi
    [ "$attempt" -lt 15 ] || return 1
    sleep 2
    attempt=$((attempt + 1))
  done
}

run_agent_vmm_lifecycle() {
  installed_helper="$1"
  shift
  "$installed_helper" "$@"
}

install_agent_vmm_bundle() {
  url="$1"
  expected_sha="$2"
  expected_size="$3"
  app="$4"
  temp_dir="$5"

  [ -n "$url" ] || return 0
  [ -n "$expected_sha" ] || fail "preflight.agent_vmm_sha_missing" "agent-vmm sha256 is required"
  case "$expected_size" in
    '' | 0 | *[!0-9]*) fail "preflight.agent_vmm_host_size_missing" "agent-vmm exact artifact size is required" ;;
  esac
  command -v ditto >/dev/null 2>&1 || fail "preflight.ditto_missing" "ditto is required for Agent VMM"
  archive="$temp_dir/Agent-VMM-Host.zip"
  unpacked="$temp_dir/agent-vmm-host-unpacked"
  download "agent_vmm_host" "$url" "$archive" "$expected_size"
  actual_sha="$(sha256_file "$archive")"
  [ "$actual_sha" = "$expected_sha" ] || fail "preflight.agent_vmm_host_checksum_mismatch" "Agent VMM Host checksum mismatch"
  mkdir -p "$unpacked"
  ditto -x -k "$archive" "$unpacked"
  staged="$unpacked/Agent VMM Host.app"
  [ -x "$staged/Contents/MacOS/agent-vmm-host" ] || fail "preflight.agent_vmm_host_bundle_invalid" "Agent VMM Host executable is missing"
  [ -x "$staged/Contents/Helpers/agent-vmm-lifecycle" ] || fail "preflight.agent_vmm_host_bundle_invalid" "Agent VMM Host lifecycle helper is missing"
  [ -x "$staged/Contents/Helpers/agent-vmm" ] || fail "preflight.agent_vmm_host_bundle_invalid" "Agent VMM managed CLI is missing"
  [ -x "$staged/Contents/Helpers/agent-vmm-service-executor" ] || fail "preflight.agent_vmm_host_bundle_invalid" "Agent VMM fixed service executor is missing"
  codesign --verify --deep --strict "$staged" >/dev/null 2>&1 || \
    fail "preflight.agent_vmm_host_signature_invalid" "Staged Agent VMM Host signature verification failed"
  target_release_id=$("$staged/Contents/Helpers/agent-vmm-lifecycle" version --json | python3 -c 'import json,sys; value=json.load(sys.stdin); release=value.get("release_id", ""); assert release; print(release)') || \
    fail "preflight.agent_vmm_host_release_invalid" "Staged Agent VMM Host release identity is invalid"
  if [ "$BFT_AGENT_VMM_SERVICE_TYPE_RESOLVED" = daemon ]; then
    [ -d "$app" ] || fail "install.agent_vmm_administrator_install_required" \
      "install this Agent VMM Host release with its administrator installer before BFT daemon onboarding"
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 || \
      fail "install.agent_vmm_host_signature_invalid" "Installed Agent VMM Host signature verification failed"
    installed_release_id=$("$app/Contents/Helpers/agent-vmm-lifecycle" version --json 2>/dev/null | \
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("release_id", ""))' 2>/dev/null || true)
    [ "$installed_release_id" = "$target_release_id" ] || fail "install.agent_vmm_administrator_update_required" \
      "install the selected Agent VMM Host release with its administrator installer before BFT daemon onboarding"
    observed="$temp_dir/agent-vmm-host-status.json"
    if ! agent_vmm_host_ready "$staged/Contents/Helpers/agent-vmm-lifecycle" "$observed"; then
      fail "install.agent_vmm_host_not_ready" "the administrator-installed Agent VMM Host is not ready"
    fi
    return 0
  fi
  app_parent="$(dirname "$app")"
  mkdir -p "$app_parent"
  request_key="${BFT_VMM_REQUEST_ID:-bft-host-$expected_sha}"
  case "$request_key" in '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*) fail "preflight.agent_vmm_request_id_invalid" "Agent VMM request ID is invalid" ;; esac
  [ "${#request_key}" -le 120 ] || fail "preflight.agent_vmm_request_id_invalid" "Agent VMM request ID is too long"
  install_request_id="$request_key-install"
  repair_request_id="$request_key-repair"
  update_request_id="$request_key-update"
  prepared="$app_parent/.Agent VMM Host.$request_key.app"
  if [ -d "$app" ] && [ ! -e "$prepared" ]; then
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 || \
      fail "install.agent_vmm_host_signature_invalid" "Installed Agent VMM Host signature verification failed"
    current_release_id=$("$app/Contents/Helpers/agent-vmm-lifecycle" version --json 2>/dev/null | \
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("release_id", ""))' 2>/dev/null || true)
    if [ "$current_release_id" = "$target_release_id" ]; then
      observed="$temp_dir/agent-vmm-host-status.json"
      if ! agent_vmm_host_ready "$staged/Contents/Helpers/agent-vmm-lifecycle" "$observed"; then
        if ! run_agent_vmm_lifecycle "$staged/Contents/Helpers/agent-vmm-lifecycle" repair \
          --service-type "$BFT_AGENT_VMM_SERVICE_TYPE_RESOLVED" \
          --service-user "$BFT_AGENT_VMM_SERVICE_USER_RESOLVED" \
          --request-id "$repair_request_id" --shared-host; then
          fail "install.agent_vmm_host_repair_failed" "Agent VMM Host repair stopped with its local recovery state retained"
        fi
        if ! agent_vmm_host_ready "$staged/Contents/Helpers/agent-vmm-lifecycle" "$observed"; then
          fail "install.agent_vmm_host_not_ready" "Agent VMM Host readiness was not observed after repair"
        fi
      fi
      return 0
    fi
  fi
  if [ -e "$prepared" ]; then
    codesign --verify --deep --strict "$prepared" >/dev/null 2>&1 || \
      fail "install.agent_vmm_host_prepared_conflict" "Retained Agent VMM recovery material belongs to a different or invalid release"
    prepared_release_id=$("$prepared/Contents/Helpers/agent-vmm-lifecycle" version --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("release_id", ""))' 2>/dev/null || true)
    [ "$prepared_release_id" = "$target_release_id" ] || \
      fail "install.agent_vmm_host_prepared_conflict" "Retained Agent VMM recovery material belongs to a different or invalid release"
  else
    if ! ditto "$staged" "$prepared"; then
      rm -rf "$prepared"
      fail "install.agent_vmm_host_install_failed" "Agent VMM Host could not be staged; the current Host was not changed"
    fi
    codesign --verify --deep --strict "$prepared" >/dev/null 2>&1 || {
      rm -rf "$prepared"
      fail "install.agent_vmm_host_signature_invalid" "Staged Agent VMM Host signature verification failed"
    }
  fi
  if [ ! -d "$app" ]; then
    # The native owner checks policy and publishes while holding the same lock
    # as maintenance. A preflight read alone cannot fence a late installer copy.
    if ! run_agent_vmm_lifecycle "$staged/Contents/Helpers/agent-vmm-lifecycle" publish-host \
      --source-app "$staged" \
      --service-type "$BFT_AGENT_VMM_SERVICE_TYPE_RESOLVED" \
      --service-user "$BFT_AGENT_VMM_SERVICE_USER_RESOLVED"; then
      fail "install.agent_vmm_host_publish_failed" "Local Host publication was not authorized or completed"
    fi
    rm -rf "$prepared"
    helper="$staged/Contents/Helpers/agent-vmm-lifecycle"
    if ! run_agent_vmm_lifecycle "$helper" install \
      --service-type "$BFT_AGENT_VMM_SERVICE_TYPE_RESOLVED" \
      --service-user "$BFT_AGENT_VMM_SERVICE_USER_RESOLVED" \
      --request-id "$install_request_id" --shared-host; then
      fail "install.agent_vmm_host_install_failed" "Agent VMM Host install stopped with its local recovery state retained"
    fi
  else
    helper="$staged/Contents/Helpers/agent-vmm-lifecycle"
    update_log="$temp_dir/agent-vmm-host-update.log"
    update_command() {
      run_agent_vmm_lifecycle "$helper" update --source-app "$prepared" \
        --target-release-id "$target_release_id" --request-id "$update_request_id" \
        --service-type "$BFT_AGENT_VMM_SERVICE_TYPE_RESOLVED" \
        --service-user "$BFT_AGENT_VMM_SERVICE_USER_RESOLVED" --shared-host
    }
    if ! update_command >"$update_log" 2>&1; then
      [ ! -s "$update_log" ] || sed -n '1,20p' "$update_log" >&2
      fail "install.agent_vmm_host_update_failed" "Agent VMM Host update stopped with the current or retained recovery bundle unchanged"
    fi
  fi

  observed="$temp_dir/agent-vmm-host-status.json"
  if ! agent_vmm_host_ready "$helper" "$observed"; then
    fail "install.agent_vmm_host_not_ready" "Agent VMM Host readiness was not observed; use the retained lifecycle operation for forward repair"
  fi
}

sanitize_stable_id() {
  raw="$1"
  stable="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_-' '-' | cut -c 1-80)"
  stable="$(printf '%s' "$stable" | sed 's/^-*//; s/-*$//')"

  if [ -z "$stable" ]; then
    stable="runner"
  fi

  printf '%s\n' "$stable"
}

read_existing_runner_field() {
  config_path="$1"
  field="$2"

  [ -f "$config_path" ] || return 0

  python3 - "$config_path" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    raise SystemExit(0)

runner = data.get("runner")
if not isinstance(runner, dict):
    raise SystemExit(0)

value = runner.get(field)
if isinstance(value, str) and value:
    print(value)
PY
}

write_json_files() {
  config_path="$1"
  status_path="$2"
  launchd_plist_path="$3"
  launchd_install_path="$4"
  default_launchd_install_path="$5"

  python3 - "$config_path" "$status_path" "$launchd_plist_path" "$launchd_install_path" "$default_launchd_install_path" <<'PY'
import json
import os
import plistlib
import sys

config_path, status_path, launchd_plist_path, launchd_install_path, default_launchd_install_path = sys.argv[1:6]

token = os.environ.get("BFT_RUNNER_TOKEN", "")
runner_path = os.environ["BFT_RUNNER_PATH_RESOLVED"]
state_dir = os.environ["BFT_STATE_DIR"]
logs_dir = os.path.join(state_dir, "logs")
config = None

config = {
    "api_base_url": os.environ.get("BFT_API_BASE_URL", ""),
    "org_id": os.environ.get("BFT_ORG_ID", ""),
    "runner": {
        "stable_id": os.environ["BFT_RUNNER_STABLE_ID"],
        "name": os.environ["BFT_RUNNER_NAME"],
    },
    "paths": {
        "salix_connect": os.environ["BFT_SALIX_CONNECT_PATH"],
        "host_runtime_lifecycle": os.environ["BFT_HOST_RUNTIME_LIFECYCLE_PATH"],
        "host_runtime_cli": os.environ["BFT_HOST_RUNTIME_CLI_PATH"],
        "runner": runner_path,
        "runner_install_status": status_path,
        "workdir": os.environ["BFT_WORKDIR"],
        "state_dir": state_dir,
    },
    "launchd": {
        "label": os.environ["BFT_LAUNCHD_LABEL"],
        "domain": os.environ["BFT_LAUNCHD_DOMAIN"],
        "service_user": os.environ["BFT_AGENT_VMM_SERVICE_USER_RESOLVED"],
        "source_plist": launchd_plist_path,
        "install_plist": default_launchd_install_path,
    },
    "capabilities": {
        "salix_connect": True,
        "component_digests": {
            "salix-connect": os.environ["BFT_SALIX_CONNECTOR_SHA256"],
            "agent-vmm-host": os.environ["BFT_AGENT_VMM_HOST_SHA256"],
        },
    },
}
if token:
    config["runner_token"] = token

if os.environ["BFT_LAUNCHD_DOMAIN"] == "system":
    next_action = "Run bft-runner doctor, bft-runner dry-run, or bft-runner. Ask an administrator to run /Library/PrivilegedHelperTools/agent-vmm-service-executor install --job runner after the foreground smoke works."
else:
    next_action = "Run bft-runner doctor, bft-runner dry-run, or bft-runner. Use bft-runner service start after the foreground smoke works."

status = {
    "component": "bridge-for-teams-runner",
    "status": "ready",
    "runner": config["runner"],
    "paths": config["paths"],
    "capabilities": config["capabilities"],
    "install": {
        "runner_source": os.environ["BFT_RUNNER_SOURCE"],
        "salix_connect_source": os.environ["BFT_SALIX_CONNECT_SOURCE"],
        "fallback_tooling_source": os.environ["BFT_FALLBACK_TOOLING_SOURCE"],
    },
    "launchd": {
        "label": os.environ["BFT_LAUNCHD_LABEL"],
        "domain": os.environ["BFT_LAUNCHD_DOMAIN"],
        "plist": launchd_plist_path,
        "install_path": launchd_install_path or None,
        "installed": os.environ["BFT_INSTALL_LAUNCHD"] == "1",
        "loaded": False,
    },
    "next_action": next_action,
}

os.makedirs(os.path.dirname(config_path), exist_ok=True)
os.makedirs(os.path.dirname(status_path), exist_ok=True)
os.makedirs(os.path.dirname(launchd_plist_path), exist_ok=True)

with open(config_path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, sort_keys=True)
    handle.write("\n")
os.chmod(config_path, 0o600)

with open(status_path, "w", encoding="utf-8") as handle:
    json.dump(status, handle, sort_keys=True)
    handle.write("\n")

plist = {
    "Label": os.environ["BFT_LAUNCHD_LABEL"],
    "EnvironmentVariables": {
        "HOME": os.environ["BFT_HOME_DIR"],
        "PATH": os.environ.get(
            "BFT_LAUNCHD_PATH",
            ":".join(
                [
                    os.environ["BFT_BIN_DIR_RESOLVED"],
                    os.path.join(os.path.expanduser("~"), ".local", "bin"),
                    os.path.join(os.path.expanduser("~"), ".npm-global", "bin"),
                    os.path.join(os.path.expanduser("~"), ".yarn", "bin"),
                    os.path.join(os.path.expanduser("~"), ".bun", "bin"),
                    os.path.join(os.path.expanduser("~"), ".volta", "bin"),
                    os.path.join(os.path.expanduser("~"), ".asdf", "shims"),
                    "/opt/homebrew/bin",
                    "/Applications/LibreOffice.app/Contents/MacOS",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin",
                ]
            ),
        ),
    },
    "ProgramArguments": [
        runner_path,
    ],
    # Claude Code and Codex app-server probes open more than the default
    # launchd soft descriptor limit. Match the host policy so discovery and
    # native session startup see the same resource envelope.
    "SoftResourceLimits": {
        "NumberOfFiles": 65536,
    },
    "HardResourceLimits": {
        "NumberOfFiles": 524288,
    },
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": os.path.join(config["paths"]["state_dir"], "runner.out.log"),
    "StandardErrorPath": os.path.join(config["paths"]["state_dir"], "runner.err.log"),
    "WorkingDirectory": os.path.dirname(config_path),
}

if os.environ["BFT_LAUNCHD_DOMAIN"] == "system":
    plist["UserName"] = os.environ["BFT_INSTALL_USER_RESOLVED"]
    plist["GroupName"] = os.environ["BFT_INSTALL_GROUP_RESOLVED"]

with open(launchd_plist_path, "wb") as handle:
    plistlib.dump(plist, handle, sort_keys=True)

if os.environ["BFT_INSTALL_LAUNCHD"] == "1" and launchd_install_path:
    os.makedirs(os.path.dirname(launchd_install_path), exist_ok=True)
    with open(launchd_install_path, "wb") as handle:
        plistlib.dump(plist, handle, sort_keys=True)
PY
}

update_launchd_status() {
  status_path="$1"
  loaded="$2"
  action="$3"

  python3 - "$status_path" "$loaded" "$action" <<'PY'
import json
import sys

status_path, loaded_raw, action = sys.argv[1:4]
with open(status_path, "r", encoding="utf-8") as handle:
    status = json.load(handle)

launchd = status.setdefault("launchd", {})
launchd["loaded"] = loaded_raw == "1"
launchd["last_action"] = action

with open(status_path, "w", encoding="utf-8") as handle:
    json.dump(status, handle, sort_keys=True)
    handle.write("\n")
PY
}

run_launchd_action() {
  action="$1"
  label="$2"
  domain="$3"
  plist_path="$4"
  status_path="$5"

  case "$action" in
    load)
      [ -n "$plist_path" ] || fail "preflight.launchd_install_missing" \
        "BFT_INSTALL_LAUNCHD=1 is required before BFT_LOAD_LAUNCHD=1"
      [ -f "$plist_path" ] || fail "preflight.launchd_plist_missing" \
        "launchd plist not found: $plist_path"
      need_cmd launchctl
      launchctl bootout "$domain/$label" 2>/dev/null || true
      launchctl bootstrap "$domain" "$plist_path"
      update_launchd_status "$status_path" "1" "bootstrap"
      printf 'launchd loaded: %s\n' "$label"
      ;;
    unload)
      [ -n "$plist_path" ] || fail "preflight.launchd_install_missing" \
        "BFT_INSTALL_LAUNCHD=1 is required before BFT_UNLOAD_LAUNCHD=1"
      need_cmd launchctl
      launchctl bootout "$domain/$label"
      update_launchd_status "$status_path" "0" "bootout"
      printf 'launchd unloaded: %s\n' "$label"
      ;;
    status)
      need_cmd launchctl
      launchctl print "$domain/$label"
      ;;
    *)
      fail "preflight.launchd_action_unknown" "unknown launchd action: $action"
      ;;
  esac
}

remove_launchd_install() {
  plist_path="$1"
  status_path="$2"

  [ -n "$plist_path" ] || fail "preflight.launchd_install_missing" \
    "BFT_INSTALL_LAUNCHD=1 or BFT_LAUNCHD_INSTALL_PATH is required before BFT_REMOVE_LAUNCHD=1"

  python3 - "$plist_path" "$status_path" <<'PY'
import json
import os
import sys

plist_path, status_path = sys.argv[1:3]
removed = os.path.exists(plist_path)
if removed:
    os.remove(plist_path)

with open(status_path, "r", encoding="utf-8") as handle:
    status = json.load(handle)

launchd = status.setdefault("launchd", {})
launchd["installed"] = False
launchd["loaded"] = False
launchd["last_action"] = "remove"
launchd["last_remove_removed"] = removed

with open(status_path, "w", encoding="utf-8") as handle:
    json.dump(status, handle, sort_keys=True)
    handle.write("\n")
PY

  printf 'launchd install removed: %s\n' "$plist_path"
}

preflight_fallback_tooling() {
  platform_value="$1"

  if [ "${BFT_INSTALL_FALLBACK_TOOLS:-0}" != "1" ]; then
    BFT_FALLBACK_TOOLING_SOURCE="skipped"
    export BFT_FALLBACK_TOOLING_SOURCE
    return 0
  fi

  case "$platform_value" in
    darwin-*) ;;
    *)
      BFT_FALLBACK_TOOLING_SOURCE="unsupported-platform"
      export BFT_FALLBACK_TOOLING_SOURCE
      return 0
      ;;
  esac

  brew_path="$(command -v brew 2>/dev/null || true)"
  [ -n "$brew_path" ] || fail "preflight.homebrew_missing" \
    "BFT_INSTALL_FALLBACK_TOOLS=1 requires Homebrew before running the single-use installer"
  BFT_FALLBACK_BREW_PATH="$brew_path"
  export BFT_FALLBACK_BREW_PATH
}

require_fallback_command() {
  display_name="$1"
  shift
  for candidate in "$@"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      return 0
    fi
  done
  fail "preflight.fallback_tool_missing" \
    "$display_name was not discoverable after Homebrew fallback-tool installation"
}

install_fallback_tooling() {
  platform_value="$1"

  if [ "${BFT_INSTALL_FALLBACK_TOOLS:-0}" != "1" ]; then
    BFT_FALLBACK_TOOLING_SOURCE="skipped"
    export BFT_FALLBACK_TOOLING_SOURCE
    return 0
  fi

  case "$platform_value" in
    darwin-*) ;;
    *) return 0 ;;
  esac

  brew_path="${BFT_FALLBACK_BREW_PATH:-$(command -v brew 2>/dev/null || true)}"
  [ -n "$brew_path" ] || fail "preflight.homebrew_missing" \
    "BFT_INSTALL_FALLBACK_TOOLS=1 requires Homebrew before running the single-use installer"

  say "Installing attachment fallback tools"
  "$brew_path" install jq poppler pandoc ffmpeg p7zip imagemagick
  "$brew_path" install --cask libreoffice

  PATH="$(dirname "$brew_path"):/Applications/LibreOffice.app/Contents/MacOS:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
  export PATH
  require_fallback_command "jq" jq
  require_fallback_command "pdftotext" pdftotext
  require_fallback_command "pandoc" pandoc
  require_fallback_command "ffmpeg" ffmpeg
  require_fallback_command "ImageMagick" magick
  require_fallback_command "7-Zip" 7z 7zz
  require_fallback_command "LibreOffice" libreoffice soffice

  BFT_FALLBACK_TOOLING_SOURCE="homebrew"
  export BFT_FALLBACK_TOOLING_SOURCE
  ok "Attachment fallback tools installed and verified"
}

main() {
  need_cmd uname
  need_cmd tr
  need_cmd awk
  need_cmd sed
  need_cmd cut
  need_cmd dirname
  need_cmd mktemp
  need_cmd python3

  platform="${BFT_PLATFORM:-$(detect_platform)}"
  installer_uid="$(/usr/bin/id -u)"
  [ "$installer_uid" != 0 ] || fail "preflight.root_business_installer_forbidden" \
    "run the BFT installer as the non-root service user; use only the fixed Agent VMM executor for administrator service actions"
  install_user="${BFT_INSTALL_USER:-$(/usr/bin/id -un)}"
  install_uid="$(/usr/bin/id -u "$install_user" 2>/dev/null || true)"
  install_gid="$(/usr/bin/id -g "$install_user" 2>/dev/null || true)"
  [ -n "$install_uid" ] && [ -n "$install_gid" ] || fail "preflight.install_user_missing" "install user does not exist: $install_user"
  [ "$install_uid" != 0 ] || fail "preflight.install_user_root" "BFT and Agent VMM must run as a non-root user"
  if [ "$installer_uid" != 0 ] && [ "$installer_uid" != "$install_uid" ]; then
    fail "preflight.install_user_permission" "a non-root installer can only install for its current user"
  fi
  if [ -n "${BFT_INSTALL_USER:-}" ]; then
    need_cmd dscl
    home_dir="$(dscl . -read "/Users/$install_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  else
    home_dir="${HOME:-}"
  fi
  [ -n "$home_dir" ] || fail "preflight.home_missing" "HOME is required"
  case "$home_dir" in /*) ;; *) fail "preflight.home_invalid" "install user home must be absolute" ;; esac
  requested_service_type="${BFT_AGENT_VMM_SERVICE_TYPE:-auto}"
  case "$requested_service_type" in agent|daemon|auto) ;; *) fail "preflight.agent_vmm_service_type" "Agent VMM service type must be agent, daemon, or auto" ;; esac
  service_type="$requested_service_type"
  if [ "$requested_service_type" = auto ]; then service_type=agent; fi
  service_user="${BFT_AGENT_VMM_SERVICE_USER:-$install_user}"
  [ "$service_user" = "$install_user" ] || fail "preflight.agent_vmm_service_user" "Agent VMM service user must match the BFT install user"
  export BFT_INSTALL_UID_RESOLVED="$install_uid"
  export BFT_INSTALL_GID_RESOLVED="$install_gid"
  export BFT_INSTALLER_EUID_RESOLVED="$installer_uid"
  export BFT_AGENT_VMM_SERVICE_TYPE_REQUESTED="$requested_service_type"
  export BFT_AGENT_VMM_SERVICE_TYPE_RESOLVED="$service_type"
  export BFT_AGENT_VMM_SERVICE_USER_RESOLVED="$service_user"

  install_prefix="${BFT_INSTALL_PREFIX:-$home_dir/.bridge-for-teams}"
  bin_dir="${BFT_BIN_DIR:-$install_prefix/bin}"
  state_dir="${BFT_STATE_DIR:-$install_prefix/state}"
  config_path="${BFT_CONFIG_PATH:-$install_prefix/runner.json}"
  status_path="${BFT_STATUS_PATH:-$install_prefix/runner-install-status.json}"
  workdir="${BFT_WORKDIR:-$install_prefix/work}"
  launchd_label="${BFT_LAUNCHD_LABEL:-com.bridgeforteams.runner}"
  launchd_plist_path="${BFT_LAUNCHD_PLIST_PATH:-$install_prefix/$launchd_label.plist}"
  install_launchd="${BFT_INSTALL_LAUNCHD:-0}"
  load_launchd="${BFT_LOAD_LAUNCHD:-0}"
  unload_launchd="${BFT_UNLOAD_LAUNCHD:-0}"
  status_launchd="${BFT_STATUS_LAUNCHD:-0}"
  remove_launchd="${BFT_REMOVE_LAUNCHD:-0}"
  if [ "$service_type" = daemon ]; then
    [ "$launchd_label" = com.bridgeforteams.runner ] || fail "preflight.system_launchd_target_rejected" \
      "the fixed administrator executor accepts only com.bridgeforteams.runner"
    case "${BFT_LAUNCHD_DOMAIN:-system}" in system) ;; *) fail "preflight.system_launchd_domain_rejected" "daemon runner service domain must be system" ;; esac
    case "${BFT_LAUNCHD_INSTALL_PATH:-/Library/LaunchDaemons/com.bridgeforteams.runner.plist}" in
      /Library/LaunchDaemons/com.bridgeforteams.runner.plist) ;;
      *) fail "preflight.system_launchd_path_rejected" "the fixed administrator executor owns the runner plist path" ;;
    esac
    if [ "$install_launchd" = 1 ] || [ "$load_launchd" = 1 ] || [ "$unload_launchd" = 1 ] || [ "$remove_launchd" = 1 ]; then
      fail "preflight.system_launchd_executor_required" \
        "ask an administrator to use /Library/PrivilegedHelperTools/agent-vmm-service-executor with --job runner"
    fi
    default_launchd_install_path=/Library/LaunchDaemons/com.bridgeforteams.runner.plist
  else
    case "${BFT_LAUNCHD_DOMAIN:-}" in system) fail "preflight.system_launchd_executor_required" "the BFT installer cannot manage a system job" ;; esac
    case "${BFT_LAUNCHD_INSTALL_PATH:-}" in /Library/LaunchDaemons/*) fail "preflight.system_launchd_executor_required" "the BFT installer cannot write a system plist" ;; esac
    default_launchd_install_path="${BFT_LAUNCHD_INSTALL_PATH:-$home_dir/Library/LaunchAgents/$launchd_label.plist}"
  fi
  launchd_domain="${BFT_LAUNCHD_DOMAIN:-}"
  if [ -z "$launchd_domain" ]; then
    case "$default_launchd_install_path" in
      /Library/LaunchDaemons/*) launchd_domain="system" ;;
      *) launchd_domain="gui/$install_uid" ;;
    esac
  fi
  launchd_install_path=""
  if [ "$install_launchd" = "1" ] || [ "$remove_launchd" = "1" ]; then
    launchd_install_path="$default_launchd_install_path"
  fi
  if [ "$load_launchd" = "1" ] && [ "$unload_launchd" = "1" ]; then
    fail "preflight.launchd_action_conflict" \
      "set only one of BFT_LOAD_LAUNCHD=1 or BFT_UNLOAD_LAUNCHD=1"
  fi
  if [ "$load_launchd" = "1" ] && [ "$remove_launchd" = "1" ]; then
    fail "preflight.launchd_action_conflict" \
      "set only one of BFT_LOAD_LAUNCHD=1 or BFT_REMOVE_LAUNCHD=1"
  fi

  # The base clean-host install has no Homebrew dependency. When optional fallback
  # tooling is requested, fail before downloading or installing any release artifact.
  preflight_fallback_tooling "$platform"

  say "BridgeForTeams runner"
  say "Org: ${BFT_ORG_ID:-unknown}"
  if [ "$remove_launchd" = "1" ]; then
    say "Mode: remove service"
  elif [ "$unload_launchd" = "1" ]; then
    say "Mode: stop service"
  elif [ "$load_launchd" = "1" ]; then
    say "Mode: install and start service"
  elif [ "$install_launchd" = "1" ]; then
    say "Mode: install service files only"
  elif [ "$status_launchd" = "1" ]; then
    say "Mode: service status"
  else
    say "Mode: install only (service not started)"
  fi
  say ""

  mkdir -p "$bin_dir" "$state_dir" "$workdir/agents"

  temp_dir="$(mktemp -d)"
  temp_dir="$(cd "$temp_dir" && pwd -P)"
  trap 'rm -rf "$temp_dir"' EXIT INT TERM

  connector_url="${BFT_SALIX_CONNECTOR_URL:-}"
  [ -n "$connector_url" ] || fail "preflight.salix_connect_url_missing" \
    "salix connector artifact URL is required"

  connector_sha="${BFT_SALIX_CONNECTOR_SHA256:-}"
  connector_size="${BFT_SALIX_CONNECTOR_SIZE:-}"
  say "Downloading artifacts"
  salix_connect_path="${BFT_SALIX_CONNECT_INSTALL_PATH:-$bin_dir/salix-connect}"
  install_binary "salix_connect" "$connector_url" "$connector_sha" "$connector_size" \
    "$salix_connect_path" "$temp_dir"
  ok "salix-connect installed and verified"

  agent_vmm_host_app="$home_dir/Library/Application Support/Agent VMM Host/current/Agent VMM Host.app"
  # Local operator intent survives removal of the application and its data.
  # Check before copying any bundle, including an older release without this gate.
  if ! python3 - "$home_dir/Library/Application Support/Agent VMM Maintenance/state.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        policy = json.load(handle)
except FileNotFoundError:
    raise SystemExit(0)
if policy.get("version") != 1 or not isinstance(policy.get("uninstalled"), bool):
    raise SystemExit("Local VMM maintenance policy is invalid")
if policy.get("activeRequest") or policy["uninstalled"]:
    raise SystemExit("Continue local VMM maintenance before BFT installation")
PY
  then
    fail "preflight.agent_vmm_maintenance_required" "Local owner maintenance prevents automatic Host installation"
  fi
  agent_vmm_host_url="$(expand_platform_url "${BFT_AGENT_VMM_HOST_URL:-}" "$platform")"
  agent_vmm_host_sha="${BFT_AGENT_VMM_HOST_SHA256:-}"
  agent_vmm_host_size="${BFT_AGENT_VMM_HOST_SIZE:-}"
  [ -n "$agent_vmm_host_url" ] || fail "preflight.agent_vmm_host_url_missing" \
    "Agent VMM Host artifact URL is required"
  install_agent_vmm_bundle "$agent_vmm_host_url" "$agent_vmm_host_sha" "$agent_vmm_host_size" \
    "$agent_vmm_host_app" "$temp_dir"
  agent_vmm_lifecycle="$agent_vmm_host_app/Contents/Helpers/agent-vmm-lifecycle"
  agent_vmm_cli="$agent_vmm_host_app/Contents/Helpers/agent-vmm"

  runner_target="${BFT_RUNNER_INSTALL_PATH:-$bin_dir/bft-runner}"
  runner_url="${BFT_RUNNER_URL:-}"
  runner_url="$(expand_platform_url "$runner_url" "$platform")"
  runner_sha="${BFT_RUNNER_SHA256:-}"
  runner_size="${BFT_RUNNER_SIZE:-}"
  install_binary "runner" "$runner_url" "$runner_sha" "$runner_size" \
    "$runner_target" "$temp_dir"
  runner_source="download"
  ok "bft-runner installed and verified"

  install_fallback_tooling "$platform"

  host_name="$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'runner')"
  existing_runner_name="$(read_existing_runner_field "$config_path" name || true)"
  if [ -n "${BFT_RUNNER_STABLE_ID:-}" ]; then
    stable_id="$BFT_RUNNER_STABLE_ID"
  else
    stable_id="$(sanitize_stable_id "$host_name")"
  fi

  runner_name="${BFT_RUNNER_NAME:-${existing_runner_name:-$host_name}}"

  export BFT_WORKDIR="$workdir"
  export BFT_HOME_DIR="$home_dir"
  export BFT_STATE_DIR="$state_dir"
  export BFT_RUNNER_STABLE_ID="$stable_id"
  export BFT_RUNNER_NAME="$runner_name"
  export BFT_SALIX_CONNECT_PATH="$salix_connect_path"
  export BFT_SALIX_CONNECT_SOURCE="download"
  export BFT_RUNNER_PATH_RESOLVED="$runner_target"
  export BFT_RUNNER_SOURCE="$runner_source"
  export BFT_HOST_RUNTIME_LIFECYCLE_PATH="$agent_vmm_lifecycle"
  export BFT_HOST_RUNTIME_CLI_PATH="$agent_vmm_cli"
  export BFT_BIN_DIR_RESOLVED="$bin_dir"
  export BFT_FALLBACK_TOOLING_SOURCE="${BFT_FALLBACK_TOOLING_SOURCE:-skipped}"
  export BFT_LAUNCHD_LABEL="$launchd_label"
  export BFT_LAUNCHD_DOMAIN="$launchd_domain"
  export BFT_INSTALL_LAUNCHD="$install_launchd"
  export BFT_INSTALL_USER_RESOLVED="$install_user"
  export BFT_INSTALL_GROUP_RESOLVED="$(/usr/bin/id -gn "$install_user")"

  say "Writing protected config"
  write_json_files "$config_path" "$status_path" "$launchd_plist_path" "$launchd_install_path" "$default_launchd_install_path"
  ok "Protected config written: $config_path"

  if [ "$unload_launchd" = "1" ]; then
    run_launchd_action "unload" "$launchd_label" "$launchd_domain" "$launchd_install_path" "$status_path"
  fi
  if [ "$remove_launchd" = "1" ]; then
    remove_launchd_install "$launchd_install_path" "$status_path"
  fi
  if [ "$load_launchd" = "1" ]; then
    run_launchd_action "load" "$launchd_label" "$launchd_domain" "$launchd_install_path" "$status_path"
  fi
  if [ "$status_launchd" = "1" ]; then
    run_launchd_action "status" "$launchd_label" "$launchd_domain" "$launchd_install_path" "$status_path"
  fi

  printf '\n'
  printf 'runner ready\n'
  printf 'Status: ready\n'
  printf 'status: %s\n' "$status_path"
  printf 'config: %s\n' "$config_path"
  printf 'launchd plist: %s\n' "$launchd_plist_path"
  if [ "$install_launchd" = "1" ]; then
    printf 'launchd install path: %s\n' "$launchd_install_path"
    if [ "$load_launchd" = "1" ]; then
      printf 'launchd loaded by explicit BFT_LOAD_LAUNCHD=1 gate\n'
    else
      printf 'launchd not loaded: rerun with BFT_LOAD_LAUNCHD=1 when ready\n'
    fi
  fi
  printf 'salix-connect: %s\n' "$salix_connect_path"
  printf 'bft-runner: %s\n' "$runner_target"
  printf 'Workdir: %s\n' "$workdir"
  printf 'Logs: %s\n' "$state_dir/logs"
  printf '\n'
  printf 'Next:\n'
  printf '  Doctor:   %s doctor\n' "$runner_target"
  printf '  Dry run:  %s dry-run\n' "$runner_target"
  printf '  Start:    %s\n' "$runner_target"
  if [ "$launchd_domain" = system ]; then
    printf '  Service:  ask an administrator to run /Library/PrivilegedHelperTools/agent-vmm-service-executor install --job runner\n'
  else
    printf '  Service:  %s service start\n' "$runner_target"
  fi
}

main "$@"
