import { DashboardBuilder } from "@grafana/grafana-foundation-sdk/dashboard";

import type { DashboardEnvironment } from "../environments.js";
import { markdownPanel, statPanel, timeSeriesPanel } from "../shared/panels.js";
import { datasourceVariable, projectVariable } from "../shared/datasource.js";

export const commaProductSlug = "comma-product";

export function buildCommaProduct(environment: DashboardEnvironment) {
  const selector = 'namespace="comma",workload="comma"';
  const workloadUp = `up{${selector}}`;

  return new DashboardBuilder("Comma Product Operations")
    .uid(`${environment.uidPrefix}-${commaProductSlug}`)
    .description(
      "Comma Product traffic and lazy backlog outcomes. Platform Overview owns shared dependencies.",
    )
    .tags(["comma", "generated", environment.name, "comma-product"])
    .withVariable(datasourceVariable())
    .withVariable(projectVariable())
    .readonly()
    .refresh("1m")
    .time({ from: "now-6h", to: "now" })
    .timezone("browser")
    .withPanel(
      statPanel(
        environment,
        401,
        "Workload scrape health",
        "Required health. No data is abnormal.",
        { x: 0, y: 0, w: 12, h: 5 },
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
      timeSeriesPanel(
        environment,
        410,
        "Operation traffic",
        "Lazy product and auth-dependency series by bounded operation/provider/outcome.",
        { x: 0, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload, operation, provider, outcome) (rate(comma_product_operations_total{${selector}}[5m]))`,
            legend: "{{operation}} {{provider}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        411,
        "Non-ok operation rate",
        "Lazy non-ok outcomes shown with scrape context; empty can mean no event.",
        { x: 12, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload, operation, provider, outcome) (rate(comma_product_operations_total{${selector},outcome!="ok"}[5m]))`,
            legend: "{{operation}} {{provider}} {{outcome}}",
          },
          {
            refId: "B",
            expression: workloadUp,
            legend: "{{workload}} scrape up",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        412,
        "Operation p95 latency",
        "Histogram p95 for operations that occurred in the selected window.",
        { x: 0, y: 13, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `histogram_quantile(0.95, sum by (le, workload, operation) (rate(comma_product_operations_duration_seconds_bucket{${selector}}[5m])))`,
            legend: "{{operation}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        420,
        "Backlog retry / terminal failure",
        "Lazy backlog outcomes. No data is interpreted with workload traffic and up, never as healthy zero.",
        { x: 12, y: 13, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload, queue) (rate(comma_product_backlog_retries_total{${selector}}[5m]))`,
            legend: "{{queue}} retry",
          },
          {
            refId: "B",
            expression: `sum by (workload, queue) (rate(comma_product_backlog_terminal_failures_total{${selector}}[5m]))`,
            legend: "{{queue}} terminal",
          },
          {
            refId: "C",
            expression: workloadUp,
            legend: "{{workload}} scrape up",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        421,
        "Durable backlog depth",
        "Current bounded Comma work by queue. No data is interpreted with workload scrape health, never as an empty queue.",
        { x: 0, y: 21, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `max by (workload, queue) (comma_product_backlog_depth{${selector}})`,
            legend: "{{queue}}",
          },
        ],
        "short",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        422,
        "Oldest durable work",
        "Age of the oldest scheduled Comma work by bounded queue. Sustained growth indicates convergence debt.",
        { x: 12, y: 21, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `max by (workload, queue) (comma_product_backlog_oldest_age_seconds{${selector}})`,
            legend: "{{queue}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        423,
        "Recommendation runs",
        "Manual, scheduled, and agent-tool recommendation runs by bounded trigger and terminal outcome.",
        { x: 0, y: 29, w: 24, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload, trigger, outcome) (rate(comma_product_recommendation_runs_total{${selector}}[5m]))`,
            legend: "{{trigger}} {{outcome}}",
          },
          {
            refId: "B",
            expression: workloadUp,
            legend: "{{workload}} scrape up",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        424,
        "OAuth IdP requests",
        "IdP endpoint traffic by semantic outcome. Rejections include 302 error redirects back to the client; login_redirect is the logged-out stash hop. Lazy series: appears once the IdP flag is on and traffic arrives.",
        { x: 0, y: 37, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload, endpoint, outcome) (rate(comma_product_oauth_idp_requests_total{${selector}}[5m]))`,
            legend: "{{endpoint}} {{outcome}}",
          },
          {
            refId: "B",
            expression: workloadUp,
            legend: "{{workload}} scrape up",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        425,
        "OAuth IdP token issuance",
        "Aggregate Continue-with-Comma issuance rate. Deliberately label-free; per-client detail lives in the structured issuance log, never a metric label.",
        { x: 12, y: 37, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload) (rate(comma_product_oauth_idp_issuance_total{${selector}}[15m]))`,
            legend: "{{workload}} issuance",
          },
          {
            refId: "B",
            expression: workloadUp,
            legend: "{{workload}} scrape up",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      markdownPanel(
        430,
        "Context",
        `[Platform Overview](/d/${environment.uidPrefix}-platform-overview) owns workload readiness, CPU, memory, and database root cause. Lazy product series appear only after the corresponding event.`,
        { x: 0, y: 45, w: 24, h: 4 },
      ),
    )
    .build();
}
