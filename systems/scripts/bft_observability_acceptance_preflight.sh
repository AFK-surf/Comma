#!/usr/bin/env bash
set -euo pipefail

# Queue-safe preflight for the BFT Operations/Observability acceptance pass.
# This script intentionally does not start services and does not run Mix.

COMMA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$COMMA_ROOT"

failures=0
passes=0

usage() {
  cat <<'EOF'
Usage:
  systems/scripts/bft_observability_acceptance_preflight.sh
  systems/scripts/bft_observability_acceptance_preflight.sh --print-serial-test-plan

The default mode checks that the local observability implementation still has
the contract files, UI entrypoints, and producer hooks.
It is safe to run while another local service slot is busy: no server is
started, no database is touched, and no Mix command is executed.
EOF
}

print_serial_test_plan() {
  cat <<'EOF'
# Run only when the local systems/test slot is available.
# Do not parallelize Mix commands for this worktree.

cd systems
mix format --check-formatted

mix test --seed 0 \
  apps/bridge_for_teams_core/test/contexts/observability_test.exs \
  apps/bridge_for_teams_core/test/contexts/observability_producer_test.exs \
  apps/bridge_for_teams_core/test/contexts/run_checks_test.exs \
  apps/bridge_for_teams_web/test/dashboard/operations_live_test.exs \
  apps/bridge_for_teams_web/test/mac_mini_provisioner_flow_test.exs

mix test --seed 0 \
  apps/bridge_for_teams_core/test/contexts/orgs_test.exs \
  apps/bridge_for_teams_core/test/contexts/projects_test.exs \
  apps/bridge_for_teams_core/test/contexts/memberships_test.exs \
  apps/bridge_for_teams_core/test/contexts/agents_test.exs \
  apps/bridge_for_teams_core/test/contexts/environments_test.exs \
  apps/bridge_for_teams_core/test/contexts/conversations_test.exs \
  apps/bridge_for_teams_core/test/contexts/schedules_test.exs \
  apps/bridge_for_teams_core/test/contexts/sites_test.exs \
  apps/bridge_for_teams_core/test/contexts/project_im_connects_test.exs \
  apps/bridge_for_teams_core/test/contexts/project_oauth_connections_test.exs \
  apps/bridge_for_teams_core/test/contexts/org_oauth_apps_test.exs \
  apps/bridge_for_teams_core/test/contexts/feishu_app_bindings_test.exs \
  apps/bridge_for_teams_core/test/contexts/salix_schedule_sink_test.exs \
  apps/bridge_for_teams_core/test/bridge_for_teams/salix/reconciler_test.exs \
  apps/bridge_for_teams_web/test/dashboard/settings_live_test.exs \
  apps/bridge_for_teams_web/test/dashboard/project_show_live_test.exs \
  apps/bridge_for_teams_web/test/dashboard/member_live_test.exs \
  apps/bridge_for_teams_web/test/dashboard/project_live_index_test.exs \
  apps/bridge_for_teams_web/test/dashboard/auth_controller_test.exs

cd ..
make test-policy

# Final gate after targeted failures are resolved.
make test-systems
EOF
}

ok() {
  passes=$((passes + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  failures=$((failures + 1))
  printf 'not ok - %s\n' "$1" >&2
}

section() {
  printf '\n== %s ==\n' "$1"
}

require_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    ok "command available: $command_name"
  else
    not_ok "command missing: $command_name"
  fi
}

require_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    ok "file exists: $path"
  else
    not_ok "missing file: $path"
  fi
}

require_fixed() {
  local label="$1"
  local needle="$2"
  shift 2

  if rg -q --fixed-strings -- "$needle" "$@"; then
    ok "$label"
  else
    not_ok "$label"
    printf '  expected fixed text: %s\n' "$needle" >&2
    printf '  files: %s\n' "$*" >&2
  fi
}

require_regex() {
  local label="$1"
  local pattern="$2"
  shift 2

  if rg -q -- "$pattern" "$@"; then
    ok "$label"
  else
    not_ok "$label"
    printf '  expected regex: %s\n' "$pattern" >&2
    printf '  files: %s\n' "$*" >&2
  fi
}

reject_regex() {
  local label="$1"
  local pattern="$2"
  shift 2

  if rg -q -- "$pattern" "$@"; then
    not_ok "$label"
    rg -n -- "$pattern" "$@" >&2 || true
  else
    ok "$label"
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --print-serial-test-plan)
    print_serial_test_plan
    exit 0
    ;;
  "")
    ;;
  *)
    usage >&2
    not_ok "unknown argument: $1"
    exit 1
    ;;
