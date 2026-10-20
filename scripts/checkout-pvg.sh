#!/usr/bin/env bash
# Bootstrap from this small file before the repository workspace exists.
# Git credentials are scoped to fetch and never enter the shared snapshot.
set -euo pipefail

# restore [exact]: seed .git from a peer snapshot of the commit or, unless
# `exact`, of its base.
restore() (
  set -euo pipefail
  config="${SYNCH_CACHE_SHARED_DIRECTORY:-/Volumes/My Shared Files/cache}/synch/s3.env"
  [[ -f "$config" && ! -e .git ]] || exit 0
  source "$config"
  repo_key="$(printf '%s' "$GITHUB_REPOSITORY" | od -An -tx1 | tr -d ' \n')"
  # A full-history checkout takes only a full snapshot; a shallow one takes
  # either, the shallow one first. Without one for this commit, a shallow
  # checkout starts from its base's (the pull request's base, or the commit
  # before a push), so only the change comes from GitHub.
  base="$(python3 -c 'import json, os; e = json.load(open(os.environ["GITHUB_EVENT_PATH"])); print((e.get("pull_request") or {}).get("base", {}).get("sha") or e.get("before") or "")' 2>/dev/null || true)"
  candidates=("$GITHUB_SHA:$GITHUB_SHA.tar")
  if [[ "${PVG_FETCH_DEPTH:-1}" != 0 ]]; then
    candidates=("$GITHUB_SHA:$GITHUB_SHA.shallow.tar" "${candidates[@]}")
    if [[ "${1:-}" != exact && "$base" =~ ^[0-9a-f]{40}$ && "$base" != "$GITHUB_SHA" ]]; then
      candidates+=("$base:$base.shallow.tar" "$base:$base.tar")
    fi
  fi
  scratch="$(mktemp -d "$RUNNER_TEMP/git-peer.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  auth=(--aws-sigv4 "aws:amz:us-east-1:s3" --user "$SYNCH_S3_ACCESS_KEY:$SYNCH_S3_SECRET_KEY")
  seed=""
  for candidate in "${candidates[@]}"; do
    if curl --fail --silent --show-error --connect-timeout 5 --speed-limit 1048576 --speed-time 30 \
      "${auth[@]}" "$SYNCH_S3_ENDPOINT/$SYNCH_S3_READ_BUCKET/comma-git/v1/$repo_key/${candidate#*:}" \
      -o "$scratch/snapshot.tar" 2>/dev/null; then
      seed="${candidate%%:*}"
      break
    fi
  done
  # A missed publish leaves the next push without a base snapshot. Start from
  # the newest ancestor a peer published instead, so GitHub still sends only
  # the change rather than the whole tree over the slow link.
  if [[ -z "$seed" && "${1:-}" != exact && "${PVG_FETCH_DEPTH:-1}" != 0 ]]; then
    for ancestor in $(ancestors); do
      [[ "$ancestor" != "$GITHUB_SHA" && "$ancestor" != "$base" ]] || continue
      for name in "$ancestor.shallow.tar" "$ancestor.tar"; do
        if curl --fail --silent --show-error --connect-timeout 5 --speed-limit 1048576 --speed-time 30 \
          "${auth[@]}" "$SYNCH_S3_ENDPOINT/$SYNCH_S3_READ_BUCKET/comma-git/v1/$repo_key/$name" \
          -o "$scratch/snapshot.tar" 2>/dev/null; then
          seed="$ancestor"
          break 2
        fi
      done
    done
  fi
  if [[ -z "$seed" ]]; then
    if [[ "${1:-}" == exact ]]; then
      echo "Synch git: no peer snapshot for $GITHUB_SHA"
    else
      echo "Synch git: no peer snapshot for $GITHUB_SHA or its base"
    fi
    exit 0
  fi
  mkdir "$scratch/repo"
  # Extract into an isolated repository. Only packfiles and shallow metadata
  # become checkout inputs; config, hooks and credentials never do.
  if ! tar -xf "$scratch/snapshot.tar" -C "$scratch/repo"; then
    echo "::warning::Synch git: snapshot extraction failed"
    exit 0
  fi
  git init -q "$scratch/seed"
  mkdir -p "$scratch/seed/.git/objects/pack"
  cp "$scratch/repo/objects/pack/"*.pack "$scratch/repo/objects/pack/"*.idx "$scratch/seed/.git/objects/pack/"
  [[ ! -f "$scratch/repo/shallow" ]] || cp "$scratch/repo/shallow" "$scratch/seed/.git/shallow"
  if ! git -C "$scratch/seed" update-ref refs/remotes/synch/seed "$seed"; then
    echo "::warning::Synch git: snapshot does not contain the requested commit"
    exit 0
  fi
  git -C "$scratch/seed" update-ref --no-deref HEAD "$seed"
  git -C "$scratch/seed" remote add origin "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
  mv "$scratch/seed/.git" .git
  if [[ "$seed" == "$GITHUB_SHA" ]]; then
    echo "Synch git: restored $GITHUB_SHA from peers"
  else
    echo "Synch git: restored base $seed from peers; fetching only the change"
  fi
)

