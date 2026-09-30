#!/usr/bin/env bash
set -euo pipefail

# Bridge ToB setup-to-first-message acceptance harness.
#
# This is intentionally safe to run locally: it verifies the configured public
# Feishu callback URL with a URL-verification request, posts a synthetic
# group-message-style event, and confirms the Salix router session receives the
# message and a deterministic local fake-LLM ack. It never prints raw secrets,
# raw event bodies, full message bodies, app IDs, chat IDs, or user emails.
#
# Usage:
#   systems/scripts/bridge_tob_acceptance_harness.sh
#   systems/scripts/bridge_tob_acceptance_harness.sh --print-env-template
#
# The harness expects the local Systems app and public callback/tunnel to be
# running already. It owns acceptance orchestration, not the whole dev
# environment lifecycle.
#
# Required env, usually sourced from the repo-local .env:
#   BRIDGE_TOB_ADMIN_API_TOKEN        admin-only token for /v1/admin/* setup repair
#   BRIDGE_TOB_FEISHU_SECRET_ENV      0600 shell env file with Feishu verification token
#   BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE
#   BRIDGE_TOB_LOCAL_LLM_BASE_URL
#   BRIDGE_TOB_LOCAL_LLM_MODEL
#   BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE
#   BRIDGE_TOB_SMOKE_PROJECT_ID
#   BRIDGE_TOB_SMOKE_PROJECT_SLUG
#   BRIDGE_TOB_SMOKE_GROUP_ID
#   BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID
#
# Optional env:
#   ENV_FILE
#   BRIDGE_TOB_SALIX_BASE_URL        default: http://127.0.0.1:4000
#   BRIDGE_TOB_PUBLIC_HEALTH_URL     default: <webhook origin>/health
#   BRIDGE_TOB_START_FAKE_LLM        default: true
#   BRIDGE_TOB_EVIDENCE_PATH         default: /tmp/bridge-tob-acceptance-evidence.json
#   BRIDGE_TOB_LAST_EVENT_PATH       default: /tmp/bridge-tob-last-synthetic-event.json
#   BRIDGE_TOB_FEISHU_VERIFICATION_TOKEN_VAR default: BRIDGE_FEISHU_VERIFICATION_TOKEN
#
# Backward-compatible THREAD_A_* env names are accepted for this PR branch;
# new local setups should use BRIDGE_TOB_*.

COMMA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$COMMA_ROOT/.env}"
FAKE_LLM_PID=""
WORK_DIR=""

usage() {
  sed -n '4,42p' "$0" >&2
}

print_env_template() {
  cat <<'EOF'
# Bridge ToB acceptance harness local template.
# Put non-secret defaults in the repo-local .env. Put secrets in 0600 files.

# Admin-only token for /v1/admin/* setup repair. Local dev usually mirrors
# SALIX_API_TOKEN; runtime and connector calls must not use this token.
BRIDGE_TOB_ADMIN_API_TOKEN=

# 0600 shell env file containing:
#   BRIDGE_FEISHU_VERIFICATION_TOKEN=...
BRIDGE_TOB_FEISHU_SECRET_ENV=

# 0600/plain local file containing only the public Feishu webhook URL.
BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE=

# Local fake or test OpenAI-compatible endpoint used for deterministic ack.
BRIDGE_TOB_LOCAL_LLM_BASE_URL=http://127.0.0.1:8787/v1
BRIDGE_TOB_LOCAL_LLM_MODEL=bridge-tob-local-smoke
BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE=.local/bridge-tob-local-llm.env

# Existing local smoke project/connect identifiers.
BRIDGE_TOB_SMOKE_PROJECT_ID=
BRIDGE_TOB_SMOKE_PROJECT_SLUG=
BRIDGE_TOB_SMOKE_GROUP_ID=
BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID=

# Optional overrides.
BRIDGE_TOB_SALIX_BASE_URL=http://127.0.0.1:4000
BRIDGE_TOB_PUBLIC_HEALTH_URL=
BRIDGE_TOB_START_FAKE_LLM=true
BRIDGE_TOB_EVIDENCE_PATH=/tmp/bridge-tob-acceptance-evidence.json
BRIDGE_TOB_LAST_EVENT_PATH=/tmp/bridge-tob-last-synthetic-event.json
BRIDGE_TOB_FEISHU_VERIFICATION_TOKEN_VAR=BRIDGE_FEISHU_VERIFICATION_TOKEN
EOF
}

