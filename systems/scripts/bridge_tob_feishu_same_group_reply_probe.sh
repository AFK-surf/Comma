#!/usr/bin/env bash
set -euo pipefail

# Redacted Feishu same-group reply probe.
#
# Uses lark-cli bot identity to read recent messages in a target Feishu group
# and emits a report-friendly evidence JSON. Raw chat IDs, message IDs, sender
# IDs, and message bodies stay in a 0600 scratch file and are never printed.

CHAT_ID_FILE="${BRIDGE_TOB_FEISHU_CHAT_ID_FILE:-}"
EVIDENCE_PATH="${BRIDGE_TOB_FEISHU_REPLY_PROBE_EVIDENCE_PATH:-/tmp/bridge-tob-feishu-same-group-reply-probe.json}"
PAGE_SIZE="${BRIDGE_TOB_FEISHU_REPLY_PROBE_PAGE_SIZE:-20}"
WORK_DIR="${BRIDGE_TOB_FEISHU_REPLY_PROBE_WORK_DIR:-${TMPDIR:-/tmp}/bridge-tob-feishu-reply-probe.$$}"

die() {
  echo "bridge-tob Feishu same-group reply probe: $*" >&2
  exit 1
}

redact_file() {
  sed -E \
    -e 's/cli_[A-Za-z0-9]+/cli_[REDACTED]/g' \
    -e 's/oc_[A-Za-z0-9]+/oc_[REDACTED]/g' \
    -e 's/ou_[A-Za-z0-9]+/ou_[REDACTED]/g' \
    -e 's/om_[A-Za-z0-9_-]+/om_[REDACTED]/g' \
    -e 's/(token|secret|authorization|cookie|session|csrf)(["=:{ ]+)[^",} ]+/\1\2[REDACTED]/Ig' \
    "$1" | head -c 1600
}

[[ -n "$CHAT_ID_FILE" ]] || die "set BRIDGE_TOB_FEISHU_CHAT_ID_FILE"
[[ -s "$CHAT_ID_FILE" ]] || die "chat id file is missing or empty"
command -v lark-cli >/dev/null 2>&1 || die "lark-cli not found"

umask 077
mkdir -p "$WORK_DIR" "$(dirname "$EVIDENCE_PATH")"

chat_id="$(tr -d '\n' < "$CHAT_ID_FILE")"
raw_response="$WORK_DIR/chat-messages.raw.json"
raw_error="$WORK_DIR/chat-messages.err"

set +e
lark-cli im +chat-messages-list \
  --as bot \
  --chat-id "$chat_id" \
  --page-size "$PAGE_SIZE" \
  --sort desc \
  --format json >"$raw_response" 2>"$raw_error"
cmd_status=$?
set -e

checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "$cmd_status" != "0" ]]; then
  redacted_error="$(redact_file "$raw_error")"
  jq -n \
    --arg checked_at "$checked_at" \
    --arg error "$redacted_error" \
    '{
      checked_at: $checked_at,
      same_group_reply_probe: {
        attempted: true,
        ok: false,
        status: "lark_cli_chat_messages_list_failed",
        method: "lark_cli_chat_messages_list",
        failure_code: "lark_cli_chat_messages_list_failed",
        stderr_redacted: $error,
        next_action: "ensure lark-cli bot identity can read recent messages for the target Feishu group",
        limits: {
          raw_chat_id_redacted: true,
          raw_message_ids_redacted: true,
          raw_sender_ids_redacted: true,
          raw_message_body_redacted: true
        }
      }
    }' >"$EVIDENCE_PATH"
  jq '.same_group_reply_probe' "$EVIDENCE_PATH"
  exit 0
fi

jq -n \
  --arg checked_at "$checked_at" \
  --slurpfile raw "$raw_response" '
  def items: ($raw[0].data.messages // $raw[0].data.items // $raw[0].messages // []);
  def sender_type($m): ($m.sender.sender_type // "system");
  def text_message($m): (($m.msg_type // "") == "text");
  def latest_user_index:
    ([range(0; items | length) as $i | select(sender_type(items[$i]) == "user") | $i] | first // null);
  def app_reply_after_latest_user:
    (latest_user_index) as $idx
    | if $idx == null then false
      else any(range(0; $idx); sender_type(items[.]) == "app" and text_message(items[.]))
      end;

  {
    checked_at: $checked_at,
    same_group_reply_probe: {
      attempted: true,
      ok: app_reply_after_latest_user,
      status: (if app_reply_after_latest_user then "feishu_group_app_reply_after_latest_user" else "no_app_reply_after_latest_user" end),
      method: "lark_cli_chat_messages_list",
      message_count: (items | length),
      latest_user_seen: (latest_user_index != null),
      app_reply_after_latest_user: app_reply_after_latest_user,
      sender_sequence_desc: (items | map(sender_type(.)) | .[0:12]),
      msg_type_sequence_desc: (items | map(.msg_type // "unknown") | .[0:12]),
      next_action: (if app_reply_after_latest_user then null else "wait for a bot reply in the target Feishu group, or inspect outbound send failures" end),
      limits: {
        raw_chat_id_redacted: true,
        raw_message_ids_redacted: true,
        raw_sender_ids_redacted: true,
        raw_message_body_redacted: true
      }
    }
  }' >"$EVIDENCE_PATH"

jq '.same_group_reply_probe' "$EVIDENCE_PATH"
