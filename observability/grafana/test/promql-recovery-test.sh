#!/usr/bin/env bash
set -euo pipefail

package_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
projection="$package_root/terraform/alerting-rules.json"
prometheus_image=${PROMETHEUS_IMAGE:-prom/prometheus:v2.44.0@sha256:0f0b7feb6f02620df7d493ad7437b6ee95b6d16d8d18799f3607124e501444b1}
test_root=$(mktemp -d "${TMPDIR:-/tmp}/comma-grafana-promql-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
chmod 755 "$test_root"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

query() {
  local uid=$1
  jq -er --arg uid "$uid" '
    .rules[]
    | select(.uid == $uid)
    | .data[]
    | select(.ref_id == "A")
    | .model.promQLQuery.expr
  ' "$projection"
}

llm_error_query=$(query comma-stg-llm-error)
ttft_query=$(query bfsralwg6q1hcd)
runtime_lost_query=$(query comma-stg-meeting-runtime-lost)
meeting_stuck_query=$(query comma-stg-meeting-stuck)
delivery_error_query=$(query comma-stg-meeting-delivery-error)

jq -n \
  --arg llm "$llm_error_query" \
  --arg ttft "$ttft_query" \
  --arg runtime_lost "$runtime_lost_query" \
  --arg meeting_stuck "$meeting_stuck_query" \
  --arg delivery_error "$delivery_error_query" '
  {
    groups: [{
      name: "comma-grafana-range-last",
      interval: "1m",
      rules: [
        {record: "comma_grafana_llm_error_breach", expr: $llm},
        {record: "comma_grafana_ttft_breach", expr: $ttft},
        {record: "comma_grafana_meeting_runtime_lost_breach", expr: $runtime_lost},
        {record: "comma_grafana_meeting_stuck_breach", expr: $meeting_stuck},
        {record: "comma_grafana_meeting_delivery_error_breach", expr: $delivery_error},
        {alert: "GrafanaLlmErrorRangeLast", expr: "last_over_time(comma_grafana_llm_error_breach[20m]) > 0", for: "15m"},
        {alert: "GrafanaTtftRangeLast", expr: "last_over_time(comma_grafana_ttft_breach[20m]) > 0", for: "15m"},
        {alert: "GrafanaMeetingRuntimeLostRangeLast", expr: "last_over_time(comma_grafana_meeting_runtime_lost_breach[20m]) > 0", for: "15m"},
        {alert: "GrafanaMeetingStuckRangeLast", expr: "last_over_time(comma_grafana_meeting_stuck_breach[20m]) > 0", for: "15m"},
        {alert: "GrafanaMeetingDeliveryErrorRangeLast", expr: "last_over_time(comma_grafana_meeting_delivery_error_breach[20m]) > 0", for: "15m"}
      ]
    }]
  }
' >"$test_root/rules.json"

jq -n \
  --arg llm "$llm_error_query" \
  --arg ttft "$ttft_query" \
  --arg runtime_lost "$runtime_lost_query" \
  --arg meeting_stuck "$meeting_stuck_query" \
  --arg delivery_error "$delivery_error_query" \
  --arg meeting_values "0 0 0 0 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1" '
  def series($name; $values): {series: $name, values: $values};
  def sample($value): {labels: "{workload=\"comma\"}", value: $value};
  def firing_alert($name): {exp_labels: {alertname: $name, workload: "comma"}};
  {
    rule_files: ["rules.json"],
    evaluation_interval: "1m",
    tests: [{
      name: "recovery emits zero and clears Grafana range-last pending state",
      interval: "1m",
      input_series: [
        series("salix_llm_requests_total{namespace=\"comma\",workload=\"comma\",outcome=\"ok\"}"; "0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 100 100 100 100 100 100 100 100 100 100 100 100 100 100 100"),
        series("salix_llm_requests_total{namespace=\"comma\",workload=\"comma\",outcome=\"error\"}"; "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3"),
        series("salix_llm_ttft_seconds_bucket{namespace=\"comma\",workload=\"comma\",le=\"1\"}"; "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1000 1000 1000 1000 1000 1000 1000 1000 1000 1000 1000 1000 1000 1000 1000"),
        series("salix_llm_ttft_seconds_bucket{namespace=\"comma\",workload=\"comma\",le=\"60\"}"; "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 20 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020"),
        series("salix_llm_ttft_seconds_bucket{namespace=\"comma\",workload=\"comma\",le=\"+Inf\"}"; "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 20 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020"),
        series("salix_llm_ttft_seconds_count{namespace=\"comma\",workload=\"comma\"}"; "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 20 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020 1020"),
        series("salix_operations_total{namespace=\"comma\",workload=\"comma\",component=\"salix_meet\",operation=\"meeting_watchdog\",surface=\"system\",outcome=\"ok\"}"; $meeting_values),
        series("salix_operations_total{namespace=\"comma\",workload=\"comma\",component=\"salix_meet\",operation=\"meeting_stuck_nonterminal\",surface=\"system\",outcome=\"retained\"}"; $meeting_values),
        series("salix_operations_total{namespace=\"comma\",workload=\"comma\",component=\"salix_meet\",operation=\"meeting_delivery\",surface=\"system\",outcome=\"error\"}"; $meeting_values)
      ],
      promql_expr_test: [
        {expr: $llm, eval_time: "15m", exp_samples: [sample(0.16666666666666666)]},
        {expr: $ttft, eval_time: "15m", exp_samples: [sample(57.05)]},
        {expr: $llm, eval_time: "16m", exp_samples: [sample(0)]},
        {expr: $ttft, eval_time: "16m", exp_samples: [sample(0)]},
        {expr: $runtime_lost, eval_time: "40m", exp_samples: [sample(0)]},
        {expr: $meeting_stuck, eval_time: "40m", exp_samples: [sample(0)]},
        {expr: $delivery_error, eval_time: "40m", exp_samples: [sample(0)]}
      ],
      alert_rule_test: [
        {eval_time: "30m", alertname: "GrafanaLlmErrorRangeLast", exp_alerts: []},
        {eval_time: "30m", alertname: "GrafanaTtftRangeLast", exp_alerts: []},
        {eval_time: "25m", alertname: "GrafanaMeetingRuntimeLostRangeLast", exp_alerts: [firing_alert("GrafanaMeetingRuntimeLostRangeLast")]},
        {eval_time: "25m", alertname: "GrafanaMeetingStuckRangeLast", exp_alerts: [firing_alert("GrafanaMeetingStuckRangeLast")]},
        {eval_time: "25m", alertname: "GrafanaMeetingDeliveryErrorRangeLast", exp_alerts: [firing_alert("GrafanaMeetingDeliveryErrorRangeLast")]},
        {eval_time: "60m", alertname: "GrafanaMeetingRuntimeLostRangeLast", exp_alerts: []},
        {eval_time: "60m", alertname: "GrafanaMeetingStuckRangeLast", exp_alerts: []},
        {eval_time: "60m", alertname: "GrafanaMeetingDeliveryErrorRangeLast", exp_alerts: []}
      ]
    }]
  }
' >"$test_root/test.json"

if command -v promtool >/dev/null; then
  promtool test rules "$test_root/test.json"
elif command -v docker >/dev/null; then
  docker run --rm \
    --entrypoint /bin/promtool \
    -v "$test_root:/work:ro" \
    "$prometheus_image" \
    test rules /work/test.json
else
  echo "promtool or Docker is required" >&2
  exit 2
fi
