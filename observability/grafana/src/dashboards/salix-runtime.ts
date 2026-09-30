import { DashboardBuilder } from "@grafana/grafana-foundation-sdk/dashboard";

import type { DashboardEnvironment } from "../environments.js";
import { markdownPanel, statPanel, timeSeriesPanel } from "../shared/panels.js";
import { datasourceVariable, projectVariable } from "../shared/datasource.js";
import { businessAlertShadowContracts } from "../shadow-contracts.js";

export const salixRuntimeSlug = "salix-runtime";

export function buildSalixRuntime(environment: DashboardEnvironment) {
  const workloadUp = 'up{namespace="comma",workload="comma"}';
  const lazyContext =
    "Lazy Salix series. No data may mean no matching event occurred; compare the required workload scrape health above.";
  const managesBusinessAlerts = environment.name === "staging";
  const pagingContext = managesBusinessAlerts
    ? "Cloud Monitoring owns platform paging; the two bounded LLM queries below also feed staging-only Grafana P2 rules."
    : "Cloud Monitoring owns platform paging; no Grafana business-alert rule is managed for this environment.";
  const llmAlertCopy = managesBusinessAlerts
    ? [
        "**Grafana evaluates the adjacent queries as staging P2 rules; the panels themselves only explain the signals. Cloud Monitoring remains the platform paging owner.**",
        "",
        "- Logical-request error ratio: above 10% with at least 10 requests in 15 minutes.",
        "- LLM TTFT p95: above 30 seconds with at least 20 TTFT samples in 15 minutes.",
        "",
        "A point shows the current 15-minute window breaching. Grafana sends FIRING/RESOLVED to `#comma-app-alerts` only after the condition remains true for 15 continuous minutes. TTFT is provider-attempt and workload-wide; a missing billing surface currently normalizes to `system`. Do not infer end-to-end customer or surface impact from a point.",
      ]
    : [
        "**This environment has no managed Grafana business-alert rule. These panels are evaluation-only.**",
        "",
        "- Logical-request error ratio: above 10% with at least 10 requests in 15 minutes.",
        "- LLM TTFT p95: above 30 seconds with at least 20 TTFT samples in 15 minutes.",
      ];

  return new DashboardBuilder("Comma Salix Runtime")
    .uid(`${environment.uidPrefix}-${salixRuntimeSlug}`)
    .description(
      "Salix domain, Triage, VM, LLM, reporting, and recovery signals. All Salix metrics are lazy; only workload scrape health is required.",
    )
    .tags(["comma", "generated", environment.name, "salix"])
    .withVariable(datasourceVariable())
    .withVariable(projectVariable())
    .readonly()
    .refresh("1m")
    .time({ from: "now-6h", to: "now" })
    .timezone("browser")
    .withPanel(
      statPanel(
        environment,
        501,
        "Workload scrape health",
        "Required health for the workload that runs Salix. Missing series is a collection failure and is never synthesized as zero.",
        { x: 0, y: 0, w: 8, h: 5 },
        [
          {
            refId: "A",
            expression: `min by (workload) (${workloadUp})`,
            legend: "{{workload}}",
          },
        ],
      ),
    )
    .withPanel(
      markdownPanel(
        502,
        "Dashboard semantics",
        [
          "Every Salix signal below is event-driven or lazily created, including reporting queue depth. No data is not converted to zero.",
          "",
          `Use the required workload health above and [Platform Overview](/d/${environment.uidPrefix}-platform-overview) for scrape, rollout, resource, and shared dependency context. ${pagingContext}`,
          "",
          "- [Telemetry contracts](https://github.com/AFK-surf/Comma/blob/main/docs/observability.md)",
        ].join("\n"),
        { x: 8, y: 0, w: 16, h: 5 },
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        510,
        "Operations traffic / outcomes",
        `${lazyContext} Domain traffic and error outcomes are grouped by bounded component, operation, surface, and outcome.`,
        { x: 0, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, component, operation, surface, outcome) (rate(salix_operations_total{namespace="comma",workload="comma"}[5m]))',
            legend:
              "{{workload}} {{component}} {{operation}} {{surface}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        511,
        "Operations p95 latency",
        `${lazyContext} Latency is computed from histogram buckets.`,
        { x: 12, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (workload, le, component, surface) (rate(salix_operations_duration_seconds_bucket{namespace="comma",workload="comma"}[5m])))',
            legend: "{{workload}} {{component}} {{surface}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        520,
        "VM operations traffic / outcomes",
        `${lazyContext} VM traffic and error outcomes are grouped by bounded surface, provider, operation, and outcome.`,
        { x: 0, y: 13, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, surface, provider, operation, outcome) (rate(salix_vm_operations_total{namespace="comma",workload="comma"}[5m]))',
            legend:
              "{{workload}} {{surface}} {{provider}} {{operation}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        521,
        "VM operation p95 latency",
        `${lazyContext} Latency is computed from histogram buckets.`,
        { x: 12, y: 13, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (workload, le, surface, provider, operation) (rate(salix_vm_operations_duration_seconds_bucket{namespace="comma",workload="comma"}[5m])))',
            legend: "{{workload}} {{surface}} {{provider}} {{operation}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        530,
        "LLM logical requests / attempts",
        `${lazyContext} Logical request and provider-attempt rates remain separate so retries are visible without reconstructing business state.`,
        { x: 0, y: 21, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, surface, provider, model_key, outcome) (rate(salix_llm_requests_total{namespace="comma",workload="comma"}[5m]))',
            legend:
              "request {{workload}} {{surface}} {{provider}} {{model_key}} {{outcome}}",
          },
          {
            refId: "B",
            expression:
              'sum by (workload, surface, provider, model_key, outcome) (rate(salix_llm_attempts_total{namespace="comma",workload="comma"}[5m]))',
            legend:
              "attempt {{workload}} {{surface}} {{provider}} {{model_key}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        531,
        "LLM attempt p95 latency",
        `${lazyContext} Provider attempt latency uses the current singular attempt metric name.`,
        { x: 6, y: 21, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (workload, le, surface, provider, model_key) (rate(salix_llm_attempt_duration_seconds_bucket{namespace="comma",workload="comma"}[5m])))',
            legend: "{{workload}} {{surface}} {{provider}} {{model_key}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        532,
        "LLM TTFT p95",
        `${lazyContext} Time to first token is computed from histogram buckets.`,
        { x: 12, y: 21, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (workload, le, surface, provider, model_key) (rate(salix_llm_ttft_seconds_bucket{namespace="comma",workload="comma"}[5m])))',
            legend: "{{workload}} {{surface}} {{provider}} {{model_key}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        533,
        "LLM token rate",
        `${lazyContext} Tokens are grouped only by bounded surface, provider, model key, and kind.`,
        { x: 18, y: 21, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, surface, provider, model_key, kind) (rate(salix_llm_tokens_total{namespace="comma",workload="comma"}[5m]))',
            legend:
              "{{workload}} {{surface}} {{provider}} {{model_key}} {{kind}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        540,
        "Reporting queue depth",
        `${lazyContext} Queue depth itself is lazy and must not be treated as a required zero-valued gauge.`,
        { x: 0, y: 29, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (workload, sink) (salix_reporting_queue_depth{namespace="comma",workload="comma"})',
            legend: "{{workload}} {{sink}}",
          },
        ],
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        541,
        "Reporting rejection / drop rate",
        `${lazyContext} Queue-full events and dropped rows are shown without inventing a capacity threshold.`,
        { x: 6, y: 29, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, sink) (rate(salix_reporting_queue_full_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{sink}} queue full",
          },
          {
            refId: "B",
            expression:
              'sum by (workload, sink) (rate(salix_reporting_dropped_rows_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{sink}} dropped rows",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        542,
        "Reporting flush p95",
        `${lazyContext} Flush latency is computed from histogram buckets.`,
        { x: 12, y: 29, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (workload, le, sink) (rate(salix_reporting_flush_duration_seconds_bucket{namespace="comma",workload="comma"}[5m])))',
            legend: "{{workload}} {{sink}} p95",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        543,
        "Reporting flush failures",
        `${lazyContext} Count non-ok flush completions as failures.`,
        { x: 18, y: 29, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, sink, outcome) (rate(salix_reporting_flush_duration_seconds_count{namespace="comma",workload="comma",outcome!="ok"}[5m]))',
            legend: "{{workload}} {{sink}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        550,
        "VM state transitions",
        `${lazyContext} Transition rates are grouped by bounded surface, provider, and state.`,
        { x: 0, y: 37, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, surface, provider, state) (rate(salix_vm_transitions_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{surface}} {{provider}} {{state}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        551,
        "VM recovery scan work",
        `${lazyContext} Recovery scans are work signals, not a reconstructed runtime state projection.`,
        { x: 8, y: 37, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, surface, provider, state) (rate(salix_vm_recovery_scanned_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{surface}} {{provider}} {{state}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        552,
        "External status projections",
        `${lazyContext} Projection outcomes expose write failures without scanning business records.`,
        { x: 16, y: 37, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, outcome) (rate(salix_external_status_projections_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        553,
        "Derived-storage convergence passes",
        `${lazyContext} Sustained error outcomes need triage: before first completion they mean the derived data cannot converge (readiness held); after the durable completed_ever fact, a failed completion-marker write also reports error while readiness stays true (scheduling state only).`,
        { x: 0, y: 45, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, operation, outcome) (rate(salix_store_convergence_passes_total{namespace="comma",workload="comma"}[15m]))',
            legend: "{{workload}} {{operation}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        554,
        "Derived-storage convergence work",
        `${lazyContext} Converged volume is bootstrap progress on first pass and drift healing afterwards; failed records block pass completion.`,
        { x: 8, y: 45, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, operation) (rate(salix_store_convergence_converged_total{namespace="comma",workload="comma"}[15m]))',
            legend: "{{workload}} {{operation}} converged",
          },
          {
            refId: "B",
            expression:
              'sum by (workload, operation) (increase(salix_store_convergence_failed_total{namespace="comma",workload="comma"}[30m]))',
            legend: "{{workload}} {{operation}} failed",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        555,
        "S3 settlement outcomes",
        `${lazyContext} CAS and create-once ambiguity settlement is bounded. Sustained indeterminate or error outcomes mean the read-back budget is exhausting or storage is failing; precondition_failed and exists are proved competing-owner results.`,
        { x: 16, y: 45, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, mode, outcome) (rate(salix_storage_settlement_total{namespace="comma",workload="comma"}[15m]))',
            legend: "{{workload}} {{mode}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      markdownPanel(
        560,
        managesBusinessAlerts
          ? "Staging P2 alert contracts"
          : "Business alert evaluations",
        llmAlertCopy.join("\n"),
        { x: 0, y: 53, w: 8, h: 8 },
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        561,
        "LLM logical error breach",
        managesBusinessAlerts
          ? "Exact query used by staging P2 rule comma-stg-llm-error. A point is the 15-minute logical-request error ratio only when it exceeds 10% and the same window contains at least 10 requests."
          : "Evaluation only; no Grafana notification rule is managed for this environment. A point is the 15-minute logical-request error ratio only when it exceeds 10% and the same window contains at least 10 requests.",
        { x: 8, y: 53, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              businessAlertShadowContracts.llmLogicalRequestError
                .breachExpression,
            legend: "{{workload}} candidate breach",
          },
        ],
        "percentunit",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        562,
        "LLM TTFT breach",
        managesBusinessAlerts
          ? "Exact query used by staging P2 rule bfsralwg6q1hcd. A point is the 15-minute provider-attempt p95 only when it exceeds 30 seconds and the same window contains at least 20 TTFT samples. It is not end-to-end user latency."
          : "Evaluation only; no Grafana notification rule is managed for this environment. A point is the 15-minute provider-attempt p95 only when it exceeds 30 seconds and the same window contains at least 20 TTFT samples.",
        { x: 16, y: 53, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression: businessAlertShadowContracts.llmTtft.breachExpression,
            legend: "{{workload}} candidate breach",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        570,
        "User-dependency job outcomes",
        `${lazyContext} Timeout, saturation, and crash outcomes identify unhealthy user-owned dependencies without consuming agent-core capacity.`,
        { x: 0, y: 61, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, kind, outcome) (rate(salix_dependency_jobs_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{kind}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        571,
        "Dependency and event pressure",
        `${lazyContext} Compare active dependency work with detached Connector event backlog; sustained pressure should be read with timeout and saturation outcomes.`,
        { x: 12, y: 61, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (workload, kind) (salix_dependency_jobs_active{namespace="comma",workload="comma"})',
            legend: "{{workload}} {{kind}} active jobs",
          },
          {
            refId: "B",
            expression:
              'max by (workload) (salix_connector_external_event_queue_depth{namespace="comma",workload="comma"})',
            legend: "{{workload}} external-event queue",
          },
        ],
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        572,
        "Connector external-event outcomes",
        `${lazyContext} Completion and terminal/cache-hit outcomes should keep pace with accepted and retry outcomes; sustained retry, timeout, or saturation indicates dependency trouble.`,
        { x: 0, y: 69, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, outcome) (rate(salix_connector_external_events_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        573,
        "Connector ownership cleanup",
        `${lazyContext} Pending RPC and stream outcomes expose caller, deadline, capacity, and transport cleanup without high-cardinality operation identities.`,
        { x: 12, y: 69, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, transport, outcome) (rate(salix_connector_pending_rpcs_total{namespace="comma",workload="comma"}[5m]))',
            legend: "RPC {{workload}} {{transport}} {{outcome}}",
          },
          {
            refId: "B",
            expression:
              'sum by (workload, transport, outcome) (rate(salix_connector_read_streams_total{namespace="comma",workload="comma"}[5m]))',
            legend: "read {{workload}} {{transport}} {{outcome}}",
          },
          {
            refId: "C",
            expression:
              'sum by (workload, transport, outcome) (rate(salix_connector_write_streams_total{namespace="comma",workload="comma"}[5m]))',
            legend: "write {{workload}} {{transport}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        580,
        "Triage phase outcomes",
        `${lazyContext} Native-Triage progress and failures are grouped by bounded phase, outcome, and source mode labels.`,
        { x: 0, y: 77, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, phase, outcome, source_mode) (rate(salix_triage_phases_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{phase}} {{outcome}} {{source_mode}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        581,
        "Triage phase p95 latency",
        `${lazyContext} Native-Triage phase latency is computed from histogram buckets.`,
        { x: 6, y: 77, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (workload, le, phase, outcome) (rate(salix_triage_phase_duration_seconds_bucket{namespace="comma",workload="comma"}[5m])))',
            legend: "{{workload}} {{phase}} {{outcome}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        582,
        "Triage recovery backlog",
        `${lazyContext} Backlog is a bounded continuation-presence signal (0 or 1), not an exact global queue depth.`,
        { x: 12, y: 77, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (workload, lane) (salix_triage_recovery_backlog{namespace="comma",workload="comma"})',
            legend: "{{workload}} {{lane}}",
          },
        ],
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        583,
        "Triage recovery record errors",
        `${lazyContext} Sustained errors mean unreadable or invalid durable records are preventing a recovery lane from reporting clean progress.`,
        { x: 18, y: 77, w: 6, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, lane, outcome) (rate(salix_triage_recovery_record_errors_total{namespace="comma",workload="comma"}[15m]))',
            legend: "{{workload}} {{lane}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        590,
        "Meeting runtime-lost terminalizations",
        managesBusinessAlerts
          ? "Exact query used by staging P2 rule comma-stg-meeting-runtime-lost. A point counts meetings the summary watchdog terminalized as runtime_lost, i.e. attendees received an incomplete-record notice instead of a summary."
          : "Evaluation only; no Grafana notification rule is managed for this environment. A point counts meetings the summary watchdog terminalized as runtime_lost.",
        { x: 0, y: 85, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              businessAlertShadowContracts.meetingRuntimeLost.breachExpression,
            legend: "{{workload}} runtime-lost",
          },
        ],
        "short",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        591,
        "Meetings stuck without an anchor",
        managesBusinessAlerts
          ? "Exact query used by staging P2 rule comma-stg-meeting-stuck. A point counts dispatched, non-abandoned meetings the watchdog could not safely terminalize because every timestamp anchor was missing."
          : "Evaluation only; no Grafana notification rule is managed for this environment. A point counts dispatched meetings with no timestamp anchor.",
        { x: 8, y: 85, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              businessAlertShadowContracts.meetingStuckNonterminal
                .breachExpression,
            legend: "{{workload}} stuck",
          },
        ],
        "short",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        592,
        "Meeting delivery errors",
        managesBusinessAlerts
          ? "Exact query used by staging P2 rule comma-stg-meeting-delivery-error. Deliveries parked on a disabled connect report the retained outcome and are excluded, so this is genuine failure only."
          : "Evaluation only; no Grafana notification rule is managed for this environment. Deliveries parked on a disabled connect are excluded.",
        { x: 16, y: 85, w: 8, h: 8 },
        [
          {
            refId: "A",
            expression:
              businessAlertShadowContracts.meetingDeliveryError
                .breachExpression,
            legend: "{{workload}} delivery error",
          },
        ],
        "short",
      ),
    )
    .build();
}
