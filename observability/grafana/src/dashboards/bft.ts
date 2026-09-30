import { DashboardBuilder } from "@grafana/grafana-foundation-sdk/dashboard";

import type { DashboardEnvironment } from "../environments.js";
import { markdownPanel, statPanel, timeSeriesPanel } from "../shared/panels.js";
import { datasourceVariable, projectVariable } from "../shared/datasource.js";

export const bftSlug = "bft";

export function buildBft(environment: DashboardEnvironment) {
  const bftUp = 'up{namespace="comma",workload="comma"}';

  return new DashboardBuilder("Comma BFT")
    .uid(`${environment.uidPrefix}-${bftSlug}`)
    .description(
      "Bridge For Teams domain operations, read-cache, and sweeper signals. BFT metrics are lazy; workload scrape health is the required collection context.",
    )
    .tags(["comma", "generated", environment.name, "bft"])
    .withVariable(datasourceVariable())
    .withVariable(projectVariable())
    .readonly()
    .refresh("1m")
    .time({ from: "now-6h", to: "now" })
    .timezone("browser")
    .withPanel(
      statPanel(
        environment,
        301,
        "BFT workload scrape health",
        "Required health for the comma workload that emits BFT metrics. No data is abnormal and is never synthesized as zero.",
        { x: 0, y: 0, w: 8, h: 5 },
        [
          {
            refId: "A",
            expression: `min by (workload) (${bftUp})`,
            legend: "{{workload}}",
          },
        ],
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        310,
        "BFT operation traffic",
        "Lazy domain traffic by bounded operation, provider, and outcome. An empty window requires checking workload scrape health above.",
        { x: 0, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, operation, provider, outcome) (rate(bft_operations_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{operation}} {{provider}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        311,
        "BFT non-ok operations",
        "Lazy non-ok outcomes. Read an empty result with operation traffic and the required workload scrape-health panel; it is not rendered as zero.",
        { x: 12, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, operation, provider, outcome) (rate(bft_operations_total{namespace="comma",workload="comma",outcome!="ok"}[5m]))',
            legend: "{{workload}} {{operation}} {{provider}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        312,
        "BFT operation p95 latency",
        "Lazy operation latency computed from histogram buckets. Missing series can mean no matching operations; verify traffic and scrape health.",
        { x: 0, y: 13, w: 24, h: 8 },
        [
          {
            refId: "A",
            expression:
              'histogram_quantile(0.95, sum by (le, workload, operation) (rate(bft_operations_duration_seconds_bucket{namespace="comma",workload="comma"}[5m])))',
            legend: "{{workload}} {{operation}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        320,
        "BFT read-cache request rate",
        "Lazy cache demand by bounded result. No requests produce No data; check workload health before interpreting an empty window.",
        { x: 0, y: 21, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, result) (rate(bft_read_cache_requests_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{result}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        321,
        "BFT read-cache hit ratio",
        "Lazy hit ratio over observed cache requests. An idle window remains No data instead of becoming a synthetic success value.",
        { x: 12, y: 21, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload) (rate(bft_read_cache_requests_total{namespace="comma",workload="comma",result="hit"}[5m])) / sum by (workload) (rate(bft_read_cache_requests_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} hit ratio",
          },
        ],
        "percentunit",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        330,
        "BFT sweeper scanned rate",
        "Lazy artifact and storage sweep work by operation and outcome. Empty results require workload-health context and do not imply a successful sweep.",
        { x: 0, y: 29, w: 16, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (workload, operation, outcome) (rate(bft_sweeper_scanned_total{namespace="comma",workload="comma"}[5m]))',
            legend: "{{workload}} {{operation}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      markdownPanel(
        340,
        "Operational context",
        [
          "BFT metrics do not define a `surface` label. This dashboard preserves their real bounded dimensions and uses linked dashboards for shared or adjacent domain context.",
          "",
          `- [Platform Overview](/d/${environment.uidPrefix}-platform-overview) — workload, HTTP, runtime, database, and Kubernetes root-cause context`,
          `- [Salix Runtime](/d/${environment.uidPrefix}-salix-runtime) — agent, VM, LLM, and reporting dependencies`,
          `- [Billing](/d/${environment.uidPrefix}-billing) — billing operation and Stripe throttling context`,
          "- [Telemetry contracts](https://github.com/AFK-surf/Comma/blob/main/docs/observability.md)",
        ].join("\n"),
        { x: 16, y: 29, w: 8, h: 8 },
      ),
    )
    .build();
}