die() {
  echo "bridge-tob acceptance harness: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$FAKE_LLM_PID" ]]; then
    kill "$FAKE_LLM_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --print-env-template)
    print_env_template
    exit 0
    ;;
  "")
    ;;
  *)
    usage
    die "unknown argument: $1"
    ;;
esac

load_env_file() {
  local file="$1"

  if [[ -f "$file" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$file"
    set +a
  fi
}

require_env() {
  local missing=()

  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("$name")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    usage
    die "missing required env: ${missing[*]}"
  fi
}

json_error() {
  local file="$1"
  jq '{error}' "$file" 2>/dev/null || true
}

write_private_file() {
  local file="$1"
  umask 077
  cat > "$file"
}

fake_llm_probe() {
  local body
  body="$(
    jq -n \
      --arg model "$BRIDGE_TOB_LOCAL_LLM_MODEL" \
      '{model:$model, stream:false, messages:[{role:"user", content:"ping"}]}'
  )"

  curl -fsS \
    -X POST "$BRIDGE_TOB_LOCAL_LLM_BASE_URL/chat/completions" \
    -H 'content-type: application/json' \
    --data "$body" \
    2>/dev/null |
    jq -e '.. | strings | select(contains("local smoke ack"))' >/dev/null 2>&1
}

start_fake_llm_if_needed() {
  if fake_llm_probe; then
    echo "fake LLM already responding"
    return
  fi

  if [[ "${BRIDGE_TOB_START_FAKE_LLM:-${THREAD_A_START_FAKE_LLM:-true}}" == "false" ]]; then
    die "fake LLM is not responding at BRIDGE_TOB_LOCAL_LLM_BASE_URL"
  fi

  python3 - "$BRIDGE_TOB_LOCAL_LLM_BASE_URL" <<'PY' &
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

base = urllib.parse.urlparse(sys.argv[1])
host = base.hostname or "127.0.0.1"
port = base.port or (443 if base.scheme == "https" else 80)
prefix = base.path.rstrip("/")
target = prefix + "/chat/completions"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        length = int(self.headers.get("content-length") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            body = {}

        if self.path != target:
            self.send_response(404)
            self.end_headers()
            return

        if body.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            chunk = {"choices": [{"delta": {"content": "local smoke ack"}, "index": 0}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode("utf-8"))
            done = {"choices": [{"delta": {}, "finish_reason": "stop", "index": 0}]}
            self.wfile.write(("data: " + json.dumps(done) + "\n\n").encode("utf-8"))
            self.wfile.write(b"data: [DONE]\n\n")
            return

        response = {
            "id": "bridge-tob-local-smoke",
            "object": "chat.completion",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": "local smoke ack"},
                    "finish_reason": "stop",
                }
            ],
        }
        data = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer((host, port), Handler)
server.serve_forever()
PY
  FAKE_LLM_PID="$!"
  sleep 0.5

  fake_llm_probe || die "failed to start fake LLM at BRIDGE_TOB_LOCAL_LLM_BASE_URL"
  echo "started temporary fake LLM"
}

load_env_file "$ENV_FILE"

BRIDGE_TOB_ADMIN_API_TOKEN="${BRIDGE_TOB_ADMIN_API_TOKEN:-${SALIX_API_TOKEN:-}}"
BRIDGE_TOB_FEISHU_SECRET_ENV="${BRIDGE_TOB_FEISHU_SECRET_ENV:-${THREAD_A_FEISHU_WEBHOOK_SECRET_ENV:-}}"
BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE="${BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE:-${THREAD_A_FEISHU_WEBHOOK_URL_FILE:-}}"
BRIDGE_TOB_LOCAL_LLM_BASE_URL="${BRIDGE_TOB_LOCAL_LLM_BASE_URL:-${THREAD_A_LOCAL_LLM_BASE_URL:-}}"
BRIDGE_TOB_LOCAL_LLM_MODEL="${BRIDGE_TOB_LOCAL_LLM_MODEL:-${THREAD_A_LOCAL_LLM_MODEL:-}}"
BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE="${BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE:-${THREAD_A_LOCAL_LLM_API_KEY_FILE:-}}"
BRIDGE_TOB_SMOKE_PROJECT_ID="${BRIDGE_TOB_SMOKE_PROJECT_ID:-${THREAD_A_SMOKE_PROJECT_ID:-}}"
BRIDGE_TOB_SMOKE_PROJECT_SLUG="${BRIDGE_TOB_SMOKE_PROJECT_SLUG:-${THREAD_A_SMOKE_PROJECT_SLUG:-}}"
BRIDGE_TOB_SMOKE_GROUP_ID="${BRIDGE_TOB_SMOKE_GROUP_ID:-${THREAD_A_SMOKE_GROUP_ID:-}}"
BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID="${BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID:-${THREAD_A_SMOKE_ROUTER_AGENT_ID:-}}"

SALIX_BASE_URL="${BRIDGE_TOB_SALIX_BASE_URL:-${THREAD_A_SALIX_BASE_URL:-http://127.0.0.1:4000}}"
EVIDENCE_PATH="${BRIDGE_TOB_EVIDENCE_PATH:-${THREAD_A_EVIDENCE_PATH:-/tmp/bridge-tob-acceptance-evidence.json}}"
LAST_EVENT_PATH="${BRIDGE_TOB_LAST_EVENT_PATH:-${THREAD_A_LAST_EVENT_PATH:-/tmp/bridge-tob-last-synthetic-event.json}}"
TOKEN_VAR="${BRIDGE_TOB_FEISHU_VERIFICATION_TOKEN_VAR:-${THREAD_A_FEISHU_VERIFICATION_TOKEN_VAR:-BRIDGE_FEISHU_VERIFICATION_TOKEN}}"

require_env \
  BRIDGE_TOB_ADMIN_API_TOKEN \
  BRIDGE_TOB_FEISHU_SECRET_ENV \
  BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE \
  BRIDGE_TOB_LOCAL_LLM_BASE_URL \
  BRIDGE_TOB_LOCAL_LLM_MODEL \
  BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE \
  BRIDGE_TOB_SMOKE_PROJECT_ID \
  BRIDGE_TOB_SMOKE_PROJECT_SLUG \
  BRIDGE_TOB_SMOKE_GROUP_ID \
  BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID

[[ -f "$BRIDGE_TOB_FEISHU_SECRET_ENV" ]] || die "missing BRIDGE_TOB_FEISHU_SECRET_ENV file"
[[ -f "$BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE" ]] || die "missing BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE file"

mkdir -p "$(dirname "$BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE")" "$(dirname "$EVIDENCE_PATH")" "$(dirname "$LAST_EVENT_PATH")"
if [[ ! -s "$BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE" ]]; then
  umask 077
  printf 'BRIDGE_TOB_LOCAL_LLM_API_KEY=%s\n' 'local-smoke-key' > "$BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE"
fi

load_env_file "$BRIDGE_TOB_FEISHU_SECRET_ENV"
load_env_file "$BRIDGE_TOB_LOCAL_LLM_API_KEY_FILE"
BRIDGE_TOB_LOCAL_LLM_API_KEY="${BRIDGE_TOB_LOCAL_LLM_API_KEY:-${THREAD_A_LOCAL_LLM_API_KEY:-}}"

[[ -n "${!TOKEN_VAR:-}" ]] || die "missing $TOKEN_VAR in BRIDGE_TOB_FEISHU_SECRET_ENV"
[[ -n "${BRIDGE_TOB_LOCAL_LLM_API_KEY:-}" ]] || die "missing BRIDGE_TOB_LOCAL_LLM_API_KEY"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bridge-tob-acceptance.XXXXXX")"
chmod 700 "$WORK_DIR"

WEBHOOK_URL="$(cat "$BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE")"
PUBLIC_HEALTH_URL="${BRIDGE_TOB_PUBLIC_HEALTH_URL:-${THREAD_A_PUBLIC_HEALTH_URL:-$(python3 - "$WEBHOOK_URL" <<'PY'
import sys
import urllib.parse
url = urllib.parse.urlparse(sys.argv[1])
print(f"{url.scheme}://{url.netloc}/health")
PY
)}}"

