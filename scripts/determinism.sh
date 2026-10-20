#!/bin/sh
# Finds code that makes a test's result depend on more than the code and the
# test: real time, real timers, deadlines, unseeded randomness and fixed ports
# (lint/determinism/rules, docs/testing.md#deterministic-tests). The findings
# that exist are a ledger that only shrinks: a change may remove findings from
# a file, never add one.
#
#   scripts/determinism.sh report        findings per rule and per area of the tree
#   scripts/determinism.sh list [PATH]   each finding under PATH with its source line
#   scripts/determinism.sh check [BASE]  fail if a file changed since BASE has more
#                                        findings of a rule than it had at BASE
#                                        (BASE defaults to the merge base with
#                                        origin/main; the working tree is compared)
#   scripts/determinism.sh staged        the same for staged files against HEAD
#
# check also fails when a list of test files left outside a deterministic suite
# (determinism/unit-real-io.txt, determinism/*-unsettled.txt) lists a file
# it did not list at BASE: these lists only shrink. An *-unsettled list may
# gain files only with DETERMINISM_LIST_GROW=true (the Determinism workflow
# sets it for a pull request the determinism owner labelled
# determinism-list-grow); the check prints them. unit-real-io.txt only shrinks.
#
# check fails as well when systems/apps/systems_clock/priv/node_timers.exs,
# the services that hold a timer on the BEAM test node, names one it did not
# name at BASE: a new worker is kept off the test node, not listed.
#
# Both sides are scanned with the current rules, so a rule change alone never
# counts as a new finding. A renamed file keeps the findings of its old path.
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"
sg="$root/scripts/ast-grep.sh"
config=lint/determinism/sgconfig.yml

# The pinned ast-grep must run: a scan that cannot run must never read as a
# tree without findings.
"$sg" --version > /dev/null

# Writes "RULE<TAB>FILE<TAB>LINE" to OUT for each finding in PATHS under DIR,
# with the -tsx suffix folded into the TypeScript rule. ast-grep exits 1 when
# it finds something; any other failure stops the script.
findings() {
  out=$1 dir=$2
  shift 2
  status=0
  (cd "$dir" && "$sg" scan --config "$config" --format github "$@") > "$out.raw" 2> "$out.err" ||
    status=$?
  if [ "$status" -gt 1 ]; then
    cat "$out.err" >&2
    echo "determinism.sh: ast-grep scan failed with status $status" >&2
    exit "$status"
  fi
  sed -n 's/^::error file=\([^,]*\),line=\([0-9]*\),.*title=\([^:]*\)::.*$/\3	\1	\2/p' "$out.raw" |
    sed 's/^tsx-/ts-/' > "$out"
}

# Copies the rules into a scratch root, so files from another revision are
# scanned there with the rules of the working tree.
scratch_root() {
  mkdir -p "$1/lint"
  cp -R "$root/lint/determinism" "$1/lint/"
}

# Reads "STATUS<TAB>OLD[<TAB>NEW]" lines of a name-status diff and writes the
# compared versions of each changed file: $2/base/PATH from the old revision
# ($3, a tree-ish or "" for the index) and $2/head/PATH from the new one ($4,
# "worktree", "index" or a tree-ish), both under the new path.
materialize() {
  list=$1 tmp=$2 old_rev=$3 new_rev=$4
  : > "$tmp/paths"
  while IFS='	' read -r status old new; do
    [ -n "${new:-}" ] || new=$old
    case $status in
      A*) old= ;;
      M* | R* | C*) ;;
      *) continue ;;
    esac
    case $new in
      *.ts | *.tsx | *.mts | *.cts | *.js | *.mjs | *.cjs | *.go | *.ex | *.exs | *.py | *.swift | *.kt | *.rs) ;;
      *) continue ;;
    esac
    printf '%s\n' "$new" >> "$tmp/paths"
    mkdir -p "$tmp/base/$(dirname "$new")" "$tmp/head/$(dirname "$new")"
    if [ -n "$old" ]; then
      git show "$old_rev:$old" > "$tmp/base/$new" 2>/dev/null || : > "$tmp/base/$new"
    fi
    case $new_rev in
      worktree) [ -f "$new" ] && cp "$new" "$tmp/head/$new" ;;
      index) git show ":$new" > "$tmp/head/$new" ;;
      *) git show "$new_rev:$new" > "$tmp/head/$new" ;;
    esac
  done < "$list"
}

