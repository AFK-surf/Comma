# shellcheck shell=bash
# Cluster locks through the in-cluster Synchronicity gateway, for CI scripts
# that publish shared snapshots. Source after the gateway's s3.env, then:
#
#   synch_lock_acquire <name>   # holds locks/<name>, or proceeds without it
#   ...
#   synch_lock_release          # releases what acquire took, if anything
#
# The gateway treats keys of $SYNCH_S3_LOCK_BUCKET under `locks/` as cluster
# locks (synchronicity docs/LOCKS.md §11): a PUT with `If-None-Match: *`
# acquires, answering 412 while another runner holds the lock and 409 or 503
# while a claim or handoff is settling; DELETE with the token releases. A
# hold is a lease of SYNCH_LOCK_TTL seconds, so a job that dies holding it
# only delays others until it expires.
#
# A lock only saves duplicate work, so it never fails the job: without a
# lock bucket, on any other answer, or after SYNCH_LOCK_WAIT seconds of
# waiting, acquire returns 1 and the caller proceeds unlocked, re-checking
# whatever the lock would have told it.

synch_lock_url=""
synch_lock_token=""

synch_lock_acquire() {
  local name="$1" deadline status headers
  synch_lock_url=""
  synch_lock_token=""
  [[ -n "${SYNCH_S3_LOCK_BUCKET:-}" ]] || return 1
  local url="$SYNCH_S3_ENDPOINT/$SYNCH_S3_LOCK_BUCKET/locks/$name"
  local auth=(--aws-sigv4 "aws:amz:us-east-1:s3" --user "$SYNCH_S3_ACCESS_KEY:$SYNCH_S3_SECRET_KEY")
  headers="$(mktemp "${RUNNER_TEMP:-/tmp}/synch-lock.XXXXXX")"
  deadline=$((SECONDS + ${SYNCH_LOCK_WAIT:-600}))
  while :; do
    status="$(curl --silent --connect-timeout 5 --max-time 60 "${auth[@]}" -X PUT \
      -H 'If-None-Match: *' -H "x-amz-meta-synch-lock-ttl: ${SYNCH_LOCK_TTL:-900}" \
      --data-binary "${RUNNER_NAME:-runner} ${GITHUB_RUN_ID:-} ${GITHUB_JOB:-}" \
      -D "$headers" -o /dev/null -w '%{http_code}' "$url")" || status=000
    case "$status" in
      200)
        synch_lock_url="$url"
        synch_lock_token="$(awk 'tolower($1) == "etag:" { gsub(/[\r"]/, "", $2); print $2 }' "$headers")"
        rm -f "$headers"
        return 0
        ;;
      409 | 412 | 503)
        if ((SECONDS >= deadline)); then
          echo "::warning::Synch lock $name: still held after ${SYNCH_LOCK_WAIT:-600}s; proceeding without it"
          break
        fi
        sleep "$((2 + RANDOM % 3))"
        ;;
      *)
        echo "::warning::Synch lock $name: gateway answered $status; proceeding without it"
        break
        ;;
    esac
  done
  rm -f "$headers"
  return 1
}

synch_lock_release() {
  [[ -n "$synch_lock_url" ]] || return 0
  curl --silent --connect-timeout 5 --max-time 30 \
    --aws-sigv4 "aws:amz:us-east-1:s3" --user "$SYNCH_S3_ACCESS_KEY:$SYNCH_S3_SECRET_KEY" \
    -X DELETE -H "If-Match: \"$synch_lock_token\"" -o /dev/null "$synch_lock_url" || true
  synch_lock_url=""
  synch_lock_token=""
}