start_fake_llm_if_needed

echo "checking local Salix health..."
curl -fsS "$SALIX_BASE_URL/health" >/dev/null

echo "checking public callback health..."
curl -fsS "$PUBLIC_HEALTH_URL" >/dev/null

echo "self-repairing local default template to fake LLM..."
template_body="$(
  jq -n \
    --arg model "$BRIDGE_TOB_LOCAL_LLM_MODEL" \
    --arg base "$BRIDGE_TOB_LOCAL_LLM_BASE_URL" \
    --arg key "$BRIDGE_TOB_LOCAL_LLM_API_KEY" \
    '{model:$model, provider:"openai", provider_config:{protocol:"chat_completions", base_url:$base, api_key:$key}}'
)"
template_body_file="$WORK_DIR/template-body.json"
admin_curl_config="$WORK_DIR/admin.curl"
printf '%s' "$template_body" | write_private_file "$template_body_file"
{
  printf 'header = "authorization: Bearer %s"\n' "$BRIDGE_TOB_ADMIN_API_TOKEN"
  printf 'header = "content-type: application/json"\n'
} | write_private_file "$admin_curl_config"

http_status="$(
  curl -sS -o "$WORK_DIR/template-update.json" -w '%{http_code}' \
    --config "$admin_curl_config" \
    -X PATCH "$SALIX_BASE_URL/v1/admin/templates/default" \
    --data-binary "@$template_body_file"
)"
if [[ "$http_status" != "200" ]]; then
  json_error "$WORK_DIR/template-update.json" >&2
  die "template update failed with HTTP $http_status"
