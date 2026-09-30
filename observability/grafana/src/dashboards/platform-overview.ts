import { DashboardBuilder } from "@grafana/grafana-foundation-sdk/dashboard";

import type { DashboardEnvironment } from "../environments.js";
import { markdownPanel, statPanel, timeSeriesPanel } from "../shared/panels.js";
import { datasourceVariable, projectVariable } from "../shared/datasource.js";
import { businessAlertShadowContracts } from "../shadow-contracts.js";

export const platformOverviewSlug = "platform-overview";

export function buildPlatformOverview(environment: DashboardEnvironment) {
  const managesBusinessAlerts = environment.name === "staging";
  const imAlertCopy = managesBusinessAlerts
    ? [
        "**Alert ownership moved on 2026-08-12: the Cloud Monitoring policy `comma_alerting:im_ingress_5xx` owns IM ingress alerting (attributed failure-ratio over the `im_ingress` operation metric). The repo manages no Grafana rule for this panel; the legacy `comma-stg-im-5xx` rule stays live only until the pending admin terraform apply removes it.**",
        "",
        "This panel keeps the HTTP-layer view: `/v1/im/*` 5xx ratio above 5% with at least 20 requests in 15 minutes. 4xx is deliberately excluded here.",
        "",
        "A point shows the current 15-minute window breaching at the HTTP layer. The alerting contract, outcome classes, and recovery semantics live in docs/observability.md. Compare with scrape health and HTTP traffic before assigning impact.",
      ]
    : [
        "**This environment has no managed Grafana business-alert rule. The panel is evaluation-only.**",
        "",
        "Candidate contract: `/v1/im/*` 5xx ratio above 5% with at least 20 requests in 15 minutes. 4xx is deliberately excluded.",
      ];
  const applicationSelector = 'namespace="comma",job="comma"';
  const environmentLabel =
    environment.name.charAt(0).toUpperCase() + environment.name.slice(1);

  return new DashboardBuilder("Comma Platform Overview")
    .uid(`${environment.uidPrefix}-${platformOverviewSlug}`)
    .description(
      `${environmentLabel} platform health and shared runtime signals, published by read-only Git Sync. No data on required health panels is abnormal.`,
    )
    .tags(["comma", "generated", environment.name, "platform"])
    .withVariable(datasourceVariable())
    .withVariable(projectVariable())
    .readonly()
    .refresh("1m")
    .time({ from: "now-6h", to: "now" })
    .timezone("browser")
    .withPanel(
      statPanel(
        environment,
        101,
        "Application scrape health",
        "Required health. Missing series is a collection failure and is never synthesized as zero.",
        { x: 0, y: 0, w: 8, h: 5 },
        [
          {
            refId: "A",
            expression: `min by (workload) (up{${applicationSelector}})`,
            legend: "{{workload}}",
          },
        ],
      ),
    )
    .withPanel(
      statPanel(
        environment,
        102,
        "Workload ready / desired",
        "Required Kubernetes readiness. Compare ready and desired series; No data is abnormal.",
        { x: 8, y: 0, w: 8, h: 5 },
        [
          {
            refId: "A",
            expression:
              'label_replace(kube_statefulset_status_replicas_ready{namespace="comma",statefulset="comma"}, "workload", "$1", "statefulset", "(.*)")',
            legend: "{{workload}} ready",
          },
          {
            refId: "B",
            expression:
              'label_replace(kube_statefulset_replicas{namespace="comma",statefulset="comma"}, "workload", "$1", "statefulset", "(.*)")',
            legend: "{{workload}} desired",
          },
        ],
      ),
    )
    .withPanel(
      statPanel(
        environment,
        103,
        "Active revision targets",
        "Rollout context grouped by bounded workload and revision labels.",
        { x: 16, y: 0, w: 8, h: 5 },
        [
          {
            refId: "A",
            expression: `count by (workload, revision) (up{${applicationSelector}})`,
            legend: "{{workload}} {{revision}}",
          },
        ],
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        110,
        "HTTP request rate",
        "Application request traffic by bounded endpoint and status class.",
        { x: 0, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, endpoint, status_class) (rate(comma_system_http_requests_total{namespace="comma"}[5m]))',
            legend: "{{workload}} {{endpoint}} {{status_class}}",
          },
        ],
        "reqps",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        111,
        "HTTP error rate",
        "Event-driven error series is interpreted with the request-traffic panel; an empty error window is not proof of scrape health.",
        { x: 12, y: 5, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, endpoint, status_class) (rate(comma_system_http_requests_total{namespace="comma",status_class=~"4xx|5xx"}[5m]))',
            legend: "{{workload}} {{endpoint}} {{status_class}}",
          },
        ],
        "reqps",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        112,
        "HTTP p95 latency",
        "Histogram latency computed from buckets with rate and histogram_quantile.",
        { x: 18, y: 5, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (le, workload, endpoint) (rate(comma_system_http_duration_seconds_bucket{namespace="comma"}[5m])))',
            legend: "{{workload}} {{endpoint}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        120,
        "BEAM memory",
        "Maximum BEAM memory by workload.",
        { x: 0, y: 13, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (workload) (comma_system_beam_memory_bytes{namespace="comma"})',
            legend: "{{workload}}",
          },
        ],
        "bytes",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        121,
        "BEAM run queue",
        "Scheduler pressure by workload.",
        { x: 6, y: 13, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (workload) (comma_system_beam_run_queue{namespace="comma"})',
            legend: "{{workload}}",
          },
        ],
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        122,
        "BEAM processes / ports",
        "Bounded runtime resource context.",
        { x: 12, y: 13, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (workload) (comma_system_beam_processes{namespace="comma"})',
            legend: "{{workload}} processes",
          },
          {
            refId: "B",
            expression:
              'max by (workload) (comma_system_beam_ports{namespace="comma"})',
            legend: "{{workload}} ports",
          },
        ],
      ),
    )
    .withPanel(
      statPanel(
        environment,
        123,
        "Current exported series",
        "Required per-target cardinality signal. No data is abnormal.",
        { x: 18, y: 13, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (workload, pod) (comma_system_telemetry_series_current{namespace="comma"})',
            legend: "{{workload}} {{pod}}",
          },
        ],
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        130,
        "DB query traffic",
        "Database operations by bounded component, repository, and outcome.",
        { x: 0, y: 21, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, component, repo, outcome) (rate(comma_system_db_queries_total{namespace="comma"}[5m]))',
            legend: "{{workload}} {{component}} {{repo}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        131,
        "DB query p95",
        "Database latency from histogram buckets.",
        { x: 8, y: 21, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (le, workload, component, repo) (rate(comma_system_db_duration_seconds_bucket{namespace="comma"}[5m])))',
            legend: "{{workload}} {{component}} {{repo}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        132,
        "DB pool wait p95",
        "Pool contention from histogram buckets.",
        { x: 16, y: 21, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (le, workload, component, repo) (rate(comma_system_db_pool_wait_seconds_bucket{namespace="comma"}[5m])))',
            legend: "{{workload}} {{component}} {{repo}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        140,
        "Container CPU",
        "GKE cAdvisor CPU usage for Comma application containers.",
        { x: 0, y: 29, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="comma",container="comma"}[5m]))',
            legend: "{{pod}}",
          },
        ],
        "cores",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        141,
        "Container working set",
        "GKE cAdvisor memory working set for Comma application containers.",
        { x: 8, y: 29, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (pod) (container_memory_working_set_bytes{namespace="comma",container="comma"})',
            legend: "{{pod}}",
          },
        ],
        "bytes",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        142,
        "Container restarts",
        "Cloud Monitoring native restart counter normalized to pod labels and shown with increase to tolerate resets.",
        { x: 16, y: 29, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (pod) (label_replace(increase({__name__="kubernetes.io/container/restart_count",monitored_resource="k8s_container",namespace_name="comma",container_name="comma"}[15m]), "pod", "$1", "pod_name", "(.*)"))',
            legend: "{{pod}}",
          },
        ],
      ),
    )
    .withPanel(
      markdownPanel(
        150,
        managesBusinessAlerts
          ? "Staging P2 alert contract"
          : "Business alert evaluation",
        imAlertCopy.join("\n"),
        { x: 0, y: 37, w: 8, h: 8 },
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        151,
        "IM ingress 5xx breach",
        managesBusinessAlerts
          ? "HTTP-layer companion view for Cloud Monitoring policy comma_alerting:im_ingress_5xx (the alert itself evaluates the im_ingress operation metric). A point is the 15-minute 5xx ratio only when it exceeds 5% and the same window contains at least 20 requests. No data is not proof of health; check required scrape health and route traffic."
          : "Evaluation only; no notification rule is managed for this environment. A point is the 15-minute 5xx ratio only when it exceeds 5% and the same window contains at least 20 requests.",
        { x: 8, y: 37, w: 16, h: 8 },
        [
          {
            refId: "A",
            expression:
              businessAlertShadowContracts.imIngress5xx.breachExpression,
            legend: "{{workload}} candidate breach",
          },
        ],
        "percentunit",
      ),
    )
    .build();
}