esac

section "Tooling"
require_command rg

section "Persisted contract files"
for path in \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/run_checks.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/adapter_diagnostic.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/producer.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/pruner.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/salix_im_sink.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/salix_schedule_sink.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/audit_log.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/check_result.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/observability_event.ex \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/operation_run.ex \
  systems/apps/bridge_for_teams_core/priv/repo/migrations/20260622000001_create_observability_tables.exs \
  systems/apps/bridge_for_teams_core/priv/repo/migrations/20260622000002_add_observability_event_correlation_dedupe.exs \
  systems/apps/bridge_for_teams_core/priv/repo/migrations/20260622000003_add_audit_log_link_to_observability_events.exs
do
  require_file "$path"
done

require_regex "observability context exposes event/run/check/audit/write boundaries" \
  "def (create_event|create_operation_run|record_run_checks|record_audit|record_write_attempt)" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability.ex
require_fixed "producer contract behavior exists" "defmodule BridgeForTeams.Observability.Producer" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/producer.ex
require_fixed "producer contract validates producer modules" "def validate_contract!" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/producer.ex
require_fixed "migration creates operation run table" "create table(:operation_runs" \
  systems/apps/bridge_for_teams_core/priv/repo/migrations/20260622000001_create_observability_tables.exs
require_fixed "migration creates check result table" "create table(:check_results" \
  systems/apps/bridge_for_teams_core/priv/repo/migrations/20260622000001_create_observability_tables.exs
require_fixed "migration creates event table" "create table(:observability_events" \
  systems/apps/bridge_for_teams_core/priv/repo/migrations/20260622000001_create_observability_tables.exs
require_fixed "audit logs are linked back into events" "audit_log_id" \
  systems/apps/bridge_for_teams_core/priv/repo/migrations/20260622000003_add_audit_log_link_to_observability_events.exs

section "Operations UI entrypoint"
for path in \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/live/operations_live/index.ex \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/controllers/operations_export_controller.ex \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/components/layouts.ex
do
  require_file "$path"
done