compare() {
  tmp=$1
  if [ ! -s "$tmp/paths" ]; then
    return 0
  fi
  scratch_root "$tmp/base"
  scratch_root "$tmp/head"
  findings "$tmp/base.all" "$tmp/base" .
  cut -f1,2 "$tmp/base.all" | sort | uniq -c > "$tmp/base.counts"
  findings "$tmp/head.all" "$tmp/head" .
  sort -k2,2 -k3,3n "$tmp/head.all" > "$tmp/head.findings"
  cut -f1,2 "$tmp/head.findings" | sort | uniq -c > "$tmp/head.counts"
  awk -v base="$tmp/base.counts" '
    BEGIN {
      while ((getline line < base) > 0) {
        n = split(line, f, " ")
        key = line; sub(/^ *[0-9]+ /, "", key)
        had[key] = f[1]
      }
    }
    {
      count = $1; key = $0; sub(/^ *[0-9]+ /, "", key)
      if (count > had[key] + 0) print key "\t" count "\t" had[key] + 0
    }
  ' "$tmp/head.counts" > "$tmp/grown"
  if [ ! -s "$tmp/grown" ]; then
    return 0
  fi
  while IFS='	' read -r rule file count had; do
    echo "$file: $count findings of $rule, $had before." >&2
    awk -F'\t' -v r="$rule" -v f="$file" '$1 == r && $2 == f { print "  " f ":" $3 }' "$tmp/head.findings" >&2
    sed -n '/^id: '"$rule"'$/,/^metadata:/p' lint/determinism/rules/*.yml |
      sed -n 's/^message: "\(.*\)"$/  \1/p' | head -n 1 >&2
  done < "$tmp/grown"
  cat >&2 <<'EOF'

A test's result must depend only on the code and the test. Remove the new
findings above: wait for the event instead of real time, move a test clock,
use fixed values. The rule's note says how (lint/determinism/rules), and
docs/testing.md#deterministic-tests explains the contract.
EOF
  return 1
}

command=${1:-report}
case $command in
  report)
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    findings "$tmp/all" "$root" .
    total=$(wc -l < "$tmp/all" | tr -d ' ')
    echo "Determinism ledger: $total findings."
    echo
    echo "By rule:"
    cut -f1 "$tmp/all" | sort | uniq -c | sort -rn
    echo
    echo "By area:"
    awk -F'\t' '{ n = split($2, p, "/"); a = p[1]; if (n > 2) a = a "/" p[2]; if (n > 3) a = a "/" p[3]; print a }' "$tmp/all" |
      sort | uniq -c | sort -rn
    ;;
  list)
    shift
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    findings "$tmp/all" "$root" "${@:-.}"
    sort -k2,2 -k3,3n "$tmp/all" | while IFS='	' read -r rule file line; do
      printf '%s:%s\t%s\t%s\n' "$file" "$line" "$rule" "$(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//' | cut -c1-120)"
    done
    ;;
  check)
    base=${2:-$(git merge-base HEAD origin/main)}
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    git diff --name-status -M "$base" -- > "$tmp/diff"
    git ls-files --others --exclude-standard | sed 's/^/A	/' >> "$tmp/diff"
    materialize "$tmp/diff" "$tmp" "$base" worktree
    compare "$tmp"
    for list in determinism/unit-real-io.txt determinism/unit-unsettled.txt \
      determinism/browser-unsettled.txt; do
      git cat-file -e "$base:$list" 2>/dev/null || continue
      git show "$base:$list" | grep '^clients/' | sort > "$tmp/list-base"
      grep '^clients/' "$root/$list" | sort > "$tmp/list-now"
      added=$(comm -13 "$tmp/list-base" "$tmp/list-now")
      [ -n "$added" ] || continue
      case "$list" in
        *-unsettled.txt)
          if [ "${DETERMINISM_LIST_GROW:-}" = true ]; then
            printf '%s gains, labelled determinism-list-grow:\n%s\n' "$list" "$added" >&2
            continue
          fi
          ;;
      esac
      printf '%s only shrinks; it now lists:\n%s\n' "$list" "$added" >&2
      exit 1
    done
    list=systems/apps/systems_clock/priv/node_timers.exs
    if git cat-file -e "$base:$list" 2>/dev/null; then
      # Each entry is a line `  Service => "what its timer does"`.
      git show "$base:$list" | sed -n 's/^  \([A-Z][A-Za-z0-9_.]*\) =>.*/\1/p' | sort > "$tmp/list-base"
      sed -n 's/^  \([A-Z][A-Za-z0-9_.]*\) =>.*/\1/p' "$root/$list" | sort > "$tmp/list-now"
      added=$(comm -13 "$tmp/list-base" "$tmp/list-now")
      if [ -n "$added" ]; then
        printf '%s only shrinks; it now lists:\n%s\n' "$list" "$added" >&2
        printf 'Keep a new worker from starting on the test node with a switch in systems/config/test.exs.\n' >&2
        exit 1
      fi
    fi
    ;;
  staged)
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    git diff --cached --name-status -M > "$tmp/diff"
    materialize "$tmp/diff" "$tmp" HEAD index
    compare "$tmp"
    ;;
  *)
    echo "usage: scripts/determinism.sh report | list [PATH...] | check [BASE] | staged" >&2
    exit 2
    ;;
esac