publish() (
  set -euo pipefail
  config="${SYNCH_CACHE_SHARED_DIRECTORY:-/Volumes/My Shared Files/cache}/synch/s3.env"
  if [[ ! -f "$config" ]]; then
    if [[ "${PVG_REQUIRE_CACHE:-false}" == true ]]; then
      echo "::error::Synch git: the runner has no in-cluster cache configuration"
      exit 1
    fi
    exit 0
  fi
  source "$config"
  repo_key="$(printf '%s' "$GITHUB_REPOSITORY" | od -An -tx1 | tr -d ' \n')"
  # A shallow clone publishes under its own name: a full-history checkout never takes it.
  suffix=tar
  [[ "$(git rev-parse --is-shallow-repository)" != true ]] || suffix=shallow.tar
  object="comma-git/v1/$repo_key/$GITHUB_SHA.$suffix"
  auth=(--aws-sigv4 "aws:amz:us-east-1:s3" --user "$SYNCH_S3_ACCESS_KEY:$SYNCH_S3_SECRET_KEY")
  transfer=(--fail --silent --show-error --connect-timeout 5 --speed-limit 1048576 --speed-time 30)
  # Checkout holds the snapshot's cluster lock already; run alone, publish
  # takes it so concurrent publishers of one commit upload it once.
  release=:
  if [[ -z "${synch_lock_url:-}" ]] && load_lock_library; then
    synch_lock_acquire "$object" || true
    release=synch_lock_release
    trap "$release" EXIT
  fi
  if curl "${transfer[@]}" "${auth[@]}" -I -o /dev/null "$SYNCH_S3_ENDPOINT/$SYNCH_S3_READ_BUCKET/$object" 2>/dev/null; then
    echo "Synch git: a peer already published $GITHUB_SHA"
    exit 0
  fi
  # Checkout remains responsible for selecting the requested source revision.
  git cat-file -e "$GITHUB_SHA^{commit}"
  scratch="$(mktemp -d "$RUNNER_TEMP/git-publish.XXXXXX")"
  trap 'rm -rf "$scratch"; $release' EXIT
  mkdir -p "$scratch/objects/pack"
  # Repack reachable objects to include objects supplied through alternates.
  git pack-objects --revs --all "$scratch/objects/pack/pack" </dev/null >/dev/null
  shallow="$(git rev-parse --git-path shallow)"
  [[ ! -f "$shallow" ]] || cp "$shallow" "$scratch/shallow"
  tar -cf "$scratch/snapshot.tar" -C "$scratch" objects
  [[ ! -f "$scratch/shallow" ]] || tar -rf "$scratch/snapshot.tar" -C "$scratch" shallow
  curl "${transfer[@]}" "${auth[@]}" -T "$scratch/snapshot.tar" -o /dev/null \
    "$SYNCH_S3_ENDPOINT/$SYNCH_S3_WRITE_BUCKET/$object"
  echo "Synch git: published $GITHUB_SHA"
  # This script too: the commit's later jobs start from it here, not from the
  # Contents API (the workflows' "Checkout through PVG peers").
  if git cat-file -e "$GITHUB_SHA:scripts/checkout-pvg.sh" 2>/dev/null; then
    git show "$GITHUB_SHA:scripts/checkout-pvg.sh" |
      curl "${transfer[@]}" "${auth[@]}" -T - -o /dev/null \
        "$SYNCH_S3_ENDPOINT/$SYNCH_S3_WRITE_BUCKET/comma-git/v1/$repo_key/$GITHUB_SHA.checkout-pvg.sh" ||
      echo "::warning::Synch git: publishing checkout-pvg.sh failed"
  fi
)

# The commit's recent ancestors, newest first, from the API (no checkout yet).
ancestors() {
  local auth=()
  [[ -z "${GH_TOKEN:-}" ]] || auth=(-H "Authorization: Bearer $GH_TOKEN")
  curl --fail --silent --show-error --connect-timeout 10 --max-time 30 ${auth[@]+"${auth[@]}"} \
    "${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/commits?sha=$GITHUB_SHA&per_page=30" 2>/dev/null |
    python3 -c 'import json, re, sys; print("\n".join(c["sha"] for c in json.load(sys.stdin) if re.fullmatch("[0-9a-f]{40}", c.get("sha", ""))))' 2>/dev/null || true
}