fi

echo "verifying Feishu URL challenge through public callback..."
challenge="bridge-tob-challenge-$(date +%s)-$RANDOM"
challenge_body="$(
  jq -n \
    --arg token "${!TOKEN_VAR}" \
    --arg challenge "$challenge" \
    '{schema:"2.0", header:{event_type:"url_verification", token:$token}, event:{challenge:$challenge}}'
)"
challenge_body_file="$WORK_DIR/url-verification-body.json"
challenge_response_file="$WORK_DIR/url-verification-response.json"
printf '%s' "$challenge_body" | write_private_file "$challenge_body_file"

http_status="$(
  curl -sS -o "$challenge_response_file" -w '%{http_code}' \
    -X POST "$WEBHOOK_URL" \
    -H 'content-type: application/json' \
    --data-binary "@$challenge_body_file"
)"
if [[ "$http_status" != "200" ]]; then
  json_error "$challenge_response_file" >&2
  die "URL verification failed with HTTP $http_status"
fi

got_challenge="$(jq -r '.challenge // empty' "$challenge_response_file")"
[[ "$got_challenge" == "$challenge" ]] || die "URL verification challenge mismatch"

echo "posting synthetic Feishu group mention event..."
suffix="$(date +%s)-$RANDOM"
marker="bridge-tob-local-ack-$suffix"
event_id="evt-bridge-tob-$suffix"
message_id="om_bridge_tob_${suffix//-/}"
event_body="$(
  jq -n \
    --arg event_id "$event_id" \
    --arg token "${!TOKEN_VAR}" \
    --arg message_id "$message_id" \
    --arg marker "$marker" \
    '{
      schema:"2.0",
      header:{event_id:$event_id,event_type:"im.message.receive_v1",token:$token,tenant_key:"tenant-bridge-tob-smoke"},
      event:{
        sender:{sender_type:"user",sender_id:{open_id:"ou_bridge_tob_smoke",user_id:"u_bridge_tob_smoke"},sender_name:"Bridge ToB Smoke"},
        message:{
          message_id:$message_id,
          chat_id:"oc_bridge_tob_smoke",
          chat_type:"group",
          message_type:"text",
          content:({text:("@Bridge " + $marker)}|tojson),
          create_time:(now*1000|floor|tostring)
        }
      }
    }'
)"
event_body_file="$WORK_DIR/synthetic-event-body.json"
event_response_file="$WORK_DIR/synthetic-event-response.json"
printf '%s' "$event_body" | write_private_file "$event_body_file"

http_status="$(
  curl -sS -o "$event_response_file" -w '%{http_code}' \
    -X POST "$WEBHOOK_URL" \
    -H 'content-type: application/json' \
    --data-binary "@$event_body_file"
)"
jq -n \
  --arg projectId "$BRIDGE_TOB_SMOKE_PROJECT_ID" \
  --arg projectSlug "$BRIDGE_TOB_SMOKE_PROJECT_SLUG" \
  --arg groupId "$BRIDGE_TOB_SMOKE_GROUP_ID" \
  --arg routerAgentId "$BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID" \
  --arg eventId "$event_id" \
  --arg messageId "$message_id" \
  --arg marker "$marker" \
  --arg httpStatus "$http_status" \
  --argjson response "$(cat "$event_response_file")" \
  '{
    projectId:$projectId,
    projectSlug:$projectSlug,
    groupId:$groupId,
    routerAgentId:$routerAgentId,
    eventId:$eventId,
    messageId:$messageId,
    marker:$marker,
    httpStatus:($httpStatus|tonumber),
    responseStatus:$response.status,
    ok:$response.ok
  }' > "$LAST_EVENT_PATH"

