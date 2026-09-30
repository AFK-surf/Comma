import { DashboardBuilder } from "@grafana/grafana-foundation-sdk/dashboard";

import type { DashboardEnvironment } from "../environments.js";
import { markdownPanel, statPanel, timeSeriesPanel } from "../shared/panels.js";
import { datasourceVariable, projectVariable } from "../shared/datasource.js";

export const billingSlug = "billing";

export function buildBilling(environment: DashboardEnvironment) {
  const selector = 'namespace="comma",workload="comma"';
  const workloadUp = `up{${selector}}`;

  return new DashboardBuilder("Billing Operations")
    .uid(`${environment.uidPrefix}-${billingSlug}`)
    .description(
      "Billing traffic, outcomes, latency, and Stripe rate limits. All billing metrics are lazy event series.",
    )
    .tags(["comma", "generated", environment.name, "billing"])
    .withVariable(datasourceVariable())
    .withVariable(projectVariable())
    .readonly()
    .refresh("1m")
    .time({ from: "now-6h", to: "now" })
    .timezone("browser")
    .withPanel(
      statPanel(
        environment,
        601,
        "Workload scrape health",
        "Required context for both billing surfaces. No data is abnormal.",
        { x: 0, y: 0, w: 24, h: 5 },
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
        610,
        "Billing operation traffic",
        "Lazy operation traffic by bounded surface and outcome.",
        { x: 0, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload, surface, operation, provider, outcome) (rate(billing_operations_total{${selector}}[5m]))`,
            legend: "{{workload}} {{surface}} {{operation}} {{outcome}}",
          },
        ],
        "ops",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        611,
        "Non-ok billing rate",
        "Lazy non-ok outcomes shown with scrape context.",
        { x: 12, y: 5, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload, surface, operation, provider, outcome) (rate(billing_operations_total{${selector},outcome!="ok"}[5m]))`,
            legend: "{{workload}} {{surface}} {{operation}} {{outcome}}",
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
        612,
        "Billing p95 latency",
        "Histogram p95 for billing operations that occurred.",
        { x: 0, y: 13, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `histogram_quantile(0.95, sum by (le, workload, surface, operation) (rate(billing_operations_duration_seconds_bucket{${selector}}[5m])))`,
            legend: "{{workload}} {{surface}} {{operation}}",
          },
        ],
        "s",
      ),
    )
    .withPanel(
      timeSeriesPanel(
        environment,
        620,
        "Stripe rate limits",
        "Lazy saturation signal. Empty means no observed rate-limit event only when scrape context is healthy.",
        { x: 12, y: 13, w: 12, h: 8 },
        [
          {
            refId: "A",
            expression: `sum by (workload, surface) (rate(billing_stripe_rate_limits_total{${selector}}[5m]))`,
            legend: "{{workload}} {{surface}}",
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
        630,
        "Context",
        `[Platform Overview](/d/${environment.uidPrefix}-platform-overview) owns shared runtime/dependency root cause. [Salix Runtime](/d/${environment.uidPrefix}-salix-runtime) owns downstream VM/LLM context.`,
        { x: 0, y: 21, w: 24, h: 4 },
      ),
    )
    .build();
}