# Cluster locks (scripts/synch-lock.sh) come from the requested commit: next
# to this script in a checkout, otherwise through the Contents API like this
# script itself. Without them every job proceeds unlocked.
load_lock_library() {
  declare -F synch_lock_acquire >/dev/null && return 0
  local library
  library="$(dirname "${BASH_SOURCE[0]}")/synch-lock.sh"
  if [[ ! -f "$library" ]]; then
    library="$RUNNER_TEMP/synch-lock.sh"
    curl --fail --silent --show-error --retry 3 --connect-timeout 10 --max-time 60 \
      -H "Authorization: Bearer ${GH_TOKEN:-}" -H "Accept: application/vnd.github.raw+json" \
      "${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/contents/scripts/synch-lock.sh?ref=$GITHUB_SHA" \
      -o "$library" 2>/dev/null || return 1
  fi
  # shellcheck source=scripts/synch-lock.sh
  source "$library"
}

# The jobs of a run start together, before their commit has a snapshot. The
# first to miss it holds the snapshot's cluster lock while it fetches the
# change from GitHub and publishes; the others wait, then restore that
# snapshot. Returns 1 without a lock, and the job proceeds alone.
lock_snapshot() {
  local config="${SYNCH_CACHE_SHARED_DIRECTORY:-/Volumes/My Shared Files/cache}/synch/s3.env"
  [[ -f "$config" ]] || return 1
  # shellcheck disable=SC1090
  source "$config"
  load_lock_library || return 1
  local repo_key suffix=shallow.tar
  repo_key="$(printf '%s' "$GITHUB_REPOSITORY" | od -An -tx1 | tr -d ' \n')"
  [[ "${PVG_FETCH_DEPTH:-1}" != 0 ]] || suffix=tar
  synch_lock_acquire "comma-git/v1/$repo_key/$GITHUB_SHA.$suffix" || return 1
  trap 'synch_lock_release' EXIT
}

checkout() {
  cd "${GITHUB_WORKSPACE:-$PWD}"
  if [[ ! -e .git ]]; then
    restore exact || echo "::warning::Synch git: restore failed"
  fi
  if [[ ! -e .git ]] && lock_snapshot; then
    # A peer may have published while this job waited for the lock.
    restore exact || echo "::warning::Synch git: restore failed"
  fi
  if [[ ! -e .git ]]; then
    restore || echo "::warning::Synch git: restore failed; fetching from origin"
  fi
  if [[ ! -e .git ]]; then
    git init -q .
    git remote add origin "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
  fi
  local depth="${PVG_FETCH_DEPTH:-1}"
  [[ "$depth" =~ ^[0-9]+$ ]] || { echo "Invalid fetch depth" >&2; return 1; }
  local extra=()
  if [[ "$depth" == 0 ]]; then
    if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
      extra+=(--unshallow)
    fi
    fetch ${extra[@]+"${extra[@]}"} origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' "$GITHUB_SHA"
  elif ! git cat-file -e "$GITHUB_SHA^{commit}" 2>/dev/null; then
    fetch --no-tags --depth="$depth" origin "$GITHUB_SHA"
  fi
  git -c advice.detachedHead=false checkout --force --detach "$GITHUB_SHA"
  git clean -ffdx
  if [[ "${PVG_REQUIRE_CACHE:-false}" == true ]]; then
    publish
  else
    publish || echo "::warning::Synch git: publication failed"
  fi
  if declare -F synch_lock_release >/dev/null; then synch_lock_release; fi
}

# fetch-commit SHA: another commit's objects at depth 1, unless the checkout
# has them already, as one restored from that commit's snapshot does.
fetch_commit() {
  cd "${GITHUB_WORKSPACE:-$PWD}"
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || { echo "fetch-commit: a commit SHA is required" >&2; return 2; }
  git cat-file -e "$1^{commit}" 2>/dev/null || fetch --no-tags --depth=1 origin "$1"
}

fetch() {
  # Git's environment configuration applies only to this process and children.
  if [[ -n "${GH_TOKEN:-}" ]]; then
    local auth
    auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.$GITHUB_SERVER_URL/.extraheader" \
      GIT_CONFIG_VALUE_0="$auth" git -c gc.auto=0 fetch --force "$@"
  else
    git -c gc.auto=0 fetch --force "$@"
  fi
}

case "${1:-checkout}" in
  checkout) checkout ;;
  restore) restore ;;
  publish) publish ;;
  fetch-commit) fetch_commit "${2:-}" ;;
  *) echo "Usage: checkout-pvg.sh [checkout|restore|publish|fetch-commit SHA]" >&2; exit 2 ;;
esac