require_fixed "dashboard has primary Operations route" \
  "live(\"/orgs/:org/operations\", OperationsLive.Index, :overview)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "dashboard has Delivery tab route" \
  "live(\"/orgs/:org/operations/delivery\", OperationsLive.Index, :delivery)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "dashboard has Integrations tab route" \
  "live(\"/orgs/:org/operations/integrations\", OperationsLive.Index, :integrations)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "dashboard has Runners tab route" \
  "live(\"/orgs/:org/operations/runners\", OperationsLive.Index, :runners)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "dashboard has Events tab route" \
  "live(\"/orgs/:org/operations/events\", OperationsLive.Index, :events)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "dashboard has Checks tab route" \
  "live(\"/orgs/:org/operations/checks\", OperationsLive.Index, :checks)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "dashboard has Audit tab route" \
  "live(\"/orgs/:org/operations/audit\", OperationsLive.Index, :audit)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "dedicated Fin route remains wired to FinLive" \
  "live(\"/orgs/:org/fin\", FinLive.Index, :index)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "sidebar exposes Operations" "gettext(\"Operations\")" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/components/layouts.ex
require_fixed "audit CSV export route exists" \
  "get(\"/orgs/:org/operations/audit.csv\", OperationsExportController, :audit)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard_router.ex
require_fixed "audit CSV export records export audit" "audit_log.exported" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/controllers/operations_export_controller.ex
require_regex "Operations LiveView renders all tab containers" \
  "operations-(overview|delivery|integrations|runners|events|checks|audit)" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/live/operations_live/index.ex
require_fixed "audit view has an explicit denied state" "operations-audit-denied" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/live/operations_live/index.ex

section "Producer hooks"
require_fixed "IM diagnostics sink starts with BFT core" "BridgeForTeams.Observability.SalixIMSink" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/application.ex
require_fixed "schedule diagnostics sink starts with BFT core" "BridgeForTeams.Observability.SalixScheduleSink" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/application.ex
require_fixed "IM diagnostics sink declares a producer contract" "producer: :salix_im_diagnostics" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/salix_im_sink.ex
require_fixed "schedule diagnostics sink declares a producer contract" "producer: :salix_schedule_diagnostics" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/observability/salix_schedule_sink.ex
require_fixed "environment writes create operation runs" "Observability.create_operation_run" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/environments.ex
require_fixed "conversation writes create audit/write attempts" "Observability.record_write_attempt" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/conversations.ex
require_fixed "schedule writes create audit/write attempts" "Observability.record_write_attempt" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schedules.ex
require_fixed "project IM connect writes create audit/write attempts" "Observability.record_write_attempt" \
  systems/apps/bridge_for_teams_core/lib/bridge_for_teams/project_im_connects.ex
require_fixed "settings Run checks persist activity" "Observability.record_run_checks_activity" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/live/settings_live.ex
require_fixed "project Run checks persist activity" "Observability.record_run_checks_activity" \
  systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/dashboard/live/project_live/show.ex

section "Automated test anchors"
for path in \
  systems/apps/bridge_for_teams_core/test/contexts/observability_test.exs \
  systems/apps/bridge_for_teams_core/test/contexts/observability_producer_test.exs \
  systems/apps/bridge_for_teams_core/test/support/observability_case.ex \
  systems/apps/bridge_for_teams_core/test/contexts/run_checks_test.exs \
  systems/apps/bridge_for_teams_web/test/dashboard/operations_live_test.exs \
  systems/apps/bridge_for_teams_web/test/dashboard/fin_live_test.exs \
  systems/apps/bridge_for_teams_web/test/mac_mini_provisioner_flow_test.exs
do
  require_file "$path"
done

require_fixed "core tests cover redaction corpus" "redaction corpus covers secrets tokens provider payloads prompts messages and pii" \
  systems/apps/bridge_for_teams_core/test/contexts/observability_test.exs
require_fixed "core tests cover Fin markers" "records Fin run markers as linked run and event facts" \
  systems/apps/bridge_for_teams_core/test/contexts/observability_test.exs
require_fixed "core tests cover erasure boundary" "org erasure hard-deletes org-scoped Operations records" \
  systems/apps/bridge_for_teams_core/test/contexts/observability_test.exs
require_fixed "producer tests cover shared contract macro" "validates a producer contract declared with the shared macro" \
  systems/apps/bridge_for_teams_core/test/contexts/observability_producer_test.exs
require_fixed "producer tests cover runtime sink contracts" "validates the shipped runtime sink producer contracts" \
  systems/apps/bridge_for_teams_core/test/contexts/observability_producer_test.exs
require_fixed "producer test helper exists" "assert_observability_contract!" \
  systems/apps/bridge_for_teams_core/test/support/observability_case.ex
require_fixed "Run checks tests lock shared JSON shape" "serializes the shared dashboard result shape for CLI JSON output" \
  systems/apps/bridge_for_teams_core/test/contexts/run_checks_test.exs
require_fixed "UI tests cover primary Operations entry" "renders the Operations overview from the sidebar entry" \
  systems/apps/bridge_for_teams_web/test/dashboard/operations_live_test.exs
require_fixed "UI tests cover redacted persisted rows" "renders persisted observability events, checks, and audit records" \
  systems/apps/bridge_for_teams_web/test/dashboard/operations_live_test.exs
require_fixed "UI tests cover audit CSV export" "exports filtered audit logs as bounded redacted CSV" \
  systems/apps/bridge_for_teams_web/test/dashboard/operations_live_test.exs
require_fixed "UI tests cover member audit denial" "ordinary org members cannot view the audit surface" \
  systems/apps/bridge_for_teams_web/test/dashboard/operations_live_test.exs
require_fixed "UI tests cover dedicated Fin page" "renders the Fin sidebar page empty state" \
  systems/apps/bridge_for_teams_web/test/dashboard/fin_live_test.exs
require_fixed "provisioner tests cover unauthenticated marker rejection" \
  "Fin run marker ingestion requires authenticated provisioner source" \
  systems/apps/bridge_for_teams_web/test/mac_mini_provisioner_flow_test.exs

section "Local environment references"
require_fixed "systems README documents local runtime command" "mix run --no-halt" \
  systems/README.md
require_fixed "BFT dashboard README documents the 4101 dashboard port" "4101" \
  systems/apps/bridge_for_teams_web/README.md
require_fixed "runtime config supports local dashboard server flag" "bridge_for_teams dashboard server" \
  systems/config/runtime.exs
require_fixed "runtime config supports dev-login only outside prod" "bridge_for_teams dashboard dev_login" \
  systems/config/runtime.exs

printf '\n== Result ==\n'
if (( failures > 0 )); then
  printf 'BFT observability preflight failed: %d failed, %d passed.\n' "$failures" "$passes" >&2
  exit 1
fi

printf 'BFT observability preflight passed: %d checks.\n' "$passes"
printf 'Next: run --print-serial-test-plan when the local systems/test slot is available.\n'