if [[ "$http_status" != "200" ]]; then
  json_error "$event_response_file" >&2
  die "synthetic event failed with HTTP $http_status"
fi

echo "waiting for router session to settle..."
sleep 3

read_session_script="$WORK_DIR/read-session.exs"
cat >"$read_session_script" <<'EXS'
Application.ensure_all_started(:salix_store)
Application.ensure_all_started(:salix_agent)
Application.ensure_all_started(:salix_im)

last = Jason.decode!(File.read!(System.fetch_env!("BRIDGE_TOB_LAST_EVENT_PATH")))
agent = last["routerAgentId"]
group = last["groupId"]
session_id = SalixIM.ProviderConnects.agent_group_router_session_id(agent, group)
{:ok, session} = SalixAgent.get_session(agent, session_id)
messages = session.messages || []
marker = last["marker"]
message_id = last["messageId"]

content = fn m -> to_string(Map.get(m, :content) || Map.get(m, "content") || "") end
role = fn m -> to_string(Map.get(m, :role) || Map.get(m, "role") || "") end
source = fn m -> to_string(Map.get(m, :source_message_id) || Map.get(m, "source_message_id") || "") end
idx = Enum.find_index(messages, fn m -> String.contains?(content.(m), marker) end)
window = if is_integer(idx), do: Enum.drop(messages, idx), else: []
ack = Enum.any?(window, fn m -> role.(m) == "assistant" and String.contains?(content.(m), "local smoke ack") end)
err = Enum.any?(window, fn m -> role.(m) == "assistant" and String.contains?(content.(m), "[LLM transport error]") end)

evidence = %{
  "ok" => true,
  "claim" => if(ack, do: "non-live-local-routed-to-conversation-with-fake-llm-ack", else: "routed-but-silent"),
  "checked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
  "project" => %{
    "slug" => last["projectSlug"],
    "project_id_prefix" => String.slice(last["projectId"], 0, 8),
    "router_agent_prefix" => String.slice(agent, 0, 12),
    "router_role" => "router"
  },
  "event" => %{
    "event_id_prefix" => String.slice(last["eventId"], 0, 18),
    "message_id_prefix" => String.slice(message_id, 0, 18),
    "chat_type" => "group",
    "message_type" => "text"
  },
  "webhook_post" => %{"http_status" => last["httpStatus"], "response_status" => last["responseStatus"]},
  "salix_session" => %{
    "session_id_prefix" => String.slice(session_id, 0, 12),
    "message_count" => length(messages),
    "marker_seen" => Enum.any?(messages, fn m -> String.contains?(content.(m), marker) end),
    "source_message_id_prefix_seen" => Enum.any?(messages, fn m -> String.starts_with?(source.(m), "im_provider:feishu:") end),
    "source_message_id_contains_message" => Enum.any?(messages, fn m -> String.contains?(source.(m), message_id) end),
    "assistant_ack_seen_after_marker" => ack,
    "llm_error_seen_after_marker" => err,
    "assistant_count" => Enum.count(messages, &(role.(&1) == "assistant")),
    "user_count" => Enum.count(messages, &(role.(&1) == "user"))
  },
  "limits" => %{
    "synthetic_event" => true,
    "live_feishu_client_message" => false,
    "same_group_feishu_reply" => false,
    "fake_llm" => true
  }
}

File.write!(System.fetch_env!("BRIDGE_TOB_EVIDENCE_PATH"), Jason.encode!(evidence, pretty: true))
IO.puts(Jason.encode!(evidence, pretty: true))
EXS

echo "reading durable router session evidence..."
(
  cd "$COMMA_ROOT/systems"
  BRIDGE_TOB_LAST_EVENT_PATH="$LAST_EVENT_PATH" BRIDGE_TOB_EVIDENCE_PATH="$EVIDENCE_PATH" \
    mix run --no-start "$read_session_script"
)

echo "evidence written: $EVIDENCE_PATH"
