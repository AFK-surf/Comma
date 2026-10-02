#!/usr/bin/env bash
# System-core Salix models only; coverage policy: ../README.md.
set -euo pipefail
cd "$(dirname "$0")"

TLA_TOOLS_VERSION="1.7.4"
TLA_TOOLS_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA_TOOLS_VERSION}/tla2tools.jar"
TLA_TOOLS_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"

CACHE_DIR="${TLA_CACHE_DIR:-${HOME}/.cache/comma-tla}"
JAR="${TLA_TOOLS_JAR:-${CACHE_DIR}/tla2tools-${TLA_TOOLS_VERSION}.jar}"
JAVA_BIN="${TLA_JAVA_BIN:-java}"
TLA_WORKERS="${TLA_WORKERS:-auto}"

# spec  config  expectation(ok|violation)  expected-property(optional)
MANIFEST="
HeadCommit       HeadCommit                    ok
Lease            Lease                         ok
Lease            Lease_BeliefExclusion         violation
Lease            Lease_EpochReset              violation
SessionEpochFence SessionEpochFence_Safety     ok
SessionEpochFence SessionEpochFence_UnsafeRebase violation FenceSafety
SessionEpochFence SessionEpochFence_LegacyStrip violation FenceSafety
SessionHotArchive SessionHotArchive_Safety          ok
SessionHotArchive SessionHotArchive_DeepFaults      ok
SessionHotArchive SessionHotArchive_Liveness        ok
SessionHotArchive SessionHotArchive_SettleBlind     violation
SessionHotArchive SessionHotArchive_AdvanceFirst    violation
SessionHotArchive SessionHotArchive_ChunkFromMemory violation
SessionHotArchive SessionHotArchive_LateApply       ok
ArchiveAppend     ArchiveAppend_Safety              ok
ArchiveAppend     ArchiveAppend_Liveness            ok
ArchiveAppend     ArchiveAppend_NoFence             violation
RpcDeliver       RpcDeliver_Safety             ok
RpcDeliver       RpcDeliver_NoFence            violation
RpcDeliver       RpcDeliver_FenceResidual      violation
RpcDeliver       RpcDeliver_NoDedupe           violation
RpcDeliver       RpcDeliver_NoReclassify       violation
RpcDeliver       RpcDeliver_LateFlipResidual   violation
RpcDeliver       RpcDeliver_NoSessionAuthority violation
RpcDeliver       RpcDeliver_NoBirthAuthority   violation
RpcDeliver       RpcDeliver_NoProbeAuthority   violation
RpcDeliver       RpcDeliver_NoStoreGuard       violation
RpcDeliver       RpcDeliver_NoStrictWritable   violation
RpcDeliver       RpcDeliver_ExecutionWitness   ok
ExternalRuntime ExternalRuntime_Safety           ok
ExternalRuntime ExternalRuntime_RestartRelease   ok
ExternalRuntime ExternalRuntime_AckRuns          violation
ExternalRuntime ExternalRuntime_UnsafeIdentity   violation
ExternalRuntime ExternalRuntime_ClearQueue       violation
ExternalRuntime ExternalRuntime_StaleCapability  violation
ExternalRuntime ExternalRuntime_UnsafeFailedRedispatch violation
ExternalRuntime ExternalRuntime_UnsafeSteerFence violation
ExternalRuntime ExternalRuntime_UnsafePrePersistFence violation
ExternalRuntime ExternalRuntime_NoRestartRelease violation
ExternalRuntime ExternalRuntime_UnsafeSourceBatch violation ProviderSourceIsolated
ExternalRuntime ExternalRuntime_UnsafeLocalRefusal violation QueueAccounting
ComputeCapacityAction ComputeCapacityAction_Safety ok
ComputeCapacityAction ComputeCapacityAction_UnsafeTimerRetry violation NoAutomaticRetry
"

fetch_jar() {
  [ -f "$JAR" ] && return 0
  mkdir -p "$(dirname "$JAR")"
  echo "fetching tla2tools ${TLA_TOOLS_VERSION} ..."
  curl -fsSL --retry 4 --retry-delay 2 -o "${JAR}.tmp" "$TLA_TOOLS_URL"
  echo "${TLA_TOOLS_SHA256}  ${JAR}.tmp" | sha256sum -c - >/dev/null
  mv "${JAR}.tmp" "$JAR"
}

# Roster discovery does not fetch Java or run TLC.
if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "$MANIFEST" | awk 'NF {print $2}'
  exit 0
fi

python3 ../check-budget.py
fetch_jar
if ! echo "${TLA_TOOLS_SHA256}  ${JAR}" | sha256sum -c - >/dev/null 2>&1; then
  echo "ERROR: ${JAR} does not match the pinned sha256" >&2
  exit 1
fi

METADIR="$(mktemp -d)"
trap 'rm -rf "$METADIR"' EXIT

# TLC writes trace-exploration files and states/ into its cwd on
# violations; run from a scratch copy so the spec directory stays pristine.
WORKDIR="${METADIR}/work"
mkdir -p "$WORKDIR"
cp ./*.tla ./*.cfg "$WORKDIR/"

filter=("$@")
wanted() {
  [ ${#filter[@]} -eq 0 ] && return 0
  local c
  for c in "${filter[@]}"; do [ "$c" = "$1" ] && return 0; done
  return 1
}

fail=0
ran=0
while read -r spec cfg expect expected_property; do
  [ -z "${spec:-}" ] && continue
  wanted "$cfg" || continue
  ran=$((ran + 1))
  out="${METADIR}/${cfg}.out"
  # TLC exit codes: 0 = no error; 12 = safety violation; 13 = liveness
  # violation.  Anything else (parse error, timeout, OOM) is a hard failure
  # for both expectations.
  set +e
  (cd "$WORKDIR" && "$JAVA_BIN" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
    -deadlock -workers "$TLA_WORKERS" -metadir "$METADIR/states-$cfg" \
    -config "${cfg}.cfg" "$spec") >"$out" 2>&1
  code=$?
  set -e
  case "$expect" in
    ok)
      if [ "$code" -eq 0 ] && grep -q "No error has been found" "$out"; then
        printf '  ok         %s\n' "$cfg"
      else
        printf '  FAIL       %s (exit %s)\n' "$cfg" "$code"
        tail -n 40 "$out" | sed 's/^/    /'
        fail=1
      fi
      ;;
    violation)
      if [ "$code" -eq 12 ] || [ "$code" -eq 13 ]; then
        if [ -n "${expected_property:-}" ] &&
           ! grep -Fq "${expected_property} is violated" "$out"; then
          printf '  FAIL       %s: wrong property violated (expected %s)\n' \
            "$cfg" "$expected_property"
          tail -n 40 "$out" | sed 's/^/    /'
          fail=1
        else
          printf '  violation  %s (expected%s)\n' "$cfg" \
            "${expected_property:+: $expected_property}"
        fi
      else
        printf '  FAIL       %s: expected a violation, got exit %s\n' "$cfg" "$code"
        tail -n 40 "$out" | sed 's/^/    /'
        fail=1
      fi
      ;;
  esac
done <<EOF
$MANIFEST
EOF

if [ "$ran" -eq 0 ]; then
  echo "no matching configs" >&2
  exit 1
fi
exit "$fail"
