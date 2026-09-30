import { DashboardBuilder } from "@grafana/grafana-foundation-sdk/dashboard";

import type { DashboardEnvironment } from "../environments.js";
import { markdownPanel, statPanel, timeSeriesPanel } from "../shared/panels.js";
import { datasourceVariable, projectVariable } from "../shared/datasource.js";

export const telemetryPipelineSlug = "telemetry-pipeline";

export function buildTelemetryPipeline(environment: DashboardEnvironment) {
  const collectorUp = 'up{namespace="comma",job="comma-otel-collector"}';

  return new DashboardBuilder("Comma Telemetry Pipeline")
    .uid(`${environment.uidPrefix}-${telemetryPipelineSlug}`)
    .description(
      "Application scrape and trace-pipeline health. Cloud Monitoring invariant alerts remain the only page owner.",
    )
    .tags(["comma", "generated", environment.name, "telemetry"])
    .withVariable(datasourceVariable())
    .withVariable(projectVariable())
    .readonly()
    .refresh("1m")
    .time({ from: "now-6h", to: "now" })
    .timezone("browser")
    .withPanel(
      statPanel(
        environment,
        201,
        "Application targets",
        "Required application scrape health, intentionally separate from Collector health.",
        { x: 0, y: 0, w: 8, h: 5 },
        [
          {
            refId: "A",
            expression: 'min by (workload) (up{namespace="comma",job="comma"})',
            legend: "{{workload}}",
          },
        ],
      ),
    )
    .withPanel(
      statPanel(
        environment,
        202,
        "Collector targets",
        "Required Collector scrape health. Healthy Collectors do not imply healthy application targets.",
        { x: 8, y: 0, w: 8, h: 5 },
        [
          {
            refId: "A",
            expression: `min by (pod) (${collectorUp})`,
            legend: "{{pod}}",
          },
        ],
      ),
    )
    .withPanel(
      statPanel(
        environment,
        203,
        "Collector revision",
        "Bounded rollout context for the Collector replicas.",
        { x: 16, y: 0, w: 8, h: 5 },
        [
          {
            refId: "A",
            expression: `count by (revision) (${collectorUp})`,
            legend: "{{revision}}",
          },
        ],
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        210,
        "Receiver accepted spans",
        "Per-instance receiver traffic; imbalance is expected with long-lived connections.",
        { x: 0, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (pod, receiver, transport) (rate({__name__="otelcol_receiver_accepted_spans__spans__total",namespace="comma"}[5m]))',
            legend: "{{pod}} {{receiver}}/{{transport}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        211,
        "Receiver refused spans",
        "Lazy failure series. Interpret an empty window with Collector up and accepted traffic; do not treat missing scrape data as healthy zero.",
        { x: 12, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (pod, receiver, transport) (rate({__name__="otelcol_receiver_refused_spans__spans__total",namespace="comma"}[5m]))',
            legend: "{{pod}} refused",
          },
          { refId: "B", expression: collectorUp, legend: "{{pod}} scrape up" },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        220,
        "Exporter sent spans",
        "Per-instance successful export attempts.",
        { x: 0, y: 13, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (pod, exporter) (rate({__name__="otelcol_exporter_sent_spans__spans__total",namespace="comma"}[5m]))',
            legend: "{{pod}} {{exporter}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        221,
        "Exporter send failures",
        "Lazy failure series shown with Collector scrape context. Cloud Monitoring owns paging.",
        { x: 12, y: 13, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression:
              'sum by (pod, exporter) (rate({__name__="otelcol_exporter_send_failed_spans__spans__total",namespace="comma"}[5m]))',
            legend: "{{pod}} failed",
          },
          { refId: "B", expression: collectorUp, legend: "{{pod}} scrape up" },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        230,
        "Exporter queue size / capacity",
        "Required queue capacity and current size. No data is abnormal; values are not synthesized.",
        { x: 0, y: 21, w: 16, h: 8 },
        [
          {
            refId: "A",
            expression:
              'max by (pod, exporter, data_type) ({__name__="otelcol_exporter_queue_size__batches_",namespace="comma"})',
            legend: "{{pod}} size",
          },
          {
            refId: "B",
            expression:
              'max by (pod, exporter, data_type) ({__name__="otelcol_exporter_queue_capacity__batches_",namespace="comma"})',
            legend: "{{pod}} capacity",
          },
        ],
      ),
    )
    .withPanel(
      markdownPanel(
        240,
        "Semantics and runbooks",
        [
          "Required health No data means collection is missing; it is never rendered as zero.",
          "",
          "Failure counters are lazy. Read them with application/Collector `up` and traffic context.",
          "",
          "- [Platform telemetry runbook](https://github.com/AFK-surf/Comma/blob/main/docs/observability.md)",
          "- [Cloud Monitoring invariant alerts](https://github.com/AFK-surf/Comma/blob/main/k8s/comma/cloud-monitoring/README.md)",
          "- [Telemetry contracts](https://github.com/AFK-surf/Comma/blob/main/docs/observability.md)",
        ].join("\n"),
        { x: 16, y: 21, w: 8, h: 8 },
      ),
    )
    .build();
}
